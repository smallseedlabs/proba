#!/usr/bin/env bash
# Automated checks of the running local platform against the design. Prints PASS / FAIL / SKIP per check
# and exits 1 if anything failed.
#   ./verify.sh              all checks (about 3-4 minutes: it waits for stub restatements and restarts the consumer)
#   ./verify.sh --quick      skip the slow checks (restart recovery, restatement, swap demos, tamper demo)
#   ./verify.sh --trace ID   print the audit trail of one traceId (parent/child spans) and exit
# Needs ./up.sh to have run. It sends its own commands through the Hub (session: see lib.sh hub_token).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker curl jq
load_env
QUICK=0
case "${1:-}" in
  --quick) QUICK=1 ;;
  --trace)
    [ -n "${2:-}" ] || die "usage: ./verify.sh --trace TRACE_ID"
    ch_pretty "SELECT occurred_at, substring(span_id,1,8) AS span, substring(ifNull(parent_span_id,''),1,8) AS parent, service, action, outcome, risk_level, target_type FROM audit_events WHERE trace_id='$2' ORDER BY occurred_at, ingested_at"
    exit 0 ;;
  "") ;;
  *) die "unknown option: ${1}" ;;
esac

chv() { ch "$1" 2>/dev/null | tr -d '[:space:]'; }   # one scalar
API="http://127.0.0.1:${AUDIT_API_HOST_PORT}"
HUB_IMG="${HUB_IMAGE:-proba-local/hub:dev}"
INGESTER_RUN() { dc run --rm --no-deps -T "$@"; }
export AUDIT_SRC="${AUDIT_SRC:-$SRC_DIR/proba-audit}" HUB_SRC="${HUB_SRC:-$SRC_DIR/proba-hub}" WEB_SRC="${WEB_SRC:-$SRC_DIR/proba-web}" PORTAL_SRC="${PORTAL_SRC:-$SRC_DIR/proba-portal}"
trap 'dc start audit-consumer >/dev/null 2>&1 || true' EXIT   # never leave the consumer stopped

# ------------------------------------------------------------------ 0. begin the slow metrics observations
WIN_FROM="$(ch "SELECT toString(toStartOfHour(now('UTC')) - INTERVAL 2 HOUR)" | tr -d '\n')"
WIN_TO="$(ch "SELECT toString(toStartOfHour(now('UTC')))" | tr -d '\n')"
win_totals() { # rollup|obs  -> "clicks|conversions|spend|maxrev" for meta, fixed window of two closed hours
  if [ "$1" = obs ]; then
    ch "SELECT concat(toString(sum(clicks)),'|',toString(round(sum(conversions),3)),'|',toString(round(toFloat64(sum(spend)),3)),'|',toString(max(revision))) FROM metric_observations FINAL WHERE platform='meta' AND granularity='hour' AND period_start >= toDateTime64('$WIN_FROM',3,'UTC') AND period_start < toDateTime64('$WIN_TO',3,'UTC')" | tr -d '\n'
  else
    ch "SELECT concat(toString(sum(clicks)),'|',toString(round(sum(conversions),3)),'|',toString(round(toFloat64(sum(spend)),3)),'|',toString(max(observation_count))) FROM metric_rollups_hourly FINAL WHERE platform='meta' AND source_granularity='hour' AND bucket_start >= toDateTime64('$WIN_FROM',3,'UTC') AND bucket_start < toDateTime64('$WIN_TO',3,'UTC')" | tr -d '\n'
  fi
}
M0_FETCH="$(chv "SELECT count() FROM audit_events WHERE action='metrics.fetch_completed'")"
M0_REV="$(chv "SELECT sum(revision) FROM metric_observations FINAL")"
M0_ROLL="$(win_totals rollup)"
T_START=$(date +%s)

# ------------------------------------------------------------------ 1. services
step "1. services"
if "$LOCAL_DIR/status.sh" --quiet; then pass "all services healthy and both migrations completed (./status.sh)"
else fail "some service is not healthy" "run ./status.sh"; fi

