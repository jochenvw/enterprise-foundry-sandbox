#!/usr/bin/env bash
# End-to-end trace: run the Team A demo agent with a known W3C trace ID, then
# wait until that trace ID appears in both places:
#   - Team A Application Insights: the agent spans (invoke_agent, chat), sent by
#     Foundry through the account's AppInsights connection.
#   - Platform Application Insights: the AI Gateway spans (inbound, policy
#     tokenLimit, backend, outbound), sent by the gateway's OpenTelemetry exporter.
# Ingestion takes a few minutes. TRACE_WAIT_ATTEMPTS x 30s bounds the wait.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

PLATFORM_WS_ID="$(deployment_output logAnalyticsWorkspaceId)"
TEAM_A_WS_ID="$(deployment_output teamALogAnalyticsWorkspaceId)"
workspace_guid() { MSYS_NO_PATHCONV=1 az resource show --ids "$1" --query properties.customerId -o tsv | tr -d '\r'; }
PLATFORM_WS="$(workspace_guid "${PLATFORM_WS_ID}")"
TEAM_A_WS="$(workspace_guid "${TEAM_A_WS_ID}")"

run_output="$(bash "${SCRIPT_DIR}/test-agent-through-gateway.sh")"
echo "${run_output}"
TRACE_ID="$(sed -n 's/^ *Trace ID: //p' <<<"${run_output}" | tr -d '\r')"
[[ -n "${TRACE_ID}" ]] || { echo "FAIL: no trace ID from the agent run." >&2; exit 1; }

BODY_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}"' EXIT
BODY_ARG="${BODY_FILE}"
command -v cygpath >/dev/null 2>&1 && BODY_ARG="$(cygpath -w "${BODY_FILE}")"

# count_spans WORKSPACE_GUID KQL -> prints the row count (0 on error)
count_spans() {
  python -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$2" > "${BODY_FILE}"
  az rest --method post --url "https://api.loganalytics.azure.com/v1/workspaces/$1/query" \
    --resource https://api.loganalytics.io --body "@${BODY_ARG}" \
    --query "tables[0].rows[0][0]" -o tsv 2>/dev/null | tr -d '\r' || echo 0
}

AGENT_KQL="AppDependencies | where OperationId == '${TRACE_ID}' | count"
GATEWAY_KQL="OTelSpans | where TraceId == '${TRACE_ID}' | count"
attempts="${TRACE_WAIT_ATTEMPTS:-20}"
agent=0; gateway=0
echo "==> Waiting for trace ${TRACE_ID} in Team A and platform Application Insights"
for i in $(seq 1 "${attempts}"); do
  [[ "${agent:-0}" -gt 0 ]] || agent="$(count_spans "${TEAM_A_WS}" "${AGENT_KQL}")"
  [[ "${gateway:-0}" -gt 0 ]] || gateway="$(count_spans "${PLATFORM_WS}" "${GATEWAY_KQL}")"
  [[ "${agent:-0}" -gt 0 && "${gateway:-0}" -gt 0 ]] && break
  [[ "${i}" -lt "${attempts}" ]] && { echo "    agent spans: ${agent:-0}, gateway spans: ${gateway:-0}; waiting 30s (${i}/${attempts})"; sleep 30; }
done
echo "    Team A agent spans:    ${agent:-0}"
echo "    AI Gateway spans:      ${gateway:-0}"
if [[ "${agent:-0}" -gt 0 && "${gateway:-0}" -gt 0 ]]; then
  echo "PASS: one trace ID links the Team A agent run to its AI Gateway call."
else
  echo "FAIL: trace ${TRACE_ID} did not reach both workspaces. Check the AppInsights connection and scripts/postdeploy-gateway-telemetry.sh." >&2
  exit 1
fi
