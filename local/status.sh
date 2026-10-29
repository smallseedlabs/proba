#!/usr/bin/env bash
# Health of every service of the local platform.  ./status.sh [--quiet]
# Exit code 0 only when everything that should run is healthy and both migrations completed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
need docker curl
load_env

bad=0
row() { # state name detail
  [ "$QUIET" = 1 ] || printf '%-5s %-18s %s\n' "$1" "$2" "$3"
  [ "$1" = OK ] || bad=1
}

container_state() { docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}|{{.State.ExitCode}}' "${PROJECT}-$1" 2>/dev/null || echo 'missing|-|-'; }

http_ok() { curl -sS -m 4 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

check_service() { # name url [expect-healthcheck]
  local name="$1" url="${2:-}" st health code
  st="$(container_state "$name")"; health="$(printf '%s' "$st" | cut -d'|' -f2)"
  if [ "$(printf '%s' "$st" | cut -d'|' -f1)" != running ]; then row DOWN "$name" "container $(printf '%s' "$st" | cut -d'|' -f1)"; return; fi
  if [ "$health" = starting ] || [ "$health" = unhealthy ]; then row DOWN "$name" "container health: $health"; return; fi
  if [ -n "$url" ]; then
    code="$(http_ok "$url")"
    if [ "$code" = 200 ]; then row OK "$name" "$url"; else row DOWN "$name" "$url -> HTTP ${code:-none}"; fi
  else
    row OK "$name" "container ${health}"
  fi
}

check_job() { # name
  local st; st="$(container_state "$1")"
  if [ "$(printf '%s' "$st" | cut -d'|' -f1,3)" = "exited|0" ]; then row OK "$1" "completed (exit 0)"; else row DOWN "$1" "state $st"; fi
}

[ "$QUIET" = 1 ] || printf '%s%-5s %-18s %s%s\n' "$C_BOLD" STATE SERVICE DETAIL "$C_OFF"
check_service postgres
check_service redis
check_service clickhouse
check_job hub-migrate
check_job audit-migrate
check_service hub "http://127.0.0.1:${HUB_HOST_PORT}/health"
check_service web "http://127.0.0.1:${WEB_HOST_PORT}/health"
check_service audit-consumer "http://127.0.0.1:${AUDIT_CONSUMER_HOST_PORT}/health"
check_service metrics-ingester "http://127.0.0.1:${METRICS_INGESTER_HOST_PORT}/health"
check_service rollup "http://127.0.0.1:${ROLLUP_HOST_PORT}/health"
check_service audit-api "http://127.0.0.1:${AUDIT_API_HOST_PORT}/health"
# The portal profile: reported only when its container exists.
if docker inspect "${PROJECT}-portal" >/dev/null 2>&1; then check_service portal "http://127.0.0.1:${PORTAL_HOST_PORT}/health"; fi
# The memory profile: reported only when its containers exist.
if docker inspect "${PROJECT}-memory-api" >/dev/null 2>&1; then
  check_service memory-postgres
  check_job memory-migrate
  check_service memory-api "http://127.0.0.1:${MEMORY_API_HOST_PORT}/health"
  check_service memory-ingestor "http://127.0.0.1:${MEMORY_INGESTOR_HOST_PORT}/health"
  check_service memory-jobs "http://127.0.0.1:${MEMORY_JOBS_HOST_PORT}/health"
fi
# The context profile: reported only when its containers exist.
if docker inspect "${PROJECT}-context-api" >/dev/null 2>&1; then
  check_service context-postgres
  check_job context-migrate
  check_service context-api "http://127.0.0.1:${CONTEXT_API_HOST_PORT}/health"
fi
exit "$bad"
