# BiteStream — Food Delivery & Real-Time Logistics

**CS6.302 Software System Development · Assignment 1 (Database Design) · Project 1**

A production-shaped, dual-engine database. All logic lives inside the database: PL/pgSQL
stored procedures with their own transaction control, an audit trigger, partial and
covering indexes, a materialized view refreshed concurrently, window analytics, and
MongoDB geospatial + faceted aggregation pipelines. **There is no application tier**, by
design — the brief asks for the data engineering, not a service around it.

---

## 1. Submission details

| | |
|---|---|
| **Team number** | **5** |
| **Project number** | 1 — BiteStream (`project_no = (team_no % 5) + 1`, so `team_no % 5 == 0`) |
| **Members** | `<NAME, ROLL NO>` · `<NAME, ROLL NO>` · `<NAME, ROLL NO>` · `<NAME, ROLL NO>` |
| **GitHub repository** | **https://github.com/adimitt/ssd_project_1** (public) |
| **Deliverables commit** | `277ce02a2ffc19138ef1d7e9d449c1bd39fe6279` |
| **Submission tag** | `submission` — `git checkout submission` resolves to the exact graded tree |

> **On the commit hash.** Writing a hash into the README necessarily changes the hash, so the
> value above is the commit containing **all deliverables**; the only commit after it is the one
> that added this line. The annotated tag `submission` is the unambiguous pointer — it is created
> last and resolves to the exact tree the graders should read.
>
> After filling in the team details below, re-stamp with:
> ```
> git add -A && git commit -m "submission: team details"
> git tag -f -a submission -m "final submission" && git push && git push -f origin submission
> git rev-parse HEAD          # <- paste this into Moodle
> ```

### Verified environment

| Component | Version used |
|---|---|
| PostgreSQL | **17.11** (Homebrew, aarch64-apple-darwin) |
| MongoDB | **8.3.7** (mongosh 2.9.2) |
| Python | **3.13.9** |
| psycopg / pymongo / Faker | 3.3.5 / 4.17.0 / 40.37.0 |

PostgreSQL ≥ 11 is the hard floor: `RANGE … PRECEDING` window frames, `INCLUDE` covering
indexes and `CREATE PROCEDURE` with transaction control all require it. `gen_random_uuid()`
would additionally require ≥ 13, but this schema uses `BIGINT IDENTITY` (see §4).

---

## 2. Setup — empty machine to verified database

```bash
# 0. Engines. PostgreSQL 16/17 and MongoDB 7/8, running on localhost.
#    macOS:
#      brew install postgresql@17 && brew services start postgresql@17
#      brew install mongodb-community && brew services start mongodb-community
#      export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
#    Then create the role and database:
psql -d postgres -c "CREATE ROLE bs LOGIN PASSWORD 'bs' CREATEDB;"
psql -d postgres -c "CREATE DATABASE bitestream OWNER bs;"

# 1. Python dependencies
python3 -m pip install -r data_generation/requirements.txt

# 2. Connection settings. Every script reads standard libpq / Mongo env vars;
#    the localhost defaults below are already correct for the commands above.
export PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=bitestream PGUSER=bs PGPASSWORD=bs
export MONGO_URI=mongodb://127.0.0.1:27017

# 3. Build, in dependency order. The order is not optional — see the note below.
psql -f sql/01_schema_ddl.sql            # tables, types, PK/FK, CHECK constraints
psql -f sql/03_triggers_and_audit.sql    # trigger BEFORE any data exists
psql -f sql/04_stored_procedures.sql     # Workflow 1
python3 data_generation/postgres_seeder.py   # COPY, then trigger-driven ledger, then VACUUM ANALYZE
psql -f sql/02_indexes.sql               # indexes AFTER the bulk load
psql -f sql/05_materialized_views.sql    # materialized view + refresh function/procedure

# 4. MongoDB
mongosh bitestream mongo/01_collections_and_indexes.js
python3 data_generation/mongo_seeder.py

# 5. The four workflows
psql -f sql/06_window_analytics.sql                  # Workflow 2
mongosh bitestream mongo/02_workflow3_geonear.js     # Workflow 3
mongosh bitestream mongo/03_workflow4_facet.js       # Workflow 4
#   Workflow 1 is a procedure — call it:
psql -c "CALL sp_execute_checkout(1, 1, 250.00, NULL, NULL);"
```