# ------------------------------------------------------------------ 2. one traceId end to end
step "2. one command through the Hub: one traceId across the audit trail"
TOKEN="$(hub_token "verify-$(date +%s)@proba.local")" || { fail "no Hub session (see docs/LOCAL_TESTING.md, Signing in)"; TOKEN=""; }
TRACE=""
if [ -n "$TOKEN" ]; then
  hub_post "$TOKEN" create_goal '{"title":"verify.sh goal","budget":{"daily":90,"total":600,"currency":"GBP"}}'
  TRACE="$LAST_ID"
  [ "$LAST_STATUS" = accepted ] && pass "POST /v1/commands accepted ($TRACE)" || fail "the Hub did not accept the command" "status $LAST_STATUS"
  [ "$LAST_TRACE_HEADER" = "$TRACE" ] && pass "X-Trace-Id response header equals the command's clientMsgId" || fail "X-Trace-Id is '$LAST_TRACE_HEADER', expected $TRACE"
  stored() { [ "$(chv "SELECT countIf(action='command.processed') FROM audit_events WHERE trace_id='$TRACE'")" -ge 1 ] 2>/dev/null; }
  if wait_until 60 "audit events of $TRACE in ClickHouse" stored; then
    n="$(chv "SELECT count() FROM audit_events WHERE trace_id='$TRACE'")"
    svcs="$(ch "SELECT arrayStringConcat(groupUniqArray(service),',') FROM audit_events WHERE trace_id='$TRACE'" | tr -d '\n')"
    [ "$svcs" = hub ] && [ "$n" -ge 6 ] && pass "$n events, one traceId, all from service 'hub'" || fail "unexpected events for the trace" "services=$svcs count=$n"
    have="$(ch "SELECT arrayStringConcat(arraySort(groupUniqArray(action)),' ') FROM audit_events WHERE trace_id='$TRACE'" | tr -d '\n')"
    missing=""
    for a in command.received command.accepted thread.created brain.llm_call brain.clarification_requested goal.created goal.budget_proposed command.processed; do
      case " $have " in *" $a "*) ;; *) missing="$missing $a" ;; esac
    done
    [ -z "$missing" ] && pass "specific action names present: $have" || fail "missing actions:$missing" "have: $have"
    roots="$(chv "SELECT countIf(parent_span_id IS NULL) FROM audit_events WHERE trace_id='$TRACE'")"
    orphans="$(chv "SELECT countIf(parent_span_id IS NOT NULL AND parent_span_id NOT IN (SELECT span_id FROM audit_events WHERE trace_id='$TRACE')) FROM audit_events WHERE trace_id='$TRACE'")"
    [ "$roots" = 1 ] && [ "$orphans" = 0 ] && pass "one root span (command.received) and every parent span exists" || fail "span tree is not connected" "roots=$roots orphans=$orphans"
  else fail "events of the trace never reached ClickHouse" "check ./status.sh and: docker compose -p proba-local logs hub audit-consumer"; fi
fi

# ------------------------------------------------------------------ 3. audit-api
step "3. audit-api (read side)"
ATOKEN="${AUDIT_API_LOCAL_TOKEN:-}"
acurl() { curl -sS -m 20 "$@"; }
if [ "${AUDIT_API_TOKEN_VERIFIER:-static}" != static ] || [ -z "$ATOKEN" ]; then
  skip "audit-api checks" "AUDIT_API_TOKEN_VERIFIER is not static: use a Firebase ID token yourself (docs/LOCAL_TESTING.md)"
