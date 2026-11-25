// =============================================================================
// Observability: Log Analytics Workspace + Application Insights
// =============================================================================

@description('Azure region.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('Log Analytics workspace name.')
param logAnalyticsName string

@description('Application Insights component name.')
param appInsightsName string

@description('Log Analytics retention in days.')
@minValue(30)
param retentionInDays int = 30

@description('Turn on OTLP ingestion so OpenTelemetry senders such as AI Gateway can export here. Azure then creates a managed Azure Monitor workspace, data collection endpoint, and data collection rule; the OTLP endpoints appear a few minutes later.')
param enableOtlpIngestion bool = false

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  // AzureMonitorWorkspaceIngestionMode is not in the Bicep types for this API version yet, so union() adds it.
  properties: union(
    {
      Application_Type: 'web'
      WorkspaceResourceId: logAnalytics.id
      publicNetworkAccessForIngestion: 'Enabled'
      publicNetworkAccessForQuery: 'Enabled'
    },
    enableOtlpIngestion ? { AzureMonitorWorkspaceIngestionMode: 'Enabled' } : {}
  )
}

output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsWorkspaceName string = logAnalytics.name
output appInsightsId string = appInsights.id
output appInsightsName string = appInsights.name
@secure()
output appInsightsConnectionString string = appInsights.properties.ConnectionString
