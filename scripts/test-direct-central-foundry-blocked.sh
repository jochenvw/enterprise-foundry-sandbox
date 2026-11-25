#!/usr/bin/env bash
# Teams must reach the central model only through the AI Gateway. Verifies:
#   1. No Team A/B identity (Foundry account or project managed identity) holds any
#      role on the central Foundry account, including inherited/group assignments.
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
if [[ -z "${CENTRAL}" || -z "${HUB_RG}" || -z "${DEPLOYMENT}" ]]; then
  echo "ERROR: Missing central Foundry outputs. Deploy first." >&2
  exit 1
fi
FAIL=0

echo "### Team identities must hold no role on central Foundry"
CENTRAL_ID="$(az cognitiveservices account show -g "${HUB_RG}" -n "${CENTRAL}" --query id -o tsv | tr -d '\r')"
if [[ -z "${CENTRAL_ID}" ]]; then
  echo "ERROR: Cannot resolve the central Foundry resource ID." >&2
  exit 1
fi
for team in A B; do
  rg="$(deployment_output "team${team}ResourceGroup")"
  account="$(deployment_output "team${team}FoundryName")"
  project="$(deployment_output "team${team}ProjectName")"
  if [[ -z "${rg}" || -z "${account}" || -z "${project}" ]]; then
    echo "ERROR: Missing Team ${team} Foundry outputs." >&2
    exit 1
  fi
  account_id="$(az cognitiveservices account show -g "${rg}" -n "${account}" --query id -o tsv | tr -d '\r')"
  if [[ -z "${account_id}" ]]; then
    echo "ERROR: Cannot resolve Team ${team} Foundry resource ID." >&2
    exit 1
  fi
  account_principal="$(az cognitiveservices account show -g "${rg}" -n "${account}" --query identity.principalId -o tsv | tr -d '\r')"
  project_principal="$(az rest --method get --url "https://management.azure.com${account_id}/projects/${project}?api-version=${FOUNDRY_API_VERSION}" --query identity.principalId -o tsv | tr -d '\r')"
  for principal in "${account_principal}" "${project_principal}"; do
    if [[ -z "${principal}" ]]; then
      echo "ERROR: Missing Team ${team} managed identity; central access was not checked." >&2
      exit 1
    fi
    # Git Bash must not rewrite an ARM scope as a local Windows path.
    if ! roles="$(MSYS_NO_PATHCONV=1 az role assignment list --assignee-object-id "${principal}" --scope "${CENTRAL_ID}" \
      --include-inherited --include-groups --fill-principal-name false \
      --query "[].id" -o tsv | tr -d '\r' | paste -sd, -)"; then
      echo "ERROR: Cannot inspect roles for Team ${team} identity ${principal}." >&2
      exit 1
    fi
    if [[ -n "${roles}" ]]; then
      echo "    FAIL  Team ${team} identity ${principal}: role assignments ${roles}" >&2
      FAIL=1
    else
      echo "    PASS  Team ${team} identity ${principal}: no role on ${CENTRAL}"
    fi
  done
done

ENDPOINT="https://${CENTRAL}.openai.azure.com/openai/v1/chat/completions"
PAYLOAD="{\"model\":\"${DEPLOYMENT}\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_completion_tokens\":8}"
echo "==> DIRECT call to central Foundry with the caller's identity: ${ENDPOINT}"
TOKEN="$(access_token https://cognitiveservices.azure.com)"
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: Cannot acquire the operator's data-plane token." >&2
  exit 1
fi
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
  echo "FAIL: central Foundry access isolation could not be verified." >&2
  exit 1
fi
echo "PASS: team account/project identities have no direct, inherited, or group role on central Foundry."