### Why that order, and not filename order

| Step | Why it sits there |
|---|---|
| `03` before any data | The audit trigger must exist before the first row, which is what lets us say **every** ledger row was written by the trigger rather than inserted directly. |
| Seeder before `02` | Loading 300k rows into a table that already carries six indexes is several times slower, and the partial UNIQUE index would abort the `COPY` midway. The seeder drops the analytics indexes, loads, then replays `sql/02_indexes.sql` itself. |
| `VACUUM (ANALYZE)` last | Without fresh statistics the planner guesses and picks a Seq Scan; without `VACUUM`, `Heap Fetches` never reaches 0. The seeder runs it as its final step. |
| Mongo indexes after the load | Building them first makes the load several times slower. `mongo_seeder.py` creates them last, TTL last of all, so nothing expires mid-load. |

> **`data_generation/mongo_seeder.py` reads restaurant coordinates out of PostgreSQL.**
> Seed PostgreSQL first or it will refuse to run, rather than invent ids that point at nothing.

## 3. What is in the repository

Exactly the structure the assignment specifies — 17 files, nothing else.

```
README.md                                setup, assumptions, EXPLAIN plans (this file)
docs/
    relational_erd.png                   PostgreSQL schema diagram, annotated with the
                                         partial unique index and the trigger direction
    mongo_schema_map.json                document structures + $jsonSchema validators.
                                         NOT documentation: mongo/01_collections_and_indexes.js
                                         and mongo_seeder.py both READ this file, so the
                                         database and this document cannot drift apart
sql/
    01_schema_ddl.sql                    4 tables, 11 CHECK constraints, PK/FK
    02_indexes.sql                       6 indexes: 1 partial UNIQUE, 2 partial covering,
                                         3 secondary
    03_triggers_and_audit.sql            audit trigger + 2 immutability guards; ends with a
                                         self-test that RAISEs if any of it is broken
    04_stored_procedures.sql             Workflow 1 — sp_execute_checkout, REPEATABLE READ
    05_materialized_views.sql            mv_restaurant_performance + REFRESH CONCURRENTLY,
                                         as both a FUNCTION and a PROCEDURE
    06_window_analytics.sql              Workflow 2 — CTEs, RANGE frames, DENSE_RANK
mongo/
    01_collections_and_indexes.js        collections, validators, 2dsphere, TTL 7200s;
                                         asserts all four before it exits
    02_workflow3_geonear.js              Workflow 3 — $geoNear, the closest active driver
    03_workflow4_facet.js                Workflow 4 — $facet analytics
data_generation/
    postgres_seeder.py                   300k orders + 150k trigger-written ledger rows
    mongo_seeder.py                      520k geospatial pings, 200k reviews, 1k menus
    requirements.txt                     pinned Python dependencies
performance/
    postgres_explain_analyzes.txt        raw EXPLAIN (ANALYZE, BUFFERS, VERBOSE) logs
    mongo_execution_stats.json           raw explain("executionStats") JSON
```

## 4. Assumptions

The brief asks twice for assumptions to be listed. These are ours.

1. **`BIGINT GENERATED ALWAYS AS IDENTITY`, not UUID.** The brief allows either. Random
   UUIDv4 keys destroy B-tree insert locality — every insert lands in a random leaf page,
   causing page splits and WAL bloat — and widen every FK from 8 bytes to 16. UUIDv7/ULID
   would fix the ordering if globally-unique external keys were ever required.
2. **"One active order per user" is a hard business rule**, enforced by
   `idx_active_user_order`. `PREPARING` and `DELIVERING` are the two active states.
