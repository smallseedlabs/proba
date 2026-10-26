#!/usr/bin/env bash
# Drive the Hub through POST /v1/commands exactly like proba-web does, to generate varied audit
# traffic: three goals (approve path, decline path, plan rejected), messages, an explain, pause /
# resume / emergency stop, a foreign thread, invalid payloads, a duplicate command, an SSE
# connect/disconnect and an unauthenticated call. Prints the traceId of every step.
#
# Session: HUB_SESSION_TOKEN (a real Firebase sign-in, see docs/LOCAL_TESTING.md) if set in
# local/.env or the environment; otherwise the Hub's development login (POST /dev/login).
#   ./seed.sh
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need curl jq
load_env
mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/seed-traces.tsv"; : > "$STATE"

curl -fsS -m 5 "$(hub_url)/health" >/dev/null || die "the Hub is not answering on $(hub_url): run ./up.sh first"

MANUAL=0; [ -n "${HUB_SESSION_TOKEN:-}" ] && MANUAL=1
# A fresh user per run keeps the polling window small (the dev login creates the user on the fly).
if [ "$MANUAL" = 0 ]; then SEED_EMAIL="seed-$(date +%s)@proba.local"; export SEED_EMAIL; fi
TOKEN="$(hub_token)" || exit 1
step "session ($([ "$MANUAL" = 1 ] && echo 'HUB_SESSION_TOKEN from the environment' || echo "development login as $SEED_EMAIL"))"
me="$(curl -sS -m 10 "$(hub_url)/v1/auth/me" -H "authorization: Bearer $TOKEN")"
USER_ID="$(jq -r '.user.id // .id // empty' <<<"$me")"
[ -n "$USER_ID" ] || die "the session token is not accepted by the Hub: $(head -c 200 <<<"$me")"
info "signed in, user id $USER_ID"
printf '%s\n' "$USER_ID" > "$STATE_DIR/seed-user-id"

note() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE"; printf '  %-34s trace %s  (%s)\n' "$1" "$2" "$3"; }

max_seq() { hub_events "$TOKEN" 0 | jq -r 'map(.seq) | max // 0'; }

# wait_ask THREAD_OR_EMPTY ASK_TYPE AFTER_SEQ -> prints the ask event JSON
wait_ask() {
  local thread="$1" kind="$2" after="$3" i=0 ev
  while [ "$i" -lt 40 ]; do
    ev="$(hub_events "$TOKEN" "$after" | jq -c --arg t "$thread" --arg k "$kind" \
      '[.[] | select(.type=="ask" and .payload.askType==$k and ($t=="" or .threadId==$t))] | last // empty')"
    if [ -n "$ev" ]; then printf '%s' "$ev"; return 0; fi
    sleep 0.5; i=$((i + 1))
  done
  die "timed out waiting for a $kind ask (is the Hub's brain scenario ${MOCK_BRAIN_SCENARIO:-happy_path}?)"
}

# goal_flow LABEL TITLE END   where END = approve | decline | reject_plan
goal_flow() {
  local label="$1" title="$2" end="$3" before t ask thread askid plan action cmd_type cmd_payload
  before="$(max_seq)"
  hub_post "$TOKEN" create_goal "$(jq -nc --arg title "$title" '{title:$title,budget:{daily:150,total:1000,currency:"GBP"}}')"; t="$LAST_ID"
  note "$label: create_goal" "$t" "$LAST_STATUS"
  ask="$(wait_ask "" clarify "$before")"
  thread="$(jq -r '.threadId' <<<"$ask")"; askid="$(jq -r '.payload.askId' <<<"$ask")"
  THREAD_LAST="$thread"

  hub_post "$TOKEN" answer_ask "$(jq -nc --arg a "$askid" '{askId:$a,choice:"approve",values:{answer:"active"}}')" "$thread"; t="$LAST_ID"
  note "$label: answer clarification" "$t" "$LAST_STATUS"
  plan="$(wait_ask "$thread" plan_approval "$before")"
  askid="$(jq -r '.payload.askId' <<<"$plan")"

  if [ "$end" = reject_plan ]; then
    hub_post "$TOKEN" approve_plan "$(jq -nc --arg p "$askid" '{planId:$p,approved:false}')" "$thread"; t="$LAST_ID"
    note "$label: reject plan" "$t" "$LAST_STATUS"
    return 0
  fi
  cmd_type="$(jq -r '[.ui.actions[]? | select(.id=="approve")][0].command.type // "approve_plan"' <<<"$plan")"
  cmd_payload="$(jq -c '[.ui.actions[]? | select(.id=="approve")][0].command.payload // empty' <<<"$plan")"
  [ -n "$cmd_payload" ] || cmd_payload="$(jq -nc --arg p "$askid" '{planId:$p,approved:true}')"
  hub_post "$TOKEN" "$cmd_type" "$cmd_payload" "$thread"; t="$LAST_ID"
  note "$label: approve plan" "$t" "$LAST_STATUS"
  action="$(wait_ask "$thread" action_approval "$before")"
  askid="$(jq -r '.payload.askId' <<<"$action")"
  if [ "$end" = approve ]; then
    hub_post "$TOKEN" answer_ask "$(jq -nc --arg a "$askid" '{askId:$a,choice:"approve"}')" "$thread"; t="$LAST_ID"
    note "$label: approve action" "$t" "$LAST_STATUS"
  else
    hub_post "$TOKEN" answer_ask "$(jq -nc --arg a "$askid" '{askId:$a,choice:"reject"}')" "$thread"; t="$LAST_ID"
    note "$label: decline action" "$t" "$LAST_STATUS"
  fi
}

