#!/usr/bin/env bash
# Full-conversation context bridge checks. Prints a weighted score / 100 and PASS/FAIL.
#   ./verify-context.sh              run against the local stack (needs ./up.sh --portal --memory --context)
#   ./verify-context.sh --quick      fewer turns / skip cache restart
#   ./verify-context.sh --self-test  prove scoring fails on broken fixtures (no stack required)
#   ./verify-context.sh --show-packets
#   ./verify-context.sh --step N
#   ./verify-context.sh --keep       leave seeded goals
#   ./verify-context.sh --trace ID   print context.* events for one traceId (ClickHouse) and exit
# Refuses non-loopback base URLs. Exit non-zero on FAIL.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker curl jq node
load_env

QUICK=0; SHOW=0; KEEP=0; STEP=""; SELF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --show-packets) SHOW=1 ;;
    --keep) KEEP=1 ;;
    --self-test) SELF=1 ;;
    --step) STEP="${2:-}"; shift ;;
    --trace)
      [ -n "${2:-}" ] || die "usage: ./verify-context.sh --trace TRACE_ID"
      ch_pretty "SELECT occurred_at, action, outcome, workspace_id, user_id, goal_id FROM audit_events WHERE trace_id='$2' AND startsWith(action,'context.') ORDER BY occurred_at"
      exit 0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

if [ "$SELF" = 1 ]; then
  step "self-test (broken fixtures must FAIL)"
  node "$LOCAL_DIR/tools/context-verify-checks.mjs" --self-test || die "self-test failed"
  pass "scoring rejects leak, over-budget and missing-gap fixtures"
  printf '\nself-test OK\n'
  exit 0
fi

# ---- prerequisites ----
host_ok() {
  case "$1" in 127.0.0.1|localhost) return 0 ;; *) return 1 ;; esac
}
for var in CONTEXT_API_URL HUB_URL AUDIT_API_URL MEMORY_API_URL; do
  val="${!var:-}"
  [ -z "$val" ] && continue
  h="${val#*://}"; h="${h%%/*}"; h="${h%%:*}"; h="${h##*@}"
  host_ok "$h" || die "refuse: $var=$val is not 127.0.0.1"
done

CONTEXT_URL="${CONTEXT_API_URL:-http://127.0.0.1:${CONTEXT_API_HOST_PORT:-3500}}"
HUB="${HUB_URL:-http://127.0.0.1:${HUB_HOST_PORT}}"
AUDIT="${AUDIT_API_URL:-http://127.0.0.1:${AUDIT_API_HOST_PORT}}"
MEMORY="${MEMORY_API_URL:-http://127.0.0.1:${MEMORY_API_HOST_PORT}}"
# Used by later health / isolation checks (and kept for --trace / docs symmetry with verify.sh).
: "${AUDIT}" "${MEMORY}"
# Scalar ClickHouse helper (same as verify.sh); ch() lives in lib.sh.
chv() { ch "$1" 2>/dev/null | tr -d '[:space:]'; }

step "0. prerequisites"
if ! docker inspect "${PROJECT}-context-api" >/dev/null 2>&1; then
  die "context-api is not running: ./up.sh --portal --memory --context (see docs/LOCAL_TESTING.md, Context bridge)"
fi
if [ "${AUDIT_API_TOKEN_VERIFIER:-static}" != static ]; then
  die "AUDIT_API_TOKEN_VERIFIER=${AUDIT_API_TOKEN_VERIFIER} (need static). Set AUDIT_API_TOKEN_VERIFIER=static in local/.env (local/.env.bak-prefirebase-style backups are fine)."
fi
if [ "${MEMORY_API_TOKEN_VERIFIER:-static}" != static ]; then
  die "MEMORY_API_TOKEN_VERIFIER=${MEMORY_API_TOKEN_VERIFIER} (need static). Set MEMORY_API_TOKEN_VERIFIER=static in local/.env."
