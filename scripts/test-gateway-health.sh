#!/usr/bin/env bash
# Lightweight AI Gateway reachability check: an unauthenticated call must reach
# the gateway and be rejected (401/403), which proves both reachability and
# that auth is enforced. A real alias is required: the gateway resolves the
# model alias before authenticating and returns 404 for unknown aliases.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

GATEWAY_URL="$(deployment_output aiGatewayUrl)"
ALIAS="$(deployment_output teamAAlias)"
if [[ -z "${GATEWAY_URL}" || -z "${ALIAS}" ]]; then
  echo "ERROR: Could not resolve aiGatewayUrl/teamAAlias from deployment outputs." >&2
  exit 1
fi

URL="${GATEWAY_URL}/default/models/openai/v1/chat/completions"
echo "==> AI Gateway: ${GATEWAY_URL}"
CODE="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' -d "{\"model\":\"${ALIAS}\",\"messages\":[]}" "${URL}" || true)"
echo "HTTP ${CODE}"

case "${CODE}" in
  401|403) echo "PASS: gateway reachable and requires authentication." ;;
  000) echo "FAIL: gateway not reachable from here." >&2; exit 1 ;;
  *) echo "FAIL: unauthenticated call returned ${CODE}." >&2; exit 1 ;;
esac
