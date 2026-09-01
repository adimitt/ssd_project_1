#!/usr/bin/env bash
# =====================================================================================
# BiteStream :: verify.sh
#
# A single read-only health check. Answers "is everything actually working?" in about
# fifteen seconds, without rebuilding or reseeding anything.
#
#   bash verify.sh
#
# Exit code 0 = every check passed. Non-zero = at least one failed.
# For the full rebuild-and-prove pipeline use run_all.sh instead.
# =====================================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGDATABASE="${PGDATABASE:-bitestream}"
export PGUSER="${PGUSER:-bs}"
export PGPASSWORD="${PGPASSWORD:-bs}"
export MONGO_URI="${MONGO_URI:-mongodb://127.0.0.1:27017}"

if ! command -v psql >/dev/null && [ -d /opt/homebrew/opt/postgresql@17/bin ]; then
    export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
fi

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# check <label> <actual> <expected-regex>
check() {
    if [[ "$2" =~ $3 ]]; then ok "$1 ($2)"; else bad "$1 — got '$2', expected /$3/"; fi
}

q()  { psql -X -t -A -c "$1" 2>/dev/null | tr -d '[:space:]'; }
mq() { mongosh "$MONGO_URI/$PGDATABASE" --quiet --eval "$1" 2>/dev/null | tr -d '[:space:]'; }

echo "======================================================================"
echo " BiteStream health check"
echo "======================================================================"

head_ "1. Engines reachable"
if pg_isready -q; then ok "PostgreSQL $(q 'SHOW server_version')"; else bad "PostgreSQL not reachable"; fi
MV=$(mq 'db.version()')
if [ -n "$MV" ]; then ok "MongoDB $MV"; else bad "MongoDB not reachable"; fi

head_ "2. Schema objects present"
check "4 base tables"            "$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('users','wallet_audit_logs','restaurants','orders')")" '^4$'
check "audit trigger installed"  "$(q "SELECT count(*) FROM pg_trigger WHERE tgname='trg_wallet_audit'")" '^1$'
check "2 immutability guards"    "$(q "SELECT count(*) FROM pg_trigger WHERE tgname IN ('trg_audit_block_row_change','trg_audit_block_truncate')")" '^2$'
check "partial unique index"     "$(q "SELECT count(*) FROM pg_indexes WHERE indexname='idx_active_user_order'")" '^1$'
check "2 covering indexes"       "$(q "SELECT count(*) FROM pg_indexes WHERE indexname IN ('idx_orders_delivered_rest_date','idx_orders_delivered_date_rest')")" '^2$'
check "materialized view"        "$(q "SELECT count(*) FROM pg_matviews WHERE matviewname='mv_restaurant_performance'")" '^1$'
check "MV unique index (needed by REFRESH CONCURRENTLY)" "$(q "SELECT count(*) FROM pg_indexes WHERE indexname='ux_mv_rest_perf'")" '^1$'
check "2 procedures"             "$(q "SELECT count(*) FROM pg_proc WHERE proname IN ('sp_execute_checkout','sp_refresh_restaurant_performance') AND prokind='p'")" '^2$'

head_ "3. Data volumes (brief requires 100k+ rows and 500k+ pings)"
ORD=$(q 'SELECT count(*) FROM orders'); AUD=$(q 'SELECT count(*) FROM wallet_audit_logs')
[ "${ORD:-0}" -ge 100000 ] && ok "orders: $ORD (>= 100,000)" || bad "orders: ${ORD:-0} — below 100,000"
[ "${AUD:-0}" -ge 100000 ] && ok "wallet_audit_logs: $AUD (>= 100,000)" || bad "ledger: ${AUD:-0} — below 100,000"
PING=$(mq 'db.DriverPings.estimatedDocumentCount()')
REV=$(mq 'db.Reviews.estimatedDocumentCount()')
[ "${PING:-0}" -ge 100000 ] && ok "DriverPings: $PING (TTL means this drains over time)" \
                             || bad "DriverPings: ${PING:-0} — reseed with mongo_seeder.py --pings-only"
[ "${REV:-0}" -ge 100000 ] && ok "Reviews: $REV" || bad "Reviews: ${REV:-0}"