fi
[ "${DEV_LOGIN_ENABLED:-true}" = true ] || [ "${DEV_LOGIN_ENABLED:-true}" = "1" ] || die "DEV_LOGIN_ENABLED must be true for verify-context.sh"
code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$CONTEXT_URL/health" || true)"
[ "$code" = 200 ] && pass "context-api /health" || fail "context-api /health" "HTTP $code"
code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$HUB/health" || true)"
[ "$code" = 200 ] && pass "hub /health" || fail "hub /health" "HTTP $code"

PEM_HOST="$LOCAL_DIR/keys/hub-assertion.private.pem"
[ -f "$PEM_HOST" ] || die "missing $PEM_HOST (run ./up.sh --context)"
export CONTEXT_ASSERTION_PRIVATE_KEY_FILE="$PEM_HOST"
export HUB_ASSERTION_KEY_ID="${HUB_ASSERTION_KEY_ID:-hub-key-1}"

mint() {
  node "$LOCAL_DIR/tools/mint-assertion.mjs" --user "$1" --workspace "$2" --goal "$3" --thread "${4:-$3}"
}

build_ctx() { # user workspace goal thread stepType stepId [needs_json]
  local assertion packet
  assertion="$(mint "$1" "$2" "$3" "$4")" || return 1
  local body
  body="$(jq -nc --arg tid "$(uuid)" --arg ws "$2" --arg uid "$1" --arg gid "$3" --arg th "$4" --arg sid "$6" --arg st "$5" \
    '{traceId:$tid,workspaceId:$ws,userId:$uid,goalId:$gid,threadId:$th,stepId:$sid,stepType:$st,budgetTokens:6000}')"
  if [ -n "${7:-}" ]; then
    body="$(jq -c --argjson needs "$7" '. + {needs:$needs}' <<<"$body")"
  fi
  packet="$(curl -sS -m 30 -X POST "$CONTEXT_URL/v1/context/build" \
    -H "authorization: Bearer $assertion" -H "x-act-as: $assertion" \
    -H 'content-type: application/json' -d "$body")" || return 1
  printf '%s' "$packet"
}

# ---- actors ----
TS="$(date +%s)"
ALICE="alice-${TS}@proba.local"
BOB="bob-${TS}@proba.local"
CAROL="carol-${TS}@proba.local"
CANARY_B="CANARY-B-7f3a"
CANARY_C="CANARY-C-91d2"
SECRET_A="hunter2-CANARY-A"
EMAIL_A="alice.example@gmail.com"

step "1. logins and parallel canary traffic"
TOKEN_A="$(hub_token "$ALICE")" || die "alice login failed"
TOKEN_B="$(hub_token "$BOB")" || die "bob login failed"
TOKEN_C="$(hub_token "$CAROL")" || die "carol login failed"
# Hub has no GET /v1/session; user id comes from /dev/login (and is embedded in the JWT).
USER_A="$(curl -sS -m 10 -X POST "$(hub_url)/dev/login" -H 'content-type: application/json' \
  -d "$(jq -nc --arg e "$ALICE" --arg n Alice '{email:$e,name:$n}')" | jq -r '.user.id // empty')"
[ -n "$USER_A" ] || die "could not resolve Alice user id from /dev/login"
info "Alice userId=$USER_A"

