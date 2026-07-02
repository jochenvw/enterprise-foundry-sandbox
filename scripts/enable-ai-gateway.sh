#!/usr/bin/env bash
# Enable the NATIVE Microsoft Foundry "AI Gateway" association on the central
# Foundry account, pointing at the (deployed or BYO) APIM, and auto-enroll
# projects. This is the Admin-console "AI Gateway" feature that makes the gateway
# visible in the Foundry control plane and applies per-project TPM/quota.
#
# Why a script (and not Bicep): as of this writing the account-level AI Gateway
# association is a control-plane PREVIEW feature that is primarily portal-driven
# and does not have a stable, documented ARM/Bicep resource type. The functional
# model-routing path (team projects consuming the central model THROUGH the
# gateway) is already created by the template via the project-level
# 'ApiManagement' connections (infra/modules/foundry-model-connection.bicep), so
# the deployment is fully functional without this toggle. This script adds the
# account-level governance association on top, idempotently, and falls back to
# the exact manual portal steps if the preview API is unavailable in your tenant.
# See docs/implementation-gaps.md (gap: native AI Gateway account association).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
HUB_RG="$(deployment_output hubResourceGroup)"
CENTRAL_FOUNDRY="$(deployment_output centralFoundryName)"
APIM_NAME="$(deployment_output apimName)"
APIM_RG="$(deployment_output apimResourceGroup)"
APIM_ID="$(deployment_output apimResourceId)"

# Gateway association name shown in the Foundry control plane.
GATEWAY_NAME="${GATEWAY_NAME:-central-ai-gateway}"
# Preview control-plane API version for the AI Gateway association.
API_VERSION="${AI_GATEWAY_API_VERSION:-2025-06-01}"

if [[ -z "${CENTRAL_FOUNDRY}" || -z "${APIM_ID}" ]]; then
  echo "ERROR: Could not read deployment outputs (centralFoundryName / apimResourceId)." >&2
  echo "       Run scripts/deploy.sh first." >&2
  exit 1
fi

echo "==> Central Foundry : ${CENTRAL_FOUNDRY} (rg=${HUB_RG})"
echo "==> APIM gateway     : ${APIM_NAME} (rg=${APIM_RG})"
echo "==> Association name  : ${GATEWAY_NAME}"

ACCOUNT_BASE="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${HUB_RG}/providers/Microsoft.CognitiveServices/accounts/${CENTRAL_FOUNDRY}"
GATEWAY_URI="${ACCOUNT_BASE}/aiGateways/${GATEWAY_NAME}?api-version=${API_VERSION}"

print_manual_steps() {
  cat <<EOF

------------------------------------------------------------------------------
MANUAL FALLBACK (Foundry Admin console) — the preview control-plane API for the
account-level AI Gateway association was not available via 'az rest' in this
tenant/subscription. The model-routing path already works via the templated
project connections; these steps only add the control-plane visibility +
auto-enroll governance:

  1. Open https://ai.azure.com (ensure "New Foundry" is on).
  2. Select Operate > Admin console > AI Gateway tab.
  3. Select "Add AI Gateway", choose Foundry resource '${CENTRAL_FOUNDRY}'.
  4. Choose "Use existing" and select APIM '${APIM_NAME}'.
  5. Name it '${GATEWAY_NAME}' and select Add. Wait for status = Enabled.
  6. New projects are auto-enrolled; for existing projects, open the gateway and
     choose "Add project to gateway" for each project.
------------------------------------------------------------------------------
EOF
}

# Idempotent: if the association already exists, do nothing.
if az rest --method get --uri "${GATEWAY_URI}" >/dev/null 2>&1; then
  echo "    AI Gateway association '${GATEWAY_NAME}' already exists. Nothing to do."
  exit 0
fi

echo "==> Creating AI Gateway association (preview control-plane API)"
BODY="$(cat <<EOF
{
  "properties": {
    "apiManagementResourceId": "${APIM_ID}",
    "autoEnrollProjects": true
  }
}
EOF
)"

set +e
OUT="$(az rest --method put --uri "${GATEWAY_URI}" --body "${BODY}" 2>&1)"
STATUS=$?
set -e

if [[ "${STATUS}" -eq 0 ]]; then
  echo "    AI Gateway association created. It should now appear in the Foundry control plane."
  echo "    New projects in '${CENTRAL_FOUNDRY}' are auto-enrolled."
else
  echo "    NOTE: preview API call did not succeed:" >&2
  echo "${OUT}" | sed 's/^/      /' >&2
  print_manual_steps
fi
