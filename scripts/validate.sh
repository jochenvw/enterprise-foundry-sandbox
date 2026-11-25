#!/usr/bin/env bash
# Validate the Bicep template: build + subscription-scope validation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

echo "==> az bicep version"
az bicep version

echo "==> az bicep build"
az bicep build --file "${TEMPLATE_FILE}" --stdout >/dev/null

if [[ "${1:-}" == "--local" ]]; then
  echo "Local validation complete."
  exit 0
fi

require_login
echo "==> az deployment sub validate"
az deployment sub validate \
  --location "${LOCATION}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters "${PARAMETERS_FILE}"

echo "Validation complete."