3. **The brief's wording about the trigger is imprecise.** It says inserting the order
   "triggers the audit log". It does not: `trg_wallet_audit` is `AFTER UPDATE OF
   wallet_balance ON users`, so the wallet **debit** fires it. We implemented the
   behaviour the brief describes (an audit row per checkout) via the mechanism the brief
   specifies (a trigger on `users`).
4. **`orders.total_amount` is pre-computed.** There are no line items in PostgreSQL;
   the itemised catalogue lives in MongoDB `Menus`. A real system would reconcile them.
5. **No cross-database foreign key exists.** `restaurant_id`, `user_id` and `order_id`
   in MongoDB are opaque copies of PostgreSQL BIGINTs. `mongo_seeder.py` reads them out of
   PostgreSQL at load time; nothing enforces them afterwards. See §8.
6. **Telemetry is intentionally lossy.** The 2-hour TTL on `DriverPings` means the
   collection is a live window, not a history. Anything needing long-term movement history
   would be rolled up into a separate collection before expiry.
7. **Single currency (INR), single timezone-agnostic storage.** All money is
   `NUMERIC(10,2)`; all timestamps are `TIMESTAMPTZ`.
8. **`checkout_attempts` is an addition beyond the brief's four tables**, added
   deliberately to demonstrate that a durable failure log must be written *after* the
   `ROLLBACK`, in the next transaction.
9. **`"timestamp"` is quoted everywhere.** The brief names the column that way; it is a
   non-reserved keyword in PostgreSQL, and quoting removes all parser ambiguity.
10. **Repo folder vs ZIP name.** The brief says the repo root is `<roll_number>_a1` but the
    Moodle upload is `<team_number>_a1.zip`. We followed both readings.

---

## 5. Dataset actually generated

| Relation | Rows | | Collection | Documents |
|---|---:|---|---|---:|
| `orders` | 300,223 | | `Menus` | 1,000 |
| — `DELIVERED` | 294,013 | | `Reviews` | 200,000 |
| — active | 6,210 | | `DriverPings` | **520,000** |
| `wallet_audit_logs` | 150,229 | | | |
| `users` | 50,003 | | **Total documents** | **721,000** |
| `restaurants` | 1,002 | | | |
| `checkout_attempts` | 402 | | Mongo data + indexes | 177 MB |
| **Total relational rows** | **501,859** | | PostgreSQL database | 110 MB |

Against the brief's Step 4 thresholds: **100,000+ ledger entries** (150,229 ✓),
**50,000+ orders** (300,223 ✓), **500,000+ geospatial pings** (520,000 ✓).

> The ping count is deliberately **520,000, not exactly 500,000**. Sitting on the threshold
> is fragile: the TTL reaper begins deleting the moment the load finishes, so a live count
> taken minutes later is already below it. The 4% margin makes the requirement unambiguous
> at capture time. The figure above is the one recorded in
> `performance/mongo_execution_stats.json`.
Full build time on the reference machine: **PostgreSQL ~11 s, MongoDB ~13 s.**

**Every one of the 150,229 ledger rows was written by the trigger.** `COPY` does not fire
an `UPDATE` trigger, so the seeder cannot bulk-load them; instead it issues three
set-based `UPDATE users SET wallet_balance = wallet_balance + …` statements. A row-level
trigger fires once per affected row even for a single statement, so each pass produces
50,000 genuine audit rows in about 1.6 seconds.

---

## 6. Performance proof

Captured on PostgreSQL 17.11 / MongoDB 8.3.7, macOS arm64, after `VACUUM (ANALYZE)` and
with `random_page_cost = 1.1`. Raw output:
[`performance/postgres_explain_analyzes.txt`](performance/postgres_explain_analyzes.txt)
and [`performance/mongo_execution_stats.json`](performance/mongo_execution_stats.json).

### Summary

