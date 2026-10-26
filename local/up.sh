#!/usr/bin/env bash
# Bring up the whole local platform with one command:  ./up.sh
#   --portal      also start the portal profile (the portal, once proba-portal has a Dockerfile)
#   --no-build    do not rebuild images (reuse proba-local/*:dev, or images you pulled via *_IMAGE)
#   --no-wait     do not wait for the services to become healthy
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PORTAL=0; BUILD=1; WAIT=1
for a in "$@"; do
  case "$a" in
    --portal) PORTAL=1 ;;
    --no-build) BUILD=0 ;;
    --no-wait) WAIT=0 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done

need docker curl jq openssl git tar awk
docker info >/dev/null 2>&1 || die "the Docker daemon is not running"
ensure_env
load_env
step "sources"
resolve_sources "$PORTAL"
step "ports"
if [ "$PORTAL" = 1 ]; then check_ports PORTAL_HOST_PORT; else check_ports; fi
info "all host ports are free (or already ours)"

step "build and start (project $PROJECT)"
if [ "$PORTAL" = 1 ]; then
  if [ -f "$PORTAL_SRC/Dockerfile" ]; then export COMPOSE_PROFILES=portal
  else warn "proba-portal has no Dockerfile yet (it has not merged one): starting the platform without the portal"; PORTAL=0; fi
fi
if [ "$BUILD" = 1 ]; then
  mkdir -p "$LOCAL_DIR/.state"
  info "building images (full log: local/.state/build.log)"
  dc build --progress=plain >"$LOCAL_DIR/.state/build.log" 2>&1 || { tail -n 40 "$LOCAL_DIR/.state/build.log" >&2; die "image build failed (see local/.state/build.log)"; }
fi
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
cat <<MSG

Platform is up.
  Web            http://localhost:${WEB_HOST_PORT}
  Hub API        http://localhost:${HUB_HOST_PORT}   (health: /health)
  Audit API      http://localhost:${AUDIT_API_HOST_PORT}   (/health, /v1/..., bearer token AUDIT_API_LOCAL_TOKEN in local/.env)
  ClickHouse     http://localhost:${CLICKHOUSE_HTTP_HOST_PORT}   (user proba, password in local/.env)
Next:  ./seed.sh   (generate varied traffic)   then   ./verify.sh   (PASS/FAIL checks)
Docs:  docs/LOCAL_TESTING.md
MSG
