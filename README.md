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
| **Team number** | `<FILL IN>` |
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
# 0. Engines. Either use Docker …
docker compose up -d

#    … or run them natively (macOS):
#    brew install postgresql@17 && brew services start postgresql@17
#    export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
#    psql -d postgres -c "CREATE ROLE bs LOGIN PASSWORD 'bs' CREATEDB;"
#    psql -d postgres -c "CREATE DATABASE bitestream OWNER bs;"

# 1. Python dependencies
python3 -m pip install -r data_generation/requirements.txt

# 2. Connection settings (localhost defaults are already correct)
cp .env.example .env

# 3. Build everything, seed it, run all four workflows, and verify
bash run_all.sh
```

`run_all.sh --quick` runs the identical pipeline at 2 % scale in a few seconds.

### Running the pieces individually

```bash
export PGHOST=127.0.0.1 PGDATABASE=bitestream PGUSER=bs PGPASSWORD=bs

psql -v ON_ERROR_STOP=1 -f sql/01_schema_ddl.sql
psql -v ON_ERROR_STOP=1 -f sql/03_triggers_and_audit.sql     # BEFORE any data exists
psql -v ON_ERROR_STOP=1 -f sql/04_stored_procedures.sql
python3 data_generation/postgres_seeder.py                   # COPY, then rebuild indexes
psql -v ON_ERROR_STOP=1 -f sql/02_indexes.sql
psql -v ON_ERROR_STOP=1 -f sql/05_materialized_views.sql
psql -f sql/06_window_analytics.sql                          # Workflow 2

mongosh bitestream mongo/01_collections_and_indexes.js
python3 data_generation/mongo_seeder.py
mongosh bitestream mongo/02_workflow3_geonear.js             # Workflow 3
mongosh bitestream mongo/03_workflow4_facet.js               # Workflow 4

psql -f sql/99_verification_suite.sql                        # 22 assertions
python3 tests/test_repeatable_read.py                        # 6 concurrency assertions
```

> **Before the viva, re-run `python3 data_generation/mongo_seeder.py --pings-only`.**
> `DriverPings` carries a 2-hour TTL index. Telemetry older than that is deleted
> automatically, so a collection seeded yesterday will be empty when you demo.

---

## 3. What is in the repository

```
sql/01_schema_ddl.sql            4 tables, PK/FK, 11 CHECK constraints
sql/02_indexes.sql               6 indexes: 4 partial, 2 covering, 1 partial-unique
sql/03_triggers_and_audit.sql    audit trigger + 2 immutability guards + self-test
sql/04_stored_procedures.sql     WORKFLOW 1 — sp_execute_checkout (transaction control)
sql/05_materialized_views.sql    mv_restaurant_performance + REFRESH CONCURRENTLY
sql/06_window_analytics.sql      WORKFLOW 2 — CTEs, window frames, DENSE_RANK
sql/99_verification_suite.sql    22 PASS/FAIL assertions across every rubric item

mongo/01_collections_and_indexes.js   validators + 2dsphere + TTL, driven by the schema map
mongo/02_workflow3_geonear.js         WORKFLOW 3 — $geoNear, nearest active driver
mongo/03_workflow4_facet.js           WORKFLOW 4 — $facet review analytics

data_generation/postgres_seeder.py    500k relational rows
data_generation/mongo_seeder.py       701k documents
data_generation/requirements.txt      pinned dependencies

docs/relational_erd.png          ERD, including the trigger edge and the partial index
docs/mongo_schema_map.json       SINGLE SOURCE OF TRUTH for the Mongo schema
docs/make_erd.py                 regenerates the ERD
docs/filedocs/                   one deep-dive document per source file

performance/postgres_explain_analyzes.txt   raw EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
performance/mongo_execution_stats.json      raw explain("executionStats")
performance/capture_postgres.sh             regenerates the above
performance/capture_mongo.sh / .js

