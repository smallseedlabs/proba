#!/usr/bin/env bash
# Static validation of Swarm artifacts. Does not start Swarm, pull images, or deploy.
#   ./validate.sh
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need node
cd "$REPO_ROOT"

if ! node -e "import('js-yaml')" 2>/dev/null; then
  npm install --no-save --no-package-lock js-yaml@4 >/dev/null
fi

info "== stack security (static)"
node scripts/check-stack-security.mjs

info "== stack security negative tests"
node --test scripts/check-stack-security.test.mjs

info "== bash -n"
for f in deploy/scripts/*.sh; do
  bash -n "$f"
done

info "== no committed operator secrets"
if grep -R --include='*.yml' --include='*.md' --include='*.env' --include='*.example' -E '-----BEGIN (OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----' deploy >/dev/null 2>&1; then
  die "private key material under deploy/"
fi

info "validate.sh passed (static only; not a runtime or production clearance)"
