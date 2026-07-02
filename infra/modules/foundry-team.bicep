// =============================================================================
// Team Foundry: AIServices account + project in a spoke, with optional agent
// network injection into the dedicated agent subnet. BYO data connections are
// created post-deploy (see scripts/postdeploy-foundry-connections.sh).
// =============================================================================

@description('Azure region.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('Team Foundry account name.')
param accountName string

@description('Team Foundry project name.')
param projectName string

@description('Team key, e.g. team-a.')
param teamName string

@description('Public network access for the account: Enabled (with optional IP allowlist) or Disabled.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Disabled'

@description('Operator IP/CIDR to allowlist when public access is Enabled. Empty leaves no IP rule.')
param allowedClientIp string = ''

@description('Deploy private endpoint for the account.')
param deployPrivateEndpoints bool = true

@description('Private endpoints subnet ID (this spoke).')
param privateEndpointsSubnetId string

@description('Dedicated agent subnet ID (this spoke). Each Foundry has its own.')
param agentSubnetId string

@description('Inject Foundry agent runtime into the dedicated agent subnet.')
param enableAgentNetworkInjection bool = false

@description('Cognitive Services private DNS zone ID.')
param cognitivePrivateDnsZoneId string

@description('OpenAI private DNS zone ID.')
param openAiPrivateDnsZoneId string

@description('AI Services private DNS zone ID.')
param aiServicesPrivateDnsZoneId string

@description('Log Analytics workspace ID for diagnostics.')
param logAnalyticsWorkspaceId string

var hasIpRule = !empty(allowedClientIp)
var networkDefaultAction = (hasIpRule || publicNetworkAccess == 'Disabled') ? 'Deny' : 'Allow'
var ipRules = hasIpRule ? [ { value: allowedClientIp } ] : []

var networkInjections = enableAgentNetworkInjection
  ? [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetId
        useMicrosoftManagedNetwork: false
      }
    ]
  : null

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
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
    disableLocalAuth: false
    networkAcls: {
      defaultAction: networkDefaultAction
      ipRules: ipRules
    }
    networkInjections: networkInjections
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: projectName
    description: 'Team ${teamName} build project. Consumes models via the central APIM AI Gateway.'
  }
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

module pe 'private-endpoint.bicep' = if (deployPrivateEndpoints) {
  name: 'pe-${teamName}-foundry'
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
}

output accountId string = account.id
output accountName string = account.name
output accountPrincipalId string = account.identity.principalId
output projectId string = project.id
output projectName string = project.name
output projectPrincipalId string = project.identity.principalId
