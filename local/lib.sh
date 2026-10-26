#!/usr/bin/env bash
# Shared helpers for the local platform scripts. Source it, do not run it.
# Works with the bash 3.2 that ships with macOS.

LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOCAL_DIR
PROJECT=proba-local
STATE_DIR="$LOCAL_DIR/.state"
SRC_DIR="$LOCAL_DIR/.src"
# Docker Desktop on macOS keeps its CLI here; harmless elsewhere.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_DIM=''; C_BOLD=''; C_OFF=''
fi

info() { printf '%s\n' "$*"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
die() { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }
step() { printf '\n%s== %s%s\n' "$C_BOLD" "$*" "$C_OFF"; }

need() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing prerequisite: $c (see docs/LOCAL_TESTING.md, Prerequisites)"
  done
}

# ---------------------------------------------------------------- env file
# Create local/.env from the example on first run and fill the secrets with random,
# local-only values. Existing values are never overwritten. Nothing is printed.
ensure_env() {
  local f="$LOCAL_DIR/.env"
  if [ ! -f "$f" ]; then
    cp "$LOCAL_DIR/.env.example" "$f"
    chmod 600 "$f"
    info "created local/.env from local/.env.example (gitignored, mode 600)"
  fi
  local key
  for key in JWT_SECRET POSTGRES_PASSWORD CLICKHOUSE_PASSWORD AUDIT_API_LOCAL_TOKEN AUDIT_API_LOCAL_VIEWER_TOKEN \
             MEMORY_POSTGRES_PASSWORD MEMORY_API_LOCAL_TOKEN MEMORY_API_LOCAL_VIEWER_TOKEN; do
    if ! grep -Eq "^${key}=.+" "$f"; then
      local val; val="$(openssl rand -hex 32)"
      # Rewrite the line without printing it; avoid sed -i (differs between macOS and Linux).
      if grep -Eq "^${key}=" "$f"; then
        awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      else
        printf '%s=%s\n' "$key" "$val" >> "$f"
      fi
      chmod 600 "$f"
      info "generated a local-only $key in local/.env"
    fi
  done
  # Settings added after a local/.env was first created: append the local default, never touch a value that exists.
  local def
  for def in AUDIT_CONTENT_ENABLED=true AUDIT_CONTENT_STORE=clickhouse; do
    if ! grep -Eq "^${def%%=*}=" "$f"; then
      printf '%s\n' "$def" >> "$f"
      info "added ${def%%=*}=${def#*=} to local/.env (raw text of events, see docs/LOCAL_TESTING.md)"
    fi
  done
}

load_env() {
  [ -f "$LOCAL_DIR/.env" ] || die "local/.env is missing: run ./up.sh first"
  # Settings given on the command line (PROBA_SRC=worktree ./up.sh) win over local/.env.
  local keep="" v
  for v in PROBA_SRC PROBA_REF PROBA_HUB_DIR PROBA_WEB_DIR PROBA_AUDIT_DIR PROBA_PORTAL_DIR PROBA_MEMORY_DIR; do
    if [ -n "${!v+x}" ]; then keep="$keep$v=$(printf '%q' "${!v}") "; fi
  done
  set -a
  # shellcheck disable=SC1091
  . "$LOCAL_DIR/.env"
  [ -z "$keep" ] || eval "$keep"
  set +a
  : "${WEB_HOST_PORT:=5180}" "${HUB_HOST_PORT:=3300}" "${POSTGRES_HOST_PORT:=55433}" "${REDIS_HOST_PORT:=56380}"
  : "${CLICKHOUSE_HTTP_HOST_PORT:=58125}" "${AUDIT_CONSUMER_HOST_PORT:=3401}" "${METRICS_INGESTER_HOST_PORT:=3402}"
  : "${ROLLUP_HOST_PORT:=3403}" "${AUDIT_API_HOST_PORT:=3400}" "${PORTAL_HOST_PORT:=3410}"
  : "${MEMORY_POSTGRES_HOST_PORT:=55434}" "${MEMORY_API_HOST_PORT:=3420}" "${MEMORY_INGESTOR_HOST_PORT:=3421}" "${MEMORY_JOBS_HOST_PORT:=3422}"
  export WEB_HOST_PORT HUB_HOST_PORT POSTGRES_HOST_PORT REDIS_HOST_PORT CLICKHOUSE_HTTP_HOST_PORT
  export AUDIT_CONSUMER_HOST_PORT METRICS_INGESTER_HOST_PORT ROLLUP_HOST_PORT AUDIT_API_HOST_PORT PORTAL_HOST_PORT
  export MEMORY_POSTGRES_HOST_PORT MEMORY_API_HOST_PORT MEMORY_INGESTOR_HOST_PORT MEMORY_JOBS_HOST_PORT
}

