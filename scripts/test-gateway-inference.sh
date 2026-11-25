#!/usr/bin/env bash
# Call the Team A alias on the AI Gateway with an Entra token (OpenAI v1 Chat
# Completions and Responses). The deploy script grants the signed-in user AI
# Gateway Models User on the Team A alias only. Expected: HTTP 200.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

GATEWAY_URL="$(deployment_output aiGatewayUrl)"
ALIAS_A="$(deployment_output teamAAlias)"
if [[ -z "${GATEWAY_URL}" || -z "${ALIAS_A}" ]]; then
  echo "ERROR: Missing AI Gateway outputs. Deploy first." >&2
  exit 1
fi

BASE="${GATEWAY_URL}/default/models/openai/v1"
TOKEN="$(access_token "${AI_GATEWAY_RESOURCE}")"
RESPONSE_FILE="$(mktemp)"
trap 'rm -f "${RESPONSE_FILE}"' EXIT
FAIL=0

# gpt-5 family models require max_completion_tokens (max_tokens is rejected).
expect_status "Team A alias, Chat Completions" "${BASE}/chat/completions" "${TOKEN}" \
  "{\"model\":\"${ALIAS_A}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in five words.\"}],\"max_completion_tokens\":64}" '200'
expect_status "Team A alias, Responses" "${BASE}/responses" "${TOKEN}" \
  "{\"model\":\"${ALIAS_A}\",\"input\":\"Say hello in five words.\",\"max_output_tokens\":64}" '200'

if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi
echo "PASS: Team A reached the central model through the AI Gateway."
