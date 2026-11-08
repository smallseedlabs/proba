#!/usr/bin/env bash
# Probe contracted endpoints. Overlay DNS is not used from here: pass URLs the
# caller can reach (operator proxy, or a throwaway isolated publish).
# Does not invent paths. Workers have no /ready.
#
#   ./readiness-check.sh --hub-url http://127.0.0.1:3000 --web-url http://127.0.0.1:8080
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HUB_URL=""
WEB_URL=""
AUDIT_API_URL=""
CONTEXT_URL=""
MEMORY_API_URL=""
LLM_URL=""
GATEWAY_URL=""
ADS_URL=""
PORTAL_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --hub-url) HUB_URL="${2:-}"; shift ;;
    --web-url) WEB_URL="${2:-}"; shift ;;
    --audit-api-url) AUDIT_API_URL="${2:-}"; shift ;;
    --context-url) CONTEXT_URL="${2:-}"; shift ;;
    --memory-api-url) MEMORY_API_URL="${2:-}"; shift ;;
    --llm-url) LLM_URL="${2:-}"; shift ;;
    --gateway-url) GATEWAY_URL="${2:-}"; shift ;;
    --ads-url) ADS_URL="${2:-}"; shift ;;
    --portal-url) PORTAL_URL="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift || true
done

need curl
bad=0
probe() {
  local name="$1" url="$2" path="$3"
  local code
  code="$(curl -sS -m 4 -o /dev/null -w '%{http_code}' "${url}${path}" || true)"
  if [ "$code" = 200 ]; then
    info "OK   $name ${path} -> $code"
  else
    info "FAIL $name ${path} -> ${code:-none}"
    bad=1
  fi
}

[ -n "$HUB_URL" ] && { probe hub "$HUB_URL" /health; probe hub "$HUB_URL" /ready; }
[ -n "$WEB_URL" ] && probe web "$WEB_URL" /health
[ -n "$PORTAL_URL" ] && probe portal "$PORTAL_URL" /health
[ -n "$AUDIT_API_URL" ] && { probe audit-api "$AUDIT_API_URL" /health; probe audit-api "$AUDIT_API_URL" /ready; }
[ -n "$CONTEXT_URL" ] && { probe context "$CONTEXT_URL" /health; probe context "$CONTEXT_URL" /ready; }
[ -n "$MEMORY_API_URL" ] && { probe memory-api "$MEMORY_API_URL" /health; probe memory-api "$MEMORY_API_URL" /ready; }
[ -n "$LLM_URL" ] && { probe llm "$LLM_URL" /health; probe llm "$LLM_URL" /ready; }
[ -n "$GATEWAY_URL" ] && { probe gateway "$GATEWAY_URL" /health; probe gateway "$GATEWAY_URL" /ready; }
[ -n "$ADS_URL" ] && { probe ads "$ADS_URL" /health; probe ads "$ADS_URL" /ready; }

if [ -z "$HUB_URL$WEB_URL$AUDIT_API_URL$CONTEXT_URL$MEMORY_API_URL$LLM_URL$GATEWAY_URL$ADS_URL$PORTAL_URL" ]; then
  die "pass at least one --*-url (this script does not discover live stacks)"
fi
exit "$bad"
