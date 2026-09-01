# Orchestration & infrastructure

Covers `verify.sh`, `run_all.sh`, `docker-compose.yml`,
`data_generation/requirements.txt`, `.gitignore`, `.env.example`.

---

## `verify.sh`

A **read-only** health check answering "is everything actually working?" in about fifteen
seconds, without rebuilding or reseeding anything. Exits non-zero on any failure.

```bash
bash verify.sh      # 31 checks
```

| Group | Checks |
|---|---|
| 1. Engines | PostgreSQL and MongoDB reachable, versions printed |
| 2. Schema objects | 4 tables, audit trigger, 2 immutability guards, partial unique index, 2 covering indexes, MV, MV unique index, 2 procedures |
| 3. Volumes | `orders` and `wallet_audit_logs` >= 100k; `DriverPings` and `Reviews` present |
| 4. Business rules **in the data** | no user with >1 active order; no negative wallet; no `DELIVERED` without `delivered_at`; every ledger row's sign matches its label |
| 5. Mongo indexes | 2dsphere present; TTL is exactly 7200s **and single-field**; 3 validators |
| 6. Workflows | WF3 returns drivers; WF4 plan is `IXSCAN` not `COLLSCAN`; WF2 returns 20 ranked rows |
| 7. Evidence | all four committed artefacts non-empty; captured WF2 plan has no `Seq Scan` and does have `Index Only Scan` |

Group 4 is the one worth pointing at in the viva: it does not check that a *constraint
exists*, it checks that **the data actually obeys it**. A constraint that exists but was
added after bad data got in would pass a catalog check and fail this one.

**It has been tested against a deliberately broken database.** Dropping
`idx_active_user_order`, `trg_wallet_audit` and `ix_pings_ttl` produced 4 failures and a
non-zero exit; restoring them returned it to 31/31. A health check that cannot fail is
decoration.

`run_all.sh` rebuilds and proves; `verify.sh` only inspects. Use `verify.sh` before the
viva, `run_all.sh` when something is actually broken.

---

## `run_all.sh`

Builds the entire project from an empty pair of servers, **in the one order that actually
works**, then proves it.

```bash
bash run_all.sh              # full dataset
bash run_all.sh --quick      # 2% scale smoke test
bash run_all.sh --no-capture # skip the EXPLAIN capture
```

### The order, and why each step sits where it does

| Step | File | Reason for this position |
|---|---|---|
| 1 | `sql/01_schema_ddl.sql` | nothing else can run without the tables |
| 2 | `sql/03_triggers_and_audit.sql` | installed **before any data exists**, so every audit row in the database was genuinely written by the trigger |
| 3 | `sql/04_stored_procedures.sql` | creates `checkout_attempts`, which the seeder truncates |
| 4 | `postgres_seeder.py` | `COPY` the bulk → set-based `UPDATE`s for the ledger → rebuild indexes → `VACUUM (ANALYZE)` |
| 5 | `sql/02_indexes.sql` | re-run standalone to **prove it is idempotent** — the seeder already replayed it |
| 6 | `sql/05_materialized_views.sql` | needs data to be meaningful; also recreates the view that step 1's `CASCADE` dropped |
| 7 | `mongo/01_collections_and_indexes.js` | validators + indexes |
| 8 | `mongo_seeder.py` | drops, loads, then rebuilds indexes (TTL last) |
| 9 | all four workflows | |
| 10 | verification suite + concurrency test | |
| — | performance capture | **last**: statistics must reflect the final data |

### Preflight

Checks `psql`, `mongosh` and `python3` are on `PATH`, that PostgreSQL accepts connections
and MongoDB answers a ping, then prints both server versions. Failing here with a clear
message beats failing in step 6 with a stack trace.

It also adds Homebrew's keg-only PostgreSQL to `PATH` automatically:

```bash
if ! command -v psql >/dev/null && [ -d /opt/homebrew/opt/postgresql@17/bin ]; then
    export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
fi
```

### A bash detail worth knowing

The script runs under `set -euo pipefail`. An early version piped Workflow 2's output
through `head -30`:

```bash
psql -f sql/06_window_analytics.sql | head -30      # WRONG
```

