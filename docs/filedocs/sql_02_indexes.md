# `sql/02_indexes.sql`

## Objective

Create every index in the relational schema: the **partial `UNIQUE` index** that encodes the
"one active order per user" business rule, the two **partial covering indexes** that make
Workflow 2 an `Index Only Scan`, and the supporting secondary indexes.

**Rubric:** Indexing & Query Optimization (10 pts).

## Position in the build order

Logically **step 5 — after the bulk load, not before**. Two reasons:

1. Loading 300k rows into a table that already carries five indexes is several times
   slower; every insert must be threaded into every B-tree as it lands.
2. The partial `UNIQUE` index will **abort a `COPY` midway** if the generated data violates
   it, leaving a half-loaded table.

`postgres_seeder.py` therefore drops these indexes, `COPY`s, and then **replays this exact
file** to rebuild them — so index definitions live in one place and cannot drift.

Running the numbered files in plain order on an empty database also works: there is simply
nothing to index yet.

## Idempotency

`DROP INDEX IF EXISTS` before every `CREATE`.

---

## Index 1 — `idx_active_user_order` (the business rule)

```sql
CREATE UNIQUE INDEX idx_active_user_order
    ON orders (user_id)
    WHERE status IN ('PREPARING', 'DELIVERING');
```

Given verbatim in the brief. It is a **uniqueness constraint that applies only to a subset
of rows**. A user may hold 500 `DELIVERED` orders — those rows are not in the index at all —
but a second `PREPARING` or `DELIVERING` row raises `unique_violation`, **SQLSTATE 23505**.

### Why an index and not a constraint

`ALTER TABLE … ADD CONSTRAINT … UNIQUE` **cannot take a `WHERE` clause**. Conditional
uniqueness is only expressible as a partial unique *index*. This is the single most likely
question about this file.

### When the planner will use it for reads

Only when the query predicate is **provably implied** by the index predicate:

| Query | Usable? |
|---|---|
| `WHERE status = 'PREPARING'` | yes — a literal the planner can reason about |
| `WHERE status IN ('PREPARING','DELIVERING')` | yes |
| `WHERE status = $1` | generally **no** — the planner cannot prove implication for a bound parameter |

Enforcement of uniqueness happens regardless of the planner; only the *read* path depends
on provability. `performance/capture_postgres.sh` uses literals for exactly this reason,
and measures **0.012 ms** for the active-order lookup.

### Consequences elsewhere

- **The seeder** cannot assign statuses at random. `build_orders()` makes every order
  `DELIVERED`, then flips exactly one order for each of 6,000 *distinct* users, and
  asserts uniqueness before loading.
- **`sp_execute_checkout`** catches `unique_violation` and reports `ACTIVE_ORDER_EXISTS`.
- **The concurrency test** must clear the active slot between iterations, or the partial
  index masks the serialization behaviour it is trying to measure.

Verified by T12 (blocks a 2nd active order) and T12b (permits 500 `DELIVERED`).

---

## Index 2 — `idx_orders_delivered_rest_date` (restaurant-leading covering)

```sql
CREATE INDEX idx_orders_delivered_rest_date
    ON orders (restaurant_id, created_at)
    INCLUDE (total_amount)
    WHERE status = 'DELIVERED';
```

Serves the materialized view and per-vendor drilldown: equality on `restaurant_id`, then
ordering by date.

## Index 2b — `idx_orders_delivered_date_rest` (date-leading covering)

```sql
CREATE INDEX idx_orders_delivered_date_rest
    ON orders (created_at, restaurant_id)
    INCLUDE (total_amount)
    WHERE status = 'DELIVERED';
```

Serves **Workflow 2**: a range over `created_at` with no restaurant predicate at all.

### Why two near-identical indexes — the obvious challenge, and its answer

A composite B-tree can only **range-scan on its leading column**. The two access patterns
in this schema lead with different columns:

| Access pattern | Shape | Needs leading |
|---|---|---|
| Workflow 2 — "all vendors, last 90 days" | range on `created_at` | `created_at` |
| MV / drilldown — "this vendor, all time" | equality on `restaurant_id` | `restaurant_id` |

