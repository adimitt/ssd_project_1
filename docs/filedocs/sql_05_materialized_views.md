# `sql/05_materialized_views.sql`

## Objective

`mv_restaurant_performance` — a physical snapshot joining `restaurants` to their lifetime
completed-order count and revenue, plus the `REFRESH … CONCURRENTLY` wrapper the brief asks
for.

**Rubric:** Indexing & Query Optimization (10 pts) — the materialized-view portion.

## Position in the build order

Step 6 — after the seeder, so the view has something to summarise. Creating it on an empty
database also works; it is simply empty.

> `sql/01_schema_ddl.sql` drops the base tables with `CASCADE`, which **also drops this
> view**. That is why the seeder checks `to_regclass('public.mv_restaurant_performance')`
> before refreshing and skips gracefully when it is absent.

## Idempotency

`DROP MATERIALIZED VIEW IF EXISTS … CASCADE`.

---

## Object 1 — `mv_restaurant_performance`

```sql
CREATE MATERIALIZED VIEW mv_restaurant_performance AS
SELECT r.id AS restaurant_id, r.name, r.city, r.is_active,
       COUNT(o.id)                                     AS completed_orders,
       COALESCE(SUM(o.total_amount), 0)::NUMERIC(14,2) AS total_revenue,
       COALESCE(AVG(o.total_amount), 0)::NUMERIC(10,2) AS avg_order_value,
       MAX(o.created_at)                               AS last_order_at
FROM restaurants r
LEFT JOIN orders o
       ON o.restaurant_id = r.id
      AND o.status = 'DELIVERED'
GROUP BY r.id, r.name, r.city, r.is_active
WITH DATA;
```

### `LEFT JOIN`, not `INNER JOIN`

A restaurant with zero delivered orders must still appear, with 0 revenue. An `INNER JOIN`
silently drops it, which quietly corrupts any ranking, any "worst performers" report, and
any count of "how many vendors do we have?". Verified by **T18**.

### The status test is in `ON`, not `WHERE` — and this is the exam question

In a `LEFT JOIN`, a `WHERE` predicate on the right-hand table is evaluated **after** the
join has manufactured NULL rows. `NULL = 'DELIVERED'` is `NULL`, i.e. not true, so those
zero-order restaurants get filtered straight back out — silently converting the `LEFT JOIN`
back into an `INNER JOIN`.

```sql
-- correct: restricts which rows are eligible to join, preserves the outer side
LEFT JOIN orders o ON o.restaurant_id = r.id AND o.status = 'DELIVERED'

-- wrong: undoes the LEFT JOIN
LEFT JOIN orders o ON o.restaurant_id = r.id WHERE o.status = 'DELIVERED'
```

The `LEFT JOIN` above is only correct *because* of this placement.

### `COALESCE`

`SUM()` and `AVG()` over zero rows return `NULL`, not `0`. Callers doing
`ORDER BY total_revenue DESC` would then sort NULLs first unless every one of them
remembered `NULLS LAST`. Fixing it once, here, is better than fixing it in every consumer.

### Cast widths

`total_revenue` is `NUMERIC(14,2)`, not `(10,2)`: it is a **sum** across up to 300k orders
and would overflow the narrower type. `avg_order_value` stays `(10,2)` because an average of
`(10,2)` values cannot exceed the range.

---

## Object 2 — `ux_mv_rest_perf` (mandatory, not optional)

```sql
CREATE UNIQUE INDEX ux_mv_rest_perf ON mv_restaurant_performance (restaurant_id);
```

`REFRESH MATERIALIZED VIEW CONCURRENTLY` works by building the new contents into a temporary
table and applying the **difference** to the existing view. To diff two sets it needs a key
that identifies a row in both. Without one:

```
ERROR:  cannot refresh materialized view "mv_restaurant_performance" concurrently
HINT:   Create a unique index with no WHERE clause on one or more columns.
```

