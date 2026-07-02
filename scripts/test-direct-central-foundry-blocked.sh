#!/usr/bin/env bash
# Attempt a DIRECT call to the Central Foundry data plane (bypassing APIM) using
# the caller's identity. Teams are not granted data-plane roles on the central
# account and (depending on networkAccessMode) the endpoint is not publicly
# reachable. Expected: 401/403 (authorization) or 000 (private networking).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

CENTRAL="$(deployment_output centralFoundryName)"
DEPLOYMENT="$(deployment_output centralModelDeployment)"
API_VERSION="${INFERENCE_API_VERSION:-2024-10-21}"
if [[ -z "${CENTRAL}" ]]; then
  echo "ERROR: Missing central Foundry output. Deploy first." >&2
  exit 1
fi

ENDPOINT="https://${CENTRAL}.openai.azure.com/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=${API_VERSION}"
PAYLOAD='{"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":8}'

echo "==> Attempting DIRECT call to central Foundry (should be blocked): ${ENDPOINT}"

# A team identity would have no data-plane role on the central account, yielding
# 401/403. With private networking, a public caller gets a connectivity failure.
TOKEN="$(az account get-access-token --resource https://cognitiveservices.azure.com \
  --query accessToken -o tsv 2>/dev/null || true)"

CODE="$(curl -s -o /tmp/direct-central.json -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "${PAYLOAD}" "${ENDPOINT}" || echo "000")"

echo "HTTP ${CODE}"
head -c 300 /tmp/direct-central.json 2>/dev/null || true
echo

case "${CODE}" in
  401|403)
    echo "PASS: direct access denied (authorization) - teams must use the APIM route." ;;
  000)
    echo "PASS: direct access not reachable (private networking) - expected from outside the VNet." ;;
  2*)
    echo "FAIL: direct call SUCCEEDED. This caller has a data-plane role on the central account." >&2
    echo "      Ensure team identities are NOT granted Cognitive Services roles centrally." >&2
    exit 1 ;;
  *)
    echo "Received HTTP ${CODE}. Review networking/RBAC; teams should not reach this endpoint." >&2
    exit 1 ;;
esac
