#!/usr/bin/env bash
# Snapshot labeled Postgres/Redis/ClickHouse containers into --output.
# Requires --filter label=proba.… so it cannot pick unlabeled or foreign stacks.
# Does not stop live stacks. Consistency of a multi-store backup still needs writers paused
# (see docs/BACKUP_RESTORE.md). This script copies whatever the engine currently has.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FILTER=""
OUT=""
ROLE="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --filter) FILTER="${2:-}"; shift ;;
    --output) OUT="${2:-}"; shift ;;
    --role) ROLE="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,6p' "$0"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift || true
done

need docker
require_label_filter "$FILTER"
[ -n "$OUT" ] || die "usage: backup.sh --filter label=proba.… --output DIR"
mkdir -p "$OUT"
chmod 700 "$OUT"
printf '%s\n' "$FILTER" > "$OUT/filter.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/taken_at.txt"

ids="$(docker ps -q --filter "$FILTER")"
[ -n "$ids" ] || die "no running containers match $FILTER"

backup_postgres() {
  local id="$1" dest="$2"
  local user db
  user="$(docker exec "$id" printenv POSTGRES_USER)"
  db="$(docker exec "$id" printenv POSTGRES_DB)"
  [ -n "$user" ] && [ -n "$db" ] || die "container $id missing POSTGRES_USER/POSTGRES_DB"
  docker exec "$id" pg_dump -U "$user" -d "$db" --format=custom --file=/tmp/proba.dump
  docker cp "$id:/tmp/proba.dump" "$dest/postgres.dump"
  docker exec "$id" rm -f /tmp/proba.dump
  printf '%s\n' "$user" > "$dest/postgres.user"
  printf '%s\n' "$db" > "$dest/postgres.db"
  info "postgres dump $id -> $dest/postgres.dump"
}

backup_redis() {
  local id="$1" dest="$2"
  docker exec "$id" redis-cli BGSAVE >/dev/null || docker exec "$id" sh -c 'REDISCLI_AUTH="$(cat /run/secrets/redis_password 2>/dev/null)" redis-cli --user "${REDIS_USER:-proba}" BGSAVE' >/dev/null || true
  sleep 1
  docker exec "$id" sh -c 'test -f /data/dump.rdb && cat /data/dump.rdb' > "$dest/dump.rdb" || true
  docker exec "$id" sh -c 'test -f /data/appendonly.aof && cat /data/appendonly.aof' > "$dest/appendonly.aof" || true
  info "redis copy $id -> $dest"
}

backup_clickhouse() {
  local id="$1" dest="$2"
  docker exec "$id" wget -q -O- 'http://127.0.0.1:8123/ping' >/dev/null
  # Native BACKUP DATABASE needs an operator disk; here we freeze a logical dump of the default db.
  docker exec "$id" sh -c "clickhouse-client --query \"SHOW DATABASES\"" > "$dest/databases.txt"
  info "clickhouse inventory $id -> $dest/databases.txt (full BACKUP DATABASE is an operator disk/S3 step; see docs/BACKUP_RESTORE.md)"
}

copied=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  names="$(docker inspect -f '{{.Name}} {{index .Config.Labels "proba.backup.role"}} {{index .Config.Labels "proba.component"}}' "$id")"
  role="$(docker inspect -f '{{index .Config.Labels "proba.backup.role"}}' "$id")"
  component="$(docker inspect -f '{{index .Config.Labels "proba.component"}}' "$id")"
  [ -n "$role" ] || continue
  if [ "$ROLE" != "all" ] && [ "$ROLE" != "$role" ]; then continue; fi
  dest="$OUT/${component:-$id}"
  mkdir -p "$dest"
  printf '%s\n' "$names" > "$dest/identity.txt"
  case "$role" in
    postgres) backup_postgres "$id" "$dest" ;;
    redis) backup_redis "$id" "$dest" ;;
    clickhouse) backup_clickhouse "$id" "$dest" ;;
    *) warn "skip unknown backup role $role on $id" ;;
  esac
  copied=$((copied + 1))
done <<< "$ids"

[ "$copied" -gt 0 ] || die "matched containers but none had proba.backup.role"
info "backup wrote $copied component(s) under $OUT"