| Query | Without the index | With the index | Gain |
|---|---:|---:|---:|
| **WF2** — 90-day revenue scan | 96.9 ms · Seq Scan · 300k rows | **29.3 ms** · Index Only Scan | **3.3× faster** |
| **MV** — revenue leaderboard | 90.4 ms · 2× Seq Scan + HashAggregate | **0.251 ms** · Index Scan on the MV | **360× faster** |
| **Partial unique index** — active-order lookup | — | **0.011 ms** · Index Scan | — |
| **Audit ledger** — per-user history | — | **0.27 ms** · Index Scan, no sort node | — |
| **WF3** — `$geoNear` 5 km | 520,000 docs · 250 ms | **43,442 docs** · 101 ms | **12.0× fewer docs** |
| **WF4** — `$facet` analytics | 200,000 docs · 49 ms | **220 docs** · 1 ms | **909× fewer docs** |
| **WF4** — `$match` moved *inside* `$facet` | 200,000 docs · 211 ms | 220 docs · 1 ms | **the rule, measured** |

### [1] Workflow 2 — the heavy scan (`Index Only Scan`, with an `Index Cond`)

```
HashAggregate  (cost=3813.05..5245.50 rows=53612 width=52) (actual time=16.755..27.190 rows=37768 loops=1)
   Group Key: o.restaurant_id, (o.created_at)::date
   Planned Partitions: 4  Batches: 5  Memory Usage: 8241kB  Disk Usage: 1584kB
   Buffers: shared hit=272, temp read=120 written=281
   ->  Index Only Scan using idx_orders_delivered_date_rest on public.orders o  (cost=0.43..1513.60 rows=53612 width=18) (actual time=0.021..7.548 rows=49070 loops=1)
         Index Cond: ((o.created_at >= (CURRENT_DATE - '90 days'::interval)) AND (o.created_at < (CURRENT_DATE + '1 day'::interval)))
         Heap Fetches: 525
         Buffers: shared hit=272
 Planning Time: 0.350 ms
 Execution Time: 29.301 ms
```

The control, with every index path disabled (`SET enable_indexscan/indexonlyscan/bitmapscan = off`):

```
->  Seq Scan on orders o  (cost=0.00..11790.22 rows=53612 width=18) (actual time=0.006..69.994 rows=49070 loops=1)
         Filter: (((status)::text = 'DELIVERED'::text) AND (created_at >= (CURRENT_DATE - '90 days'::interval)) AND (created_at < (CURRENT_DATE + '1 day'::interval)))
Execution Time: 96.880 ms
```

**Three things make this plan possible**, and all three are easy to get wrong:

- **`ANALYZE` had been run.** Without fresh statistics the planner guesses and picks a
  Seq Scan. This is the single most common cause of "why is my index not used?".
- **The predicate is selective.** 90 days out of 540 is ~17 % of the table. Widen the
  window and a Seq Scan genuinely becomes the cheaper plan — the planner would be *right*,
  and the proof would evaporate.
- **The date-leading index exists.** `idx_orders_delivered_date_rest` is
  `(created_at, restaurant_id) INCLUDE (total_amount) WHERE status='DELIVERED'`. A B-tree
  can only range-scan on its **leading** column, so the restaurant-leading twin
  (`idx_orders_delivered_rest_date`, which serves the MV and per-vendor drilldown) can
  only produce a full index walk with no `Index Cond`.

`Heap Fetches: 525` out of 49,070 rows (~1 %) rather than 0: `VACUUM` cannot mark pages
whose transactions are still newer than the oldest running snapshot, and the seeder's
checkout calls commit moments before the capture. A second `VACUUM` pass takes it to 24.

### [2] Workflow 3 — `$geoNear` uses `GEO_NEAR_2DSPHERE`

```json
{ "nReturned": 11609, "executionTimeMillis": 80,
  "totalKeysExamined": 24378, "totalDocsExamined": 42048,
  "stages": { "FETCH": 45, "GEO_NEAR_2DSPHERE": 1, "IXSCAN": 44 },
  "usedIndex": true }
```

