#!/usr/bin/env bash
# Restore a backup.sh directory into NEW disposable containers labeled with
# --into-label. Never attaches to an existing live volume. Never uses down -v.
#
#   ./restore.sh --backup DIR --into-label proba.isolated-drill-id=… --postgres-image IMAGE
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKUP=""
INTO_LABEL=""
POSTGRES_IMAGE="postgres:16-alpine@sha256:0cefaabd882e42bcb2a2f3dc56d3ce4770560ba62fd7f197f1a2e008fd5731ab"
NAME_PREFIX="proba-restore"
HOST_BIND="127.0.0.1"
HOST_PORT=""
PASSWORD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --backup) BACKUP="${2:-}"; shift ;;
    --into-label) INTO_LABEL="${2:-}"; shift ;;
    --postgres-image) POSTGRES_IMAGE="${2:-}"; shift ;;
    --name-prefix) NAME_PREFIX="${2:-}"; shift ;;
    --host-port) HOST_PORT="${2:-}"; shift ;;
    --password) PASSWORD="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,6p' "$0"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift || true
done

need docker
[ -n "$BACKUP" ] && [ -d "$BACKUP" ] || die "usage: restore.sh --backup DIR --into-label label=value"
require_label_filter "$INTO_LABEL"
case "$NAME_PREFIX" in
  proba-restore*|proba-drill*) ;;
  *) die "name prefix must start with proba-restore or proba-drill" ;;
esac

pg_dir=""
for d in "$BACKUP"/*; do
  [ -d "$d" ] || continue
  if [ -f "$d/postgres.dump" ]; then pg_dir="$d"; break; fi
done
[ -n "$pg_dir" ] || die "no postgres.dump under $BACKUP"

user="$(cat "$pg_dir/postgres.user")"
db="$(cat "$pg_dir/postgres.db")"
[ -n "$PASSWORD" ] || PASSWORD="$(openssl rand -hex 16)"
[ -n "$HOST_PORT" ] || HOST_PORT="0"

name="${NAME_PREFIX}-pg"
vol="${NAME_PREFIX}-data"
if docker inspect "$name" >/dev/null 2>&1; then
  die "container $name already exists; pick another --name-prefix (will not clobber)"
fi
if docker volume inspect "$vol" >/dev/null 2>&1; then
  die "volume $vol already exists; pick another --name-prefix (will not clobber)"
fi

label_key="${INTO_LABEL#label=}"
label_name="${label_key%%=*}"
label_val="${label_key#*=}"

docker volume create --label "$label_name=$label_val" --label proba.isolated-drill=1 "$vol" >/dev/null
docker run -d \
  --name "$name" \
  --label "$label_name=$label_val" \
  --label proba.backup.role=postgres \
  --label proba.component="${NAME_PREFIX}-postgres" \
  -e POSTGRES_USER="$user" \
  -e POSTGRES_PASSWORD="$PASSWORD" \
  -e POSTGRES_DB="$db" \
  -v "$vol:/var/lib/postgresql/data" \
  -p "${HOST_BIND}:${HOST_PORT}:5432" \
  "$POSTGRES_IMAGE" >/dev/null

# Wait for readiness on this new container only.
for _ in $(seq 1 30); do
  if docker exec "$name" pg_isready -U "$user" -d "$db" >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$name" pg_isready -U "$user" -d "$db" >/dev/null

docker cp "$pg_dir/postgres.dump" "$name:/tmp/proba.dump"
docker exec -e PGPASSWORD="$PASSWORD" "$name" pg_restore -U "$user" -d "$db" --clean --if-exists /tmp/proba.dump
docker exec "$name" rm -f /tmp/proba.dump

mapped="$(docker port "$name" 5432 | head -n 1)"
info "restored postgres into $name ($mapped) label $INTO_LABEL"
info "password is not printed; pass --password if a later step must connect"
printf '%s\n' "$name"
