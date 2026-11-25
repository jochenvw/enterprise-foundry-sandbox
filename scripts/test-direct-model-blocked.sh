#!/usr/bin/env bash
# Demonstrate that teams CANNOT call the central Foundry model endpoint directly.
# Teams are not granted data-plane roles on the central account, and (depending
# on networkAccessMode) the endpoint is not publicly reachable.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

CENTRAL="$(deployment_output centralFoundryName)"
DEPLOYMENT="$(deployment_output centralModelDeployment)"
if [[ -z "${CENTRAL}" ]]; then
  echo "ERROR: Missing central Foundry output. Deploy first." >&2
  exit 1
fi

ENDPOINT="https://${CENTRAL}.openai.azure.com/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=${INFERENCE_API_VERSION}"
PAYLOAD='{"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":8}'

echo "==> Attempting DIRECT call to central model (should be blocked): ${ENDPOINT}"

# Use the caller's AAD token; a team identity would have no role on the central
# account, yielding 401/403. With private networking, a public caller gets a
# connectivity failure instead.
TOKEN="$(az account get-access-token --resource https://cognitiveservices.azure.com \
  --query accessToken -o tsv 2>/dev/null || true)"

RESPONSE_FILE="$(mktemp)"
trap 'rm -f "${RESPONSE_FILE}"' EXIT
CODE="$(curl -sS --max-time 120 -o "${RESPONSE_FILE}" -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "${PAYLOAD}" "${ENDPOINT}" || true)"

echo "HTTP ${CODE}"
head -c 300 "${RESPONSE_FILE}" 2>/dev/null || true
echo

case "${CODE}" in
  401|403)
    echo "OK: direct access denied (authorization) - teams must use the AI Gateway." ;;
  000)
    echo "OK: direct access not reachable (private networking) - expected from outside the VNet." ;;
  2*)
    echo "WARNING: direct call SUCCEEDED. This caller has a role on the central account."
    echo "         Ensure team identities are NOT granted Cognitive Services roles centrally." ;;
  *)
    echo "Received HTTP ${CODE}. Review networking/RBAC; teams should not reach this endpoint." ;;
esac