else
  code="$(acurl -o /dev/null -w '%{http_code}' "$API/v1/session")"
  [ "$code" = 401 ] && pass "no token: 401" || fail "GET /v1/session without a token answered $code, expected 401"
  sess="$(acurl "$API/v1/session" -H "authorization: Bearer $ATOKEN")"
  [ "$(jq -r .role <<<"$sess")" = admin ] && [ "$(jq -r .workspaceId <<<"$sess")" = seedbed ] && pass "local token: admin of workspace seedbed (workspace comes from config, not the request)" || fail "GET /v1/session" "$sess"
  code="$(acurl -o /dev/null -w '%{http_code}' "$API/v1/events?workspaceId=other" -H "authorization: Bearer $ATOKEN")"
  [ "$code" = 400 ] && pass "a workspaceId query parameter is refused (400)" || fail "workspaceId parameter answered $code, expected 400"
  if [ -n "$TRACE" ]; then
    tr_json="$(acurl "$API/v1/traces/$TRACE" -H "authorization: Bearer $ATOKEN")"
    want="$(chv "SELECT count() FROM audit_events WHERE trace_id='$TRACE'")"
    if [ "$(jq -r '.eventCount' <<<"$tr_json")" = "$want" ] && [ "$(jq -r '.roots | length' <<<"$tr_json")" = 1 ] && [ "$(jq -r '.roots[0].action' <<<"$tr_json")" = command.received ]; then
      pass "GET /v1/traces/{traceId}: span tree with root command.received, $want events"
    else fail "GET /v1/traces/$TRACE does not match ClickHouse" "$(head -c 300 <<<"$tr_json")"; fi
    ev_json="$(acurl "$API/v1/events?traceId=$TRACE&limit=200" -H "authorization: Bearer $ATOKEN")"
    if [ "$(jq -r '.events | length' <<<"$ev_json")" = "$want" ] && jq -e '.events | all(.hash and (.prevHash != null or .prevHash == null) and .ingestedAt)' <<<"$ev_json" >/dev/null; then
      pass "GET /v1/events?traceId=: same $want events, with their chain fields (hash, prevHash)"
    else fail "GET /v1/events?traceId= differs from ClickHouse" "$(head -c 300 <<<"$ev_json")"; fi
  fi
  from="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"; to="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cv="$(acurl "$API/v1/chain/verify?from=$from&to=$to" -H "authorization: Bearer $ATOKEN")"
  [ "$(jq -r .ok <<<"$cv")" = true ] && pass "GET /v1/chain/verify (last hour): ok, $(jq -r .checked <<<"$cv") events checked" || fail "GET /v1/chain/verify" "$(head -c 300 <<<"$cv")"
  d0="$(date -u -v-2d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '2 days ago' +%Y-%m-%dT00:00:00Z)"; d1="$(date -u -v+1d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d 'tomorrow' +%Y-%m-%dT00:00:00Z)"
  sm="$(acurl "$API/v1/analytics/summary?granularity=day&from=$d0&to=$d1" -H "authorization: Bearer $ATOKEN")"
  cur="$(jq -r '[.totals[].currency] | sort | join(",")' <<<"$sm" 2>/dev/null)"
  if [ "$cur" = "AUD,GBP,USD" ] && jq -e '.totals | all(.clicks > 0 and .spend > 0)' <<<"$sm" >/dev/null; then
    pass "GET /v1/analytics/summary: one total per currency ($cur), never added together"
  else fail "GET /v1/analytics/summary" "currencies=$cur $(head -c 200 <<<"$sm")"; fi
  # The API records reads with the protocol's specific actions (audit-api 0.3.2+): audit.* for the trail, analytics.* for metrics.
  read_actions="'audit.searched','audit.event_viewed','audit.trace_viewed','audit.integrity_checked','analytics.queried','analytics.compared'"
  api_reads() { [ "$(chv "SELECT countIf(action IN ($read_actions)) FROM audit_events WHERE service='audit-api'")" -ge 2 ]; }
  if wait_until 40 "the audit-api's own audit events" api_reads; then
    pass "reads are audited: the audit-api wrote $(chv "SELECT countIf(action IN ($read_actions)) FROM audit_events WHERE service='audit-api'") audit.*/analytics.* events about the reads above"
  else fail "no audit event for the API reads"; fi
fi

# ------------------------------------------------------------------ 4. hash chain
step "4. hash chain"
vc="$(verify_chain "$CH_DB" seedbed)"
if [ "$(jq -r '.ok' <<<"$vc" 2>/dev/null)" = true ]; then pass "verifyChain (proba-audit's own): workspace seedbed intact, $(jq -r .checked <<<"$vc") events"
else fail "verifyChain found problems" "$(head -c 400 <<<"$vc")"; fi