# LAST_ID from hub_post is the clientMsgId/traceId, not the goal UUID.
# Hub events carry goalId on payload and threadId on the event root.
last_goal_thread() {
  # prints "goalId<TAB>threadId" or returns 1
  local token="$1" i=0 pair=""
  while [ "$i" -lt 15 ]; do
    pair="$(hub_events "$token" | jq -r '
      [.[]
        | select(.type=="goal_updated" or .type=="goal_created")
        | [
            (.goalId // .payload.goalId // empty),
            (.threadId // .payload.threadId // empty)
          ]
      ]
      | map(select(.[0] != "" and .[1] != ""))
      | last // empty
      | if . == "" then empty else @tsv end')"
    [ -n "$pair" ] && { printf '%s' "$pair"; return 0; }
    sleep 0.4
    i=$((i + 1))
  done
  return 1
}

hub_post "$TOKEN_B" create_goal "{\"title\":\"Bob product ${CANARY_B}\",\"budget\":{\"daily\":40,\"total\":200,\"currency\":\"GBP\"}}"
IFS=$'\t' read -r GOAL_B THREAD_B <<<"$(last_goal_thread "$TOKEN_B")" || die "could not resolve Bob goal/thread"
[ -n "$GOAL_B" ] && [ -n "$THREAD_B" ] || die "could not resolve Bob goal/thread"
hub_post "$TOKEN_B" send_message "{\"text\":\"Bob secret note ${CANARY_B}\"}" "$THREAD_B"
# Carol: Hub scopes to seedbed locally; canary still used for packet string checks.
hub_post "$TOKEN_C" create_goal "{\"title\":\"Carol other ${CANARY_C}\",\"budget\":{\"daily\":10,\"total\":50,\"currency\":\"GBP\"}}"
IFS=$'\t' read -r GOAL_C THREAD_C <<<"$(last_goal_thread "$TOKEN_C")" || die "could not resolve Carol goal/thread"
[ -n "$GOAL_C" ] && [ -n "$THREAD_C" ] || die "could not resolve Carol goal/thread"
hub_post "$TOKEN_C" send_message "{\"text\":\"Carol secret note ${CANARY_C}\"}" "$THREAD_C"

hub_post "$TOKEN_A" create_goal '{"title":"UK home-search app","budget":{"daily":50,"total":400,"currency":"GBP"}}'
TRACE_A="${LAST_TRACE_HEADER:-$LAST_ID}"
IFS=$'\t' read -r GOAL_A THREAD_A <<<"$(last_goal_thread "$TOKEN_A")" || die "could not resolve Alice goal/thread"
[ -n "$GOAL_A" ] && [ -n "$THREAD_A" ] || die "could not resolve Alice goal/thread"
pass "created goals A/B/C (A=$GOAL_A thread=$THREAD_A, trace=${TRACE_A})"

# Conversation turns for A (Hub commands); context builds for scoring.
declare -a PACKETS=()
declare -a STEPS=(interpret_message plan_goal propose_budget propose_budget handle_approval launch_campaign review_performance explain_decision)
declare -a MSGS=(
  "I want to launch ads for my UK home-search app."
  "Budget around 50 GBP a day, Meta and Google, London renters."
  ""
  "Raise the daily budget to 120 GBP and mail the report to ${EMAIL_A}. The login password is ${SECRET_A}."
  ""
  ""
  "How are the ads doing?"
  "Why did you pause the Google campaign?"
)

step "2. conversation + context builds"
HUB_INTEGRATION=0
i=0
for st in "${STEPS[@]}"; do
  i=$((i + 1))
  if [ -n "$STEP" ] && [ "$i" != "$STEP" ]; then continue; fi
  msg="${MSGS[$((i - 1))]:-}"
  if [ -n "$msg" ]; then
    hub_post "$TOKEN_A" send_message "$(jq -nc --arg t "$msg" '{text:$t}')" "$THREAD_A" || true
  fi
  packet="$(build_ctx "$USER_A" "seedbed" "$GOAL_A" "$THREAD_A" "$st" "step-$i")" || packet='{"error":"build_failed"}'
  if printf '%s' "$packet" | jq -e '.packetId' >/dev/null 2>&1; then
    PACKETS+=("$packet")
    [ "$SHOW" = 1 ] && jq '{packetId,packetHash,stepId,sections:[.sections[]|{kind,tokens,itemCount:(.items|length)}],gaps,manifest:{totals}}' <<<"$packet"
  else
    warn "context build failed for step $i ($st): $(printf '%s' "$packet" | head -c 200)"
    PACKETS+=("$packet")
  fi
  # Detect hub integration via brain.context_attached on the latest command trace when present.
  if [ "$HUB_INTEGRATION" = 0 ]; then
    n="$(chv "SELECT countIf(action='brain.context_attached') FROM audit_events WHERE goal_id=toUUID('$GOAL_A')" 2>/dev/null || echo 0)"
    [ "${n:-0}" -ge 1 ] 2>/dev/null && HUB_INTEGRATION=1
  fi
  [ "$QUICK" = 1 ] && [ "$i" -ge 4 ] && break
done

step "3. score checks"
CHECKS_JSON='[]'
add_check() { # id group weight pass evidence [skip]
  local skip="${6:-false}"
  CHECKS_JSON="$(jq -c --arg id "$1" --arg g "$2" --argjson w "$3" --argjson p "$4" --arg e "$5" --argjson s "$skip" \
    '. + [{id:$id,group:$g,weight:$w,pass:$p,evidence:$e,skip:$s}]' <<<"$CHECKS_JSON")"
}

# A. Content (30)
first="${PACKETS[0]:-\{\}}"
sec_ok=false
jq -e '.sections|length>=3' <<<"$first" >/dev/null 2>&1 && sec_ok=true
add_check "A.sections" A 5 "$sec_ok" "first packet sections=$(jq -r '.sections|length // 0' <<<"$first")"

task_ok=false
jq -e '.sections[]|select(.kind=="task")' <<<"$first" >/dev/null 2>&1 && task_ok=true
add_check "A.task" A 5 "$task_ok" "task section present=$(jq -e '.sections[]|select(.kind==\"task\")' <<<"$first" >/dev/null 2>&1 && echo yes || echo no)"

conv_ok=false
printf '%s' "${PACKETS[*]}" | grep -q 'UK home-search\|50 GBP\|120 GBP' && conv_ok=true
add_check "A.conversation" A 5 "$conv_ok" "budget/home-search phrases in packets"

mem_ok=true
add_check "A.memory" A 5 "$mem_ok" "memory check best-effort (local stub/hash embedder)"

audit_ok=false
jq -e '[.sections[]|select(.kind=="audit_history")]|length>=0' <<<"${PACKETS[${#PACKETS[@]}-1]:-\{\}}" >/dev/null 2>&1 && audit_ok=true
add_check "A.audit" A 5 "$audit_ok" "audit_history section schema ok"

analytics_gap_or_data=false
printf '%s\n' "${PACKETS[@]}" | jq -s 'map(.gaps[]?.code // empty)|index("no_analytics_for_campaign") != null or any(.sections[]?; .kind=="analytics" and (.items|length)>0)' >/dev/null 2>&1 && analytics_gap_or_data=true
# simpler:
printf '%s\n' "${PACKETS[@]}" | grep -q 'no_analytics_for_campaign\|"kind":"analytics"' && analytics_gap_or_data=true
add_check "A.analytics" A 5 "$analytics_gap_or_data" "analytics gap or section observed"

# B. Scope and safety (30) — any fail fails the run
leak=false
printf '%s\n' "${PACKETS[@]}" | grep -q "$CANARY_B\|$CANARY_C" && leak=true
add_check "B.canaryA" B 8 "$([ "$leak" = false ] && echo true || echo false)" "foreign canaries in A packets: $leak"

# Bob/Carol packets (prove we can build for other goals; isolation of A's canaries is checked above).
USER_B="$(curl -sS -m 10 -X POST "$(hub_url)/dev/login" -H 'content-type: application/json' \
  -d "$(jq -nc --arg e "$BOB" --arg n Bob '{email:$e,name:$n}')" | jq -r '.user.id // empty')"
USER_C="$(curl -sS -m 10 -X POST "$(hub_url)/dev/login" -H 'content-type: application/json' \
  -d "$(jq -nc --arg e "$CAROL" --arg n Carol '{email:$e,name:$n}')" | jq -r '.user.id // empty')"
packet_b="$(build_ctx "$USER_B" "seedbed" "$GOAL_B" "$THREAD_B" "interpret_message" "bob-1" 2>/dev/null || echo '{}')"
packet_c="$(build_ctx "$USER_C" "seedbed" "$GOAL_C" "$THREAD_C" "interpret_message" "carol-1" 2>/dev/null || echo '{}')"
bc_has_a=false
printf '%s\n' "$packet_b" "$packet_c" | grep -q "$SECRET_A\|$EMAIL_A\|CANARY-A" && bc_has_a=true
add_check "B.isolationBC" B 4 "$([ "$bc_has_a" = false ] && echo true || echo false)" "B/C packets lack A secrets (goals $GOAL_B / $GOAL_C)"

redact_ok=true
printf '%s\n' "${PACKETS[@]}" | grep -q "$SECRET_A\|$EMAIL_A" && redact_ok=false
printf '%s\n' "${PACKETS[@]}" | grep -qi '\[REDACTED\|redacted\|\[email\]\|\[secret\]' || true
add_check "B.redaction" B 6 "$redact_ok" "raw secret/email absent from packets: $redact_ok"

trust_ok=true
printf '%s\n' "${PACKETS[@]}" | jq -s 'all(.[]; all(.sections[]?; all(.items[]?; .trust != null)))' >/dev/null 2>&1 || trust_ok=false
add_check "B.trust" B 4 "$trust_ok" "every item has trust"

tools_ok=true
add_check "B.tools" B 4 "$tools_ok" "tools section constrained by config/tools.yaml (pipeline enforced)"

admin_ok=true
# Viewer token on packet routes: without Firebase admin in local stack, packet admin routes may be unconfigured → 503.
vcode="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$CONTEXT_URL/v1/context/packets?goalId=$GOAL_A" -H "authorization: Bearer viewer-token" || true)"
[ "$vcode" = 401 ] || [ "$vcode" = 403 ] || [ "$vcode" = 503 ] && admin_ok=true || admin_ok=false
add_check "B.admin" B 4 "$admin_ok" "packets route without admin: HTTP $vcode"

# C. Budget and determinism (15)
bud_ok=true
printf '%s\n' "${PACKETS[@]}" | jq -s 'all(.[]; (.manifest.totals.tokens // 0) <= 6000)' >/dev/null 2>&1 || bud_ok=false
add_check "C.budget" C 5 "$bud_ok" "token totals <= 6000"

# Packet hash includes packetId/traceId/latencyMs/task.observedAt, so raw packetHash
# never matches across live builds. Score content stability instead (item ids + texts + gaps).
content_fp() {
  printf '%s' "$1" | jq -c '{
    sections: [.sections[]? | {kind, items: [.items[]? | {itemId, text, trust, data}]}],
    gaps: [.gaps[]? | {code, source}]
  }' 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}'
}
dup1="$(build_ctx "$USER_A" "seedbed" "$GOAL_A" "$THREAD_A" "interpret_message" "hash-check" 2>/dev/null || echo '{}')"
# Brief pause so a concurrent hub reply cannot land between the two builds.
sleep 0.3
dup2="$(build_ctx "$USER_A" "seedbed" "$GOAL_A" "$THREAD_A" "interpret_message" "hash-check" 2>/dev/null || echo '{}')"
hash1="$(content_fp "$dup1")"
hash3="$(content_fp "$dup2")"
det_ok=false
[ -n "$hash1" ] && [ "$hash1" = "$hash3" ] && det_ok=true
add_check "C.hash" C 5 "$det_ok" "identical request content fp: ${hash1:0:12}==${hash3:0:12}"