`$geoNear` searches outwards in expanding rings, which is why one `GEO_NEAR_2DSPHERE`
stage sits above 44 `IXSCAN`s. **No `COLLSCAN` anywhere.** The control — the equivalent
bounding-box query pinned to a collection scan with `hint({$natural: 1})`, doing the same
`$sort`/`$group`/`$limit` work — examines all 520,000 documents in 250 ms.

There is no "without index" variant of `$geoNear` itself. MongoDB rejects the pipeline:

```
$geoNear requires a 2d or 2dsphere index, but none were found
```

### [3] Workflow 4 — `IXSCAN`, and the anti-pattern measured

```json
{ "indexed":     { "totalDocsExamined": 220, "executionTimeMillis": 1,
                   "stages": {"PROJECTION_SIMPLE":1,"FETCH":1,"IXSCAN":1} },
  "collscan":    { "totalDocsExamined": 200000, "executionTimeMillis": 49 },
  "antipattern": { "totalDocsExamined": 200000, "executionTimeMillis": 211 } }
```

The `antipattern` row is the same work with the `$match` moved **inside** the `$facet`.
**`$facet` sub-pipelines cannot use indexes — only the stage immediately preceding `$facet`
can.** Moving the filter one stage inwards costs 909× the documents examined. That is why
the leading `$match` in `mongo/03_workflow4_facet.js` is load-bearing, not stylistic.

---

## 7. Verification

There is no separate test harness in this repository — the assignment's structure does not
include one. Instead **the required scripts verify themselves**, and fail loudly rather than
printing something reassuring and wrong.

| Run this | What it asserts, and how it fails |
|---|---|
| `psql -f sql/03_triggers_and_audit.sql` | A `DO` block at the end credits a wallet, debits it, writes a **no-op** update, and tries to tamper with the ledger. It checks that exactly 2 rows were logged with the correct signs and `balance_after`, that the no-op produced **none**, and that the `UPDATE` was rejected. Everything is rolled back. Any failure raises and the script exits non-zero; success prints `self-test passed`. |
| `python3 data_generation/postgres_seeder.py` | Prints a row-count table, then asserts the partial unique index actually holds in the generated data: **`users with >1 active order (must be 0)`**. Also reports how many ledger rows exist and that all were trigger-generated. |
| `mongosh bitestream mongo/01_collections_and_indexes.js` | Asserts the 2dsphere index exists, the TTL is exactly **7200 s**, the TTL index is **single-field** (a compound TTL index is impossible and this catches an attempt), and all three collections carry validators. Throws on any failure. |
| `mongosh bitestream mongo/02_workflow3_geonear.js` | Prints the plan stages and asserts `GEO_NEAR_2DSPHERE` is present and `COLLSCAN` is not — throwing if either check fails. Ends with a `verdict` line. |
| `mongosh bitestream mongo/03_workflow4_facet.js` | Asserts `IXSCAN` and throws on `COLLSCAN` for the single-restaurant query. Run it with `--eval 'SCOPE="all"'` and it reports a `COLLSCAN` as **expected** — at that selectivity a full scan genuinely is the cheaper plan, and the script knows the difference. |
| `python3 data_generation/mongo_seeder.py` | Reports the oldest ping's age against the TTL window, and runs a real `$geoNear` to confirm drivers are actually found — which catches the `[lat, lng]` coordinate-order bug that otherwise fails silently. |

### Exercising Workflow 1's failure paths by hand

`sp_execute_checkout` returns a machine-readable status. Each of these should produce the
outcome named, and **leave nothing behind**:

