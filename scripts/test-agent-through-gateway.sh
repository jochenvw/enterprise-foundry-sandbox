#!/usr/bin/env bash
# Team A demo agent: a prompt agent in the Team A (spoke) project whose model is
# the hub's central model, reached through the team's AI Gateway connection
# (<connection>/<team alias>). Creates the agent if it is missing or points at
# another model, runs one turn, and leaves the agent in place so it shows in the
# Foundry portal (Agents and Tracing).
#
# The run carries a W3C traceparent. Its trace ID is printed so the run can be
# found in Team A's Application Insights (agent spans) and in the platform
# Application Insights (AI Gateway spans).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

AGENT_NAME="${AGENT_NAME:-team-a-demo-agent}"
PROJECT_ENDPOINT="$(deployment_output teamAProjectEndpoint)"
MODEL="$(deployment_output teamAFoundryModel)"
if [[ -z "${PROJECT_ENDPOINT}" || -z "${MODEL}" ]]; then
  echo "ERROR: missing deployment outputs; run scripts/deploy.sh first." >&2
  exit 1
fi
RESPONSE_FILE="$(mktemp)"
trap 'rm -f "${RESPONSE_FILE}"' EXIT
TOKEN="$(access_token "${FOUNDRY_DATA_RESOURCE}" | tr -d '\r')"

current_model="$(curl -sS --max-time 60 -H "Authorization: Bearer ${TOKEN}" \
  "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}?api-version=v1" \
  | python -c 'import json,sys
try: print(json.load(sys.stdin)["versions"]["latest"]["definition"]["model"])
except Exception: print("")' | tr -d '\r')"

if [[ "${current_model}" == "${MODEL}" ]]; then
  echo "==> Agent ${AGENT_NAME} exists and uses ${MODEL}"
else
  payload="$(python -c 'import json,sys
print(json.dumps({"description": "Team A demo agent: hub model through Azure AI Gateway.",
  "definition": {"kind": "prompt", "model": sys.argv[1],
    "instructions": "You are the Team A demo agent. Answer in one or two short sentences."}}))' "${MODEL}")"
  code="$(post_json "${PROJECT_ENDPOINT}/agents/${AGENT_NAME}/versions?api-version=v1" "${TOKEN}" "${payload}")"
  if [[ "${code}" != 2* ]]; then
    echo "FAIL: creating agent ${AGENT_NAME}: HTTP ${code}" >&2
    head -c 400 "${RESPONSE_FILE}" >&2; echo >&2
    exit 1
  fi
  echo "==> Created agent ${AGENT_NAME} with model ${MODEL}"
fi

TRACE_ID="$(python -c 'import secrets; print(secrets.token_hex(16))')"
TRACEPARENT="00-${TRACE_ID}-$(python -c 'import secrets; print(secrets.token_hex(8))')-01"
payload="$(python -c 'import json,sys
print(json.dumps({"agent_reference": {"type": "agent_reference", "name": sys.argv[1]},
  "input": "In one sentence: what does an AI gateway add between an agent and a model?"}))' "${AGENT_NAME}")"

attempt=1
while true; do
  code="$(curl -sS --max-time 180 -o "${RESPONSE_FILE}" -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -H "traceparent: ${TRACEPARENT}" -d "${payload}" \
    "${PROJECT_ENDPOINT}/openai/v1/responses" || true)"
  if [[ "${code}" =~ ^(401|403|429)$ && "${attempt}" -lt "${RETRY_ATTEMPTS}" ]]; then
    echo "    HTTP ${code}, retrying in ${RETRY_DELAY}s (${attempt}/${RETRY_ATTEMPTS})"
    attempt=$((attempt + 1)); sleep "${RETRY_DELAY}"; continue
  fi
  break
done
echo "==> Run ${AGENT_NAME}: HTTP ${code}"
if [[ "${code}" != "200" ]]; then
  echo "FAIL: the agent run did not succeed." >&2
  head -c 600 "${RESPONSE_FILE}" >&2; echo >&2
  exit 1
fi
answer="$(python -c 'import json,sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
print(" ".join(c.get("text", "") for o in r.get("output", []) if o.get("type") == "message"
               for c in o.get("content", [])).strip(), "|", r.get("status"))' "${RESPONSE_FILE}")"
echo "    Agent: ${answer}"
echo "    Trace ID: ${TRACE_ID}"
if [[ "${answer}" != *"| completed" || "${answer}" == "| completed" ]]; then
  echo "FAIL: the run did not complete with a message." >&2
  exit 1
fi
echo "PASS: Team A agent answered with the hub model through the AI Gateway."
