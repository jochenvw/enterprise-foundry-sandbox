#!/usr/bin/env bash
# Verify the central model is available in the target region BEFORE deploying.
# Fails with a clear message naming the parameter to change if it is not.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

CATALOG_FILE="$(mktemp)"
trap 'rm -f "${CATALOG_FILE}"' EXIT
az cognitiveservices model list --location "${LOCATION}" -o json > "${CATALOG_FILE}"
"${PYTHON}" "${SCRIPT_DIR}/check_model.py" "${PARAMETERS_FILE}" "${CATALOG_FILE}" "${LOCATION}"
