#!/usr/bin/env bash
# Stop and remove the containers of the local platform. Data volumes stay (use ./reset.sh to wipe them).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker
[ -f "$LOCAL_DIR/.env" ] || die "nothing to stop: local/.env does not exist"
load_env
export COMPOSE_PROFILES=portal
# Image sources are irrelevant to `down`, but compose still interpolates the file.
export HUB_SRC="${HUB_SRC:-$SRC_DIR/proba-hub}" WEB_SRC="${WEB_SRC:-$SRC_DIR/proba-web}"
export AUDIT_SRC="${AUDIT_SRC:-$SRC_DIR/proba-audit}" PORTAL_SRC="${PORTAL_SRC:-$SRC_DIR/proba-portal}"
dc down --remove-orphans
info "stopped. Data is kept in the Docker volumes ${PROJECT}_postgres_data, ${PROJECT}_redis_data, ${PROJECT}_clickhouse_data."
