#!/usr/bin/env bash
# Subscription-scope what-if for the full environment.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

echo "==> az deployment sub what-if"
az deployment sub what-if \
  --name "${DEPLOYMENT_NAME}" \
  --location "${LOCATION}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters "${PARAMETERS_FILE}"
