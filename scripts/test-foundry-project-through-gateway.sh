#!/usr/bin/env bash
# Call the Team A Foundry project with the gateway-connected model
# (<connection>/<alias>). Foundry forwards the call to the AI Gateway with the
# project's managed identity, which holds AI Gateway Models User on the Team A
# alias only. Expected: HTTP 200.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

PROJECT_ENDPOINT="$(deployment_output teamAProjectEndpoint)"
MODEL="$(deployment_output teamAFoundryModel)"
if [[ -z "${PROJECT_ENDPOINT}" || -z "${MODEL}" ]]; then
  echo "ERROR: Missing Team A project outputs. Deploy first." >&2
  exit 1
fi

TOKEN="$(access_token "${FOUNDRY_DATA_RESOURCE}")"
RESPONSE_FILE="$(mktemp)"
trap 'rm -f "${RESPONSE_FILE}"' EXIT
FAIL=0

expect_status "Team A project -> ${MODEL} (Responses)" "${PROJECT_ENDPOINT}/openai/v1/responses" "${TOKEN}" \
  "{\"model\":\"${MODEL}\",\"input\":\"Say hello in five words.\",\"max_output_tokens\":64}" '200'

if [[ "${FAIL}" -ne 0 ]]; then
  echo "If the project is reachable only privately, run from inside the Team A VNet." >&2
  exit 1
fi
echo "PASS: Team A project reached the central model through its gateway connection."
