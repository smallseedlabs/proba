#!/usr/bin/env bash
# Isolated Postgres backup→restore proof. Unique labels and a loopback port.
# Never touches unlabeled volumes, never swarm init, never down -v / prune.
# Skips (exit 0) when docker is missing unless --require-runtime.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REQUIRE=0
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --require-runtime) REQUIRE=1 ;;
    --keep) KEEP=1 ;;
    -h|--help)
      sed -n '2,6p' "$0"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift || true
done

if ! command -v docker >/dev/null 2>&1; then
  [ "$REQUIRE" = 1 ] && die "docker is required for the isolated drill"
  warn "docker not found: isolated backup drill skipped (static artifacts only)"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  [ "$REQUIRE" = 1 ] && die "docker daemon not reachable"
  warn "docker daemon not reachable: isolated backup drill skipped"
  exit 0
fi

need openssl
ID="drill$(openssl rand -hex 6)"
LABEL="proba.isolated-drill-id=$ID"
NAME="proba-drill-$ID"
IMAGE="postgres:16-alpine@sha256:0cefaabd882e42bcb2a2f3dc56d3ce4770560ba62fd7f197f1a2e008fd5731ab"
PASSWORD="$(openssl rand -hex 16)"
MARKER="marker-$ID"
WORKDIR="$DEPLOY_DIR/.drill/$ID"
mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"

cleanup() {
  if [ "$KEEP" = 1 ]; then
    warn "keeping $NAME* (--keep); delete with: docker rm -f \$(docker ps -aq --filter label=$LABEL); docker volume rm \$(docker volume ls -q --filter label=$LABEL)"
    return
  fi
  docker ps -aq --filter "label=$LABEL" | while IFS= read -r c; do
    [ -n "$c" ] || continue
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker volume ls -q --filter "label=$LABEL" | while IFS= read -r v; do
    [ -n "$v" ] || continue
    docker volume rm "$v" >/dev/null 2>&1 || true
  done
  rm -rf "$WORKDIR"
}

trap cleanup EXIT

info "isolated drill id=$ID (loopback publish, scoped labels, no swarm)"
docker volume create --label "$LABEL" --label proba.isolated-drill=1 "$NAME-src-data" >/dev/null
docker run -d \
  --name "$NAME-src" \
  --label "$LABEL" \
  --label proba.backup.role=postgres \
  --label proba.component="$NAME-src" \
  -e POSTGRES_USER=proba \
  -e POSTGRES_PASSWORD="$PASSWORD" \
  -e POSTGRES_DB=proba_drill \
  -v "$NAME-src-data:/var/lib/postgresql/data" \
  -p 127.0.0.1::5432 \
  "$IMAGE" >/dev/null

for _ in $(seq 1 40); do
  docker exec "$NAME-src" pg_isready -U proba -d proba_drill >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$NAME-src" pg_isready -U proba -d proba_drill >/dev/null
docker exec -e PGPASSWORD="$PASSWORD" "$NAME-src" \
  psql -U proba -d proba_drill -c "CREATE TABLE drill (id int primary key, note text); INSERT INTO drill VALUES (1, '$MARKER');"

"$DEPLOY_SCRIPTS/backup.sh" --filter "label=$LABEL" --output "$WORKDIR/backup" --role postgres

"$DEPLOY_SCRIPTS/restore.sh" \
  --backup "$WORKDIR/backup" \
  --into-label "label=$LABEL" \
  --name-prefix "$NAME-dst" \
  --postgres-image "$IMAGE" \
  --password "$PASSWORD" >/dev/null

got="$(docker exec -e PGPASSWORD="$PASSWORD" "$NAME-dst-pg" \
  psql -U proba -d proba_drill -Atc "SELECT note FROM drill WHERE id=1")"
[ "$got" = "$MARKER" ] || die "restore mismatch: expected $MARKER got $got"

info "isolated backup/restore drill passed (marker $MARKER); scoped cleanup on exit"
