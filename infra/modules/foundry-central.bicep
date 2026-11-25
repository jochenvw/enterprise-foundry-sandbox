// =============================================================================
// Central Foundry: AIServices account (hub) hosting approved model deployments.
// Teams must NOT be granted direct access; the AI Gateway is the only sanctioned caller.
// =============================================================================

@description('Azure region.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('Central Foundry account name.')
param accountName string

@description('Central Foundry project name.')
param projectName string

@description('Public network access for the account: Enabled (with optional IP allowlist) or Disabled.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Disabled'

@description('Operator IPs/CIDRs to allowlist when public access is Enabled. Empty leaves no IP rule. Pass single hosts bare (no /32) for Storage compatibility.')
param allowedClientIpRanges array = []

@description('Private endpoints subnet ID (hub).')
param privateEndpointsSubnetId string

@description('Cognitive Services private DNS zone ID.')
param cognitivePrivateDnsZoneId string

@description('OpenAI private DNS zone ID.')
param openAiPrivateDnsZoneId string

@description('AI Services private DNS zone ID.')
param aiServicesPrivateDnsZoneId string

@description('Log Analytics workspace ID for diagnostics.')
param logAnalyticsWorkspaceId string

@description('Deploy the central model deployment.')
param deployModel bool = true

@description('Model deployment name.')
param modelDeploymentName string

@description('Model name.')
param modelName string

@description('Model version, or "latest".')
param modelVersion string

@description('Model deployment SKU name.')
param modelSkuName string = 'GlobalStandard'

@description('Model deployment capacity.')
param modelCapacity int = 1

var ipRules = map(allowedClientIpRanges, r => { value: r })

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    publicNetworkAccess: publicNetworkAccess
    disableLocalAuth: true
    networkAcls: {
      defaultAction: 'Deny'
      ipRules: ipRules
    }
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-09-01' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: projectName
    description: 'Central platform project hosting approved model deployments.'
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2026-09-01' = if (deployModel) {
  parent: account
  name: modelDeploymentName
  sku: {
    name: modelSkuName
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
  // Serialize child operations on the account; parallel writes return RequestConflict.
  dependsOn: [
    project
  ]
}

resource accountDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: account
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

module pe 'private-endpoint.bicep' = {
  name: 'pe-central-foundry'
  params: {
    location: location
    tags: tags
    privateEndpointName: 'pe-${accountName}'
    subnetId: privateEndpointsSubnetId
    privateLinkServiceId: account.id
    groupIds: [
      'account'
    ]
    privateDnsZoneIds: [
      cognitivePrivateDnsZoneId
      openAiPrivateDnsZoneId
      aiServicesPrivateDnsZoneId
    ]
  }
  dependsOn: [
    project
    modelDeployment
  ]
}

output accountId string = account.id
output accountName string = account.name
output accountPrincipalId string = account.identity.principalId
output accountEndpoint string = account.properties.endpoint
output projectId string = project.id
output projectName string = project.name
output modelDeploymentName string = deployModel ? modelDeployment.name : ''
