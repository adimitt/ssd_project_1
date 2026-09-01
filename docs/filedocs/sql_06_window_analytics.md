# `sql/06_window_analytics.sql` — Workflow 2

## Objective

CTEs + window functions over `orders`:

- **Q1** the 7-day moving average of revenue per restaurant, ranked with `DENSE_RANK()`
- **Q2** the same series over time for the current top vendors
- **Q3** week-over-week momentum with `LAG()` and `NTILE()`

Q1 is the "heaviest query" whose `EXPLAIN (ANALYZE)` is captured in `performance/`.

**Rubric:** Advanced Analytics (25 pts) — the SQL half.

## Position in the build order

Step 8. Needs seeded data **and** `idx_orders_delivered_date_rest` to produce the
`Index Only Scan` the performance section depends on. Read-only, so trivially idempotent.

---

## Q1 — the pipeline

| CTE | Purpose |
|---|---|
| `daily` | collapse ~300k order rows to one row per (restaurant, calendar day) |
| `calendar` | the complete grid of restaurant × every day in the window |
| `filled` | `daily` LEFT JOINed onto `calendar`, so a day with no orders becomes **0** |
| `windowed` | the window functions themselves |
| final `SELECT` | take one day's slice and rank it |

### Why the gap fill exists

Without it, a restaurant that sold nothing on Tuesday simply has **no Tuesday row**. A frame
of "the previous 6 rows" would then reach back across the hole into much older data, and the
average would be divided by the wrong denominator.

### Why date literals and not a `params` CTE — the planner detail

A non-recursive CTE referenced **more than once** is **materialized** by PostgreSQL 12+ and
becomes an optimisation fence: the planner can no longer see the constant, so it cannot use
it as an index bound and falls back to a sequential scan.

Inlining `CURRENT_DATE - INTERVAL '90 days'` keeps the predicate visible at plan time. **This
single detail is the difference between an `Index Only Scan` and a `Seq Scan` here** —
30.9 ms versus 99.5 ms in the captured plans.

(`CURRENT_DATE` is `STABLE`, so it is evaluated once at plan time and is usable as an index
bound. `now()` would behave the same way; `clock_timestamp()`, being `VOLATILE`, would not.)

---

## The window frame — `ROWS` vs `RANGE` vs `GROUPS`

```sql
WINDOW w7 AS (
    PARTITION BY f.restaurant_id
    ORDER BY f.d
    RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW
)
```

| Frame | Means | Failure mode |
|---|---|---|
| `ROWS BETWEEN 6 PRECEDING` | the previous six **rows**, however far back in calendar time | spans 10 calendar days across a 3-day gap |
| **`RANGE BETWEEN INTERVAL '6 days' PRECEDING`** | every row whose `d` lies in `[d-6, d]` | correct **boundary** |
| `GROUPS BETWEEN 6 PRECEDING` | the previous six **peer groups** | rarely what you want here |

`RANGE` with an offset requires PostgreSQL 11+, and the `ORDER BY` column type must support
the offset type (`date` + `interval` works).

### The precise claim — and the correction our own tests forced

**`RANGE` fixes the window boundary. It does NOT invent rows for missing days.**

Measured in **T19** with a fixture of 100/day for 7 days, a 3-day gap, then 800:

| Frame at `2026-01-11` | Reaches back to | Calendar span |
|---|---|---|
| `ROWS BETWEEN 6 PRECEDING` | `2026-01-02` | **10 days** — silently wrong |
| `RANGE BETWEEN INTERVAL '6 days' PRECEDING` | `2026-01-05` | **7 days** — correct |

But **neither** frame supplies a zero for a day with no orders. **T19b** shows the other
half: over the ungapped rows the average is 275.00; over the gap-filled series it is 157.14.
Only `generate_series` + `LEFT JOIN` makes the denominator 7.

**A correct 7-day moving average needs both**, which is why this file does both.

### Named `WINDOW` clause

`WINDOW w7 AS (…)` is declared once and referenced twice (`ma7_revenue`, `orders_last_7d`).
Beyond readability, it lets the planner satisfy both aggregates from a **single `WindowAgg`
node** rather than two.