Given only 2a, Workflow 2 can still manage an `Index Only Scan` — but it must walk the
**entire** index and filter `created_at` row by row: no `Index Cond`, no early termination.
With 2b the captured plan shows:

```
Index Cond: ((o.created_at >= (CURRENT_DATE - '90 days'::interval))
         AND (o.created_at <  (CURRENT_DATE + '1 day'::interval)))
```

The write cost is two extra leaf updates per insert. `orders` is append-mostly and
read-heavy, so the trade is clearly worth it.

### What `INCLUDE` does

`INCLUDE (total_amount)` stores the payload in the index **leaf** without making it a key
column: it does not affect index ordering, uniqueness, or key comparisons. The effect is
that Workflow 2 can be answered from the index alone → `Index Only Scan`.

`INCLUDE` requires PostgreSQL 11+.

### Why the partial predicate helps twice

`WHERE status = 'DELIVERED'` covers ~98 % of rows, so it barely shrinks the index. It earns
its place differently: the planner knows every entry satisfies the predicate, so it can
**drop the `status` test entirely** from the scan.

### `Heap Fetches`

`Index Only Scan` still has to confirm row visibility, which it does via the **visibility
map**. That map is only populated by `VACUUM`. Without it, the scan visits the heap for
every row and the plan looks far weaker than it is. The seeder therefore ends with
`VACUUM (ANALYZE)`, and the capture script runs two passes — the measured result is
**526 heap fetches out of 49,065 rows (~1 %)**, dropping to 25 on the repeat.

It does not reach exactly 0 because `VACUUM` cannot mark pages whose transactions are still
newer than the oldest running snapshot, and the seeder's checkout calls commit moments
before the capture.

---

## Indexes 3–5 — supporting

| Index | Definition | Serves | Measured |
|---|---|---|---|
| `idx_orders_user_created` | `(user_id, created_at DESC)` | "my recent orders" | — |
| `idx_audit_user_ts` | `(user_id, "timestamp" DESC)` | per-user ledger replay | **0.40 ms**, no sort node |
| `idx_restaurants_active` | `(id) WHERE is_active` | active-vendor scoping | — |

`DESC` in the index matches the query's `ORDER BY … DESC`, so the planner needs no separate
sort node. That absence is visible in the captured plan and is worth pointing out.

`idx_restaurants_active` is a second partial index, this time on a boolean predicate —
useful as a contrast to the `IN (…)` predicate on index 1.

---

## Deliberately **not** created (and why)

### BRIN on `orders(created_at)`

```sql
-- CREATE INDEX brin_orders_created ON orders USING BRIN (created_at)
--     WITH (pages_per_range = 32);
```

BRIN stores only min/max per block range, making it roughly **1/1000th** the size of the
equivalent B-tree, and it is excellent for naturally time-ordered append-only data.

Not created because (a) the seeder randomises `created_at` across 540 days, destroying the
physical/logical correlation BRIN depends on, and (b) a second index on `created_at` would
add planner noise to the very proof Workflow 2 is trying to demonstrate.

### `CREATE INDEX CONCURRENTLY`

The production choice — it does not take an `ACCESS EXCLUSIVE` lock, so writes keep working
while the index builds. Not used here because **it cannot run inside a transaction block**,
and because this file runs against an offline database during setup where the lock is free.

### GIN on a `tsvector` of `restaurants.name`

Only worth it once free-text vendor search exists. It does not.

---

## Viva questions

1. Why can a partial `UNIQUE` index express this rule when a `UNIQUE` constraint cannot?
2. When will the planner *not* use the partial index for reads? *(Bound parameter — implication is unprovable at plan time.)*
3. What does `INCLUDE` do, and how does it differ from adding the column as a key?
4. Why are there two indexes on almost the same columns? *(Leading-column range-scan rule.)*
5. What makes `Heap Fetches: 0` possible, and why is ours 526 rather than 0?
6. Your query does a `Seq Scan` and it is *correct*. Why? *(Low selectivity: at ~50 % of the table a sequential scan genuinely costs less than random index access plus heap visits.)*
7. B-tree vs BRIN vs GIN — where would each fit in this schema?
8. Why build indexes after the load rather than before?
