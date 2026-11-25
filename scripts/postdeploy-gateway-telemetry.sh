#!/usr/bin/env bash
# Connect the AI Gateway to the platform Application Insights over OpenTelemetry,
# in the order Azure needs (same steps as the gateway portal's "Configure telemetry"):
#   1. Wait until the component reports its OTLP endpoints and data collection
#      rule (DCR). Azure creates them minutes after OTLP ingestion turns on.
#   2. Grant the gateway identity Monitoring Metrics Publisher on the DCR. Bicep
#      cannot: the DCR sits in a managed resource group with a deny assignment.
#   3. Deploy infra/modules/ai-gateway-telemetry.bicep, retrying while the role
#      assignment propagates.
# Idempotent; deploy.sh runs it after every deployment.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login
# Git Bash would rewrite /subscriptions/... resource IDs into Windows paths.
export MSYS_NO_PATHCONV=1
TEMPLATE="${REPO_ROOT}/infra/modules/ai-gateway-telemetry.bicep"
command -v cygpath >/dev/null 2>&1 && TEMPLATE="$(cygpath -w "${TEMPLATE}")"
GATEWAY_RG="$(deployment_output aiGatewayResourceGroup)"
GATEWAY_NAME="$(deployment_output aiGatewayName)"
GATEWAY_ID="$(deployment_output aiGatewayId)"
APPI_ID="$(deployment_output platformAppInsightsId)"
if [[ -z "${GATEWAY_NAME}" || -z "${APPI_ID}" ]]; then
  echo "ERROR: missing deployment outputs; run scripts/deploy.sh first." >&2
  exit 1
fi

if [[ "$(az provider show -n Microsoft.Monitor --query registrationState -o tsv | tr -d '\r')" != "Registered" ]]; then
  echo "==> Registering Microsoft.Monitor (managed Azure Monitor workspace behind OTLP ingestion)"
  az provider register -n Microsoft.Monitor --wait
fi

echo "==> Waiting for the OTLP endpoints of ${APPI_ID##*/}"
READY="(properties.OTLPMetricsEndpoint && properties.OTLPLogsEndpoint && properties.OTLPTracesEndpoint)"
DCR_ID=""
for attempt in $(seq 1 60); do
  DCR_ID="$(az resource show --ids "${APPI_ID}" --api-version 2020-02-02 \
    --query "${READY} && properties.DataCollectionRuleResourceId || ''" -o tsv 2>/dev/null | tr -d '\r' || true)"
  [[ -n "${DCR_ID}" ]] && break
  if [[ "${attempt}" -eq 60 ]]; then
    echo "ERROR: ${APPI_ID##*/} has no OTLP endpoints after 10 minutes." >&2
    exit 1
  fi
  sleep 10
done
mapfile -t OTLP_URLS < <(az resource show --ids "${APPI_ID}" --api-version 2020-02-02 \
  --query "[properties.OTLPMetricsEndpoint, properties.OTLPLogsEndpoint, properties.OTLPTracesEndpoint]" -o tsv | tr -d '\r')
METRICS_URL="${OTLP_URLS[0]}"; LOGS_URL="${OTLP_URLS[1]}"; TRACES_URL="${OTLP_URLS[2]}"
echo "    DCR: ${DCR_ID##*/}"

PRINCIPAL_ID="$(az resource show --ids "${GATEWAY_ID}" --query identity.principalId -o tsv | tr -d '\r')"
echo "==> Granting the gateway identity Monitoring Metrics Publisher on the DCR"
az role assignment create --assignee-object-id "${PRINCIPAL_ID}" --assignee-principal-type ServicePrincipal \
  --role "Monitoring Metrics Publisher" --scope "${DCR_ID}" -o none

echo "==> Deploying the gateway OpenTelemetry exporter"
for attempt in $(seq 1 10); do
  if az deployment group create -g "${GATEWAY_RG}" -n ai-gateway-telemetry \
      --template-file "${TEMPLATE}" \
      --parameters gatewayName="${GATEWAY_NAME}" metricsEndpoint="${METRICS_URL}" \
        logsEndpoint="${LOGS_URL}" tracesEndpoint="${TRACES_URL}" -o none; then
    echo "PASS: ${GATEWAY_NAME} exports metrics, logs, and traces to ${APPI_ID##*/}."
    exit 0
  fi
  [[ "${attempt}" -lt 10 ]] || break
  echo "    The role assignment may still be propagating; retrying in 30s (${attempt}/10)."
  sleep 30
done
echo "ERROR: telemetry exporter deployment failed; rerun this script in a few minutes." >&2
exit 1
