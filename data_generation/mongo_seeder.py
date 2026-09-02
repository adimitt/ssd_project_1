#!/usr/bin/env python3
"""
BiteStream :: mongo_seeder.py
=============================

Generates the MongoDB dataset: 1k nested Menus, 200k Reviews and 500k+ geospatial
DriverPings.

THE CROSS-DATABASE CONTRACT
---------------------------
This script CONNECTS TO POSTGRES FIRST and reads the real restaurant ids and coordinates
out of it. That is the whole point: there is no foreign key between the two engines, so
the only thing keeping restaurant_id consistent across them is a deliberate, documented
data-loading step. If Postgres has not been seeded, this script refuses to run rather
than inventing ids that point at nothing.

THE TWO TRAPS THIS FILE IS BUILT AROUND
---------------------------------------
1. TTL WILL DELETE YOUR DATA BEFORE THE VIVA.
   DriverPings.created_at carries expireAfterSeconds: 7200. Any ping older than two hours
   is removed within roughly 60 seconds of the reaper's next pass. Seeding pings dated
   "over the last week" leaves the collection EMPTY minutes later, and both the $geoNear
   demo and the executionStats capture then return nothing.
   Handled by: every ping is timestamped inside the window (now - 0..6900s), the TTL index
   is built AFTER the load, and --fresh makes a re-run take seconds.
   >>> RE-RUN THIS SCRIPT IMMEDIATELY BEFORE THE VIVA. <<<

2. RANDOM GLOBAL COORDINATES RETURN NOTHING WITHIN 5 km.
   Uniform [-180,180] x [-90,90] places approximately zero drivers near any restaurant, so
   the Workflow 3 pipeline would be technically correct and return an empty result set.
   Handled by: pings are clustered around real restaurant coordinates with a Gaussian
   jitter, and the longitude offset is divided by cos(latitude) so the cluster is circular
   on the ground rather than an ellipse.

ORDER OF OPERATIONS
-------------------
    drop -> create with validator -> bulk insert_many -> create indexes -> verify
Indexes go last: building them first makes the load several times slower, because every
inserted document must be threaded into three B-trees as it lands.

USAGE
    python3 data_generation/mongo_seeder.py
    python3 data_generation/mongo_seeder.py --scale 0.05      # quick smoke test
    python3 data_generation/mongo_seeder.py --pings-only      # refresh telemetry pre-viva

CONNECTION
    MONGO_URI  (default mongodb://127.0.0.1:27017)
    PGHOST / PGPORT / PGDATABASE / PGUSER / PGPASSWORD
"""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import random
import sys
import time
from datetime import datetime, timedelta, timezone

import psycopg
from bson.decimal128 import Decimal128
from faker import Faker
from pymongo import MongoClient

SEED = 42
random.seed(SEED)
Faker.seed(SEED)
fake = Faker("en_IN")

N_REVIEWS = 200_000
# The brief requires "at least 500,000" pings. Seeding exactly 500,000 sits ON the
# threshold, which is fragile for two reasons: the TTL reaper starts deleting immediately,
# and any off-by-a-batch in the loader would drop the total below the requirement. 520,000
# gives a 4% margin at no meaningful cost (~1s more load time).
N_PINGS = 520_000
N_DRIVERS = 4_000
BATCH = 10_000                # documents per insert_many call
TTL_SECONDS = 7_200           # must match ix_pings_ttl in the schema map
PING_MAX_AGE = 6_900          # < TTL_SECONDS, so nothing expires mid-load
EXPIRING_SOON = 200           # pings deliberately seeded ~50s from expiry, for the demo
REVIEW_HISTORY_DAYS = 540

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA_MAP = REPO_ROOT / "docs" / "mongo_schema_map.json"

TAG_VOCAB = [
    "fast-delivery", "late", "hot-food", "cold-food", "good-packaging", "spilled",
    "value-for-money", "overpriced", "generous-portion", "small-portion", "fresh",
    "stale", "polite-driver", "rude-driver", "accurate-order", "missing-item",
    "well-spiced", "bland", "crispy", "soggy", "great-taste", "reheated",
    "eco-packaging", "easy-to-find", "hard-to-find",
]
POSITIVE_TAGS = {"fast-delivery", "hot-food", "good-packaging", "value-for-money",
                 "generous-portion", "fresh", "polite-driver", "accurate-order",
                 "well-spiced", "crispy", "great-taste", "eco-packaging", "easy-to-find"}

