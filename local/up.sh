#!/usr/bin/env bash
# Bring up the whole local platform with one command:  ./up.sh
#   --portal      also start Proba Insights (proba-portal); needs the Firebase settings, see docs/LOCAL_TESTING.md
#   --memory      also start the memory service (proba-memory: memory-api, ingestor, jobs, own Postgres); see docs/LOCAL_TESTING.md
#   --no-build    do not rebuild images (reuse proba-local/*:dev, or images you pulled via *_IMAGE)
#   --no-wait     do not wait for the services to become healthy
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PORTAL=0; MEMORY=0; BUILD=1; WAIT=1
for a in "$@"; do
  case "$a" in
    --portal) PORTAL=1 ;;
    --memory) MEMORY=1 ;;
    --no-build) BUILD=0 ;;
    --no-wait) WAIT=0 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done

need docker curl jq openssl git tar awk
docker info >/dev/null 2>&1 || die "the Docker daemon is not running"
ensure_env
load_env
step "sources"
resolve_sources "$PORTAL" "$MEMORY"
step "ports"
EXTRA_PORTS=""
[ "$PORTAL" = 1 ] && EXTRA_PORTS="$EXTRA_PORTS PORTAL_HOST_PORT"
[ "$MEMORY" = 1 ] && EXTRA_PORTS="$EXTRA_PORTS MEMORY_POSTGRES_HOST_PORT MEMORY_API_HOST_PORT MEMORY_INGESTOR_HOST_PORT MEMORY_JOBS_HOST_PORT"
# shellcheck disable=SC2086
check_ports $EXTRA_PORTS
info "all host ports are free (or already ours)"

step "build and start (project $PROJECT)"
PROFILES=""
if [ "$PORTAL" = 1 ]; then
  if [ -f "$PORTAL_SRC/Dockerfile" ]; then PROFILES="portal"
  else warn "proba-portal has no Dockerfile in $PORTAL_SRC (not merged to the snapshotted ref? try PROBA_SRC=worktree): starting the platform without the portal"; PORTAL=0; fi
fi
if [ "$MEMORY" = 1 ]; then
  if [ -f "$MEMORY_SRC/Dockerfile" ]; then PROFILES="${PROFILES:+$PROFILES,}memory"
  else warn "proba-memory has no Dockerfile in $MEMORY_SRC (try PROBA_SRC=worktree or PROBA_REF): starting the platform without the memory service"; MEMORY=0; fi
fi
[ -z "$PROFILES" ] || export COMPOSE_PROFILES="$PROFILES"
if [ "$PORTAL" = 1 ]; then
  [ "${AUDIT_API_TOKEN_VERIFIER:-static}" = "firebase" ] || warn "the portal signs in with Firebase ID tokens, but the audit API is on AUDIT_API_TOKEN_VERIFIER=${AUDIT_API_TOKEN_VERIFIER:-static}: set it to firebase in local/.env (see docs/LOCAL_TESTING.md, Portal profile)"
  [ -n "${FIREBASE_API_KEY:-}" ] && [ -n "${FIREBASE_AUTH_DOMAIN:-}" ] && [ -n "${FIREBASE_PROJECT_ID:-}" ] && [ -n "${FIREBASE_APP_ID:-}" ] || warn "FIREBASE_API_KEY, FIREBASE_AUTH_DOMAIN, FIREBASE_PROJECT_ID and FIREBASE_APP_ID are not all set in local/.env: the portal will say that sign-in has not been set up"
fi
if [ "$BUILD" = 1 ]; then
  mkdir -p "$LOCAL_DIR/.state"
  info "building images (full log: local/.state/build.log)"
  dc build --progress=plain >"$LOCAL_DIR/.state/build.log" 2>&1 || { tail -n 40 "$LOCAL_DIR/.state/build.log" >&2; die "image build failed (see local/.state/build.log)"; }
fi
# The ClickHouse migrations (including 0008, the table for the raw text of events) must have run before the
# audit-consumer starts: with AUDIT_CONTENT_ENABLED it writes the text there first. compose also waits for
# audit-migrate, but running it here makes it explicit, and applies a new migration to an existing volume.
step "ClickHouse migrations"
dc up -d --wait clickhouse >/dev/null 2>&1 || dc up -d clickhouse >/dev/null
dc run --rm --no-deps -T audit-migrate 2>&1 | tail -n 4 || die "the ClickHouse migrations failed: docker compose -p $PROJECT logs clickhouse"
dc up -d

if [ "$WAIT" = 1 ]; then
  step "waiting for health (up to 240 s)"
  i=0
  until "$LOCAL_DIR/status.sh" --quiet; do
    i=$((i + 5)); [ "$i" -lt 240 ] || { "$LOCAL_DIR/status.sh" || true; die "the platform did not become healthy: docker compose -p $PROJECT logs <service>"; }
    sleep 5
  done
fi
step "status"
"$LOCAL_DIR/status.sh" || true
PORTAL_LINE=""
[ "$PORTAL" = 1 ] && PORTAL_LINE=$'\n'"  Proba Insights http://localhost:${PORTAL_HOST_PORT}   (health: /health)"
[ "$MEMORY" = 1 ] && PORTAL_LINE="$PORTAL_LINE"$'\n'"  Memory API     http://localhost:${MEMORY_API_HOST_PORT}   (/health, /v1/..., bearer token MEMORY_API_LOCAL_TOKEN in local/.env)"
cat <<MSG

Platform is up.
  Web            http://localhost:${WEB_HOST_PORT}
  Hub API        http://localhost:${HUB_HOST_PORT}   (health: /health)
  Audit API      http://localhost:${AUDIT_API_HOST_PORT}   (/health, /v1/..., bearer token AUDIT_API_LOCAL_TOKEN in local/.env)
  ClickHouse     http://localhost:${CLICKHOUSE_HTTP_HOST_PORT}   (user proba, password in local/.env)${PORTAL_LINE}
Next:  ./seed.sh   (generate varied traffic)   then   ./verify.sh   (PASS/FAIL checks)
Docs:  docs/LOCAL_TESTING.md
MSG
