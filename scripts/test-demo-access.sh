#!/usr/bin/env bash
# Verify this machine can reach every Foundry account and its connected data
# resources (Storage, Cosmos DB, AI Search, Key Vault) over the public endpoint,
# which is what the Foundry portal needs for a live demo. Fails on network
# denials (firewall / IP rules / public access disabled), not on RBAC denials:
# an authorization error proves the request passed the network layer.
#   DEMO_ACCESS_ATTEMPTS  re-probe blocked endpoints (rule propagation), default 1
#   DEMO_ACCESS_DELAY     seconds between attempts, default 30
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

ATTEMPTS="${DEMO_ACCESS_ATTEMPTS:-1}"
DELAY="${DEMO_ACCESS_DELAY:-30}"
NETWORK_DENIAL='Virtual Network/Firewall|ForbiddenByFirewall|firewall settings|AuthorizationFailure|not allowed by applicable rules|Public access is not permitted|public network access is disabled|PublicNetworkAccessDisabled|IpAuthorizationError'

MODE="$(deployment_output networkAccessMode)"
if [[ "${MODE}" == "privateOnly" ]]; then
  echo "SKIP: networkAccessMode=privateOnly. Demo the portal from inside the VNet (test VM / VPN)."
  exit 0
fi

CENTRAL="$(deployment_output centralFoundryName)"
CENTRAL_PROJECT="$(deployment_output centralProjectName)"
TEAM_A="$(deployment_output teamAFoundryName)"
TEAM_B="$(deployment_output teamBFoundryName)"
TEAM_A_PROJECT="$(deployment_output teamAProjectName)"
TEAM_B_PROJECT="$(deployment_output teamBProjectName)"
if [[ -z "${CENTRAL}" || -z "${TEAM_A}" || -z "${TEAM_B}" ]]; then
  echo "ERROR: Missing Foundry outputs. Deploy first." >&2
  exit 1
fi

# label|token audience|URL|extra header
TARGETS=()
add_foundry() {
  local account="$1" project="$2"
  TARGETS+=("${account} (OpenAI endpoint)|https://cognitiveservices.azure.com|https://${account}.openai.azure.com/openai/deployments?api-version=2023-05-15|")
  TARGETS+=("${account}/${project} (project endpoint)|${FOUNDRY_DATA_RESOURCE}|https://${account}.services.ai.azure.com/api/projects/${project}/connections?api-version=v1|")
}
add_foundry "${CENTRAL}" "${CENTRAL_PROJECT:-proj-central}"
add_foundry "${TEAM_A}" "${TEAM_A_PROJECT}"
add_foundry "${TEAM_B}" "${TEAM_B_PROJECT}"

