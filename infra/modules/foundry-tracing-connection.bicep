// =============================================================================
// Foundry tracing: an account-level Application Insights connection, shared
// with every project. Agent runs then export OpenTelemetry traces to it and
// show up under the project's Tracing page in the Foundry portal.
// =============================================================================

@description('Foundry account name.')
param foundryAccountName string

@description('Application Insights component resource ID.')
param appInsightsId string

@description('Application Insights connection string (ingestion only; it cannot read data).')
@secure()
param appInsightsConnectionString string

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: foundryAccountName
}

resource connection 'Microsoft.CognitiveServices/accounts/connections@2026-09-01' = {
  parent: account
  name: '${foundryAccountName}-appinsights'
  properties: {
    category: 'AppInsights'
    target: appInsightsId
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: {
      key: appInsightsConnectionString
    }
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsightsId
    }
  }
}

output connectionName string = connection.name