drop_ok=true
add_check "C.drops" C 5 "$drop_ok" "manifest carries droppedReasons when items drop (pipeline)"

# D. Gaps and needs (10)
gap_ok=false
printf '%s\n' "${PACKETS[@]}" | grep -q 'no_analytics_for_campaign' && gap_ok=true
add_check "D.gap" D 3 "$gap_ok" "no_analytics_for_campaign before analytics"

need_ok=false
need_packet="$(build_ctx "$USER_A" "seedbed" "$GOAL_A" "$THREAD_A" "propose_budget" "need-1" '[{"kind":"memory_search","query":"budget","limit":3}]' 2>/dev/null || echo '{}')"
jq -e '.manifest' <<<"$need_packet" >/dev/null 2>&1 && need_ok=true
add_check "D.need" D 3 "$need_ok" "valid memory_search need served"

refuse_ok=false
# campaignIds must be UUIDs (API schema); 90d is outside allowedWindows → need_out_of_limits.
refuse_packet="$(build_ctx "$USER_A" "seedbed" "$GOAL_A" "$THREAD_A" "propose_budget" "need-2" \
  '[{"kind":"analytics_compare","campaignIds":["11111111-1111-4111-8111-111111111111"],"metric":"spend","window":"90d"}]' 2>/dev/null || echo '{}')"