# Fail closed: a listing error or a missing always-deployed data resource must
# not silently shrink the set of endpoints checked. Key Vault is optional.
for team in teamA teamB; do
  rg="$(deployment_output "${team}ResourceGroup")"
  if [[ -z "${rg}" ]]; then
    echo "ERROR: Missing ${team}ResourceGroup output. Deploy first." >&2
    exit 1
  fi
  if ! RESOURCES="$(az resource list -g "${rg}" --query "[].[name,type]" -o tsv --only-show-errors)"; then
    echo "ERROR: Cannot list resources in ${rg}; connected data resources were not checked." >&2
    exit 1
  fi
  found_storage=0; found_cosmos=0; found_search=0
  while IFS=$'\t' read -r name type; do
    name="${name%$'\r'}"; type="${type%$'\r'}"
    case "${type}" in
      Microsoft.Storage/storageAccounts)
        found_storage=1
        TARGETS+=("${name} (Storage)|https://storage.azure.com|https://${name}.blob.core.windows.net/?comp=list|x-ms-version: 2023-11-03") ;;
      Microsoft.DocumentDB/databaseAccounts)
        found_cosmos=1
        TARGETS+=("${name} (Cosmos DB)|https://${name}.documents.azure.com|https://${name}.documents.azure.com/dbs|x-ms-version: 2018-12-31") ;;
      Microsoft.Search/searchServices)
        found_search=1
        TARGETS+=("${name} (AI Search)|https://search.azure.com|https://${name}.search.windows.net/indexes?api-version=2024-07-01|") ;;
      Microsoft.KeyVault/vaults)
        TARGETS+=("${name} (Key Vault)|https://vault.azure.net|https://${name}.vault.azure.net/secrets?api-version=7.4|") ;;
    esac
  done <<< "${RESOURCES}"
  missing=()
  (( found_storage )) || missing+=("Storage")
  (( found_cosmos )) || missing+=("Cosmos DB")
  (( found_search )) || missing+=("AI Search")
  if (( ${#missing[@]} )); then
    echo "ERROR: ${rg} is missing expected connected resource(s): ${missing[*]}." >&2
    exit 1
  fi
done

declare -A TOKENS=()
RESPONSE_FILE="$(mktemp)"
trap 'rm -f "${RESPONSE_FILE}"' EXIT

# probe TARGET -> 0 reachable, 1 network-blocked. Prints a status line.
probe() {
  local label audience url header code observed auth
  IFS='|' read -r label audience url header <<< "$1"
  if [[ -z "${TOKENS[${audience}]:-}" ]]; then
    TOKENS[${audience}]="$(access_token "${audience}" 2>/dev/null || true)"
  fi
  auth="Bearer ${TOKENS[${audience}]}"
  if [[ "${url}" == *documents.azure.com* ]]; then
    auth="type%3Daad%26ver%3D1.0%26sig%3D${TOKENS[${audience}]}"
    header="${header}"$'\n'"x-ms-date: $(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')"
  fi
  local args=(-sS --max-time 30 -o "${RESPONSE_FILE}" -w '%{http_code}' -H "Authorization: ${auth}")
  while IFS= read -r h; do [[ -n "${h}" ]] && args+=(-H "${h}"); done <<< "${header}"
  code="$(curl "${args[@]}" "${url}" 2>/dev/null || true)"
  if [[ "${code}" == "000" ]] || grep -qiE "${NETWORK_DENIAL}" "${RESPONSE_FILE}" 2>/dev/null; then
    observed="$(grep -oE 'originated from IP [0-9.]+|Client address: [0-9.]+' "${RESPONSE_FILE}" 2>/dev/null | grep -oE '[0-9.]+$' | head -1 || true)"
    echo "    BLOCKED  ${label}: HTTP ${code}${observed:+ (Azure saw ${observed})}"
    return 1
  fi
  echo "    OK       ${label}: HTTP ${code} (network allowed)"
}

echo "### Demo access from this machine (networkAccessMode=${MODE:-unknown})"
echo "    Allowlisted: $(deployment_output allowedClientIpRanges | tr -d '\r\n ')"
PENDING=("${TARGETS[@]}")
for ((attempt = 1; ; attempt++)); do
  BLOCKED=()
  for target in "${PENDING[@]}"; do
    probe "${target}" || BLOCKED+=("${target}")
  done
  [[ ${#BLOCKED[@]} -eq 0 ]] && break
  if (( attempt >= ATTEMPTS )); then
    echo "FAIL: ${#BLOCKED[@]} endpoint(s) block this network; the Foundry portal will show" >&2
    echo "      'protected by network access controls'. Run scripts/allow-demo-access.sh" >&2
    echo "      (adds this network's egress ranges in place) or redeploy with scripts/deploy.sh." >&2
    exit 1
  fi
  echo "    ${#BLOCKED[@]} blocked; rules may still be propagating. Retrying in ${DELAY}s (${attempt}/${ATTEMPTS})"
  sleep "${DELAY}"
  PENDING=("${BLOCKED[@]}")
done
echo "PASS: all Foundry accounts and connected data resources are reachable for the demo."
