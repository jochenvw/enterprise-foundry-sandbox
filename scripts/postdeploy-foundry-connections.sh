#!/usr/bin/env bash
# Verify that each team''s Foundry project has the admin-connected model
# connection to the central Azure AI Gateway.
#
# The connection itself is now created by the Bicep template
# (infra/modules/foundry-model-connection.bicep), not by this script. A team
# project''s connection of category ''ApiManagement'' (kind AiGateway) points at the
# gateway and surfaces the team''s governed alias. This script is a read-only
# check that the templated connections exist and are shaped as expected.
# See docs/implementation-gaps.md.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TEAM_A_RG="$(deployment_output teamAResourceGroup)"
TEAM_B_RG="$(deployment_output teamBResourceGroup)"
TEAM_A_ACC="$(deployment_output teamAFoundryName)"
TEAM_B_ACC="$(deployment_output teamBFoundryName)"
TEAM_A_PROJ="$(deployment_output teamAProjectName)"
TEAM_B_PROJ="$(deployment_output teamBProjectName)"
CONN_A="$(deployment_output teamAModelConnectionName)"
CONN_B="$(deployment_output teamBModelConnectionName)"
API_VERSION="${FOUNDRY_API_VERSION}"

rc=0

verify_connection() {
  local rg="$1" account="$2" project="$3" conn="$4" team="$5"
  local base="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${rg}/providers/Microsoft.CognitiveServices/accounts/${account}/projects/${project}/connections/${conn}?api-version=${API_VERSION}"

  echo "==> ${team}: checking connection ''${conn}'' on project ''${project}''"
  local category target
  if ! category="$(az rest --method get --uri "${base}" --query "properties.category" -o tsv 2>/dev/null)"; then
    echo "    MISSING: connection not found. Re-run scripts/deploy.sh to create it." >&2
    rc=1
    return
  fi
  target="$(az rest --method get --uri "${base}" --query "properties.target" -o tsv 2>/dev/null || true)"
  echo "    found: category=${category:-?} target=${target:-?}"
  if [[ "${category}" != "ApiManagement" ]]; then
    echo "    WARNING: expected category ''ApiManagement''." >&2
    rc=1
  else
    echo "    OK"
  fi
}

verify_connection "${TEAM_A_RG}" "${TEAM_A_ACC}" "${TEAM_A_PROJ}" "${CONN_A}" "team-a"
verify_connection "${TEAM_B_RG}" "${TEAM_B_ACC}" "${TEAM_B_PROJ}" "${CONN_B}" "team-b"

if [[ "${rc}" -eq 0 ]]; then
  echo "All team model connections verified."
else
  echo "One or more connections are missing or misconfigured." >&2
fi
exit "${rc}"