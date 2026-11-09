#!/usr/bin/env bash
# Print (default) docker service rollback commands. Never rolls back unless
# --apply AND PROBA_I_ACCEPT_LIVE_STACK_UPDATE=1 AND --service NAME.
#
#   ./rollback.sh --service proba-app_hub
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY=0
SERVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --service) SERVICE="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,6p' "$0"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift || true
done

[ -n "$SERVICE" ] || die "usage: rollback.sh --service <stack>_<svc>  (dry-run default)"
case "$SERVICE" in
  proba-*) ;;
  *) die "service name must start with proba- (got $SERVICE)" ;;
esac

info "Prepared: docker service rollback $SERVICE"
info "Then: docker service ps $SERVICE"
info "Stateful volumes are not reverted by service rollback; restore from backup if the schema moved."

if [ "$APPLY" != 1 ]; then
  info "dry-run complete; no live rollback"
  exit 0
fi
[ "${PROBA_I_ACCEPT_LIVE_STACK_UPDATE:-}" = 1 ] || die "refusing --apply without PROBA_I_ACCEPT_LIVE_STACK_UPDATE=1"
die "apply path is operator-only; this environment does not run live stack updates"
