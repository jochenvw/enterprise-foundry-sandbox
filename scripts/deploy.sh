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

echo "==> Detecting operator egress ranges for the data-plane allowlist"
CLIENT_IP_RANGES="$(detect_client_ip_ranges | tr -d '\r')"
if [[ "${CLIENT_IP_RANGES}" != "[]" ]]; then
  echo "    Allowlisting ${CLIENT_IP_RANGES} (mode: ${NETWORK_ACCESS_MODE})"
else
  echo "    WARNING: could not detect a public IP; deploying without an IP allowlist." >&2
  echo "    Set ALLOWED_CLIENT_IPS=<ip-or-cidr,...> to allowlist manually." >&2
fi
# Arrays go through a parameters file: inline JSON does not survive az.cmd quoting on Windows.
RANGES_PARAMS_FILE="$(mktemp)"
trap 'rm -f "${RANGES_PARAMS_FILE}"' EXIT
RANGES_PARAMS_ARG="${RANGES_PARAMS_FILE}"
# Windows az (native Python) cannot open MSYS paths such as /tmp/...
command -v cygpath >/dev/null 2>&1 && RANGES_PARAMS_ARG="$(cygpath -w "${RANGES_PARAMS_FILE}")"
cat > "${RANGES_PARAMS_FILE}" <<EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": { "allowedClientIpRanges": { "value": ${CLIENT_IP_RANGES} } }
}
EOF

# Grant the signed-in identity a test role on the Team A alias only (smoke and
# isolation tests). Set SKIP_TEST_PRINCIPAL=1 to skip.
TEST_PRINCIPAL_ID=""
TEST_PRINCIPAL_TYPE="User"
if [[ "${SKIP_TEST_PRINCIPAL:-0}" != "1" ]]; then
  if [[ "$(az account show --query user.type -o tsv)" == "servicePrincipal" ]]; then
    TEST_PRINCIPAL_TYPE="ServicePrincipal"
    TEST_PRINCIPAL_ID="$(az ad sp show --id "$(az account show --query user.name -o tsv)" --query id -o tsv 2>/dev/null || true)"
  else
    TEST_PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
  fi
  echo "==> Test principal for the Team A alias: ${TEST_PRINCIPAL_ID:-<none>}"
fi

echo "==> az deployment sub create"
az deployment sub create \
  --name "${DEPLOYMENT_NAME}" \
  --location "${LOCATION}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters "${PARAMETERS_FILE}" \
  --parameters "@${RANGES_PARAMS_ARG}" \
  --parameters networkAccessMode="${NETWORK_ACCESS_MODE}" \
    gatewayTestPrincipalId="${TEST_PRINCIPAL_ID}" gatewayTestPrincipalType="${TEST_PRINCIPAL_TYPE}"

echo
echo "Deployment complete. Key outputs:"
az deployment sub show --name "${DEPLOYMENT_NAME}" \
  --query "properties.outputs" -o jsonc || true

# Always confirm the portal can reach Foundry and its data resources from here,
# so live demos don't hit "protected by network access controls". New rules can
# take several minutes to propagate. Set SKIP_DEMO_ACCESS_CHECK=1 (e.g. in CI).
if [[ "${SKIP_DEMO_ACCESS_CHECK:-0}" != "1" ]]; then
  echo
  DEMO_ACCESS_ATTEMPTS="${DEMO_ACCESS_ATTEMPTS:-20}" bash "${SCRIPT_DIR}/test-demo-access.sh"
fi

echo
echo "Team projects are connected to their AI Gateway aliases by the template."
echo "Run scripts/postdeploy-foundry-connections.sh to VERIFY the connections, or"
echo "scripts/test-model-through-gateway.sh for an end-to-end check."