step "goals and approvals"
THREAD_LAST=""
goal_flow "A approve path" "Test demand for trail shoes" approve; THREAD_A="$THREAD_LAST"
goal_flow "B decline path" "Try a bigger budget on retargeting" decline
goal_flow "C plan rejected" "Launch a second landing page" reject_plan

step "messages, explain, control"
# The canary text must never reach the audit trail (verify.sh looks for it).
CANARY='canary-brief mail seed.canary@example.com Bearer abc123canary'
hub_post "$TOKEN" send_message "$(jq -nc --arg x "$CANARY" '{text:$x}')" "$THREAD_A"; t="$LAST_ID"; note "send_message (text is never stored)" "$t" "$LAST_STATUS"
hub_post "$TOKEN" send_message '{"text":"First message in a brand new thread"}'; t="$LAST_ID"; note "send_message, new thread" "$t" "$LAST_STATUS"
hub_post "$TOKEN" explain '{"targetRef":"campaign-1"}' "$THREAD_A"; t="$LAST_ID"; note "explain" "$t" "$LAST_STATUS"
for a in pause resume kill; do
  hub_post "$TOKEN" control "$(jq -nc --arg a "$a" '{action:$a}')" "$THREAD_A"; t="$LAST_ID"; note "control $a" "$t" "$LAST_STATUS"
done

step "rejections, duplicate, SSE, auth"
hub_post "$TOKEN" send_message '{"text":"hi"}' "$(uuid)"; t="$LAST_ID"; note "foreign thread (access denied)" "$t" "$LAST_STATUS"
hub_post "$TOKEN" send_message '{"notText":1}'; t="$LAST_ID"; note "invalid payload" "$t" "$LAST_STATUS"
dup="$(uuid)"
hub_post "$TOKEN" send_message '{"text":"same command twice"}' "" "$dup"; t="$LAST_ID"; note "duplicate, first send" "$t" "$LAST_STATUS"
sleep 1
hub_post "$TOKEN" send_message '{"text":"same command twice"}' "" "$dup"; t="$LAST_ID"; note "duplicate, second send" "$t" "$LAST_STATUS"

sse_trace="$(curl -sS -m 3 -D - -o /dev/null -H 'accept: text/event-stream' -H "authorization: Bearer $TOKEN" "$(hub_url)/v1/events" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="x-trace-id:" {print $2}' || true)"
[ -n "$sse_trace" ] && note "SSE connect + disconnect" "$sse_trace" "stream.*"
denied_trace="$(curl -sS -m 5 -D - -o /dev/null "$(hub_url)/v1/auth/me" | tr -d '\r' | awk 'tolower($1)=="x-trace-id:" {print $2}')"
[ -n "$denied_trace" ] && note "no token (auth.denied)" "$denied_trace" "401"
if [ "$MANUAL" = 0 ]; then
  # A second session, signed out again: auth.sign_in / session_issued / sign_out / session_revoked.
  SEED_EMAIL="seed-logout-$(date +%s)@proba.local"; export SEED_EMAIL
  tok2="$(hub_token)"
  out_trace="$(curl -sS -m 5 -X POST -D - -o /dev/null "$(hub_url)/v1/auth/logout" -H "authorization: Bearer $tok2" | tr -d '\r' | awk 'tolower($1)=="x-trace-id:" {print $2}')"
  [ -n "$out_trace" ] && note "sign out (second session)" "$out_trace" "auth.sign_out"
fi

step "what the audit trail stored (waiting for relay + consumer, up to 40 s)"
# Hub outbox rows of the user's traces must all arrive in ClickHouse.
traces="$(cut -f2 "$STATE" | sort -u | sed "s/.*/'&'/" | paste -sd, -)"
expected_in_ch() { ch "SELECT count() FROM audit_events WHERE service='hub' AND trace_id IN ($traces)" 2>/dev/null; }
expected_in_outbox() { pg "SELECT count(*) FROM audit_outbox WHERE payload->>'traceId' IN ($traces)"; }
i=0
while [ "$i" -lt 40 ]; do
  a="$(expected_in_outbox | tr -d '[:space:]')"; b="$(expected_in_ch | tr -d '[:space:]')"
  [ -n "$a" ] && [ "$a" = "$b" ] && break
  sleep 1; i=$((i + 1))
done
info "hub audit events: $a in the outbox, $b in ClickHouse"
ch_pretty "SELECT action, count() AS events FROM audit_events WHERE service='hub' AND trace_id IN ($traces) GROUP BY action ORDER BY action"
info ""
info "Traces are saved in local/.state/seed-traces.tsv. Inspect one:"
first="$(sed -n 1p "$STATE" | cut -f2)"
info "  ./verify.sh --trace $first"
[ "$a" = "$b" ] || { warn "not every outbox event arrived in ClickHouse yet (check ./status.sh and the audit-consumer logs)"; exit 1; }
