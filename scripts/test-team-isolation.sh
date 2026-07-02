#!/usr/bin/env bash
# Prove team isolation at the gateway: each team's subscription key must FAIL
# against the OTHER team's route.
#   Team A key  -> Team B route  => expected 401
#   Team B key  -> Team A route  => expected 401
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

HUB_RG="$(deployment_output hubResourceGroup)"
APIM_NAME="$(deployment_output apimName)"
GATEWAY_URL="$(deployment_output apimGatewayUrl)"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

if [[ -z "${APIM_NAME}" || -z "${GATEWAY_URL}" ]]; then
  echo "ERROR: Missing APIM outputs. Deploy first." >&2
  exit 1
fi

get_key() {
  az rest --method post \
    --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${HUB_RG}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/$1/listSecrets?api-version=2024-06-01-preview" \
    --query primaryKey -o tsv 2>/dev/null || true
}

KEY_A="$(get_key sub-team-a)"
KEY_B="$(get_key sub-team-b)"

DEPLOYMENT="${CENTRAL_DEPLOYMENT:-enterprise-gpt5-mini}"
API_VERSION="${INFERENCE_API_VERSION:-2024-10-21}"
PAYLOAD='{"messages":[{"role":"user","content":"Say hello in five words."}],"max_completion_tokens":32}'

A_ROUTE="${GATEWAY_URL}/ai/team-a/deployments/${DEPLOYMENT}/chat/completions?api-version=${API_VERSION}"
B_ROUTE="${GATEWAY_URL}/ai/team-b/deployments/${DEPLOYMENT}/chat/completions?api-version=${API_VERSION}"

FAIL=0
check_blocked() {
  local label="$1" url="$2" key="$3"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "api-key: ${key}" \
    -H 'Content-Type: application/json' \
    -d "${PAYLOAD}" "${url}" || true)"
  echo "==> ${label}: HTTP ${code}"
  if [[ "${code}" == "401" || "${code}" == "403" ]]; then
    echo "    PASS: blocked as expected."
  else
    echo "    FAIL: expected 401/403, got ${code}." >&2
    FAIL=1
  fi
}

echo "### Cross-team isolation (expected 401/403)"
check_blocked "Team A key -> Team B route" "${B_ROUTE}" "${KEY_A}"
check_blocked "Team B key -> Team A route" "${A_ROUTE}" "${KEY_B}"

if [[ "${FAIL}" -eq 0 ]]; then
  echo "PASS: team isolation enforced at the gateway."
else
  echo "FAIL: isolation not enforced." >&2
  exit 1
fi