# ------------------------------------------------------------------ 5. action names
step "5. action names and categories against the protocol catalog"
catalog="$(docker run --rm --entrypoint node "$HUB_IMG" -e "import('@smallseedlabs/proba-protocol/audit').then(m=>{for(const [a,i] of Object.entries(m.AUDIT_ACTION_INFO))console.log(a+'\t'+i.category+'\t'+i.status)})" 2>/dev/null)"
if [ -z "$catalog" ]; then skip "catalog checks" "cannot read AUDIT_ACTION_INFO from the hub image ($HUB_IMG)"
else
  bad_list="$(awk -F'\t' '$3!="specific"{printf "%s'"'"'%s'"'"'", (n++?",":""), $1}' <<<"$catalog")"
  pairs="$(awk -F'\t' '$3=="specific"{printf "%s('"'"'%s'"'"','"'"'%s'"'"')", (n++?",":""), $1, $2}' <<<"$catalog")"
  spec_list="$(awk -F'\t' '$3=="specific"{printf "%s'"'"'%s'"'"'", (n++?",":""), $1}' <<<"$catalog")"
  hub_bad="$(chv "SELECT count() FROM audit_events WHERE service='hub' AND action IN ($bad_list)")"
  [ "$hub_bad" = 0 ] && pass "hub: no generic or alias action stored" || fail "hub stored generic/alias actions" "$(ch "SELECT action, count() FROM audit_events WHERE service='hub' AND action IN ($bad_list) GROUP BY action" | tr '\n' ' ')"
  all_bad="$(ch "SELECT service, action, count() FROM audit_events WHERE action IN ($bad_list) GROUP BY service, action ORDER BY service, action" | tr '\t\n' ' ;')"
  if [ -z "$all_bad" ]; then pass "all services: no generic or alias action stored"
  else fail "other services store generic/alias actions (service action count): $all_bad" "design: use the preferred specific name (AUDIT_ACTION_INFO[action].preferred); open item for that service"; fi
  mism="$(chv "SELECT count() FROM audit_events WHERE action IN ($spec_list) AND (action, toString(category)) NOT IN ($pairs)")"
  [ "$mism" = 0 ] && pass "every stored catalog action has the catalog's category" || fail "$mism events have a category that differs from the catalog" "$(ch "SELECT action, toString(category), count() FROM audit_events WHERE action IN ($spec_list) AND (action, toString(category)) NOT IN ($pairs) GROUP BY action, category" | tr '\n' ';')"
  unk="$(ch "SELECT DISTINCT action FROM audit_events WHERE action NOT IN ($spec_list) AND action NOT IN ($bad_list) ORDER BY action" | tr '\n' ' ')"
  info "      (actions not in the catalog, allowed: ${unk:-none})"
fi

# ------------------------------------------------------------------ 6. redaction
step "6. redaction: no tokens, emails or message text in the stored trail"
TEXTS="concat(ifNull(details,''),' ',ifNull(error_message,''),' ',ifNull(target_id,''),' ',actor_id,' ',arrayStringConcat(tags,' '))"
emails="$(chv "SELECT count() FROM audit_events WHERE match($TEXTS, '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+[.][A-Za-z]{2,}')")"
[ "$emails" = 0 ] && pass "no email-shaped string in any event" || fail "$emails events contain an email-shaped string" "$(ch "SELECT service, action FROM audit_events WHERE match($TEXTS, '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+[.][A-Za-z]{2,}') LIMIT 3" | tr '\n' ';')"
secrets="$(chv "SELECT count() FROM audit_events WHERE match($TEXTS, '(?i)bearer[[:space:]]+[A-Za-z0-9]|eyJ[A-Za-z0-9_-]{5,}[.][A-Za-z0-9_-]{5,}[.]')")"
[ "$secrets" = 0 ] && pass "no bearer token or JWT in any event" || fail "$secrets events contain a bearer token or JWT"
canary="$(chv "SELECT count() FROM audit_events WHERE positionCaseInsensitive($TEXTS, 'canary-brief') > 0 OR positionCaseInsensitive($TEXTS, 'abc123canary') > 0 OR positionCaseInsensitive($TEXTS, 'seed.canary') > 0")"
[ "$canary" = 0 ] && pass "the message text seed.sh sent (with a canary email and bearer string) is not stored anywhere" || fail "canary text found in $canary events"
if [ -n "$TOKEN" ]; then
  mine="$(chv "SELECT count() FROM audit_events WHERE position($TEXTS, '$TOKEN') > 0")"
  [ "$mine" = 0 ] && pass "this run's session token appears in no event" || fail "the session token is stored in $mine events"