`head` exits after 30 lines, `psql` receives **SIGPIPE**, `pipefail` propagates the failure,
and `set -e` **aborts the entire script** — silently skipping every remaining step. Replaced
with:

```bash
psql -f sql/06_window_analytics.sql | sed -n '1,30p'
```

`sed` reads its input to the end, so no SIGPIPE. This is a classic and it cost us a
confusing debugging session.

### Exit behaviour

`set -e` means any failing step aborts the run — which is what you want: a green run is a
real green run.

---

## `docker-compose.yml`

Pins **PostgreSQL 17** and **MongoDB 8** so every team member and the grader run identical
servers.

```yaml
command: >
  postgres
  -c shared_buffers=512MB
  -c work_mem=32MB
  -c maintenance_work_mem=256MB
  -c max_wal_size=4GB
  -c random_page_cost=1.1
  -c track_io_timing=on
```

| Setting | Why |
|---|---|
| `random_page_cost=1.1` | the default `4.0` models a spinning disk and pushes the planner towards sequential scans. **This is the difference between an `Index Only Scan` and a `Seq Scan` in the Workflow 2 proof.** |
| `work_mem=32MB` | the Workflow 2 `HashAggregate` still spills (`Disk Usage: 1584kB`); raising it further would avoid that but is not needed for the proof |
| `maintenance_work_mem=256MB` | faster index builds during the seed |
| `max_wal_size=4GB` | fewer checkpoints during the bulk `COPY` |
| `track_io_timing=on` | makes `EXPLAIN (ANALYZE, BUFFERS)` report real I/O timings |

Both services have healthchecks so `docker compose up -d` reports readiness rather than just
"started".

Named volumes (`pgdata`, `mongodata`) persist across `down`; `down -v` is the full reset.

> Nothing in the project *depends* on Docker — the reference run for this submission used
> Homebrew PostgreSQL 17.11 and a locally installed MongoDB 8.3.7.

---

## `data_generation/requirements.txt`

```
psycopg[binary]==3.3.5
pymongo==4.17.0
Faker==40.37.0
matplotlib==3.10.6
```

Pinned to the versions actually developed and tested against, so a grader re-running the
seeders gets identical behaviour.

- **`psycopg[binary]`, not `psycopg2`** — psycopg 3's streaming `cursor.copy()` API is what
  makes the 300k-row `COPY` fast. The binary wheel bundles `libpq`, so no separate
  `postgresql-client` install is needed.
- **`matplotlib`** is only needed to *regenerate* the ERD. The committed PNG means it is
  optional in practice.

---

## `.gitignore`

Enforces the brief's submission rules, which are explicit about what must **not** be in the
ZIP:

| Excluded | Why |
|---|---|
| `venv/`, `__pycache__/`, `*.pyc` | the brief forbids them |
| `*.dump`, `*.csv`, `*.tsv`, `*.bson`, `dump/` | the brief forbids raw data dumps — only the generation scripts may ship |
| `pgdata/`, `mongodata/` | local Docker volumes |
| `.env` | real credentials (`.env.example` is committed) |
| `.DS_Store` | macOS noise |

It carries an explicit note that `performance/postgres_explain_analyzes.txt` and
`performance/mongo_execution_stats.json` **are** committed on purpose — they are the graded
Performance Proof deliverable, and it would be easy to sweep them out with a broader rule.

Verify before zipping:

```bash
git status --ignored
du -sh .        # currently ~1 MB, limit is 20 MB
```

---

## `.env.example`

Every script reads standard environment variables with localhost defaults; **none of them
hardcode a host or a password.**

```
PGHOST=127.0.0.1
PGPORT=5432
PGDATABASE=bitestream
PGUSER=bs
PGPASSWORD=bs
MONGO_URI=mongodb://127.0.0.1:27017
MONGO_DB=bitestream
```

`cp .env.example .env` and edit if your servers are elsewhere.

## Viva questions

1. Why must the trigger be installed before the seeder runs?
2. Why is the performance capture last?
3. What does `random_page_cost` do, and why change it?
4. Why is `sql/02_indexes.sql` run twice?
5. Why `psycopg` 3 rather than `psycopg2`?
6. What is not allowed in the submitted ZIP, and how do you enforce it?
