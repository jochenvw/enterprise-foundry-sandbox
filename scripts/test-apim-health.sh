#!/usr/bin/env bash
# Lightweight APIM gateway health check. When public access is disabled this
# must be run from inside the network (see test-dns.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

GATEWAY_URL="$(deployment_output apimGatewayUrl)"
if [[ -z "${GATEWAY_URL}" ]]; then
  echo "ERROR: Could not resolve gateway URL from deployment outputs." >&2
  exit 1
fi

echo "==> APIM gateway: ${GATEWAY_URL}"
echo "==> Probing ${GATEWAY_URL}/status-0123456789abcdef (built-in health endpoint)"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
  "${GATEWAY_URL}/status-0123456789abcdef" || true)"
echo "HTTP ${HTTP_CODE}"

if [[ "${HTTP_CODE}" == "200" ]]; then
  echo "OK: gateway reachable."
else
  echo "Gateway returned ${HTTP_CODE}. If public access is disabled, run this"
  echo "from inside the hub VNet. A non-200 may also mean the probe path differs."
fi