fi

# ------------------------------------------------------------------ 7. dead letters
step "7. dead letters"
dlq="$(rds XLEN proba.audit.events.dlq | tr -d '[:space:]')"
[ "${dlq:-0}" = 0 ] && pass "dead-letter stream proba.audit.events.dlq is empty" || fail "$dlq dead letters" "XRANGE proba.audit.events.dlq - + COUNT 3"
qn="$(chv "SELECT count() FROM metric_observation_quarantine")"
[ "$qn" = 0 ] && pass "metric quarantine table is empty" || fail "$qn quarantined observations" "SELECT reason, count() FROM metric_observation_quarantine GROUP BY reason"

# ------------------------------------------------------------------ 8. restart recovery
step "8. restart recovery: stop the consumer, send events, start it, nothing lost"
if [ "$QUICK" = 1 ] || [ -z "$TOKEN" ]; then skip "restart recovery" "--quick (or no Hub session)"
else
  dc stop audit-consumer >/dev/null 2>&1
  ids=""
  for i in 1 2 3 4 5; do
    hub_post "$TOKEN" send_message "{\"text\":\"recovery $i\"}"
    ids="$ids,'$LAST_ID'"
  done
  ids="${ids#,}"
  published() { [ "$(pg "SELECT count(*) FROM audit_outbox WHERE payload->>'traceId' IN ($ids) AND published_at IS NULL" | tr -d '[:space:]')" = 0 ] && [ "$(pg "SELECT count(*) FROM audit_outbox WHERE payload->>'traceId' IN ($ids)" | tr -d '[:space:]')" -ge 5 ]; }
  wait_until 40 "hub relay published the events to Redis" published || true
  want="$(pg "SELECT count(*) FROM audit_outbox WHERE payload->>'traceId' IN ($ids)" | tr -d '[:space:]')"
  during="$(chv "SELECT count() FROM audit_events WHERE trace_id IN ($ids)")"
  [ "$during" = 0 ] && pass "consumer down: $want events produced by the Hub, 0 stored yet (they wait in the Redis stream)" || fail "events were stored while the consumer was stopped" "$during"
  dc start audit-consumer >/dev/null 2>&1
  caught() { [ "$(chv "SELECT count() FROM audit_events WHERE trace_id IN ($ids)")" = "$want" ]; }
  if wait_until 90 "consumer to store all $want events" caught; then
    dist="$(chv "SELECT uniqExact(event_id) FROM audit_events WHERE trace_id IN ($ids)")"
    [ "$dist" = "$want" ] && pass "consumer restarted: all $want events stored exactly once" || fail "duplicates after the restart" "$dist distinct of $want"
  else fail "after the restart ClickHouse has $(chv "SELECT count() FROM audit_events WHERE trace_id IN ($ids)") of $want events"; fi
  vc2="$(verify_chain "$CH_DB" seedbed)"
  [ "$(jq -r '.ok' <<<"$vc2" 2>/dev/null)" = true ] && pass "hash chain still intact after the restart ($(jq -r .checked <<<"$vc2") events)" || fail "chain broken after the restart" "$(head -c 300 <<<"$vc2")"
fi

# ------------------------------------------------------------------ 9. tamper detection
step "9. tamper detection (throwaway database)"
if [ "$QUICK" = 1 ]; then skip "tamper demo" "--quick (run ./tamper-demo.sh)"
else
  if "$LOCAL_DIR/tamper-demo.sh" --quiet >/tmp/proba-local-tamper.$$ 2>&1; then pass "an altered event -> hash_mismatch, a deleted one -> broken_link, real chain untouched (./tamper-demo.sh shows it)"
  else fail "tamper demo failed" "$(tail -n 6 /tmp/proba-local-tamper.$$ | tr '\n' ' ')"; fi
  rm -f /tmp/proba-local-tamper.$$
fi