tests/test_repeatable_read.py    the two-session concurrency proof
verify.sh                        31-point read-only health check (~15 s, no rebuild)
run_all.sh                       full build + seed + verify, in dependency order
docker-compose.yml               pinned PostgreSQL 17 + MongoDB 8
ARCHITECTURE.md                  the design document this implementation follows
```

**`docs/mongo_schema_map.json` is not documentation — it is the definition.**
`mongo/01_collections_and_indexes.js` and `data_generation/mongo_seeder.py` both read it
and apply it, so the schema map and the database cannot drift apart.

**Per-file deep dives live in [`docs/filedocs/`](docs/filedocs/)** — one Markdown document
per source file, covering every function, every constraint and every design decision.
Start at [`docs/filedocs/README.md`](docs/filedocs/README.md).

---

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
| `orders` | 300,226 | | `Menus` | 1,000 |
| — `DELIVERED` | 294,016 | | `Reviews` | 200,000 |
| — active | 6,210 | | `DriverPings` | 499,800 |
| `wallet_audit_logs` | 150,232 | | | |
| `users` | 50,003 | | **Total documents** | **700,800** |
| `restaurants` | 1,002 | | | |
| `checkout_attempts` | 402 | | Mongo data + indexes | 172 MB |
| **Total relational rows** | **501,865** | | PostgreSQL database | 114 MB |

Both the "100k+ rows" and "500k+ pings" requirements are cleared with margin.
Full build time on the reference machine: **PostgreSQL ~11 s, MongoDB ~13 s.**

**Every one of the 150,232 ledger rows was written by the trigger.** `COPY` does not fire
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
| **WF3** — `$geoNear` 5 km | 500,000 docs · 233 ms | **42,048 docs** · 80 ms | **11.9× fewer docs** |
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
`$sort`/`$group`/`$limit` work — examines all 500,000 documents in 240 ms.

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

```bash
bash verify.sh                            # 31/31 PASS - read-only, ~15 s, no rebuild
psql -f sql/99_verification_suite.sql     # 22/22 PASS
python3 tests/test_repeatable_read.py     #  6/6  PASS
```

`verify.sh` is the fastest answer to "is it working?": it checks engine reachability, every
schema object, data volumes against the brief's thresholds, the business rules holding in
the actual data, the Mongo indexes, all three workflows returning real results, and the
committed performance evidence. It exits non-zero on any failure, and it has been tested
against a deliberately broken database to confirm it detects one.

| Group | Covered |
|---|---|
| T01–T06 | all six `sp_execute_checkout` outcomes |
| T07–T09 | trigger: CREDIT, DEBIT, and no-op suppression via the `WHEN` clause |
| T10–T11 | ledger immutability: `UPDATE` and `DELETE` both rejected |
| T12–T12b | partial unique index blocks a 2nd active order, permits 500 `DELIVERED` |
| T13–T15 | `CHECK` constraints on wallet, amount and status |
| T16 | atomicity: a failed debit changes neither balance nor ledger |
| T17–T18 | `REFRESH … CONCURRENTLY`; `LEFT JOIN` keeps zero-order restaurants |
| T19–T19b | `ROWS` spans 10 calendar days where `RANGE` spans exactly 7 |
| T20 | `DENSE_RANK` vs `RANK` on a tie |
| A / B / C | REPEATABLE READ → 40001; READ COMMITTED → stale read; 8-thread contention |

The strongest single assertion is the last one in `test_repeatable_read.py`:
after eight threads contend on one wallet,

```
final_balance == opening_balance + SUM(wallet_audit_logs.amount_changed)
```

holds **exactly**. No code path can move money without the trigger recording it.

### Two corrections our own tests forced

1. **`RANGE` does not supply zeros for missing days.** It fixes the window *boundary* —
   `ROWS BETWEEN 6 PRECEDING` reached back 10 calendar days in our fixture where
   `RANGE BETWEEN INTERVAL '6 days' PRECEDING` reached back exactly 7 — but neither frame
   invents a row for a day with no orders. Only the `generate_series` gap fill makes the
   denominator 7. A correct 7-day moving average needs **both**, which is why
   `sql/06_window_analytics.sql` does both. (T19 / T19b)
2. **`CALL` rejects subqueries in its arguments** — `cannot use subquery in CALL argument`.
   Fixture ids must be captured with `\gset` and passed as literals.

---

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

## 9. Attribution

`ARCHITECTURE.md` is the design document; this repository is its implementation. Every
non-obvious decision carries a **Why / Viva** comment in the source, and
[`docs/filedocs/`](docs/filedocs/) explains each file end to end.
