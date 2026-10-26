#!/usr/bin/env bash
# Hash-chain tamper detection demo on a THROWAWAY ClickHouse database. The real database
# (proba_audit) is only read, never written.
#   1. copy the first 300 events of the workspace chain into proba_audit_tamper
#   2. verify the copy: intact
#   3. alter one stored event in the copy (ALTER TABLE ... UPDATE) -> verifyChain reports hash_mismatch
#   4. restore the copy, delete one event -> verifyChain reports broken_link
#   5. drop the throwaway database; verify the real chain again: still intact
# Exit code 0 when both manipulations were detected and the real chain is intact.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker curl jq
load_env
WS=seedbed; TDB=proba_audit_tamper
quiet=0; [ "${1:-}" = "--quiet" ] && quiet=1
say() { [ "$quiet" = 1 ] || printf '%s\n' "$*"; }
result=0

fresh_copy() {
  ch "DROP DATABASE IF EXISTS $TDB" >/dev/null
  ch "CREATE DATABASE $TDB" >/dev/null
  ch "CREATE TABLE $TDB.audit_events AS $CH_DB.audit_events" >/dev/null
  ch "INSERT INTO $TDB.audit_events SELECT * FROM $CH_DB.audit_events WHERE workspace_id='$WS' ORDER BY ingested_at, event_id LIMIT 300" >/dev/null
}
brief() { jq -c '{ok, checked, problems: [.problems[]? | {type, eventId}]}' <<<"$1"; }

step "tamper demo (throwaway database $TDB)"
before="$(verify_chain "$CH_DB" "$WS")"
say "real chain before:      $(brief "$before")"

fresh_copy
intact="$(verify_chain "$TDB" "$WS")"
say "copy, untouched:        $(brief "$intact")"
if [ "$(jq -r .ok <<<"$intact")" = true ]; then pass "the copy of the chain verifies"; else fail "the untouched copy does not verify" "$intact"; result=1; fi

victim="$(ch "SELECT event_id FROM $TDB.audit_events WHERE outcome='success' ORDER BY ingested_at LIMIT 1 OFFSET 20")"
if [ -z "$victim" ]; then
  skip "tamper demo" "the audit trail is empty: run ./seed.sh first"; ch "DROP DATABASE IF EXISTS $TDB" >/dev/null; exit 0
fi
say "tampering: ALTER TABLE $TDB.audit_events UPDATE outcome='failure' WHERE event_id='$victim'"
ch "ALTER TABLE $TDB.audit_events UPDATE outcome='failure' WHERE event_id='$victim' SETTINGS mutations_sync=2" >/dev/null
altered="$(verify_chain "$TDB" "$WS")"
say "copy, one event altered: $(brief "$altered")"
if [ "$(jq -r .ok <<<"$altered")" = false ] && jq -e --arg id "$victim" '.problems[]? | select(.type=="hash_mismatch" and .eventId==$id)' <<<"$altered" >/dev/null; then
  pass "an altered event is reported as hash_mismatch (that very event)"
else fail "the altered event was not detected as hash_mismatch" "$altered"; result=1; fi

fresh_copy
victim2="$(ch "SELECT event_id FROM $TDB.audit_events ORDER BY ingested_at LIMIT 1 OFFSET 50")"
say "tampering: ALTER TABLE $TDB.audit_events DELETE WHERE event_id='$victim2'"
ch "ALTER TABLE $TDB.audit_events DELETE WHERE event_id='$victim2' SETTINGS mutations_sync=2" >/dev/null
deleted="$(verify_chain "$TDB" "$WS")"
say "copy, one event deleted: $(brief "$deleted")"
if [ "$(jq -r .ok <<<"$deleted")" = false ] && jq -e '.problems[]? | select(.type=="broken_link")' <<<"$deleted" >/dev/null; then
  pass "a deleted event is reported as broken_link"
else fail "the deleted event was not detected as broken_link" "$deleted"; result=1; fi

ch "DROP DATABASE IF EXISTS $TDB" >/dev/null
after="$(verify_chain "$CH_DB" "$WS")"
say "real chain after:       $(brief "$after")"
if [ "$(jq -r .ok <<<"$after")" = true ]; then pass "the real chain is untouched and intact"; else fail "the real chain does not verify" "$after"; result=1; fi
exit "$result"
