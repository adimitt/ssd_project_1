#!/usr/bin/env bash
# Runs performance/capture_mongo.js and writes performance/mongo_execution_stats.json.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DB="${MONGO_DB:-bitestream}"
URI="${MONGO_URI:-mongodb://127.0.0.1:27017}"

echo "[capture_mongo] $URI/$DB -> $HERE/mongo_execution_stats.json"
cd "$ROOT"
mongosh "$URI/$DB" --quiet "$HERE/capture_mongo.js" > "$HERE/mongo_execution_stats.json"

python3 - "$HERE/mongo_execution_stats.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(f"[capture_mongo] ok - {len(open(sys.argv[1]).read()):,} bytes")
for wf in ("workflow3","workflow4"):
    s=d[wf]["summary"]; c=d[wf]["control_summary"]
    print(f"  {wf}: indexed docsExamined={s['totalDocsExamined']:,} "
          f"time={s['executionTimeMillis']}ms usedIndex={s['usedIndex']}")
    print(f"  {' '*len(wf)}  control docsExamined={c['totalDocsExamined']:,} "
          f"time={c['executionTimeMillis']}ms usedIndex={c['usedIndex']}")
PY