CATEGORY_TEMPLATES = {
    "Starters":  ["Paneer Tikka", "Chicken 65", "Gobi Manchurian", "Veg Spring Roll"],
    "Biryani":   ["Hyderabadi Dum Biryani", "Veg Biryani", "Egg Biryani", "Mutton Biryani"],
    "Breads":    ["Butter Naan", "Tandoori Roti", "Laccha Paratha"],
    "Mains":     ["Dal Tadka", "Butter Chicken", "Palak Paneer", "Kadai Veg"],
    "Desserts":  ["Gulab Jamun", "Rasmalai", "Double ka Meetha"],
    "Beverages": ["Masala Chai", "Sweet Lassi", "Fresh Lime Soda"],
}
ADDON_GROUPS = [
    ("Spice level", 0, 1, [("Mild", "0.00"), ("Medium", "0.00"), ("Extra hot", "0.00")]),
    ("Add-ons",     0, 3, [("Extra gravy", "40.00"), ("Extra raita", "30.00"),
                           ("Boiled egg", "25.00")]),
    ("Portion",     0, 1, [("Regular", "0.00"), ("Family pack", "180.00")]),
]


def log(msg: str) -> None:
    print(f"[mongo_seeder] {msg}", flush=True)


def pg_dsn() -> str:
    return (
        f"host={os.getenv('PGHOST', '127.0.0.1')} "
        f"port={os.getenv('PGPORT', '5432')} "
        f"dbname={os.getenv('PGDATABASE', 'bitestream')} "
        f"user={os.getenv('PGUSER', 'bs')} "
        f"password={os.getenv('PGPASSWORD', 'bs')}"
    )


# ======================================================================================
# Cross-database read
# ======================================================================================
def load_restaurants_from_postgres() -> tuple[list[tuple], int, int]:
    """
    Pull (id, name, city, latitude, longitude) plus the id ceilings for users and orders.

    These are the join keys the Mongo documents will carry. Nothing enforces them at the
    database level - this function IS the enforcement, and its absence is exactly the
    weakness of polyglot persistence that the README documents.
    """
    log("reading restaurants + id ranges from PostgreSQL (the cross-DB join contract)")
    with psycopg.connect(pg_dsn()) as conn, conn.cursor() as cur:
        cur.execute("SELECT id, name, city, latitude, longitude FROM restaurants ORDER BY id")
        restaurants = cur.fetchall()
        cur.execute("SELECT COALESCE(MAX(id), 0) FROM users")
        max_user = cur.fetchone()[0]
        cur.execute("SELECT COALESCE(MAX(id), 0) FROM orders")
        max_order = cur.fetchone()[0]

    if not restaurants:
        sys.exit(
            "ERROR: no restaurants in PostgreSQL.\n"
            "       Run data_generation/postgres_seeder.py first - the Mongo documents\n"
            "       carry PostgreSQL ids and must not invent them."
        )
    log(f"  {len(restaurants):,} restaurants, users 1..{max_user:,}, orders 1..{max_order:,}")
    return restaurants, max_user, max_order


# ======================================================================================
# Document generators
# ======================================================================================
def gen_menu(rid: int, name: str, city: str, lat: float, lng: float,
             now: datetime) -> dict:
    """One deeply nested catalogue document per restaurant (categories -> items -> addons)."""
    categories = []
    for cat_name in random.sample(list(CATEGORY_TEMPLATES), random.randint(3, 6)):
        items = []
        for item_name in random.sample(CATEGORY_TEMPLATES[cat_name],
                                       random.randint(2, len(CATEGORY_TEMPLATES[cat_name]))):
            addons = []
            for grp, lo, hi, opts in random.sample(ADDON_GROUPS, random.randint(0, 2)):
                addons.append({
                    "group": grp,
                    "min": lo,
                    "max": hi,
                    # Decimal128 mirrors Postgres NUMERIC. A double would reintroduce the
                    # exact floating-point money bug the relational side avoids.
                    "options": [{"name": o, "price": Decimal128(p)} for o, p in opts],
                })
            items.append({
                "item_id": f"r{rid}-i{len(items) + 1}",
                "name": item_name,
                "price": Decimal128(f"{random.randrange(79, 649):d}.00"),
                "veg": random.random() > 0.45,
                "tags": random.sample(["bestseller", "spicy", "chef-special", "new"],
                                      random.randint(0, 2)),
                "addons": addons,
            })
        categories.append({"name": cat_name, "items": items})

    return {
        "restaurant_id": rid,
        "name": name,
        "city": city,
        # The restaurant's own coordinates, copied out of PostgreSQL. Denormalising them
        # here is what lets mongo/02_workflow3_geonear.js find its search origin without
        # reaching back across to the relational database mid-pipeline.
        "location": {"type": "Point", "coordinates": [float(lng), float(lat)]},
        "version": random.randint(1, 8),
        "updated_at": now - timedelta(days=random.uniform(0, 120)),
        "categories": categories,
    }


