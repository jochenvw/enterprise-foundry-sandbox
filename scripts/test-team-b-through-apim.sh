#!/usr/bin/env bash
# Call the Team B APIM route with its OWN subscription key and a minimal
# chat/completions payload. Uses the clean team route (no /openai segment):
#   POST https://<apim-host>/ai/team-b/deployments/<deployment>/chat/completions
# Expected: HTTP 200.
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

KEY_B="$(az rest --method post \
  --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${HUB_RG}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/sub-team-b/listSecrets?api-version=2024-06-01-preview" \
  --query primaryKey -o tsv 2>/dev/null || true)"

DEPLOYMENT="${CENTRAL_DEPLOYMENT:-enterprise-gpt5-mini}"
API_VERSION="${INFERENCE_API_VERSION:-2024-10-21}"
# gpt-5 family models require max_completion_tokens (max_tokens is rejected).
PAYLOAD='{"messages":[{"role":"user","content":"Say hello in five words."}],"max_completion_tokens":32}'

URL="${GATEWAY_URL}/ai/team-b/deployments/${DEPLOYMENT}/chat/completions?api-version=${API_VERSION}"

echo "==> Team B -> Team B route (chat)"
echo "    POST ${URL}"
CODE="$(curl -s -o /tmp/resp-team-b.json -w '%{http_code}' \
  -H "api-key: ${KEY_B}" \
  -H 'Content-Type: application/json' \
  -d "${PAYLOAD}" "${URL}" || true)"
echo "    HTTP ${CODE}"
head -c 400 /tmp/resp-team-b.json 2>/dev/null || true
echo

if [[ "${CODE}" == "200" ]]; then
  echo "PASS: Team B reached the central model through the gateway."
else
  echo "FAIL: expected HTTP 200, got ${CODE}." >&2
  echo "If APIM public access is disabled, run from inside the hub VNet." >&2
  exit 1
fi
