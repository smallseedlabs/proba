#!/usr/bin/env bash
# Shared helpers for deploy/scripts. Source it; do not run it.

DEPLOY_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$DEPLOY_SCRIPTS/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
STACK_DIR="$DEPLOY_DIR/stacks"
export DEPLOY_SCRIPTS DEPLOY_DIR REPO_ROOT STACK_DIR

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_YELLOW=''; C_BOLD=''; C_OFF=''
fi
export C_RED C_YELLOW C_BOLD C_OFF

info() { printf '%s\n' "$*"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
die() { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

need() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing prerequisite: $c"
  done
}

# Refuse destructive global docker arguments. Scoped project/label cleanup is allowed.
assert_safe_docker_args() {
  local a next
  while [ $# -gt 0 ]; do
    a="$1"; shift || true
    case "$a" in
      system) die "refusing docker system … (no global prune)" ;;
      prune) die "refusing docker prune (no global prune)" ;;
      --volumes|-v)
        die "refusing unscoped -v/--volumes; name the resources this script created"
        ;;
      down)
        next="${1:-}"
        if [ "$next" = "-v" ] || [ "$next" = "--volumes" ]; then
          die "refusing docker compose/stack down -v"
        fi
        ;;
    esac
  done
}

require_label_filter() {
  local filter="${1:-}"
  [ -n "$filter" ] || die "refusing to operate without --filter label=… (scoped resources only)"
  case "$filter" in
    label=proba.isolated-drill-id=*|label=proba.backup.role=*|label=proba.component=*) ;;
    *) die "filter must be a proba.* label (got $filter)" ;;
  esac
}

stack_files() {
  ls -1 "$STACK_DIR"/*.yml
}
