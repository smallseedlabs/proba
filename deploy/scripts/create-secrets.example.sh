#!/usr/bin/env bash
# Example: create Swarm secrets from files in a gitignored directory.
# Default is dry-run. Does not print file contents.
#
#   SECRETS_DIR=/etc/proba/secret-src ./create-secrets.example.sh
#   SECRETS_DIR=... ./create-secrets.example.sh --apply   # operator cluster only
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY=0
SECRETS_DIR="${SECRETS_DIR:-}"
NAMES='postgres_password redis_password jwt_secret clickhouse_password clickhouse_consumer_password clickhouse_api_password clickhouse_migrator_password anchor_hmac_key anchor_db_password context_postgres_password memory_postgres_password ads_postgres_password ads_database_url redis_url hub_assertion_public_jwks context_service_public_jwks hub_service_jwks gateway_jwks llm_api_key'

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dir) SECRETS_DIR="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,7p' "$0"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift || true
done

[ -n "$SECRETS_DIR" ] || die "set SECRETS_DIR to a mode-700 directory of secret files (not in git)"

info "Would create external Docker secrets from $SECRETS_DIR (names only):"
for n in $NAMES; do
  info "  docker secret create $n $SECRETS_DIR/$n"
done
info "Private PEMs are bind-mounted from PROBA_KEYS_DIR (chmod 600), not docker secrets."

if [ "$APPLY" != 1 ]; then
  info "dry-run complete"
  exit 0
fi
die "apply path is operator-only; this environment does not create cluster secrets"
