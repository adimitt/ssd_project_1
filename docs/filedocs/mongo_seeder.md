# `data_generation/mongo_seeder.py`

## Objective

Generate the MongoDB dataset: **1,000 nested `Menus`, 200,000 `Reviews`, 499,800 geospatial
`DriverPings`** — 700,800 documents, target ≥ 500k pings.

**Rubric:** Stress Testing & Proof (10 pts).

## How to run

```bash
python3 data_generation/mongo_seeder.py                # full, ~13 s
python3 data_generation/mongo_seeder.py --scale 0.05   # smoke test
python3 data_generation/mongo_seeder.py --pings-only   # <<< run this before the viva
```

---

## The cross-database contract

**This script connects to PostgreSQL first.**

```python
cur.execute("SELECT id, name, city, latitude, longitude FROM restaurants ORDER BY id")
cur.execute("SELECT COALESCE(MAX(id), 0) FROM users")
cur.execute("SELECT COALESCE(MAX(id), 0) FROM orders")
```

That is the whole point. There is **no foreign key between the two engines**, so the only
thing keeping `restaurant_id` consistent across them is this deliberate, documented loading
step. If PostgreSQL has not been seeded, the script **refuses to run** rather than inventing
ids that point at nothing:

```
ERROR: no restaurants in PostgreSQL.
       Run data_generation/postgres_seeder.py first - the Mongo documents
       carry PostgreSQL ids and must not invent them.
```

This function *is* the referential integrity of the polyglot design. Say that in the viva,
then say what it does not cover: nothing stops a review pointing at an order deleted later.

---

## Trap 1 — TTL will delete your data before the viva

`DriverPings.created_at` carries `expireAfterSeconds: 7200`. Any ping older than two hours
is removed within roughly 60 seconds of the reaper's next pass.

**Seed pings dated "over the last week" and the collection is EMPTY minutes later.** Both
the `$geoNear` demo and the `executionStats` capture then return nothing, and the failure
looks like a bug in the pipeline rather than a data-lifecycle issue.

How this file handles it:

- every ping is timestamped inside the window: `created_at = now − uniform(0, 6900 s)`
  (`PING_MAX_AGE = 6900 < TTL_SECONDS = 7200`, so nothing expires mid-load)
- the TTL index is built **after** the load
- `--pings-only` makes a pre-viva refresh take a few seconds
- **200 pings are deliberately seeded ~45 s from expiry** so the TTL reaper can be
  *demonstrated live* rather than merely asserted

```python
age = random.uniform(TTL_SECONDS - 50, TTL_SECONDS - 40) if expiring \
    else random.uniform(0, PING_MAX_AGE)
```

The `verify()` function then checks it:

```
oldest ping age: 7,173s  (TTL 7200s) -> OK
```

> **Put this in your demo script.** `db.DriverPings.countDocuments()`, wait 60 seconds,
> count again, watch it drop. That is a far better proof than pointing at an index listing.

## Trap 2 — random global coordinates return nothing within 5 km

Uniform `[-180,180] × [-90,90]` places approximately zero drivers near any restaurant, so
Workflow 3 would be technically correct and return an empty result set.

```python
_, _, _, r_lat, r_lng = random.choice(restaurants)
lat = r_lat + random.gauss(0, 0.02)
lng = r_lng + random.gauss(0, 0.02) / math.cos(math.radians(r_lat))
lat = max(-90.0, min(90.0, lat))
lng = max(-180.0, min(180.0, lng))
```

- `sigma = 0.02°` ≈ **2.2 km** of latitude, so the bulk of the cloud lands comfortably
  inside the 5 km radius.
- **Divided by `cos(latitude)`** so the cluster is circular on the ground, not an ellipse.
- **Clamped**, because a `2dsphere` index build **fails outright** on an out-of-range
  coordinate — a failure that surfaces 500,000 documents later.

`verify()` proves it with a real query:

```
$geoNear 5km around restaurant 1 (Hyderabad): 5 active drivers
  nearest: driver 2290 at 48 m
```

---

## Order of operations

```
drop -> create with validator -> bulk insert_many -> create indexes -> verify
```

**Indexes go last**: building them first makes the load several times slower, because every
inserted document must be threaded into three B-trees as it lands. Measured throughput with
indexes deferred: **~98,000 documents/second**.

---

## Document generators

### `gen_menu()`

Four levels of nesting — `categories[] → items[] → addons[] → options[]` — which is what
makes this a genuine flexible catalogue rather than a flat table in disguise.

`price` uses **`Decimal128`**, mirroring PostgreSQL `NUMERIC`. A double would reintroduce
the exact floating-point money bug the relational side avoids.

`location` is the restaurant's own GeoJSON Point, copied from PostgreSQL. It is
denormalised here so `mongo/02_workflow3_geonear.js` can find its search origin without
reaching back across to the relational database mid-pipeline.

### `gen_review()`

```python
rating = random.choices([1, 2, 3, 4, 5], weights=[6, 8, 16, 34, 36])[0]
```

Deliberately skewed towards 4–5, like real review data, so the Workflow 4 histogram has an
interesting J-shape instead of a flat line. Tags are drawn from a positive or negative pool
depending on the rating, and `sentiment` is derived from it — so the facets are internally
consistent and the demo output tells a coherent story.

### `gen_ping()`

Covered under Trap 2. `status` is weighted `ACTIVE 60 / IDLE 30 / OFFLINE 10`; `order_id` is
set only for `ACTIVE` drivers, which is why the validator allows `"null"` in its bsonType
list.

---

## `bulk_insert()`

```python
coll.insert_many(batch, ordered=False)
```

Batches of 10,000. **`ordered=False`** lets the driver pipeline the batch and, critically,
means one rejected document does not abort the remaining documents in that batch.

Progress is printed with a carriage return so the load shows movement without flooding the
terminal.

## `build_indexes()`

Reads index definitions from `docs/mongo_schema_map.json` — the same file
`mongo/01_collections_and_indexes.js` uses — so the two consumers cannot drift. Keys are
rebuilt from ordered `[field, direction]` pairs because compound index order is
semantically significant.

## `verify()`

Prints a document/index table, then asserts the two traps were actually avoided:

```
COLLECTION                  DOCS  INDEXES
Menus                      1,000  ux_menus_restaurant, ix_menus_item_name
Reviews                  200,000  ix_reviews_restaurant_recent, ix_reviews_tags, ix_reviews_rating
DriverPings              499,800  ix_pings_geo, ix_pings_ttl, ix_pings_driver_recent
TOTAL DOCUMENTS          700,800

oldest ping age: 7,173s  (TTL 7200s) -> OK
$geoNear 5km around restaurant 1 (Hyderabad): 5 active drivers
```

If `$geoNear` returns nothing it prints the actual cause — coordinate order — rather than
leaving you to guess.

## Viva questions

1. Why does a **Mongo** seeder connect to **PostgreSQL**?
2. What enforces `restaurant_id` pointing at a real restaurant? What does not?
3. Why are all pings less than two hours old?
4. What happens if you seed pings dated last week?
5. Why divide the longitude offset by `cos(latitude)`?
6. What happens if a coordinate is out of range?
7. Why build indexes after the load?
8. What does `ordered=False` change?
9. Why `Decimal128` and not a float for prices?
10. Why is the rating distribution weighted rather than uniform?
