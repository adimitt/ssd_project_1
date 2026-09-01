# `mongo/03_workflow4_facet.js` — Workflow 4

## Objective

One pass over `Reviews` producing, via `$facet`:

1. the **rating distribution**, 1–5 stars
2. the **most frequent tag strings**, via `$unwind`
3. the **overall average rating**

plus a sentiment split and a monthly trend, which cost nothing once the stream is open.

**Rubric:** Advanced Analytics (25 pts) — the `$facet` portion.

## How to run

```bash
mongosh bitestream mongo/03_workflow4_facet.js
mongosh bitestream --eval 'RESTAURANT_ID=42' -f mongo/03_workflow4_facet.js
mongosh bitestream --eval 'SCOPE="all"'      -f mongo/03_workflow4_facet.js
mongosh bitestream --eval 'EXPLAIN=true'     -f mongo/03_workflow4_facet.js
```

---

## The leading `$match` — the most important line in the file

```javascript
const match = SCOPE_ALL
    ? { created_at: { $gte: since } }
    : { restaurant_id: RID, created_at: { $gte: since } };
```

> **`$facet` sub-pipelines cannot use indexes. Only the stage immediately preceding
> `$facet` can.**

So this `$match` is not a stylistic nicety — it is the **only** opportunity the entire
aggregation has to touch an index. Remove it, or move it inside a facet, and the query
degrades to a full `COLLSCAN` of every review in the collection.

The predicate is shaped to match `ix_reviews_restaurant_recent {restaurant_id:1,
created_at:-1}`: **equality on the leading field, then a range on the second.** Reversed,
the range portion would be unusable.

### The anti-pattern, measured

`performance/capture_mongo.js` runs the same work with the `$match` moved **inside** the
facet and records both:

| Variant | Documents examined | Time |
|---|---:|---:|
| `$match` **before** `$facet` | **220** | **1 ms** |
| forced `COLLSCAN` (`hint({$natural:1})`) | 200,000 | 51 ms |
| `$match` **inside** `$facet` | 200,000 | 253 ms |

**909× the documents examined** for moving one stage inwards. That number is the single most
persuasive thing in the Mongo half of the submission.

---

## The `$facet` stage

### Why `$facet` at all

It runs every sub-pipeline over the **same input stream in a single pass**. The alternative
is five separate aggregations, each re-reading the same documents. That single-pass property
is the entire reason the stage exists, and it is the answer to *"why not just run three
queries?"*.

### Sub-pipeline 1 — `ratingDistribution`

`$group` by `$rating`, `$sort` by `_id`, `$project` to rename `_id` → `rating`.
Output is 1–5 star counts. The script renders it as an ASCII bar chart.

### Sub-pipeline 2 — `topTags`, via `$unwind`

```javascript
{ $unwind: "$tags" },
{ $group:  { _id: "$tags", count: { $sum: 1 } } },
{ $sort:   { count: -1, _id: 1 } },
{ $limit:  10 },
```

- **`$unwind` is a multiplying stage.** A review carrying 4 tags becomes 4 documents.
- **`preserveNullAndEmptyArrays` is deliberately OFF here.** A review with no tags
  contributes nothing to a *tag ranking*, so dropping it is correct. It would be required if
  the count had to include untagged reviews.
- **`$sort: {count: -1, _id: 1}`** — `_id` breaks ties deterministically, so two runs produce
  the same top-10 ordering. Without it, equal-count tags come back in arbitrary order.
- **`$limit: 10` bounds the fan-out** — see the 16 MB note below.

### Sub-pipeline 3 — `overall`

`$group` with `_id: null` computing `$avg`, `$sum`, `$stdDevPop`, `$min`, `$max`.

`_id: null` means "one group for everything". Note that over **zero** input documents this
sub-pipeline legitimately produces **no documents at all**, not a zero — which is what the
`$ifNull` in the final `$project` handles.

### Sub-pipelines 4 and 5

`sentimentSplit` and `monthlyTrend` (`$dateToString` to `%Y-%m`, last 6 months). Free,
because the stream is already open — which is the point being demonstrated.

---

## The 16 MB ceiling

`$facet` emits **one document** containing every sub-result, so the combined output is
bounded by the **BSON document size limit**. Any sub-pipeline that can fan out must be
capped — hence the `$limit` inside `topTags`, which would otherwise emit one entry per
distinct tag in the corpus.

## What `$facet` forbids

`$out`, `$merge`, `$geoNear`, `$changeStream`, and **nested `$facet`**.

---

## Unwrapping the output

```javascript
{ $project: {
    ratingDistribution: 1, topTags: 1, sentimentSplit: 1, monthlyTrend: 1,
    totalReviews: { $ifNull: [{ $arrayElemAt: ["$overall.totalReviews", 0] }, 0] },
    avgRating:    { $round: [{ $ifNull: [{ $arrayElemAt: ["$overall.avgRating", 0] }, 0] }, 3] },
    …
}}
```

Each sub-pipeline is itself **an array of documents**, so every scalar arrives wrapped in a
single-element array. `$arrayElemAt` unwraps it; `$ifNull` covers the empty-result case.

## `allowDiskUse: true`

Lets a `$group` whose working set exceeds the 100 MB in-memory limit spill to disk instead
of failing. Harmless when it is not needed.

---

## Measured result

```
--- 220 reviews aggregated in 3 ms

  OVERALL   average 3.827   sd 1.19   range 1-5

  RATING DISTRIBUTION
    1 star       14    6.4%  ######
    2 star       19    8.6%  ########
    3 star       37   16.8%  ################
    4 star       71   32.3%  ###############################
    5 star       79   35.9%  ##################################

  collection size    : 200,000 reviews
  documents examined : 220
  execution time     : 1 ms
  plan stages        : PROJECTION_SIMPLE <- FETCH <- IXSCAN
  verdict            : IXSCAN on ix_reviews_restaurant_recent, no COLLSCAN -> index confirmed
```

The distribution is deliberately skewed towards 4–5 by the seeder's
`random.choices([1..5], weights=[6,8,16,34,36])`, because real review data is
J-shaped and a flat histogram would look synthetic.

## `SCOPE="all"` — where a `COLLSCAN` is *correct*

With `SCOPE="all"` the predicate covers most of the collection, and MongoDB correctly
chooses a `COLLSCAN`. The script does **not** treat that as a failure:

```javascript
if (stages.includes("COLLSCAN")) {
    if (SCOPE_ALL) {  print("EXPECTED for SCOPE=\"all\" …"); }
    else { throw new Error("FAIL: COLLSCAN on a single-restaurant query"); }
}
```

This mirrors the PostgreSQL point in [sql_02](sql_02_indexes.md): at low selectivity a full
scan genuinely *is* the cheaper plan, and a query planner choosing one is not a bug.

## Viva questions

1. Why can't `$facet` sub-pipelines use indexes? What do you do about it?
2. What limits `$facet` output size, and which sub-pipeline here is at risk?
3. What is disallowed inside `$facet`?
4. Why `$facet` instead of three separate aggregations?
5. What does `$unwind` do to document count? When would you need `preserveNullAndEmptyArrays`?
6. Why `$sort: {count: -1, _id: 1}` rather than just `{count: -1}`?
7. Why does every scalar need `$arrayElemAt`?
8. Your `SCOPE="all"` run does a `COLLSCAN`. Is that a bug?
9. `$group` with `_id: null` over an empty input — what comes back?