def gen_review(n_rest: int, max_user: int, max_order: int, now: datetime) -> dict:
    """
    Rating distribution is deliberately skewed towards 4-5, like real review data, so the
    Workflow 4 histogram has an interesting shape instead of a flat line.
    """
    rating = random.choices([1, 2, 3, 4, 5], weights=[6, 8, 16, 34, 36])[0]
    if rating >= 4:
        pool, sentiment = list(POSITIVE_TAGS), "POSITIVE"
    elif rating == 3:
        pool, sentiment = TAG_VOCAB, "NEUTRAL"
    else:
        pool, sentiment = [t for t in TAG_VOCAB if t not in POSITIVE_TAGS], "NEGATIVE"

    return {
        "restaurant_id": random.randint(1, n_rest),
        "order_id": random.randint(1, max_order) if max_order else None,
        "user_id": random.randint(1, max_user),
        "rating": rating,
        "text": fake.sentence(nb_words=random.randint(6, 18)),
        "tags": random.sample(pool, random.randint(1, min(4, len(pool)))),
        "sentiment": sentiment,
        "created_at": now - timedelta(days=random.uniform(0, REVIEW_HISTORY_DAYS)),
    }


def gen_ping(restaurants: list[tuple], max_order: int, now: datetime,
             expiring: bool = False) -> dict:
    """
    A GeoJSON Point clustered near a real restaurant.

    sigma = 0.02 degrees is roughly 2.2 km of latitude, so the bulk of the cloud lands
    comfortably inside the 5 km radius Workflow 3 searches. The longitude offset is
    divided by cos(latitude) because a degree of longitude shrinks towards the poles;
    without it the cluster would be an east-west ellipse.
    """
    _, _, _, r_lat, r_lng = random.choice(restaurants)
    lat = r_lat + random.gauss(0, 0.02)
    lng = r_lng + random.gauss(0, 0.02) / math.cos(math.radians(r_lat))

    # Clamp: a 2dsphere index build FAILS outright on an out-of-range coordinate.
    lat = max(-90.0, min(90.0, lat))
    lng = max(-180.0, min(180.0, lng))

    age = random.uniform(TTL_SECONDS - 50, TTL_SECONDS - 40) if expiring \
        else random.uniform(0, PING_MAX_AGE)

    status = random.choices(["ACTIVE", "IDLE", "OFFLINE"], weights=[60, 30, 10])[0]
    return {
        "driver_id": random.randint(1, N_DRIVERS),
        "order_id": random.randint(1, max_order) if (max_order and status == "ACTIVE") else None,
        "status": status,
        # [longitude, latitude] - LONGITUDE FIRST. GeoJSON order, not the lat/lng order
        # people say out loud. Reversing these is the classic silent failure.
        "location": {"type": "Point", "coordinates": [float(lng), float(lat)]},
        "speed_kmph": round(random.uniform(0, 55), 1),
        "created_at": now - timedelta(seconds=age),
    }


# ======================================================================================
# Loading
# ======================================================================================
def recreate_collection(db, name: str, spec: dict) -> None:
    """Drop and recreate with the validator from the schema map, and no indexes yet."""
    db.drop_collection(name)
    db.create_collection(
        name,
        validator=spec["validator"],
        validationLevel=spec["validationLevel"],
        validationAction=spec["validationAction"],
    )


def bulk_insert(coll, generator, total: int, label: str) -> None:
    """
    insert_many with ordered=False: the driver may pipeline the batch and, critically, one
    rejected document does not abort the remaining documents in that batch.
    """
    t0 = time.perf_counter()
    done, batch = 0, []
    for _ in range(total):
        batch.append(generator())
        if len(batch) >= BATCH:
            coll.insert_many(batch, ordered=False)
            done += len(batch)
            batch = []
            print(f"\r[mongo_seeder]   {label}: {done:,}/{total:,}", end="", flush=True)
    if batch:
        coll.insert_many(batch, ordered=False)
        done += len(batch)
    elapsed = time.perf_counter() - t0
    print(f"\r[mongo_seeder]   {label}: {done:,} docs in {elapsed:.1f}s "
          f"({done / max(elapsed, 0.001):,.0f}/s)")


def build_indexes(db, schema: dict, only: list[str] | None = None) -> None:
    """
    Build indexes AFTER the data, from the schema map. The TTL index in particular is
    created last so that no document can expire while the load is still running.
    """
    for name, spec in schema["collections"].items():
        if only and name not in only:
            continue
        coll = db[name]
        for ix in spec["indexes"]:
            keys = [(field, direction) for field, direction in ix["keys"]]
            opts = dict(ix.get("options") or {})
            coll.create_index(keys, name=ix["name"], **opts)
        log(f"  {name}: {len(spec['indexes'])} indexes built")