# ---------------------------------------------------------------- compose
dc() {
  docker compose -p "$PROJECT" --env-file "$LOCAL_DIR/.env" -f "$LOCAL_DIR/docker-compose.yml" "$@"
}

abs_dir() { # resolve a path relative to local/ (or absolute) to an absolute one
  case "$1" in
    /*) (cd "$1" 2>/dev/null && pwd) ;;
    *) (cd "$LOCAL_DIR/$1" 2>/dev/null && pwd) ;;
  esac
}

# Snapshot the committed ref of a sibling checkout into local/.src/<name> (git archive), so the
# build never sees uncommitted work or the branch someone else has checked out.
snapshot_repo() { # name dir
  local name="$1" dir="$2" ref="${PROBA_REF:-origin/main}" dest="$SRC_DIR/$1"
  [ -n "$dir" ] && [ -d "$dir/.git" ] || return 1
  if [ "${PROBA_NO_FETCH:-0}" != "1" ]; then git -C "$dir" fetch -q origin 2>/dev/null || warn "git fetch failed in $name (continuing with what is local)"; fi
  if ! git -C "$dir" rev-parse --verify -q "$ref^{commit}" >/dev/null; then
    warn "$name: ref $ref not found, using main"
    ref=main
    git -C "$dir" rev-parse --verify -q "$ref^{commit}" >/dev/null || return 1
  fi
  local sha; sha="$(git -C "$dir" rev-parse "$ref^{commit}")"
  if [ -f "$dest/.snapshot-commit" ] && [ "$(cat "$dest/.snapshot-commit")" = "$sha" ]; then
    info "  $name: snapshot of $ref @ ${sha:0:7} (cached)"
  else
    rm -rf "$dest"; mkdir -p "$dest"
    git -C "$dir" archive "$ref" | tar -x -C "$dest"
    printf '%s' "$sha" > "$dest/.snapshot-commit"
    info "  $name: snapshot of $ref @ ${sha:0:7}"
  fi
}

# Sets and exports HUB_SRC WEB_SRC AUDIT_SRC PORTAL_SRC MEMORY_SRC (absolute build contexts).
# resolve_sources [want_portal 0|1] [want_memory 0|1]
resolve_sources() {
  local mode="${PROBA_SRC:-main}" want_portal="${1:-0}" want_memory="${2:-0}"
  local hub web audit portal memory
  hub="$(abs_dir "${PROBA_HUB_DIR:-../../proba-hub}")" || true
  web="$(abs_dir "${PROBA_WEB_DIR:-../../proba-web}")" || true
  audit="$(abs_dir "${PROBA_AUDIT_DIR:-../../proba-audit}")" || true
  portal="$(abs_dir "${PROBA_PORTAL_DIR:-../../proba-portal}")" || true
  memory="$(abs_dir "${PROBA_MEMORY_DIR:-../../proba-memory}")" || true
  if [ "$want_memory" = "1" ] && [ -z "$memory" ]; then die "proba-memory checkout not found at ${PROBA_MEMORY_DIR:-../../proba-memory} (set PROBA_MEMORY_DIR in local/.env)"; fi
  [ -n "$hub" ] || die "proba-hub checkout not found at ${PROBA_HUB_DIR:-../../proba-hub} (set PROBA_HUB_DIR in local/.env)"
  [ -n "$web" ] || die "proba-web checkout not found at ${PROBA_WEB_DIR:-../../proba-web} (set PROBA_WEB_DIR in local/.env)"
  [ -n "$audit" ] || die "proba-audit checkout not found at ${PROBA_AUDIT_DIR:-../../proba-audit} (set PROBA_AUDIT_DIR in local/.env)"
  case "$mode" in
    worktree)
      info "building from the working trees of the sibling checkouts (PROBA_SRC=worktree)"
      HUB_SRC="$hub"; WEB_SRC="$web"; AUDIT_SRC="$audit"; PORTAL_SRC="$portal"; MEMORY_SRC="${memory:-$SRC_DIR/proba-memory}" ;;
    main)
      info "snapshotting ${PROBA_REF:-origin/main} of the sibling checkouts into local/.src (PROBA_SRC=main)"
      snapshot_repo proba-hub "$hub" || die "cannot snapshot proba-hub"
      snapshot_repo proba-web "$web" || die "cannot snapshot proba-web"
      snapshot_repo proba-audit "$audit" || die "cannot snapshot proba-audit"
      HUB_SRC="$SRC_DIR/proba-hub"; WEB_SRC="$SRC_DIR/proba-web"; AUDIT_SRC="$SRC_DIR/proba-audit"
      PORTAL_SRC="$SRC_DIR/proba-portal"; MEMORY_SRC="$SRC_DIR/proba-memory"
      if [ "$want_portal" = "1" ] && [ -n "$portal" ]; then snapshot_repo proba-portal "$portal" || true; fi
      if [ "$want_memory" = "1" ]; then snapshot_repo proba-memory "$memory" || die "cannot snapshot proba-memory"; fi ;;
    *) die "PROBA_SRC must be main or worktree (got $mode)" ;;
  esac
  [ -f "$AUDIT_SRC/Dockerfile" ] || die "no Dockerfile in $AUDIT_SRC"
  export HUB_SRC WEB_SRC AUDIT_SRC PORTAL_SRC MEMORY_SRC
}

port_listening() {
  if command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; fi
}

# Fail early, naming the variable to change, when a host port is already taken by something
# that is not this project's own container.
check_ports() {
  local bad=0 pair var port ours
  ours="$(docker ps --filter "name=${PROJECT}-" --format '{{.Ports}}' 2>/dev/null || true)"
  for var in WEB_HOST_PORT HUB_HOST_PORT POSTGRES_HOST_PORT REDIS_HOST_PORT CLICKHOUSE_HTTP_HOST_PORT \
             AUDIT_CONSUMER_HOST_PORT METRICS_INGESTER_HOST_PORT ROLLUP_HOST_PORT AUDIT_API_HOST_PORT "$@"; do
    port="$(eval "printf '%s' \"\${$var}\"")"
    if port_listening "$port" && ! printf '%s' "$ours" | grep -q ":$port->"; then
      warn "port $port ($var) is already in use on this machine: set another $var in local/.env"
      bad=1
    fi
  done
  [ "$bad" = 0 ] || die "free the port(s) above or change them in local/.env, then run ./up.sh again"
  : "$pair"
}

# ---------------------------------------------------------------- data access helpers
CH_DB=proba_audit
ch() { # ch "SQL"  -> raw result (TSV unless the SQL has FORMAT)
  printf 'user = "proba:%s"\n' "$CLICKHOUSE_PASSWORD" |
    curl -sS -f -K - "http://127.0.0.1:${CLICKHOUSE_HTTP_HOST_PORT}/?database=${2:-$CH_DB}" --data-binary "$1"
}
ch_pretty() { ch "$1 FORMAT PrettyCompactMonoBlock"; }
pg() { dc exec -T postgres psql -U proba -d proba_hub -tA -c "$1"; }
rds() { dc exec -T redis redis-cli "$@"; }

hub_url() { printf 'http://127.0.0.1:%s' "$HUB_HOST_PORT"; }

# A Hub session token. HUB_SESSION_TOKEN wins (a real Firebase sign-in, see docs); otherwise the
# Hub's development login (only registered when the Hub runs outside production and
# DEV_LOGIN_ENABLED is not false).
hub_token() {
  if [ -n "${HUB_SESSION_TOKEN:-}" ]; then printf '%s' "$HUB_SESSION_TOKEN"; return 0; fi
  local email="${1:-${SEED_EMAIL:-seed@proba.local}}" out
  out="$(curl -sS -m 15 -X POST "$(hub_url)/dev/login" -H 'content-type: application/json' \
    -d "{\"email\":\"$email\",\"name\":\"Local Seed\"}")" || return 1
  printf '%s' "$out" | jq -er '.token' 2>/dev/null ||
    { warn "no session: /dev/login answered '$(printf '%s' "$out" | head -c 160)'. Set HUB_SESSION_TOKEN in local/.env (docs/LOCAL_TESTING.md, Signing in)."; return 1; }
}

uuid() { if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; else cat /proc/sys/kernel/random/uuid; fi; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

# hub_post TOKEN TYPE PAYLOAD_JSON [THREAD_ID] [CLIENT_MSG_ID]  -> sets LAST_ID (the clientMsgId = traceId) and LAST_STATUS.
# Not run in a subshell, so call it directly (not inside $(...)).
hub_post() {
  local token="$1" type="$2" payload="$3" thread="${4:-}" id body resp
  id="${5:-$(uuid)}"
  body="$(jq -nc --arg id "$id" --arg type "$type" --argjson payload "$payload" --arg thread "$thread" --arg now "$(now_iso)" \
    '{kind:"command",clientMsgId:$id,type:$type,payload:$payload,sentAt:$now} + (if $thread=="" then {} else {threadId:$thread} end)')"
  local hdr; hdr="$(mktemp)"
  resp="$(curl -sS -m 20 -D "$hdr" -X POST "$(hub_url)/v1/commands" -H "authorization: Bearer $token" -H 'content-type: application/json' -d "$body")" || { rm -f "$hdr"; return 1; }
  LAST_TRACE_HEADER="$(tr -d '\r' < "$hdr" | awk 'tolower($1)=="x-trace-id:" {print $2}')"
  rm -f "$hdr"
  LAST_STATUS="$(printf '%s' "$resp" | jq -r '.status // "error"')"
  LAST_ID="$id"
}

# hub_events TOKEN [AFTER] -> JSON array of all the user's events after a seq (follows the 50-per-page polling)
hub_events() {
  local after="${2:-0}" page acc='[]' more=true
  while [ "$more" = true ]; do
    page="$(curl -sS -m 20 "$(hub_url)/v1/events?after=${after}" -H "authorization: Bearer $1")" || return 1
    acc="$(jq -c --argjson a "$acc" '$a + (.events // [])' <<<"$page")"
    more="$(jq -r '.hasMore // false' <<<"$page")"
    after="$(jq -r '.nextSeq // 0' <<<"$page")"
  done
  printf '%s' "$acc"
}

wait_until() { # wait_until SECONDS "description" command...
  local secs="$1" what="$2" i=0; shift 2
  while [ "$i" -lt "$secs" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1; i=$((i + 1))
  done
  warn "timed out after ${secs}s waiting for: $what"
  return 1
}

# ---------------------------------------------------------------- PASS/FAIL reporting
CHECKS_PASS=0; CHECKS_FAIL=0; CHECKS_SKIP=0
pass() { CHECKS_PASS=$((CHECKS_PASS + 1)); printf '%sPASS%s  %s\n' "$C_GREEN" "$C_OFF" "$1"; }
fail() { CHECKS_FAIL=$((CHECKS_FAIL + 1)); printf '%sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$1"; [ -z "${2:-}" ] || printf '      %s%s%s\n' "$C_DIM" "$2" "$C_OFF"; }
skip() { CHECKS_SKIP=$((CHECKS_SKIP + 1)); printf '%sSKIP%s  %s\n' "$C_YELLOW" "$C_OFF" "$1"; [ -z "${2:-}" ] || printf '      %s%s%s\n' "$C_DIM" "$2" "$C_OFF"; }

# verify_chain [DATABASE] [WORKSPACE] -> prints proba-audit's verifyChain result as one JSON line (exit 0 intact, 2 broken).
# Runs inside the metrics-ingester image (it contains the proba-audit core and adapters), against ClickHouse.
verify_chain() {
  local db="${1:-$CH_DB}" ws="${2:-seedbed}"
  : "${AUDIT_SRC:=$SRC_DIR/proba-audit}" "${HUB_SRC:=$SRC_DIR/proba-hub}" "${WEB_SRC:=$SRC_DIR/proba-web}" "${PORTAL_SRC:=$SRC_DIR/proba-portal}" "${MEMORY_SRC:=$SRC_DIR/proba-memory}"
  export AUDIT_SRC HUB_SRC WEB_SRC PORTAL_SRC MEMORY_SRC
  dc run --rm --no-deps -T -e "CLICKHOUSE_DATABASE=$db" -v "$LOCAL_DIR/tools:/app/tools:ro" \
    --entrypoint node metrics-ingester /app/tools/verify-chain.mjs "$ws" 2>/dev/null | tail -n 1
}
