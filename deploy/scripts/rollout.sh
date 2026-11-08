#!/usr/bin/env bash
# Print (default) or apply Swarm stack deploys. Default is dry-run.
# This script never inits or joins Swarm. It never runs unless the operator
# passes --apply AND PROBA_I_ACCEPT_LIVE_STACK_UPDATE=1.
#
#   ./rollout.sh                         # prints commands
#   ./rollout.sh --stacks data,app       # subset
#   ./rollout.sh --apply                 # refused without the env flag
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY=0
STACKS="data,app,audit"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --stacks) STACKS="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift || true
done

file_for() {
  case "$1" in
    data) printf '%s\n' "$STACK_DIR/10-data.yml" ;;
    app) printf '%s\n' "$STACK_DIR/20-app.yml" ;;
    audit) printf '%s\n' "$STACK_DIR/30-audit.yml" ;;
    memory) printf '%s\n' "$STACK_DIR/40-memory.yml" ;;
    portal) printf '%s\n' "$STACK_DIR/50-portal.yml" ;;
    llm) printf '%s\n' "$STACK_DIR/60-llm.yml" ;;
    gateway) printf '%s\n' "$STACK_DIR/70-gateway.yml" ;;
    ads) printf '%s\n' "$STACK_DIR/80-ads.yml" ;;
    *) die "unknown stack alias: $1" ;;
  esac
}

stack_name_for() {
  printf 'proba-%s\n' "$1"
}

info "${C_BOLD}Prepared commands (not executed unless --apply + PROBA_I_ACCEPT_LIVE_STACK_UPDATE=1)${C_OFF}"
info "Prerequisites: Swarm already initialised by the operator; overlay will be created by proba-data;"
info "external secrets exist; images built and tagged; PROBA_KEYS_DIR chmod 600 on labeled nodes."
info "Hub main has no gateway client. llm/gateway/ads stacks are not an E2E paid path."

OLDIFS="$IFS"
IFS=,
# shellcheck disable=SC2086
set -- $STACKS
IFS="$OLDIFS"

cmds=()
for alias in "$@"; do
  alias="$(printf '%s' "$alias" | tr -d ' ')"
  [ -n "$alias" ] || continue
  f="$(file_for "$alias")"
  [ -f "$f" ] || die "missing $f"
  name="$(stack_name_for "$alias")"
  cmds+=("docker stack deploy -c $f $name")
  info "  docker stack deploy -c $f $name"
done

if [ "$APPLY" != 1 ]; then
  info "dry-run complete; no live stack update"
  exit 0
fi

[ "${PROBA_I_ACCEPT_LIVE_STACK_UPDATE:-}" = 1 ] || die "refusing --apply (set PROBA_I_ACCEPT_LIVE_STACK_UPDATE=1 after reviewing docs/DEPLOYMENT.md)"
need docker
for c in "${cmds[@]}"; do
  # shellcheck disable=SC2086
  assert_safe_docker_args $c
done
die "apply path is operator-only on a dedicated cluster; this environment does not run live stack updates"