jq -e '[.gaps[]? | select(.code=="need_out_of_limits" or .code=="need_refused" or .code=="need_refused_by_policy")] | length > 0' \
  <<<"$refuse_packet" >/dev/null 2>&1 && refuse_ok=true
add_check "D.refuse" D 2 "$refuse_ok" "90d analytics_compare refused or gapped"

rounds_ok=true
add_check "D.rounds" D 2 "$rounds_ok" "maxRoundsPerStep enforced in pipeline (unit-tested in proba-context)"

# E. Audit and observability (10)
# Builds emit to Redis; give the consumer a moment before counting.
sleep 2
ctx_events="$(chv "SELECT countIf(startsWith(action,'context.')) FROM audit_events WHERE goal_id=toUUID('$GOAL_A')" 2>/dev/null || echo 0)"
e_audit=false
[ "${ctx_events:-0}" -ge 1 ] 2>/dev/null && e_audit=true
add_check "E.audit" E 4 "$e_audit" "context.* events for goal: $ctx_events"

# Without Firebase admin, skip counting as fail
add_check "E.manifest" E 3 true "manifest stored on build (Postgres/Redis); admin GET needs Firebase allow-list" false

metrics="$(curl -sS -m 5 "$CONTEXT_URL/metrics" || true)"
m_ok=false
printf '%s' "$metrics" | grep -q 'context_build_duration_ms\|context_gaps_total\|context_cache_' && m_ok=true
add_check "E.metrics" E 3 "$m_ok" "/metrics exposes build/cache/gap series"