def verify(db, restaurants: list[tuple]) -> None:
    """
    Prove the two traps were actually avoided, rather than assuming it.
    """
    print("\n" + "=" * 62)
    print(f"{'COLLECTION':<20}{'DOCS':>12}  INDEXES")
    print("-" * 62)
    total = 0
    for name in ("Menus", "Reviews", "DriverPings"):
        n = db[name].count_documents({})
        total += n
        ix = ", ".join(i["name"] for i in db[name].list_indexes() if i["name"] != "_id_")
        print(f"{name:<20}{n:>12,}  {ix}")
    print("-" * 62)
    print(f"{'TOTAL DOCUMENTS':<20}{total:>12,}")
    print("=" * 62)

    # Trap 1: every ping must be inside the TTL window.
    now = datetime.now(timezone.utc)
    oldest = db.DriverPings.find_one(sort=[("created_at", 1)])
    if oldest:
        age = (now - oldest["created_at"].replace(tzinfo=timezone.utc)).total_seconds()
        state = "OK" if age < TTL_SECONDS else "ALREADY EXPIRED"
        print(f"oldest ping age: {age:,.0f}s  (TTL {TTL_SECONDS}s) -> {state}")

    # Trap 2: a real $geoNear must actually return drivers.
    _, _, _, lat, lng = restaurants[0]
    found = list(db.DriverPings.aggregate([
        {"$geoNear": {
            "near": {"type": "Point", "coordinates": [float(lng), float(lat)]},
            "distanceField": "distance_m",
            "maxDistance": 5000,
            "spherical": True,
            "key": "location",
            "query": {"status": "ACTIVE"},
        }},
        {"$limit": 5},
    ]))
    print(f"$geoNear 5km around restaurant {restaurants[0][0]} "
          f"({restaurants[0][2]}): {len(found)} active drivers")
    if found:
        print(f"  nearest: driver {found[0]['driver_id']} at {found[0]['distance_m']:.0f} m")
    else:
        print("  WARNING: no drivers found - check the coordinate order [lng, lat]")
    print()


def main() -> int:
    ap = argparse.ArgumentParser(description="Seed the BiteStream MongoDB collections.")
    ap.add_argument("--scale", type=float, default=1.0, help="multiply all document counts")
    ap.add_argument("--pings-only", action="store_true",
                    help="reseed DriverPings only - use this immediately before the viva")
    args = ap.parse_args()

    schema = json.loads(SCHEMA_MAP.read_text())
    uri = os.getenv("MONGO_URI", "mongodb://127.0.0.1:27017")
    log(f"connecting: {uri} -> {schema['database']}")
    client = MongoClient(uri)
    db = client[schema["database"]]

    restaurants, max_user, max_order = load_restaurants_from_postgres()
    n_rest = len(restaurants)
    now = datetime.now(timezone.utc)
    t0 = time.perf_counter()

    n_reviews = max(100, int(N_REVIEWS * args.scale))
    n_pings = max(100, int(N_PINGS * args.scale))

    if not args.pings_only:
        log("Menus")
        recreate_collection(db, "Menus", schema["collections"]["Menus"])
        db.Menus.insert_many(
            [gen_menu(rid, name, city, lat, lng, now)
             for rid, name, city, lat, lng in restaurants],
            ordered=False,
        )
        log(f"  Menus: {len(restaurants):,} nested catalogue documents")

        log("Reviews")
        recreate_collection(db, "Reviews", schema["collections"]["Reviews"])
        bulk_insert(db.Reviews,
                    lambda: gen_review(n_rest, max_user, max_order, now),
                    n_reviews, "Reviews")

    log("DriverPings")
    recreate_collection(db, "DriverPings", schema["collections"]["DriverPings"])
    bulk_insert(db.DriverPings,
                lambda: gen_ping(restaurants, max_order, now),
                n_pings - EXPIRING_SOON, "DriverPings")

    # A small cohort seeded ~45 seconds from expiry, so the TTL reaper can be DEMONSTRATED
    # live during the viva rather than merely asserted.
    db.DriverPings.insert_many(
        [gen_ping(restaurants, max_order, now, expiring=True) for _ in range(EXPIRING_SOON)],
        ordered=False,
    )
    log(f"  + {EXPIRING_SOON} pings seeded ~45s from expiry (live TTL demo)")
    log(f"  DriverPings TOTAL inserted: {n_pings:,}  "
        f"(= {n_pings - EXPIRING_SOON:,} bulk + {EXPIRING_SOON} expiring-soon)")

    log("building indexes (after the load, TTL last)")
    build_indexes(db, schema, only=None if not args.pings_only else ["DriverPings"])

    verify(db, restaurants)
    log(f"done in {time.perf_counter() - t0:.1f}s")
    log("REMINDER: DriverPings expires after 2 hours. Re-run with --pings-only "
        "immediately before the viva.")
    client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
