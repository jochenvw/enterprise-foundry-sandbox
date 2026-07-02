#!/usr/bin/env bash
# Delete the four resource groups created by this deployment. Destructive.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

RGS=()
for out in observabilityResourceGroup hubResourceGroup teamAResourceGroup teamBResourceGroup; do
  rg="$(deployment_output "${out}")"
  [[ -n "${rg}" ]] && RGS+=("${rg}")
done

if [[ "${#RGS[@]}" -eq 0 ]]; then
  echo "No resource groups resolved from deployment outputs. Nothing to do."
  exit 0
fi

echo "About to DELETE these resource groups:"
printf '  - %s\n' "${RGS[@]}"
read -r -p "Type 'yes' to confirm: " CONFIRM
[[ "${CONFIRM}" == "yes" ]] || { echo "Aborted."; exit 1; }

for rg in "${RGS[@]}"; do
  echo "==> Deleting ${rg}"
  az group delete --name "${rg}" --yes --no-wait
done

echo "Deletion started (--no-wait). Key Vaults are soft-deleted; purge separately if needed."
