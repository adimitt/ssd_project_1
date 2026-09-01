# `mongo/02_workflow3_geonear.js` — Workflow 3

## Objective

Find the closest **ACTIVE** drivers within a **5 km** radius of a restaurant, using
`$geoNear` against the `2dsphere` index on `DriverPings.location`.

**Rubric:** Advanced Analytics (25 pts) — the geospatial portion.

## How to run

```bash
mongosh bitestream mongo/02_workflow3_geonear.js
mongosh bitestream --eval 'RESTAURANT_ID=42' -f mongo/02_workflow3_geonear.js
mongosh bitestream --eval 'RADIUS=2000'      -f mongo/02_workflow3_geonear.js
mongosh bitestream --eval 'EXPLAIN=true'     -f mongo/02_workflow3_geonear.js
```

## Depends on

`mongo/01_collections_and_indexes.js` (`ix_pings_geo`) and
`data_generation/mongo_seeder.py` (pings clustered near restaurants, inside the TTL window).

---

## Finding the origin

```javascript
const menu = db.Menus.findOne({ restaurant_id: RID }, { name: 1, city: 1, location: 1 });
const origin = menu.location;
```

`Menus` carries the restaurant's coordinates, copied from PostgreSQL by `mongo_seeder.py`.
That keeps the pipeline **self-contained** — no cross-database call at query time. If the
document is missing, the script throws a message naming the seeder rather than failing on
`undefined.location`.

---

## The pipeline

```javascript
{ $geoNear: {
    near: origin,
    distanceField: "distance_m",
    maxDistance: RADIUS_M,
    spherical: true,
    key: "location",
    query: { status: "ACTIVE" },
}},
{ $sort:  { driver_id: 1, distance_m: 1 } },
{ $group: { _id: "$driver_id", distance_m: { $first: "$distance_m" }, … } },
{ $sort:  { distance_m: 1 } },
{ $limit: 5 },
{ $project: { …, eta_minutes: { $round: [{ $divide: ["$distance_m", 366.7] }, 1] } } }
```

### The five rules that cannot be bent

1. **`$geoNear` must be the very first stage.** No exceptions — not after a `$match`, not
   inside a `$facet`, not after anything at all.
2. **Exactly one `$geoNear` per pipeline.**
3. **`maxDistance` is in METRES** when `spherical: true` is used with GeoJSON. With the
   legacy coordinate-pair form it is in **radians** — a six-orders-of-magnitude difference.
4. **The filter belongs inside `$geoNear.query`**, not in a later `$match`. Inside, it is
   pushed down into the index scan; outside, MongoDB fetches documents purely to discard
   them.
5. **`key: "location"` is required** when the collection carries more than one `2dsphere`
   index. Specified here regardless, so the intent is explicit.

### The two sorts — and why one of them is not redundant

`$geoNear` **already returns documents in ascending distance order**. A plain
`{$sort: {distance_m: 1}}` immediately after it is redundant and signals not knowing that.

The first sort here is deliberate and different: a driver emits many pings, so the stream is
sorted by `(driver_id, distance_m)` to let `$group`/`$first` collapse each driver to their
single closest ping. The **second** sort is then necessary because `$group` destroys
ordering.

---

## The explain helpers

```javascript
function execStatsOf(explainDoc) { … }
function stageNames(node, acc) { … }
```

The shape of an aggregation explain has changed across MongoDB releases **and differs by
which stage owns the cursor**:

| Case | Path |
|---|---|
| MongoDB ≤ 4.x | `explain.stages[0].$cursor.executionStats` |
| `$geoNear`, MongoDB 8 | `explain.stages[0].$geoNearCursor.executionStats` |
| SBE / find | `explain.executionStats` |

Probing all three keeps the script working on whatever version the grader runs, instead of
throwing a `TypeError` halfway through the demo. (It did exactly that on our first run.)

`stageNames` walks the `executionStages` tree collecting stage names, so the script can
**assert** that `GEO_NEAR_2DSPHERE` is present and `COLLSCAN` is not:

```javascript
if (!allStages.includes("GEO_NEAR_2DSPHERE")) throw new Error("FAIL: …");
if (allStages.includes("COLLSCAN"))           throw new Error("FAIL: …");
```

### Why the stage list is collapsed for display

`$geoNear` searches **outwards in expanding rings**, emitting one `IXSCAN` per ring, so the
raw stage list repeats dozens of times. The script counts them instead:

```
plan stages : FETCH x45, GEO_NEAR_2DSPHERE, IXSCAN x44
```

That single line is also the clearest explanation of *how* `$geoNear` works.

---

## Measured result

```
5 active drivers within 5000 m  (138 ms)
  nearest: driver 2290 at 48.4 m

collection size    : 499,800 pings
documents examined : 42,048
keys examined      : 24,371
execution time     : 110 ms
plan stages        : FETCH x45, GEO_NEAR_2DSPHERE, IXSCAN x44
verdict            : GEO_NEAR_2DSPHERE present, no COLLSCAN -> index confirmed
```

Control (bounding-box query pinned to a collection scan, doing the same
`$sort`/`$group`/`$limit` work): **500,000 documents examined, 240 ms.**

**11.9× fewer documents examined.**

### An honest caveat worth raising yourself

`$geoNear` examines far fewer documents but does **more work per document**: expanding ring
searches, true spherical distance computation, sorted output. On a collection this size —
held entirely in RAM — a linear bounding-box scan is sometimes competitive on wall-clock
time, and in one of our runs it was faster.

The index is still the right answer, for three reasons:
1. It is the only way to get **correct spherical distances in sorted order**. A bounding box
   is a rectangle on a sphere and gets the corners wrong.
2. It scales: the scan cost grows with the collection, the index cost with the result set.
3. **`$geoNear` cannot run without it at all** (below).

### `$geoNear` has no un-indexed fallback

```
$geoNear requires a 2d or 2dsphere index, but none were found
```

MongoDB rejects the pipeline outright rather than degrading to a scan. `capture_mongo.js`
records this error text as evidence.

---

## Failure modes the script names for you

If the result is empty it prints the two actual causes:

1. **coordinates stored as `[lat, lng]` instead of `[lng, lat]`** — the single most common
   bug in this assignment; the query silently returns nothing.
2. **the TTL reaper has emptied `DriverPings`** — re-run
   `python3 data_generation/mongo_seeder.py --pings-only`.

## Viva questions

1. Why must `$geoNear` be the first stage?
2. Why does the filter go inside `$geoNear.query` rather than a following `$match`?
3. `maxDistance` — metres or radians? What decides?
4. GeoJSON coordinate order, and what happens if you swap them?
5. When is `key` mandatory?
6. `$geoNear` already sorts by distance — so why is there a `$sort` right after it?
7. What does `GEO_NEAR_2DSPHERE` above 44 `IXSCAN`s tell you about the algorithm?
8. Your indexed query was slower in wall-clock than the scan. Is the index wrong?