head_ "4. Business rules hold in the data"
check "no user has >1 active order" "$(q "SELECT count(*) FROM (SELECT user_id FROM orders WHERE status IN ('PREPARING','DELIVERING') GROUP BY user_id HAVING count(*)>1) x")" '^0$'
check "no negative wallet"          "$(q 'SELECT count(*) FROM users WHERE wallet_balance < 0')" '^0$'
check "no DELIVERED without delivered_at" "$(q "SELECT count(*) FROM orders WHERE status='DELIVERED' AND delivered_at IS NULL")" '^0$'
check "every ledger row's sign matches its label" "$(q "SELECT count(*) FROM wallet_audit_logs WHERE (action_type='CREDIT' AND amount_changed<=0) OR (action_type='DEBIT' AND amount_changed>=0)")" '^0$'

head_ "5. Mongo indexes"
check "2dsphere on DriverPings.location" "$(mq 'db.DriverPings.getIndexes().filter(i=>i.key.location==="2dsphere").length')" '^1$'
check "TTL = 7200s"                      "$(mq 'const t=db.DriverPings.getIndexes().find(i=>i.expireAfterSeconds!==undefined);t?t.expireAfterSeconds:0')" '^7200$'
check "TTL index is single-field"        "$(mq 'const t=db.DriverPings.getIndexes().find(i=>i.expireAfterSeconds!==undefined);t?Object.keys(t.key).length:0')" '^1$'
check "3 collections have validators"    "$(mq '["Menus","Reviews","DriverPings"].filter(c=>{const i=db.getCollectionInfos({name:c})[0];return i&&i.options&&i.options.validator}).length')" '^3$'

head_ "6. Workflows return real results"
check "WF3 \$geoNear finds active drivers within 5km" "$(mq '
const m=db.Menus.findOne({restaurant_id:1});
db.DriverPings.aggregate([{$geoNear:{near:m.location,distanceField:"d",maxDistance:5000,
  spherical:true,key:"location",query:{status:"ACTIVE"}}},{$limit:5}]).toArray().length')" '^[1-9]'
check "WF4 \$facet uses IXSCAN, not COLLSCAN" "$(mq '
const p=[{$match:{restaurant_id:7}},{$facet:{r:[{$group:{_id:"$rating",n:{$sum:1}}}]}}];
JSON.stringify(db.Reviews.explain("executionStats").aggregate(p)).includes("COLLSCAN")?"COLLSCAN":"IXSCAN"')" '^IXSCAN$'
check "WF2 window query returns 20 ranked rows" "$(q "
WITH daily AS (SELECT restaurant_id, created_at::date d, SUM(total_amount) rev FROM orders
               WHERE status='DELIVERED' AND created_at >= CURRENT_DATE - INTERVAL '90 days'
               GROUP BY 1,2)
SELECT count(*) FROM (SELECT DENSE_RANK() OVER (PARTITION BY d ORDER BY rev DESC) FROM daily
                      WHERE d = CURRENT_DATE - 1 LIMIT 20) x")" '^20$'

head_ "7. Performance evidence committed"
for f in performance/postgres_explain_analyzes.txt performance/mongo_execution_stats.json \
         docs/relational_erd.png docs/mongo_schema_map.json; do
  [ -s "$f" ] && ok "$f ($(du -h "$f" | cut -f1))" || bad "$f missing or empty"
done
check "no Seq Scan on orders in the captured WF2 plan" \
      "$(sed -n '/\[1\] WORKFLOW 2/,/\[1b\]/p' performance/postgres_explain_analyzes.txt 2>/dev/null | grep -c 'Seq Scan')" '^0$'
check "captured WF2 plan shows Index Only Scan" \
      "$(sed -n '/\[1\] WORKFLOW 2/,/\[1b\]/p' performance/postgres_explain_analyzes.txt 2>/dev/null | grep -c 'Index Only Scan')" '^[1-9]'

echo ""
echo "======================================================================"
printf " %d passed, %d failed\n" "$PASS" "$FAIL"
echo "======================================================================"
[ "$FAIL" -eq 0 ] || exit 1
