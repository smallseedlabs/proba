#!/usr/bin/env bash
# Run SQL against the local ClickHouse (database proba_audit) and print the result as a table.
#   ./sql.sh "SELECT action, count() FROM audit_events GROUP BY action ORDER BY 2 DESC"
#   echo "SELECT 1" | ./sql.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need curl
load_env
q="${1:-$(cat)}"
ch "$q FORMAT PrettyCompactMonoBlock"
