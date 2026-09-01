# `performance/` — capture scripts and evidence

Files: `capture_postgres.sh`, `capture_mongo.sh`, `capture_mongo.js`,
`postgres_explain_analyzes.txt`, `mongo_execution_stats.json`.

## Objective

Produce the **raw** `EXPLAIN (ANALYZE)` and `explain("executionStats")` evidence the brief
calls **CRITICAL**, each paired with a control so the index's contribution is *measured*
rather than asserted.

**Rubric:** Stress Testing & Proof (10 pts), and much of the demo's credibility.

## How to run

```bash
bash performance/capture_postgres.sh    # -> performance/postgres_explain_analyzes.txt
bash performance/capture_mongo.sh       # -> performance/mongo_execution_stats.json
```

Both are also invoked by `run_all.sh`. **Prerequisite:** the seeders have run, so statistics
are fresh.

---

## `capture_postgres.sh`

### The key design decision: `enable_*` GUCs, not `DROP INDEX`

To produce the "without the index" numbers, the script tells the planner the access path is
unavailable:

```sql
SET enable_indexscan     = off;
SET enable_indexonlyscan = off;
SET enable_bitmapscan    = off;
```

versus the obvious alternative of dropping and recreating the index. The GUC approach is:

- **session-local** — it cannot leak into another connection
- **instantaneous** — no index rebuild
- **completely reversible** — `RESET` and it is gone
- **safe** — it cannot fail halfway through and leave the grader's database without an index

The planner then picks the next-best plan, which is exactly the comparison wanted.

### Preamble

```sql
SET random_page_cost = 1.1;      -- SSD; the default 4.0 models a spinning disk
VACUUM (ANALYZE) orders;
VACUUM (ANALYZE) wallet_audit_logs;
VACUUM (ANALYZE) orders;         -- second pass, see below
```

A second `VACUUM` pass matters: the first cannot mark pages whose transactions are still
newer than the oldest running snapshot, so `Heap Fetches` drops further on the repeat
(526 → 25 in our runs).

### The six captures

| # | Query | Expected plan | Measured |
|---|---|---|---|
| 1 | Workflow 2's heavy scan | `Index Only Scan` + `Index Cond` on `created_at` | **30.9 ms** |
| 1b | the same, index paths disabled | `Seq Scan` | 99.5 ms |
| 2 | the complete windowed query | CTEs + `WindowAgg` + `DENSE_RANK` on top | 198 ms |
| 3 | active-order lookup | `Index Scan using idx_active_user_order` | **0.012 ms** |
| 4 | MV revenue leaderboard | `Index Scan` on the MV | **0.223 ms** |
| 4b | the same answer from base tables | 2× `Seq Scan` + `HashAggregate` | 90.4 ms |
| 5 | per-user ledger history | `Index Scan using idx_audit_user_ts`, no sort node | 0.40 ms |

Plus an **index inventory** (name, size, `idx_scan` usage count) and **table sizes**.

### One detail that made capture 3 meaningful

The first version hardcoded `WHERE user_id = 4242`, which happened to have no active order —
so the plan was technically correct and returned zero rows, proving nothing. Fixed by
selecting a user that genuinely has one:

```sql
SELECT user_id AS active_uid FROM orders
 WHERE status IN ('PREPARING','DELIVERING') ORDER BY user_id LIMIT 1 \gset
```

Note the `status` values stay **literal** in the `EXPLAIN`. The planner can only use a
partial index when it can *prove* the query predicate implies the index predicate, which it
cannot do for a bound parameter.

---

## `capture_mongo.js`

### `execStatsOf()` / `stageNames()` / `summarise()`

The explain shape differs by MongoDB version **and** by which stage owns the cursor
(`$cursor` vs `$geoNearCursor` vs top-level `executionStats`). `execStatsOf` probes all
three; `stageNames` walks the `executionStages` tree so `usedIndex` can be computed as
"no `COLLSCAN` anywhere".

### What it records

For each of Workflow 3 and Workflow 4: the pipeline, a summary, wall-clock timing, and the
**full raw explain document**. Plus:

| Extra | Purpose |
|---|---|
| `collection_sizes`, `indexes` | context, including `expireAfterSeconds` on the TTL index |
| `workflow3.control_*` | brute-force bounding box pinned to a scan with `hint({$natural:1})` |
| `workflow3.geonear_without_index` | the literal error text proving `$geoNear` needs the index |
| `workflow4.control_*` | the identical pipeline forced onto a `COLLSCAN` |
| `workflow4.antipattern_*` | the `$match` moved **inside** the `$facet` |

### Making the controls fair

The first Workflow 3 control ended with `$limit: 5` — so the collection scan **stopped after
139 documents** and appeared faster than the index. That is not a comparison, it is an
artefact of early termination.

Fixed by giving the control the same `$sort`/`$group`/`$sort`/`$limit` tail as Workflow 3,
which forces it to consume every matching document before it can dedupe by driver:

```
control docsExamined=500,000  time=240ms  usedIndex=False
indexed docsExamined= 42,048  time=110ms  usedIndex=True
```

**If a control looks suspiciously good, check whether it is doing the same work.**

### The anti-pattern measurement

`workflow4.antipattern_*` runs the same aggregation with the `$match` moved inside the
`$facet`. Because `$facet` sub-pipelines cannot use indexes:

| Variant | Docs examined | Time |
|---|---:|---:|
| `$match` before `$facet` | **220** | **1 ms** |
| forced `COLLSCAN` | 200,000 | 51 ms |
| `$match` inside `$facet` | 200,000 | 253 ms |

**909× the documents examined** for moving one stage inwards.

---

## `capture_mongo.sh`

Wraps the `.js`, redirects stdout to `mongo_execution_stats.json`, and prints a short summary
using Python so a broken capture is obvious immediately rather than at submission time.

## Output sizes

`postgres_explain_analyzes.txt` ≈ 245 lines. `mongo_execution_stats.json` ≈ 500 KB — large
because the `$geoNear` full explain contains 45 ring-search stages. The whole repository is
about **1 MB**, comfortably under the 20 MB ZIP limit.

## What the grader is looking for

| Must show | Must NOT show |
|---|---|
| `Index Only Scan` / `Index Scan` / `Bitmap Heap Scan` | `Seq Scan` on `orders` |
| low `Heap Fetches` | large heap fetches |
| actual rows ≈ estimated rows | 100× misestimates |
| `GEO_NEAR_2DSPHERE` | `COLLSCAN` |
| `IXSCAN` on the Reviews compound index | `COLLSCAN` |
| `totalDocsExamined` ≪ collection size | ratio near 1.0 |

All are present. The plans are also pasted **inline in `README.md`**, which the brief
requires — leaving them only in `performance/` would lose marks.

## Viva questions

1. Why `enable_indexscan = off` rather than `DROP INDEX`?
2. Why `random_page_cost = 1.1`?
3. Why run `VACUUM` twice?
4. Why are the `status` values literals in capture 3?
5. Your `$geoNear` control looked faster at first. What was wrong with it?
6. There is no "without index" `$geoNear` number. Why not?
7. Which single number best demonstrates the `$facet` rule? *(909×.)*