# ------------------------------------------------------------------ 10. metrics
step "10. stub metrics: flow, rollups, timezones, restatement"
acct="$(chv "SELECT uniqExact(platform, account_id) FROM metric_rollups_daily")"
tzs="$(ch "SELECT arrayStringConcat(arraySort(groupUniqArray(timezone)),',') FROM metric_rollups_daily" | tr -d '\n')"
h="$(chv "SELECT count() FROM metric_rollups_hourly")"; d="$(chv "SELECT count() FROM metric_rollups_daily")"
[ "${h:-0}" -gt 0 ] && [ "${d:-0}" -gt 0 ] && [ "$acct" = 6 ] && pass "rollups present: $h hourly and $d daily rows for $acct accounts (2 platforms x 3)" || fail "rollups missing" "hourly=$h daily=$d accounts=$acct"
[ "$tzs" = "America/New_York,Australia/Sydney,Europe/London" ] && pass "daily buckets per account timezone: $tzs" || fail "unexpected timezones in the daily rollups" "$tzs"
tzbad=0
for tz in America/New_York Australia/Sydney Europe/London; do
  m="$(chv "SELECT countIf(bucket_date != toDate(bucket_start, '$tz')) FROM metric_rollups_daily FINAL WHERE timezone='$tz'")"
  [ "${m:-1}" = 0 ] || { tzbad=1; fail "bucket_date != local date of bucket_start in $tz" "$m rows"; }
done
syd="$(chv "SELECT countIf(toHour(bucket_start, 'UTC') != 0) FROM metric_rollups_daily FINAL WHERE timezone='Australia/Sydney'")"
if [ "$tzbad" = 0 ] && [ "${syd:-0}" -gt 0 ]; then pass "a daily bucket is the account's local day: Sydney days start at $(ch "SELECT toString(any(toHour(bucket_start,'UTC'))) FROM metric_rollups_daily FINAL WHERE timezone='Australia/Sydney'" | tr -d '\n'):00 UTC, New York days at $(ch "SELECT toString(any(toHour(bucket_start,'UTC'))) FROM metric_rollups_daily FINAL WHERE timezone='America/New_York'" | tr -d '\n'):00 UTC"
elif [ "$tzbad" = 0 ]; then fail "Sydney daily buckets all start at UTC midnight (timezone not applied)"; fi
cur="$(chv "SELECT arrayStringConcat(arraySort(groupUniqArray(toString(currency))),',') FROM metric_rollups_daily")"
[ "$cur" = "AUD,GBP,USD" ] && pass "currencies kept apart: $cur" || fail "currencies" "$cur"

if [ "$QUICK" = 1 ]; then skip "ingest flow over time and restatement" "--quick"
else
  # flow: the ingester keeps fetching and keeps restating
  grew() { [ "$(chv "SELECT count() FROM audit_events WHERE action='metrics.fetch_completed'")" -gt "$M0_FETCH" ] && [ "$(chv "SELECT sum(revision) FROM metric_observations FINAL")" -gt "$M0_REV" ]; }
  if wait_until 120 "more fetches and a higher total revision" grew; then
    pass "observations flowing: fetch_completed $M0_FETCH -> $(chv "SELECT count() FROM audit_events WHERE action='metrics.fetch_completed'"), total revision $M0_REV -> $(chv "SELECT sum(revision) FROM metric_observations FINAL") (restatements)"
  else fail "the ingest flow did not advance during the run"; fi
  # restatement: the rollup totals of two closed hours move and then equal the latest revisions
  changed() { [ "$(win_totals rollup)" != "$M0_ROLL" ]; }
  settled() { [ "$(win_totals rollup | cut -d'|' -f1-3)" = "$(win_totals obs | cut -d'|' -f1-3)" ]; }
  if wait_until 150 "the window totals to change" changed; then
    if wait_until 60 "the rollup to catch up with the latest revisions" settled; then
      pass "restatement: window [$WIN_FROM, $WIN_TO) rollup clicks|conversions|spend $(echo "$M0_ROLL" | cut -d'|' -f1-3) -> $(win_totals rollup | cut -d'|' -f1-3) = the latest observation revisions (max revision $(win_totals obs | cut -d'|' -f4))"
    else fail "rollup totals changed but differ from the latest revisions" "rollup=$(win_totals rollup) obs=$(win_totals obs)"; fi
  else fail "no restatement reached the rollups of the window" "rollup stayed $M0_ROLL; max revision in the window: $(win_totals obs | cut -d'|' -f4)"; fi
