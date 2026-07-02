#!/usr/bin/env bash
# Validate the Bicep template: build + subscription-scope validation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

echo "==> az bicep version"
az bicep version

echo "==> az bicep build"
az bicep build --file "${TEMPLATE_FILE}"

echo "==> az deployment sub validate"
az deployment sub validate \
  --location "${LOCATION}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters "${PARAMETERS_FILE}"

echo "Validation complete."
