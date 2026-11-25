#!/usr/bin/env bash
# Add this network's egress ranges to the IP allowlists of every Foundry account
# and connected data resource in place (no redeploy), then verify demo access.
# Use before a live demo or after moving networks. Rules are additive; the next
# scripts/deploy.sh resets them to the ranges detected at that time.
# Overrides: ALLOWED_CLIENT_IPS, EXTRA_CLIENT_IP_RANGES, CLIENT_IP_PREFIX (see common.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

if [[ "$(deployment_output networkAccessMode)" == "privateOnly" ]]; then
  echo "networkAccessMode=privateOnly: public access is disabled by design; nothing to allow." >&2
  exit 1
fi

echo "==> Detecting this network's egress ranges (/${CLIENT_IP_PREFIX})"
RANGES_JSON="$(detect_client_ip_ranges)"
mapfile -t RANGES < <("${PYTHON}" -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])))' "${RANGES_JSON}" | tr -d '\r')
if [[ ${#RANGES[@]} -eq 0 ]]; then
  echo "ERROR: no public IPv4 egress detected. Set ALLOWED_CLIENT_IPS." >&2
  exit 1
fi
echo "    ${RANGES[*]}"

# merged EXISTING... -> existing rules plus RANGES, deduplicated/collapsed.
merged() {
  "${PYTHON}" -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])))' \
    "$("${PYTHON}" "${SCRIPT_DIR}/client_ip_ranges.py" 32 "$@" "${RANGES[@]}")" | tr -d '\r'
}

for rg in "$(deployment_output hubResourceGroup)" "$(deployment_output teamAResourceGroup)" "$(deployment_output teamBResourceGroup)"; do
  if [[ -z "${rg}" ]] || ! RESOURCES="$(az resource list -g "${rg}" --query "[].[name,type]" -o tsv --only-show-errors)"; then
    echo "ERROR: Cannot list resources in '${rg}'; deploy first or check access." >&2
    exit 1
  fi
  while IFS=$'\t' read -r name type; do
    name="${name%$'\r'}"; type="${type%$'\r'}"
    case "${type}" in
      Microsoft.CognitiveServices/accounts)
        echo "==> ${name} (Foundry)"
        for r in "${RANGES[@]}"; do
          az cognitiveservices account network-rule add -g "${rg}" -n "${name}" --ip-address "${r}" -o none --only-show-errors 2>/dev/null || true
        done ;;
      Microsoft.Storage/storageAccounts)
        echo "==> ${name} (Storage)"
        for r in "${RANGES[@]}"; do
          az storage account network-rule add -g "${rg}" -n "${name}" --ip-address "${r}" -o none --only-show-errors 2>/dev/null || true
        done ;;
      Microsoft.KeyVault/vaults)
        echo "==> ${name} (Key Vault)"
        for r in "${RANGES[@]}"; do
          az keyvault network-rule add -g "${rg}" -n "${name}" --ip-address "${r}" -o none --only-show-errors 2>/dev/null || true
        done ;;
      Microsoft.DocumentDB/databaseAccounts)
        echo "==> ${name} (Cosmos DB; update takes a few minutes)"
        mapfile -t existing < <(az cosmosdb show -g "${rg}" -n "${name}" --query "ipRules[].ipAddressOrRange" -o tsv | tr -d '\r')
        az cosmosdb update -g "${rg}" -n "${name}" --ip-range-filter "$(merged "${existing[@]}" | paste -sd, -)" -o none --only-show-errors ;;
      Microsoft.Search/searchServices)
        echo "==> ${name} (AI Search)"
        mapfile -t existing < <(az search service show -g "${rg}" -n "${name}" --query "networkRuleSet.ipRules[].value" -o tsv | tr -d '\r')
        az search service update -g "${rg}" -n "${name}" --ip-rules "$(merged "${existing[@]}" | paste -sd, -)" -o none --only-show-errors ;;
    esac
  done <<< "${RESOURCES}"
done

# Storage, Cosmos DB and Key Vault ignore IP rules while publicNetworkAccess is
# Disabled (tenant policies can force this; see exemptDataResourcesFromNetworkPolicy).
echo
DEMO_ACCESS_ATTEMPTS="${DEMO_ACCESS_ATTEMPTS:-20}" bash "${SCRIPT_DIR}/test-demo-access.sh"
