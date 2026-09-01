# `data_generation/postgres_seeder.py`

## Objective

Generate the PostgreSQL stress-test dataset (**501,865 rows**, target ≥ 100k) and leave the
database in exactly the state the performance capture expects.

**Rubric:** Stress Testing & Proof (10 pts).

## How to run

```bash
python3 data_generation/postgres_seeder.py                 # full dataset, ~11 s
python3 data_generation/postgres_seeder.py --scale 0.05    # 5% smoke test
python3 data_generation/postgres_seeder.py --skip-checkouts
```

Connection via standard libpq environment variables (`PGHOST`, `PGPORT`, `PGDATABASE`,
`PGUSER`, `PGPASSWORD`) with localhost defaults. Nothing is hardcoded.

---

## Volumes produced

| Entity | Rows |
|---|---:|
| `restaurants` | 1,000 |
| `users` | 50,000 |
| `orders` | 300,000 (≈294k `DELIVERED`, ≈6.2k active) |
| `wallet_audit_logs` | **150,000+, every row trigger-generated** |
| `checkout_attempts` | ~300 |

Orders are spread over **540 days**, which is what makes the 90-day Workflow 2 window ~17 %
selective — selective enough that the planner prefers an index. Widen the history or narrow
the window and that changes.

---

## The ten steps, and why each is where it is

| # | Step | Why here |
|---|---|---|
| 1 | `random.seed(42)`, `Faker.seed(42)` | reproducible runs; a grader re-running must get the same shape of data |
| 2 | disable the audit guards | `wallet_audit_logs` has a `BEFORE TRUNCATE` trigger, so the reset cannot happen by accident |
| 3 | `TRUNCATE … RESTART IDENTITY CASCADE` | resets identity sequences so ids are a predictable `1..N` |
| 4 | drop the analytics indexes | loading into fewer indexes is far faster, and the partial `UNIQUE` index would abort a `COPY` midway |
| 5 | `COPY` the bulk | streaming `COPY`, not 300k `INSERT`s: seconds instead of minutes |
| 6 | set-based `UPDATE`s | **the only way to fill the ledger** — see below |
| 7 | replay `sql/02_indexes.sql` | one definition of every index in the repo, no drift |
| 8 | `VACUUM (ANALYZE)` | without stats the planner picks `Seq Scan`; without `VACUUM`, `Heap Fetches` never drops |
| 9 | exercise Workflow 1 | ~300 real `sp_execute_checkout` calls, success **and** failure |
| 10 | refresh the MV | so `mv_restaurant_performance` is populated for the demo |

---

## `reset()` — and the guard it has to defeat

```python
cur.execute("ALTER TABLE wallet_audit_logs DISABLE TRIGGER USER")
cur.execute(f"TRUNCATE {targets} RESTART IDENTITY CASCADE")
cur.execute("ALTER TABLE wallet_audit_logs ENABLE TRIGGER USER")
```

This is **not** a workaround — it is the immutability design working. Wiping the ledger
requires table ownership and a deliberate, visible act. It cannot happen by accident.

`DISABLE TRIGGER USER` disables all user triggers on the table (both guards) while leaving
system triggers, i.e. FK enforcement, in place.

### Tolerating objects created by later files

```python
cur.execute("SELECT to_regclass('public.checkout_attempts') IS NOT NULL")
```

`checkout_attempts` is created by `sql/04`, which may not have run yet if someone is
executing files one at a time. The seeder truncates only what exists, so it never depends on
a file that runs after it. `refresh_mv()` does the same for the materialized view — which
`sql/01`'s `CASCADE` drop removes and `sql/05` recreates.

---

## `seed_restaurants()` — clustered coordinates

```python
lat = clat + random.gauss(0, 0.05)
lng = clng + random.gauss(0, 0.05) / math.cos(math.radians(clat))
lat = max(-90.0, min(90.0, lat))      # honour ck_rest_latitude
lng = max(-180.0, min(180.0, lng))    # honour ck_rest_longitude
```

Restaurants cluster around eight Indian metros. **The longitude offset is divided by
`cos(latitude)`** because a degree of longitude shrinks towards the poles; without it the
cluster would be an east-west ellipse rather than a circle on the ground.

The clamps honour the `CHECK` constraints — and, downstream, stop `mongo_seeder.py`
generating a coordinate that a `2dsphere` index build would reject.

`mongo_seeder.py` reads these coordinates back out of PostgreSQL, which is what puts driver
pings within `$geoNear` range.

---

## `build_orders()` — the function shaped entirely by one index

`idx_active_user_order` is `UNIQUE ON orders(user_id) WHERE status IN ('PREPARING',
'DELIVERING')`. **Assigning statuses at random would put two live orders on some user and
abort the `COPY` partway through**, leaving a half-loaded table.

The strategy:

1. every order starts as `DELIVERED`, with a `delivered_at`
2. sample `n_active` **distinct** users that actually placed at least one order
3. flip exactly **one** order per sampled user to `PREPARING` or `DELIVERING`, and clear its
   `delivered_at` (`ck_orders_delivered_has_timestamp` only constrains `DELIVERED`)
4. assert the active user ids are unique before returning

```python
assert len(active_users) == len(set(active_users)), \
    "partial unique index would be violated: duplicate active user"
```

Active orders are also given a **recent** `created_at` (last 110 minutes), so they line up
with the `DriverPings` TTL window on the MongoDB side.

---

## `seed_ledger()` — the subtle part of the file

**Why not just `COPY` into `wallet_audit_logs`?** Because then no row would have come from
`trg_wallet_audit`, and the claim that the ledger is trigger-maintained would be false. An
examiner can check: `balance_after` must reconcile with `users.wallet_balance`.

**Why not loop 150k single-row `UPDATE`s?** Correct, but slow.

**The insight:** a row-level trigger fires once per **affected row**, even for a single
set-based statement. One `UPDATE` touching 50,000 users therefore produces 50,000 audit rows
in one statement.

```python
LEDGER_PASSES = [
    ("welcome top-up",          500.00),
    ("first order settlement", -137.50),
    ("cashback",                 89.25),
]
```

Three statements, **150,000 genuinely trigger-generated rows, ~1.6 s each.** The amounts are
chosen so the running balance can never go negative — one
`ck_users_wallet_non_negative` violation would abort the entire statement.

This is the strongest single claim in the submission: *"every row in the audit table was
written by the trigger; nothing was inserted directly."*

Note this only works because `COPY` into `users` fires **no** update trigger — see
[sql_03](sql_03_triggers_and_audit.md).

---

## `recreate_indexes()`

Reads `sql/02_indexes.sql`, strips psql meta-commands (lines starting with `\`, which
psycopg cannot execute since it speaks the wire protocol), and runs the rest. Index
definitions therefore live in **exactly one place**. Rebuild time: ~0.5 s.

## `analyze()` — the most important five lines

```python
conn.autocommit = True          # VACUUM cannot run inside a transaction block
cur.execute("VACUUM (ANALYZE) orders")
```

| | Effect |
|---|---|
| `ANALYZE` | refreshes planner statistics. On a freshly loaded table with none, the planner guesses and its guesses lead straight to a `Seq Scan`. **This is the number one cause of "why is my index not being used?"** |
| `VACUUM` | sets the visibility map, which is what allows an `Index Only Scan` to report low `Heap Fetches` |

## `exercise_checkouts()`

~300 real `CALL sp_execute_checkout(...)` invocations, weighted so every branch fires:

| Roll | Amount | Expected outcome |
|---|---|---|
| < 0.10 | 999,999.00 | `INSUFFICIENT_FUNDS` |
| < 0.15 | −25.00 | `AMOUNT_INVALID` |
| < 0.20 | valid, bad restaurant id | `BAD_REFERENCE` |
| else | 99–900 | `OK` (or `ACTIVE_ORDER_EXISTS`) |

Measured on a full run: `OK 210`, `ACTIVE_ORDER_EXISTS 34`, `INSUFFICIENT_FUNDS 31`,
`AMOUNT_INVALID 15`, `BAD_REFERENCE 10`.

**Two connection details that matter:**

- **`autocommit = True`.** `sp_execute_checkout` performs its own `COMMIT`/`ROLLBACK`, so a
  `CALL` nested inside a client-side `BEGIN` raises `2D000`.
- **Explicit casts.** psycopg infers the **narrowest** type that fits, so a small Python
  `int` arrives as `smallint` and a `float` as `double precision` — and PostgreSQL then finds
  no procedure with that signature (`procedure sp_execute_checkout(smallint, smallint,
  double precision, unknown, unknown) does not exist`). Hence
  `%s::bigint, %s::bigint, %s::numeric(10,2)` and `Decimal(str(amount))`.

## `summary()`

Prints a row-count table and then **verifies the business rule in the data**:

```
users with >1 active order (must be 0): 0
ledger rows, all trigger-generated:     150,210
```

A visible "it worked" moment for the demo, and a real assertion rather than decoration.

## Viva questions

1. Why `COPY` rather than `INSERT`? How much faster?
2. Why drop indexes before the load and rebuild after?
3. How did you get 150k audit rows when `COPY` fires no update trigger?
4. Why is `build_orders()` structured the way it is? What breaks otherwise?
5. Why divide the longitude offset by `cos(latitude)`?
6. What does `VACUUM (ANALYZE)` do for the performance section? What breaks without it?
7. Why must the checkout calls use an autocommit connection?
8. Why the explicit `::bigint` casts?
9. Why `random.seed(42)`?
