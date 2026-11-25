#!/usr/bin/env bash
# Prove team isolation and model governance at the AI Gateway. The caller holds
# AI Gateway Models User on the Team A alias only, so:
#   Team B alias           => expected 401/403
#   unpublished model name => expected 4xx (not routed to any backend)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

GATEWAY_URL="$(deployment_output aiGatewayUrl)"
ALIAS_B="$(deployment_output teamBAlias)"
DEPLOYMENT="$(deployment_output centralModelDeployment)"
if [[ -z "${GATEWAY_URL}" || -z "${ALIAS_B}" ]]; then
  echo "ERROR: Missing AI Gateway outputs. Deploy first." >&2
  exit 1
fi

URL="${GATEWAY_URL}/default/models/openai/v1/chat/completions"
TOKEN="$(access_token "${AI_GATEWAY_RESOURCE}")"
RESPONSE_FILE="$(mktemp)"
trap 'rm -f "${RESPONSE_FILE}"' EXIT
FAIL=0
payload() {
  echo "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"max_completion_tokens\":16}"
}

echo "### Cross-team isolation and governance (expected denials)"
expect_status "Team A identity -> Team B alias" "${URL}" "${TOKEN}" "$(payload "${ALIAS_B}")" '401|403'
expect_status "Raw central deployment name (not an alias)" "${URL}" "${TOKEN}" "$(payload "${DEPLOYMENT:-enterprise-gpt5-mini}")" '400|401|403|404'
expect_status "Unpublished model" "${URL}" "${TOKEN}" "$(payload unapproved-model)" '400|401|403|404'

if [[ "${FAIL}" -ne 0 ]]; then
  echo "FAIL: isolation or governance not enforced." >&2
  exit 1
fi
echo "PASS: team isolation and model governance enforced at the gateway."