```bash
psql <<'SQL'
INSERT INTO users (name, wallet_balance) VALUES ('demo', 500.00) RETURNING id AS u \gset
SELECT id AS r FROM restaurants ORDER BY id LIMIT 1 \gset

CALL sp_execute_checkout(:u, :r, 200.00,   NULL, NULL);   -- OK
CALL sp_execute_checkout(:u, :r, 50.00,    NULL, NULL);   -- ACTIVE_ORDER_EXISTS  (23505)
CALL sp_execute_checkout(:u, :r, 999999.00,NULL, NULL);   -- INSUFFICIENT_FUNDS   (23514)
CALL sp_execute_checkout(:u, :r, -50.00,   NULL, NULL);   -- AMOUNT_INVALID       (22023)
CALL sp_execute_checkout(:u, 99999999, 10.00, NULL, NULL);-- BAD_REFERENCE        (23503)
CALL sp_execute_checkout(99999999, :r, 10.00, NULL, NULL);-- USER_NOT_FOUND

-- After the failures: balance unchanged, no extra ledger row, no extra order.
SELECT wallet_balance FROM users WHERE id = :u;
SELECT count(*) FROM wallet_audit_logs WHERE user_id = :u;
SQL
```

> **`CALL` must run in autocommit.** `sp_execute_checkout` controls its own transaction, so a
> `CALL` nested inside a client-side `BEGIN` raises `2D000 invalid transaction termination`.
> Note also that PostgreSQL rejects a **subquery as a `CALL` argument** — capture the id with
> `\gset` first, as above.

### Regenerating the performance evidence

The two files in `performance/` are committed outputs. To reproduce them:

```bash
psql -c "SET random_page_cost = 1.1;" -c "VACUUM (ANALYZE) orders;" \
     -c "EXPLAIN (ANALYZE, BUFFERS, VERBOSE) <the Workflow 2 daily CTE>" \
     > performance/postgres_explain_analyzes.txt

mongosh bitestream --quiet --eval 'EXPLAIN=true' -f mongo/02_workflow3_geonear.js \
     > performance/mongo_execution_stats.json
```

`VACUUM (ANALYZE)` before capturing is not optional: without fresh statistics the planner
picks a Seq Scan, and without `VACUUM` an Index Only Scan reports a large `Heap Fetches`
count that makes a good plan look bad.

## 8. Known limitations

- **No cross-database referential integrity.** A `Review` can point at a deleted
  `order_id` and nothing will complain. Detecting it needs a reconciliation job that pulls
  `SELECT id FROM orders` and diffs it against the distinct `order_id`s in MongoDB. We did
  not build it; `mongo_seeder.py` reading real ids from PostgreSQL is the only integrity
  mechanism present.
- **No cross-engine transaction.** A checkout that must write to both engines atomically
  would need an outbox table plus an idempotent consumer. Out of scope here.
- **`sp_execute_checkout` has no idempotency key.** A client that retries after a network
  timeout could place two orders. Production would take a caller-supplied key with a
  unique index.
- **The materialized view is fully rebuilt on refresh.** At this scale that is ~120 ms; at
  100× it would need an incremental rollup table instead.
- **`Heap Fetches` is not exactly 0** — see §6.
- **`$geoNear` is not always faster in wall-clock time.** It examines 11.9× fewer documents
  but does more work per document (expanding ring searches, true spherical distance,
  sorted output). On a collection this size, held entirely in cache, a linear bounding-box
  scan can be competitive. The index is still the right answer: it is the only way to get
  correct spherical distances in sorted order, and `$geoNear` cannot run without it.

### What changes at 100× scale

| Pressure | Response |
|---|---|
| `orders` at 30 M rows | declarative partitioning by month on `created_at`; the partial indexes become per-partition |
| MV refresh cost | incremental rollup table maintained by a statement trigger, or `pg_cron` on a narrower window |
| `DriverPings` write volume | shard on `driver_id` (high cardinality, even distribution); TTL keeps each shard bounded |
| Ledger growth | partition `wallet_audit_logs` by month; archive cold partitions to object storage |
| Connection count | PgBouncer in transaction pooling mode |
| Read load on analytics | run Workflow 2 against a physical replica |

---

## 9. Notes

The repository contains exactly the 17 files the assignment's structure specifies. Design
rationale that would normally live in a separate document is kept as comments inside the file
it applies to, so each script explains its own decisions where they are made.