fi

# ------------------------------------------------------------------ 11. swap by configuration
step "11. swap by configuration (throwaway ingester containers, nothing shared)"
if [ "$QUICK" = 1 ]; then skip "swap demos" "--quick"
else
  out="$(INGESTER_RUN -e EVENT_BUS=memory -e AUDIT_STORE=memory -e METRICS_STORE=memory -e CHECKPOINT_STORE=memory -e QUARANTINE_STORE=memory -e PLATFORM_CONNECTORS=meta:stub -e PORT=3199 \
    --entrypoint sh metrics-ingester -c 'timeout 15 node apps/metrics-ingester/dist/index.js 2>&1' 2>&1 || true)"
  if grep -q '"eventBus":"memory"' <<<"$out" && grep -q '"auditStore":"memory"' <<<"$out" && grep -q '"metricsStore":"memory"' <<<"$out" && grep -q 'lifecycle":"started"' <<<"$out"; then
    pass "EVENT_BUS=memory AUDIT_STORE=memory METRICS_STORE=memory: the ingester starts on the in-memory adapters, no code change"
  else fail "the in-memory swap did not start" "$(tail -n 3 <<<"$out" | cut -c1-200 | tr '\n' ' ')"; fi
  out="$(INGESTER_RUN -e PLATFORM_CONNECTORS=meta:not-a-library -e PORT=3199 --entrypoint sh metrics-ingester -c 'timeout 15 node apps/metrics-ingester/dist/index.js 2>&1; echo "exit=$?"' 2>&1 || true)"
  if grep -q 'exit=[1-9]' <<<"$out" && grep -qi 'stub' <<<"$out"; then
    pass "PLATFORM_CONNECTORS=meta:not-a-library: refused at start-up, the message lists the available adapters (stub)"
  else fail "an unknown connector name was not refused with the list of adapters" "$(tail -n 3 <<<"$out" | cut -c1-200 | tr '\n' ' ')"; fi
fi

# ------------------------------------------------------------------ summary
printf '\n%s%d passed, %d failed, %d skipped%s  (%d s)\n' "$C_BOLD" "$CHECKS_PASS" "$CHECKS_FAIL" "$CHECKS_SKIP" "$C_OFF" "$(( $(date +%s) - T_START ))"
cat <<MSG

Queries to try (./sql.sh runs SQL against ClickHouse; ./verify.sh --trace ID prints one trace):
  ./sql.sh "SELECT service, action, count() n FROM audit_events GROUP BY service, action ORDER BY n DESC"
  ./sql.sh "SELECT occurred_at, action, outcome, risk_level FROM audit_events WHERE trace_id='${TRACE:-<traceId>}' ORDER BY occurred_at"
  ./sql.sh "SELECT toString(category) category, action, count() n FROM audit_events WHERE service='hub' GROUP BY category, action ORDER BY category, action"
  ./sql.sh "SELECT platform, account_id, timezone, bucket_date, impressions, clicks, spend, currency FROM metric_rollups_daily FINAL ORDER BY bucket_date DESC, platform, account_id LIMIT 12"
  ./sql.sh "SELECT revision, count() FROM metric_observations GROUP BY revision ORDER BY revision LIMIT 10"
  ./sql.sh "SELECT action, details FROM audit_events WHERE action='metrics.restated' ORDER BY occurred_at DESC LIMIT 3"
  ./sql.sh "SELECT hash, prev_hash, ingested_at FROM audit_events WHERE workspace_id='seedbed' ORDER BY ingested_at DESC LIMIT 3"
  curl -s -H "authorization: Bearer \$AUDIT_API_LOCAL_TOKEN" "$API/v1/traces/${TRACE:-<traceId>}" | jq    # after: set -a; . local/.env; set +a
MSG
[ "$CHECKS_FAIL" = 0 ]
