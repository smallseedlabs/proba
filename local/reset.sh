#!/usr/bin/env bash
# Wipe everything the local platform stored: containers, volumes (Postgres, Redis, ClickHouse),
# the seed state and the source snapshots. local/.env (and its secrets) is kept unless --env.
#   ./reset.sh [--yes] [--env] [--images]
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker
YES=0; ENVF=0; IMAGES=0
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1 ;; --env) ENVF=1 ;; --images) IMAGES=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done
if [ "$YES" != 1 ]; then
  printf 'This deletes ALL local platform data (project %s: Postgres, Redis, ClickHouse, memory Postgres). Type yes: ' "$PROJECT"
  read -r answer; [ "$answer" = yes ] || die "aborted"
fi
if [ -f "$LOCAL_DIR/.env" ]; then
  load_env
  export COMPOSE_PROFILES=portal,memory
  export HUB_SRC="$SRC_DIR/proba-hub" WEB_SRC="$SRC_DIR/proba-web" AUDIT_SRC="$SRC_DIR/proba-audit" PORTAL_SRC="$SRC_DIR/proba-portal" MEMORY_SRC="$SRC_DIR/proba-memory"
  dc down --volumes --remove-orphans
else
  warn "no local/.env: removing the project's volumes by name"
  for v in postgres_data redis_data clickhouse_data memory_postgres_data; do docker volume rm "${PROJECT}_$v" >/dev/null 2>&1 || true; done
fi
rm -rf "$STATE_DIR" "$SRC_DIR"
if [ "$IMAGES" = 1 ]; then
  for img in $(docker image ls --format "{{.Repository}}:{{.Tag}}" | grep "^proba-local/"); do docker image rm "$img" >/dev/null 2>&1 || true; done
fi
if [ "$ENVF" = 1 ]; then rm -f "$LOCAL_DIR/.env"; info "removed local/.env (a new one with new secrets is created by ./up.sh)"; fi
info "reset done. Start again with ./up.sh"
