// =============================================================================
// AI Gateway telemetry: an OpenTelemetry exporter on the gateway's default
// workspace that sends metrics, logs, and traces to an Application Insights
// component with OTLP ingestion on. This is what the gateway portal's
// "Configure telemetry" wizard creates; see
// https://azure.github.io/aigateway/labs/13-monitoring/
//
// Deployed by scripts/postdeploy-gateway-telemetry.sh, not by main.bicep:
// the OTLP endpoints exist only minutes after ingestion is turned on, and the
// Monitoring Metrics Publisher grant on the managed data collection rule is
// blocked for deployments by a deny assignment.
// =============================================================================

@description('Existing AI Gateway name in this resource group.')
param gatewayName string

@description('OTLP metrics endpoint of the Application Insights component.')
param metricsEndpoint string

@description('OTLP logs endpoint of the Application Insights component.')
param logsEndpoint string

@description('OTLP traces endpoint of the Application Insights component.')
param tracesEndpoint string

@description('Log prompt and response payloads. Off: payloads can be sensitive and add volume.')
param payloadCapture bool = false

// The portal's "Include recommended token claims": tenant, caller object ID,
// and calling app, so usage can be attributed to each team identity.
var claimAttributes = [
  { source: { kind: 'claims', value: 'tid' }, signals: ['logs', 'traces', 'metrics'] }
  { source: { kind: 'claims', value: 'oid' }, signals: ['logs', 'traces', 'metrics'] }
  { source: { kind: 'claims', value: 'appid' }, signals: ['logs', 'traces'] }
  { source: { kind: 'claims', value: 'azp' }, signals: ['logs', 'traces'] }
]

#disable-next-line BCP081
resource gateway 'Microsoft.ApiManagement/aigateways@2026-11-01' existing = {
  name: gatewayName
}

#disable-next-line BCP081
resource defaultWorkspace 'Microsoft.ApiManagement/aigateways/workspaces@2026-11-01' existing = {
  parent: gateway
  name: 'default'
}

#disable-next-line BCP081
resource exporter 'Microsoft.ApiManagement/aigateways/workspaces/telemetryExporters@2026-11-01' = {
  parent: defaultWorkspace
  name: 'appinsights'
  properties: {
    telemetryExporterType: 'OpenTelemetry'
    payloadCapture: payloadCapture
    openTelemetry: {
      metricsEndpoint: { url: metricsEndpoint }
      logsEndpoint: { url: logsEndpoint }
      tracesEndpoint: { url: tracesEndpoint }
    }
    authentication: {
      managedIdentity: {
        resource: 'https://monitor.azure.com'
      }
    }
    telemetry: {
      attributes: claimAttributes
    }
  }
}

output exporterId string = exporter.id
