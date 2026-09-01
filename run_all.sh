#!/usr/bin/env bash
# =====================================================================================
# BiteStream :: run_all.sh
#
# Builds the entire project from an empty pair of database servers, in the one order
# that actually works, and then proves it.
#
#   bash run_all.sh              # full dataset  (~500k relational rows, 701k documents)
#   bash run_all.sh --quick      # 2% scale, for a fast smoke test
#   bash run_all.sh --no-capture # skip the EXPLAIN capture step
#
# WHY THIS ORDER
#   01 schema        -> nothing else can run without the tables
#   03 triggers      -> installed BEFORE any data exists, so every audit row in the
#                       database was genuinely written by the trigger
#   seeder           -> COPY the bulk, then set-based UPDATEs to drive the trigger,
#                       then rebuild indexes, then VACUUM (ANALYZE)
#   02 indexes       -> replayed by the seeder after the load; re-run here so the file
#                       itself is demonstrably runnable standalone
#   04 procedures    -> need the CHECK, the trigger and the partial index to exist in
#                       order for their exception handlers to be testable
#   05 mat. view     -> needs data to be meaningful
#   06 analytics     -> needs the covering index for the Index Only Scan
#   mongo            -> collections and validators, then load, then indexes
#   capture          -> last: statistics must reflect the final data
# =====================================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

SCALE=1.0
CAPTURE=1
for arg in "$@"; do
    case "$arg" in
        --quick)      SCALE=0.02 ;;
        --no-capture) CAPTURE=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGDATABASE="${PGDATABASE:-bitestream}"
export PGUSER="${PGUSER:-bs}"
export PGPASSWORD="${PGPASSWORD:-bs}"
export MONGO_URI="${MONGO_URI:-mongodb://127.0.0.1:27017}"

# Homebrew keeps postgresql@17 off the default PATH.
if ! command -v psql >/dev/null && [ -d /opt/homebrew/opt/postgresql@17/bin ]; then
    export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
fi

PSQL=(psql -X -q -v ON_ERROR_STOP=1)

step() { printf '\n\033[1m=== %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "missing required command: $1" >&2; exit 1; }; }

need psql
need mongosh
need python3

step "0/10  preflight"
pg_isready -q || { echo "PostgreSQL is not accepting connections on $PGHOST:$PGPORT" >&2; exit 1; }
mongosh "$MONGO_URI" --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null \
    || { echo "MongoDB is not reachable at $MONGO_URI" >&2; exit 1; }
echo "  PostgreSQL $(psql -X -t -A -c 'SHOW server_version')  |  MongoDB $(mongosh "$MONGO_URI" --quiet --eval 'db.version()')"
echo "  scale: $SCALE"

step "1/10  sql/01_schema_ddl.sql"
"${PSQL[@]}" -f sql/01_schema_ddl.sql

step "2/10  sql/03_triggers_and_audit.sql   (before any data exists)"
"${PSQL[@]}" -f sql/03_triggers_and_audit.sql

step "3/10  sql/04_stored_procedures.sql"
"${PSQL[@]}" -f sql/04_stored_procedures.sql

step "4/10  data_generation/postgres_seeder.py"
python3 data_generation/postgres_seeder.py --scale "$SCALE"

step "5/10  sql/02_indexes.sql   (re-run standalone to prove it is idempotent)"
"${PSQL[@]}" -f sql/02_indexes.sql

step "6/10  sql/05_materialized_views.sql"
"${PSQL[@]}" -f sql/05_materialized_views.sql
psql -X -q -c 'CALL sp_refresh_restaurant_performance();'

step "7/10  mongo/01_collections_and_indexes.js"
mongosh "$MONGO_URI/$PGDATABASE" --quiet mongo/01_collections_and_indexes.js

step "8/10  data_generation/mongo_seeder.py"
python3 data_generation/mongo_seeder.py --scale "$SCALE"

step "9/10  workflows"
echo "--- Workflow 2 (SQL window analytics)"
# NOTE: no "| head -N" here. head exits early, psql takes SIGPIPE, and with
# "set -o pipefail" that aborts the whole script. sed reads its input to the end.
psql -X -q -f sql/06_window_analytics.sql | sed -n '1,30p' 
echo "--- Workflow 3 (\$geoNear)"
mongosh "$MONGO_URI/$PGDATABASE" --quiet mongo/02_workflow3_geonear.js
echo "--- Workflow 4 (\$facet)"
mongosh "$MONGO_URI/$PGDATABASE" --quiet mongo/03_workflow4_facet.js

step "10/10 verification"
psql -X -q -f sql/99_verification_suite.sql
python3 tests/test_repeatable_read.py

if [ "$CAPTURE" = "1" ]; then
    step "performance capture"
    bash performance/capture_postgres.sh
    bash performance/capture_mongo.sh
fi

printf '\n\033[1mAll steps completed.\033[0m\n'
echo "  EXPLAIN evidence : performance/postgres_explain_analyzes.txt"
echo "                     performance/mongo_execution_stats.json"
echo "  ERD              : docs/relational_erd.png   (regenerate: python3 docs/make_erd.py)"
echo ""
echo "  REMINDER: DriverPings has a 2-hour TTL. Before the viva, re-run:"
echo "      python3 data_generation/mongo_seeder.py --pings-only"