Note **"with no `WHERE` clause"** — a *partial* unique index does not satisfy this
requirement, which is a nice contrast with `idx_active_user_order`.

## Object 3 — `idx_mv_rest_perf_revenue`

`(total_revenue DESC)` — supports the usual access pattern, the revenue leaderboard. The
captured plan shows an `Index Scan` on it at **0.223 ms** versus **90.4 ms** to compute the
same answer from the base tables: a **405× improvement**.

---

## Object 4 — `sp_refresh_restaurant_performance()`

```sql
CREATE OR REPLACE PROCEDURE sp_refresh_restaurant_performance()
LANGUAGE plpgsql AS $sp$
DECLARE v_started TIMESTAMPTZ := clock_timestamp(); v_rows BIGINT;
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_restaurant_performance;
    SELECT count(*) INTO v_rows FROM mv_restaurant_performance;
    RAISE NOTICE 'mv_restaurant_performance refreshed CONCURRENTLY: % rows in %',
                 v_rows, (clock_timestamp() - v_started);
END;
$sp$;
```

### Two preconditions, both satisfied above

1. **A non-partial `UNIQUE` index exists on the view** → `ux_mv_rest_perf`.
2. **The view has already been populated at least once** → `WITH DATA`. A view created
   `WITH NO DATA` is *unscannable*, and a concurrent refresh on it fails.

### Plain vs `CONCURRENTLY`

| | Lock taken | Readers | Speed | Needs unique index |
|---|---|---|---|---|
| `REFRESH MATERIALIZED VIEW` | `ACCESS EXCLUSIVE` | **blocked for the entire rebuild** | faster | no |
| `REFRESH … CONCURRENTLY` | `EXCLUSIVE` | **keep working** | slower (build + diff + apply) | **yes** |

For a dashboard that must stay queryable, `CONCURRENTLY` is the right trade.

### Why a `PROCEDURE` rather than a plain `FUNCTION`

Verified empirically on PostgreSQL 17.11: `REFRESH MATERIALIZED VIEW CONCURRENTLY` **does**
run inside a PL/pgSQL procedure body. A `PROCEDURE` called with `CALL` from autocommit gives
the refresh its own transaction, keeping the lock window as short as possible and avoiding
transaction-context differences across versions. Measured: **~120 ms for 1,002 rows.**

### Staleness policy — have one

The right production answer is **`pg_cron` every 15 minutes**: revenue dashboards tolerate
15-minute staleness, and that bounds the lock churn.

The wrong answer, and a likely probe: a statement trigger on `orders` that refreshes the
view on every order. That rebuilds 1,002 rows for each of 300k orders.

At 100× scale, neither: you would maintain an **incremental rollup table** instead of a
full rebuild.

---

## MV vs VIEW vs summary table

| | Freshness | Read cost | Maintenance |
|---|---|---|---|
| `VIEW` | always current | re-runs the whole query every time (90 ms here) | none |
| **`MATERIALIZED VIEW`** | stale until refreshed | index scan on a snapshot (0.22 ms) | one refresh command |
| summary table | whatever you maintain | fastest, fully indexable | you write and debug the maintenance |

---

## Viva questions

1. Why does `REFRESH CONCURRENTLY` require a unique index? Why must it be non-partial?
2. What locks does each refresh mode take, and who blocks?
3. Why is the status test in `ON` rather than `WHERE`? What breaks if you move it?
4. Why `LEFT JOIN` at all — give a query whose answer is wrong with `INNER`.
5. Why `COALESCE` around `SUM` and `AVG`?
6. Why is `total_revenue` `NUMERIC(14,2)` when `total_amount` is `(10,2)`?
7. How would you keep this fresh in production? What is your staleness budget?
8. `MATERIALIZED VIEW` vs `VIEW` vs a summary table — when would you pick each?
9. What happens if you create the view `WITH NO DATA` and immediately refresh concurrently?
