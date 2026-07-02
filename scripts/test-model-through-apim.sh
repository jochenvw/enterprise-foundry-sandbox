#!/usr/bin/env bash
# Call the Team A and Team B APIM routes with a minimal chat/completions payload,
# each using its OWN subscription key. Then prove cross-team isolation: Team A's
# key must FAIL against the Team B route and vice versa.
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
  local sub="$1"
  az rest --method post \
    --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${HUB_RG}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/${sub}/listSecrets?api-version=2024-06-01-preview" \
    --query primaryKey -o tsv 2>/dev/null || true
}

KEY_A="$(get_key sub-team-a)"
KEY_B="$(get_key sub-team-b)"

# gpt-5 family models require max_completion_tokens (max_tokens is rejected).
PAYLOAD='{"messages":[{"role":"user","content":"Say hello in five words."}],"max_completion_tokens":32}'

# The gateway now exposes the standard Azure OpenAI surface and accepts the APIM
# subscription key via the `api-key` header (so Foundry connections work too).
DEPLOYMENT="${CENTRAL_DEPLOYMENT:-enterprise-gpt5-mini}"
API_VERSION='2024-10-21'

call() {
  local label="$1" url="$2" key="$3"
  echo "==> ${label}: POST ${url}"
  local code
  code="$(curl -s -o /tmp/resp.json -w '%{http_code}' \
    -H "api-key: ${key}" \
    -H 'Content-Type: application/json' \
    -d "${PAYLOAD}" "${url}" || true)"
  echo "    HTTP ${code}"
  head -c 300 /tmp/resp.json 2>/dev/null || true
  echo
}

A_FAST="${GATEWAY_URL}/ai/team-a/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=${API_VERSION}"
B_FAST="${GATEWAY_URL}/ai/team-b/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=${API_VERSION}"

echo "### Expected to SUCCEED (own key, own route)"
call "Team A -> Team A (chat)" "${A_FAST}" "${KEY_A}"
call "Team B -> Team B (chat)" "${B_FAST}" "${KEY_B}"

echo "### Model enumeration through the gateway (what Foundry calls)"
echo "==> Team A: GET /openai/deployments"
curl -s -H "api-key: ${KEY_A}" "${GATEWAY_URL}/ai/team-a/openai/deployments?api-version=${API_VERSION}" | head -c 400
echo

echo "### Expected to FAIL (cross-team key) - team isolation"
call "Team A key -> Team B route"   "${B_FAST}"   "${KEY_A}"
call "Team B key -> Team A route"   "${A_FAST}"   "${KEY_B}"

echo "Done. 2xx for own-route calls; 401 for cross-team calls indicates isolation works."
echo "If public access is disabled, run this from inside the hub VNet."