---

## The ranking functions

```sql
DENSE_RANK()   OVER (PARTITION BY w.d ORDER BY w.ma7_revenue DESC) AS rank_by_ma7,
RANK()         OVER (PARTITION BY w.d ORDER BY w.ma7_revenue DESC) AS rank_gapped,
PERCENT_RANK() OVER (PARTITION BY w.d ORDER BY w.ma7_revenue)      AS pct_rank
```

On values `300, 200, 200, 100` (verified by **T20**):

| Function | Result | Behaviour on ties |
|---|---|---|
| `DENSE_RANK` | `1, 2, 2, 3` | ties share a rank; **nothing is skipped** |
| `RANK` | `1, 2, 2, 4` | ties share a rank; the next rank is skipped |
| `ROW_NUMBER` | `1, 2, 3, 4` | ties broken **arbitrarily and non-deterministically** |

The brief asks for `DENSE_RANK`, and the justification is real: a leaderboard should not
jump from 2nd to 4th because two venues tied. `RANK` is emitted alongside purely so the
difference is visible in the output during the demo.

## Other window functions in Q1

| Expression | Frame | Point |
|---|---|---|
| `SUM(revenue) OVER (… ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` | cumulative | running total |
| `LAG(revenue, 7) OVER (…)` | offset | same weekday last week — an offset of exactly 7 rows *is* 7 days **only because the series is gap-filled** |

---

## Q2 — the moving average as a time series

Restricts to the current top 5 vendors and prints the last 14 days, so the demo can point at
`ma7_revenue` actually smoothing a noisy `revenue_today`. Note rows where `revenue_today` is
0 but `ma7_revenue` is non-zero — that is the gap fill visibly working.

## Q3 — week-over-week momentum

Uses `LAG()` over a weekly grain plus `NTILE(4)` for quartile bucketing.

**It needs an extra CTE (`scored`), and that is the teaching point.** Window functions are
evaluated **after** `WHERE` and `GROUP BY` but **before** `ORDER BY` and `LIMIT`. So you
cannot filter on a window function's output in the same `SELECT` that computes it — it
always needs a wrapper.

Logical evaluation order:

```
FROM -> WHERE -> GROUP BY -> HAVING -> window functions -> SELECT -> DISTINCT -> ORDER BY -> LIMIT
```

---

## The performance proof, and how to not lose it

Captured plan for the `daily` scan:

```
->  Index Only Scan using idx_orders_delivered_date_rest on public.orders o
      Index Cond: ((o.created_at >= (CURRENT_DATE - '90 days'::interval))
               AND (o.created_at <  (CURRENT_DATE + '1 day'::interval)))
      Heap Fetches: 526
Execution Time: 30.919 ms
```

Control with index paths disabled: `Seq Scan`, **99.516 ms**.

Three conditions, all easy to lose:

1. **`ANALYZE` has been run.** Without statistics the planner guesses and picks `Seq Scan`.
2. **The predicate is selective.** 90 days out of 540 is ~17 %. Widen it and a `Seq Scan`
   genuinely becomes cheaper — the planner would be **right**, and the proof evaporates.
3. **The date-leading index exists.** A B-tree range-scans only on its leading column.

---

## Viva questions

1. `ROWS` vs `RANGE` vs `GROUPS`. Show where `ROWS` gives a wrong 7-day average.
2. Does `RANGE` fix the missing-day problem? *(No — it fixes the boundary. Only the gap fill fixes the denominator.)*
3. `DENSE_RANK` vs `RANK` vs `ROW_NUMBER` on tied values.
4. Why can't you filter on a window function's output in the same `WHERE`?
5. What is the logical evaluation order of a `SELECT`?
6. Why literals instead of a `params` CTE? *(CTEs referenced more than once are materialized in PG12+ and become optimisation fences.)*
7. Your query does a `Seq Scan` and it's correct. Why?
8. What does the named `WINDOW` clause buy you?
9. Why is `LAG(revenue, 7)` only meaningful here? *(Because the gap fill makes 7 rows = 7 days.)*