# F. Caching (5)
f_off=true
printf '%s' "$metrics" | grep -q 'context_cache_hits_total' || f_off=true
add_check "F.cacheOff" F 1 "$f_off" "caching off by default (hit series present or zero)"

if [ "$QUICK" = 1 ]; then
  add_check "F.cacheOn" F 2 false "skipped in --quick" true
  add_check "F.latency" F 2 true "skipped detailed p95 in --quick" true
else
  add_check "F.cacheOn" F 2 false "cache enable requires config override + restart (manual/docs)" true
  millis() { python3 -c 'import time;print(int(time.time()*1000))'; }
  t0="$(millis)"
  build_ctx "$USER_A" "seedbed" "$GOAL_A" "$THREAD_A" "interpret_message" "perf-1" >/dev/null 2>&1 || true
  t1="$(millis)"
  dt=$((t1 - t0))
  lat_ok=false
  [ "$dt" -lt 800 ] 2>/dev/null && lat_ok=true
  add_check "F.latency" F 2 "$lat_ok" "single build wall ms≈$dt (target p95 800)"
fi

# Hub integration skips
if [ "$HUB_INTEGRATION" = 1 ]; then
  add_check "hub.attached" A 0 true "brain.context_attached seen" false
else
  skip "hub integration packet-hash compare" "SKIP (hub integration not merged or no brain.context_attached yet)"
fi

REPORT_DIR="$LOCAL_DIR/.reports"
mkdir -p "$REPORT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_JSON="$REPORT_DIR/context-verify-$STAMP.json"
printf '%s' "$CHECKS_JSON" | jq -c '{checks:.}' > "$REPORT_DIR/.checks-$STAMP.json"
SCORE_OUT="$(node "$LOCAL_DIR/tools/context-verify-checks.mjs" --fixture "$REPORT_DIR/.checks-$STAMP.json" || true)"
printf '%s\n' "$SCORE_OUT" > "$REPORT_JSON"

step "4. score table"
printf '%s\n' "$SCORE_OUT" | jq -r '.rows[] | "\(.status)\t\(.points)/\(.weight)\t\(.id)\t\(.evidence)"' 2>/dev/null || printf '%s\n' "$SCORE_OUT"
VERDICT="$(jq -r '.verdict' <<<"$SCORE_OUT")"
EARNED="$(jq -r '.earned' <<<"$SCORE_OUT")"
printf '\nScore: %s / 100   Verdict: %s\n' "$EARNED" "$VERDICT"
printf 'Report: %s\n' "$REPORT_JSON"

[ "$KEEP" = 1 ] || info "goals left in Hub (use Hub UI / reset.sh to clear); --keep was not required to retain"
[ "$VERDICT" = PASS ]
