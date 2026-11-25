#!/usr/bin/env bash
# Teams must reach the central model only through the AI Gateway. Verifies:
#   1. No Team A/B identity (Foundry account or project managed identity) holds any
#      role on the central Foundry account, inherited or direct. This is the actual
#      isolation guarantee and does not depend on where the test runs from.
#   2. A DIRECT data-plane call with the caller's identity. With demo access the
#      central endpoint is network-reachable from the operator's IP, so success here
#      only means the *operator* holds a data role (e.g. Foundry User granted outside
#      this template); it is reported, not failed. 401/403/000 are fine.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

CENTRAL="$(deployment_output centralFoundryName)"
HUB_RG="$(deployment_output hubResourceGroup)"
DEPLOYMENT="$(deployment_output centralModelDeployment)"
if [[ -z "${CENTRAL}" || -z "${HUB_RG}" ]]; then
  echo "ERROR: Missing central Foundry outputs. Deploy first." >&2
  exit 1
fi
FAIL=0

echo "### Team identities must hold no role on central Foundry"
CENTRAL_ID="$(az cognitiveservices account show -g "${HUB_RG}" -n "${CENTRAL}" --query id -o tsv | tr -d '\r')"
for team in A B; do
  rg="$(deployment_output "team${team}ResourceGroup")"
  account="$(deployment_output "team${team}FoundryName")"
  project="$(deployment_output "team${team}ProjectName")"
  account_id="$(az cognitiveservices account show -g "${rg}" -n "${account}" --query id -o tsv | tr -d '\r')"
  for principal in \
    "$(az cognitiveservices account show -g "${rg}" -n "${account}" --query identity.principalId -o tsv | tr -d '\r')" \
    "$(az rest --method get --url "https://management.azure.com${account_id}/projects/${project}?api-version=${FOUNDRY_API_VERSION}" --query identity.principalId -o tsv | tr -d '\r')"; do
    [[ -z "${principal}" ]] && continue
    roles="$(az role assignment list --assignee "${principal}" --scope "${CENTRAL_ID}" --include-inherited \
      --query "[].roleDefinitionName" -o tsv 2>/dev/null | tr -d '\r' | paste -sd, - || true)"
    if [[ -n "${roles}" ]]; then
      echo "    FAIL  Team ${team} identity ${principal}: ${roles}" >&2
      FAIL=1
    else
      echo "    PASS  Team ${team} identity ${principal}: no role on ${CENTRAL}"
    fi
  done
done

ENDPOINT="https://${CENTRAL}.openai.azure.com/openai/deployments/${DEPLOYMENT}/chat/completions?api-version=${INFERENCE_API_VERSION}"
PAYLOAD='{"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":8}'
echo "==> DIRECT call to central Foundry with the caller's identity: ${ENDPOINT}"
TOKEN="$(access_token https://cognitiveservices.azure.com 2>/dev/null || true)"
RESPONSE_FILE="$(mktemp)"
trap 'rm -f "${RESPONSE_FILE}"' EXIT
CODE="$(curl -sS --max-time 120 -o "${RESPONSE_FILE}" -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d "${PAYLOAD}" "${ENDPOINT}" || true)"
echo "HTTP ${CODE}"
case "${CODE}" in
  401|403) echo "    Denied (authorization or firewall)." ;;
  000)     echo "    Not reachable (private networking)." ;;
  2*)      echo "    INFO: the operator identity holds a data role on ${CENTRAL} (not a team identity)." ;;
  *)       echo "    FAIL: unexpected HTTP ${CODE}." >&2; head -c 300 "${RESPONSE_FILE}" >&2 || true; FAIL=1 ;;
esac

if [[ "${FAIL}" -ne 0 ]]; then
  echo "FAIL: a team identity can reach central Foundry directly, bypassing the AI Gateway." >&2
  exit 1
fi
echo "PASS: no team identity can call central Foundry directly; teams must use the AI Gateway."
