#!/usr/bin/env bash
# Verify the central model is available in the target region BEFORE deploying.
# Fails with a clear message naming the parameter to change if it is not.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

# Read desired model from the parameters file.
MODEL_NAME="$(az deployment sub validate --location "${LOCATION}" \
  --template-file "${TEMPLATE_FILE}" --parameters "${PARAMETERS_FILE}" \
  --query "properties.parameters.centralModelName.value" -o tsv 2>/dev/null || true)"
MODEL_NAME="${MODEL_NAME:-gpt-5-mini}"

echo "==> Looking for model '${MODEL_NAME}' in ${LOCATION}"

# List OpenAI/AIServices models available in the region.
AVAILABLE="$(az cognitiveservices model list \
  --location "${LOCATION}" \
  --query "[?kind=='OpenAI' || kind=='AIServices'].model.name" \
  -o tsv 2>/dev/null || true)"

if echo "${AVAILABLE}" | grep -qx "${MODEL_NAME}"; then
  echo "OK: '${MODEL_NAME}' is available in ${LOCATION}."
  exit 0
fi

cat >&2 <<EOF
ERROR: Model '${MODEL_NAME}' is NOT available in ${LOCATION}.

  Change the 'centralModelName' (and optionally 'centralModelVersion')
  parameter in infra/main.parameters.dev.json to an available model, e.g.:

$(echo "${AVAILABLE}" | sort -u | sed 's/^/    - /' | head -n 30)

Then re-run the deployment.
EOF
exit 1
