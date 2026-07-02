#!/usr/bin/env bash
# Deploy the full environment at subscription scope.
# Checks central model availability first (override with SKIP_MODEL_CHECK=1).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

if [[ "${SKIP_MODEL_CHECK:-0}" != "1" ]]; then
  echo "==> Checking central model availability in ${LOCATION}"
  "${SCRIPT_DIR}/check-model-availability.sh"
fi

echo "==> Detecting operator public IP for the data-plane allowlist"
CLIENT_IP="$(detect_client_ip)"
if [[ -n "${CLIENT_IP}" ]]; then
  echo "    Allowlisting ${CLIENT_IP} (mode: ${NETWORK_ACCESS_MODE})"
else
  echo "    WARNING: could not detect a public IP; deploying without an IP allowlist." >&2
  echo "    Set ALLOWED_CLIENT_IP=<your.ip> to allowlist manually." >&2
fi

echo "==> az deployment sub create"
az deployment sub create \
  --name "${DEPLOYMENT_NAME}" \
  --location "${LOCATION}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters "${PARAMETERS_FILE}" \
  --parameters networkAccessMode="${NETWORK_ACCESS_MODE}" allowedClientIp="${CLIENT_IP}"

echo
echo "Deployment complete. Key outputs:"
az deployment sub show --name "${DEPLOYMENT_NAME}" \
  --query "properties.outputs" -o jsonc || true

echo
echo "Team projects are wired to the central APIM-backed model connection by the"
echo "template itself. Run scripts/postdeploy-foundry-connections.sh to VERIFY the"
echo "connections, or scripts/test-model-through-apim.sh for an end-to-end check."
echo
echo "To add the account-level native AI Gateway association (control-plane"
echo "visibility + auto-enroll projects), run scripts/enable-ai-gateway.sh."
