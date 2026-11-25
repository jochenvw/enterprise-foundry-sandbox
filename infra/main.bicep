// =============================================================================
// Enterprise Microsoft Foundry simulation - subscription-scoped entrypoint
// -----------------------------------------------------------------------------
// Creates four resource groups (observability, hub, team-a, team-b) and calls
// resource-group-scoped modules to build a hub/spoke Foundry topology with a
// central Azure AI Gateway (Microsoft.ApiManagement/aigateways). Region: Sweden Central.
//
// API versions follow published stable Bicep schemas, not just provider metadata.
// See docs/deployment.md for the verified version baseline and exceptions.
// =============================================================================

targetScope = 'subscription'

// -----------------------------------------------------------------------------
// Parameters
// -----------------------------------------------------------------------------

@description('Short environment name used in resource names, e.g. dev/test/prod.')
param environmentName string = 'dev'

@description('Azure region (location code, not display name).')
param location string = 'swedencentral'

@description('Short prefix applied to all resource names.')
param namePrefix string = 'ai'

@description('Deploy an optional test VM inside a spoke for DNS/private-endpoint testing.')
param deployTestVm bool = false

@description('Admin password for the optional test VM. Required only when deployTestVm=true.')
@secure()
param testVmAdminPassword string = ''

@description('''Network access posture for data-plane resources (Foundry accounts, Storage, Cosmos, Search, Key Vault):
- hybridPePlusIp: private endpoints PLUS an operator-IP allowlist on public access (reachable out-of-the-box). Default.
- privateOnly:    private endpoints only, public access disabled (access via VPN/jumpbox/test VM).''')
@allowed([
  'hybridPePlusIp'
  'privateOnly'
])
param networkAccessMode string = 'hybridPePlusIp'

@description('Operator public IPs or CIDRs to allowlist on public access (e.g. ["203.0.113.0/24"]). Corporate networks often egress through several NAT addresses, so the deploy script detects all of them and passes their /24 ranges. Ignored for privateOnly.')
param allowedClientIpRanges array = []

@description('Tag Storage, Cosmos DB and Key Vault with the governance opt-out tag so tenant "modify" policies do not force publicNetworkAccess=Disabled, keeping the operator IP allowlist effective (needed for live portal demos). Local auth stays disabled in the template regardless.')
param exemptDataResourcesFromNetworkPolicy bool = false

@description('Tag name/value that tenant governance policies honour as an opt-out (MCAPS default: SecurityControl=Ignore).')
param networkPolicyExemptionTag object = {
  SecurityControl: 'Ignore'
}

@description('Inject the Foundry agent runtime into each team spoke\'s dedicated agent subnet (standard-agent VNet integration). Enabled by default.')
param enableAgentNetworkInjection bool = true

@description('Create each team project\'s capability host (standard agent). Requires enableAgentNetworkInjection. The BYO data connections and project-identity role assignments are created whenever agent injection is on, regardless of this flag.')
param deployAgentCapabilityHost bool = true

@description('AI Search SKU for each team. basic is the smallest tier that supports private endpoints; switch (e.g. to standard) if a region temporarily lacks basic capacity.')
@allowed([
  'basic'
  'standard'
  'standard2'
  'standard3'
])
param searchSkuName string = 'basic'

@description('Central model deployment name (stable alias-friendly name).')
param centralModelDeploymentName string = 'enterprise-gpt5-mini'

@description('Central model name. Availability varies by region/date - keep parameterized.')
param centralModelName string = 'gpt-5-mini'

@description('Central model version. Prefer a concrete version verified by check-model-availability.sh.')
param centralModelVersion string = '2025-08-07'

@description('Central model deployment SKU name.')
param centralModelSkuName string = 'GlobalStandard'

@description('Central model deployment capacity (no PTU).')
@minValue(1)
param centralModelCapacity int = 50

@description('Team identifiers used to build spoke names. Order is significant.')
param teamNames array = [
  'team-a'
  'team-b'
]

@description('Hub VNet address space.')
param hubVnetAddressPrefix string = '10.10.0.0/16'

@description('Team A spoke VNet address space.')
param teamAVnetAddressPrefix string = '10.20.0.0/16'

@description('Team B spoke VNet address space.')
param teamBVnetAddressPrefix string = '10.30.0.0/16'

@description('Optionally screen prompts and responses on each team alias with the supported contentSafety policy at Medium severity.')
param enableContentSafetyPolicy bool = false

@description('Per-team tokens-per-minute (TPM) limits applied on each team alias (counted per caller identity), aligned by index with teamNames.')
param teamTokenLimitsPerMinute array = [
  20000
  20000
]

@description('Apply the per-team tokenLimit policy on each team alias.')
param enableTokenLimitPolicy bool = true

@description('Deploy an inbound private endpoint to the AI Gateway. Requires the gated subscription feature Microsoft.Network/AllowPrivateEndpoints, so it is off by default and the gateway ingress stays public behind Entra ID auth.')
param deployAiGatewayPrivateEndpoint bool = false

@description('Optional object ID granted AI Gateway Models User on the FIRST team alias only, plus Foundry User on that team\'s account, for smoke and isolation tests. The deploy script passes the signed-in user.')
param gatewayTestPrincipalId string = ''

@description('Principal type of gatewayTestPrincipalId.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param gatewayTestPrincipalType string = 'User'

@description('Team project connections send Responses API requests upstream to the gateway (false = Chat Completions).')
param useResponsesApiUpstream bool = true

@description('Optional explicit unique suffix. When empty, derived from subscription id + environment.')
param uniqueSuffixOverride string = ''

@description('Tags applied to all resource groups and (where supported) resources.')
param tags object = {
  workload: 'enterprise-foundry'
  environment: environmentName
  managedBy: 'bicep'
}

// -----------------------------------------------------------------------------
// Naming
// -----------------------------------------------------------------------------

// Short region token used in deterministic names (Sweden Central -> swc).
var regionToken = 'swc'

// Deterministic unique token for globally-unique names (storage, etc.).
var uniqueSuffix = empty(uniqueSuffixOverride)
  ? substring(uniqueString(subscription().id, environmentName), 0, 6)
  : uniqueSuffixOverride

var nameSuffix = '${regionToken}-${environmentName}'

// -----------------------------------------------------------------------------
// Derived network posture (from networkAccessMode)
// -----------------------------------------------------------------------------

// Public network access string applied to data-plane resources.
var publicNetworkAccess = networkAccessMode == 'privateOnly' || empty(allowedClientIpRanges) ? 'Disabled' : 'Enabled'

// Operator IP allowlist is only meaningful when public access is enabled.
// Storage rejects /32 (and /31) prefixes, so single hosts are passed bare.
var effectiveAllowedClientIpRanges = networkAccessMode == 'privateOnly'
  ? []
  : map(allowedClientIpRanges, r => endsWith(r, '/32') ? substring(r, 0, length(r) - 3) : r)

var dataResourceTags = exemptDataResourcesFromNetworkPolicy ? union(tags, networkPolicyExemptionTag) : tags

// Resource group names.
var rgObservabilityName = 'rg-${namePrefix}-observability-${nameSuffix}'
var rgHubName = 'rg-${namePrefix}-hub-${nameSuffix}'
var rgTeamAName = 'rg-${namePrefix}-${teamNames[0]}-${nameSuffix}'
var rgTeamBName = 'rg-${namePrefix}-${teamNames[1]}-${nameSuffix}'

// -----------------------------------------------------------------------------
// Resource groups
// -----------------------------------------------------------------------------

resource rgObservability 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: rgObservabilityName
  location: location
  tags: tags
}

resource rgHub 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: rgHubName
  location: location
  tags: tags
}

resource rgTeamA 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: rgTeamAName
  location: location
  tags: tags
}

resource rgTeamB 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: rgTeamBName
  location: location
  tags: tags
}

// -----------------------------------------------------------------------------
// Observability (Log Analytics + Application Insights)
// -----------------------------------------------------------------------------

module observability 'modules/observability.bicep' = {
  name: 'observability'
  scope: rgObservability
  params: {
    location: location
    tags: tags
    logAnalyticsName: 'law-${namePrefix}-${nameSuffix}'
    appInsightsName: 'appi-${namePrefix}-${nameSuffix}'
  }
}

module observabilityTeamA 'modules/observability.bicep' = {
  name: 'observability-team-a'
  scope: rgTeamA
  params: {
    location: location
    tags: tags
    logAnalyticsName: 'law-${namePrefix}-${teamNames[0]}-${nameSuffix}'
    appInsightsName: 'appi-${namePrefix}-${teamNames[0]}-${nameSuffix}'
  }
}

module observabilityTeamB 'modules/observability.bicep' = {
  name: 'observability-team-b'
  scope: rgTeamB
  params: {
    location: location
    tags: tags
    logAnalyticsName: 'law-${namePrefix}-${teamNames[1]}-${nameSuffix}'
    appInsightsName: 'appi-${namePrefix}-${teamNames[1]}-${nameSuffix}'
  }
}

// -----------------------------------------------------------------------------
// Networking: hub + two spokes + bidirectional peering
// -----------------------------------------------------------------------------

var hubVnetName = 'vnet-${namePrefix}-hub-${nameSuffix}'
var teamAVnetName = 'vnet-${namePrefix}-${teamNames[0]}-${nameSuffix}'
var teamBVnetName = 'vnet-${namePrefix}-${teamNames[1]}-${nameSuffix}'

// Derive /24 subnet prefixes from each /16 base (e.g. 10.20.0.0/16 -> 10.20.x.0/24).
var hubBase = substring(hubVnetAddressPrefix, 0, lastIndexOf(hubVnetAddressPrefix, '.0.0/16'))
var teamABase = substring(teamAVnetAddressPrefix, 0, lastIndexOf(teamAVnetAddressPrefix, '.0.0/16'))
var teamBBase = substring(teamBVnetAddressPrefix, 0, lastIndexOf(teamBVnetAddressPrefix, '.0.0/16'))

module networkHub 'modules/network-hub.bicep' = {
  name: 'network-hub'
  scope: rgHub
  params: {
    location: location
    tags: tags
    vnetName: hubVnetName
    addressPrefix: hubVnetAddressPrefix
    aiGatewaySubnetPrefix: '${hubBase}.1.0/24'
    privateEndpointsSubnetPrefix: '${hubBase}.2.0/24'
    sharedServicesSubnetPrefix: '${hubBase}.3.0/24'
  }
}

module networkTeamA 'modules/network-spoke.bicep' = {
  name: 'network-team-a'
  scope: rgTeamA
  params: {
    location: location
    tags: tags
    vnetName: teamAVnetName
    addressPrefix: teamAVnetAddressPrefix
    agentSubnetPrefix: '${teamABase}.1.0/24'
    privateEndpointsSubnetPrefix: '${teamABase}.2.0/24'
    teamAppsSubnetPrefix: '${teamABase}.3.0/24'
  }
}

module networkTeamB 'modules/network-spoke.bicep' = {
  name: 'network-team-b'
  scope: rgTeamB
  params: {
    location: location
    tags: tags
    vnetName: teamBVnetName
    addressPrefix: teamBVnetAddressPrefix
    agentSubnetPrefix: '${teamBBase}.1.0/24'
    privateEndpointsSubnetPrefix: '${teamBBase}.2.0/24'
    teamAppsSubnetPrefix: '${teamBBase}.3.0/24'
  }
}

// Hub -> spoke peerings (deployed in hub RG).
module peerHubToA 'modules/network-peering.bicep' = {
  name: 'peer-hub-to-a'
  scope: rgHub
  params: {
    localVnetName: hubVnetName
    remoteVnetId: networkTeamA.outputs.vnetId
    peeringName: 'peer-hub-to-${teamNames[0]}'
  }
  dependsOn: [
    networkHub
  ]
}

module peerHubToB 'modules/network-peering.bicep' = {
  name: 'peer-hub-to-b'
  scope: rgHub
  params: {
    localVnetName: hubVnetName
    remoteVnetId: networkTeamB.outputs.vnetId
    peeringName: 'peer-hub-to-${teamNames[1]}'
  }
  dependsOn: [
    networkHub
    peerHubToA
  ]
}

// Spoke -> hub peerings (deployed in each team RG).
module peerAToHub 'modules/network-peering.bicep' = {
  name: 'peer-a-to-hub'
  scope: rgTeamA
  params: {
    localVnetName: teamAVnetName
    remoteVnetId: networkHub.outputs.vnetId
    peeringName: 'peer-${teamNames[0]}-to-hub'
  }
  dependsOn: [
    networkTeamA
  ]
}

module peerBToHub 'modules/network-peering.bicep' = {
  name: 'peer-b-to-hub'
  scope: rgTeamB
  params: {
    localVnetName: teamBVnetName
    remoteVnetId: networkHub.outputs.vnetId
    peeringName: 'peer-${teamNames[1]}-to-hub'
  }
  dependsOn: [
    networkTeamB
  ]
}

// -----------------------------------------------------------------------------
// Private DNS zones (hub RG) linked to hub + both spokes
// -----------------------------------------------------------------------------

var privateDnsZoneNames = [
  'privatelink.cognitiveservices.azure.com' // Cognitive Services / Foundry
  'privatelink.openai.azure.com' // Azure OpenAI inference
  'privatelink.services.ai.azure.com' // AI Services / Foundry
  'privatelink.search.windows.net' // Azure AI Search
  'privatelink.documents.azure.com' // Cosmos DB (SQL)
  'privatelink.blob.${environment().suffixes.storage}' // Storage blob
  'privatelink.vaultcore.azure.net' // Key Vault
]

module privateDns 'modules/private-dns.bicep' = {
  name: 'private-dns'
  scope: rgHub
  params: {
    tags: tags
    zoneNames: privateDnsZoneNames
    linkedVnetIds: [
      networkHub.outputs.vnetId
      networkTeamA.outputs.vnetId
      networkTeamB.outputs.vnetId
    ]
  }
}

// Zone index map (order must match privateDnsZoneNames above).
var zoneIdxCognitive = 0
var zoneIdxOpenAi = 1
var zoneIdxAiServices = 2
var zoneIdxSearch = 3
var zoneIdxCosmos = 4
var zoneIdxBlob = 5
var zoneIdxVault = 6

// -----------------------------------------------------------------------------
// Team BYO data resources (Storage / Cosmos / Search / Key Vault)
// -----------------------------------------------------------------------------

module teamAData 'modules/foundry-team-data.bicep' = {
  name: 'team-a-data'
  scope: rgTeamA
  params: {
    location: location
    tags: dataResourceTags
    teamName: teamNames[0]
    uniqueSuffix: uniqueSuffix
    nameSuffix: nameSuffix
    publicNetworkAccess: publicNetworkAccess
    allowedClientIpRanges: effectiveAllowedClientIpRanges
    searchSkuName: searchSkuName
    privateEndpointsSubnetId: networkTeamA.outputs.privateEndpointsSubnetId
    logAnalyticsWorkspaceId: observabilityTeamA.outputs.logAnalyticsWorkspaceId
    blobPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxBlob]
    cosmosPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxCosmos]
    searchPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxSearch]
    keyVaultPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxVault]
  }
}

module teamBData 'modules/foundry-team-data.bicep' = {
  name: 'team-b-data'
  scope: rgTeamB
  params: {
    location: location
    tags: dataResourceTags
    teamName: teamNames[1]
    uniqueSuffix: uniqueSuffix
    nameSuffix: nameSuffix
    publicNetworkAccess: publicNetworkAccess
    allowedClientIpRanges: effectiveAllowedClientIpRanges
    searchSkuName: searchSkuName
    privateEndpointsSubnetId: networkTeamB.outputs.privateEndpointsSubnetId
    logAnalyticsWorkspaceId: observabilityTeamB.outputs.logAnalyticsWorkspaceId
    blobPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxBlob]
    cosmosPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxCosmos]
    searchPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxSearch]
    keyVaultPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxVault]
  }
}

// -----------------------------------------------------------------------------
// Foundry resources: central (hub) + per-team (spokes)
// -----------------------------------------------------------------------------

module foundryCentral 'modules/foundry-central.bicep' = {
  name: 'foundry-central'
  scope: rgHub
  params: {
    location: location
    tags: tags
    accountName: 'fndry-central-${nameSuffix}'
    projectName: 'proj-central'
    publicNetworkAccess: publicNetworkAccess
    allowedClientIpRanges: effectiveAllowedClientIpRanges
    privateEndpointsSubnetId: networkHub.outputs.privateEndpointsSubnetId
    cognitivePrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxCognitive]
    openAiPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxOpenAi]
    aiServicesPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxAiServices]
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsWorkspaceId
    deployModel: true
    modelDeploymentName: centralModelDeploymentName
    modelName: centralModelName
    modelVersion: centralModelVersion
    modelSkuName: centralModelSkuName
    modelCapacity: centralModelCapacity
  }
}

module foundryTeamA 'modules/foundry-team.bicep' = {
  name: 'foundry-team-a'
  scope: rgTeamA
  params: {
    location: location
    tags: tags
    accountName: 'fndry-${teamNames[0]}-${nameSuffix}'
    projectName: 'proj-${teamNames[0]}'
    teamName: teamNames[0]
    publicNetworkAccess: publicNetworkAccess
    allowedClientIpRanges: effectiveAllowedClientIpRanges
    enableAgentNetworkInjection: enableAgentNetworkInjection
    privateEndpointsSubnetId: networkTeamA.outputs.privateEndpointsSubnetId
    agentSubnetId: networkTeamA.outputs.agentSubnetId
    cognitivePrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxCognitive]
    openAiPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxOpenAi]
    aiServicesPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxAiServices]
    logAnalyticsWorkspaceId: observabilityTeamA.outputs.logAnalyticsWorkspaceId
  }
}

module foundryTeamB 'modules/foundry-team.bicep' = {
  name: 'foundry-team-b'
  scope: rgTeamB
  params: {
    location: location
    tags: tags
    accountName: 'fndry-${teamNames[1]}-${nameSuffix}'
    projectName: 'proj-${teamNames[1]}'
    teamName: teamNames[1]
    publicNetworkAccess: publicNetworkAccess
    allowedClientIpRanges: effectiveAllowedClientIpRanges
    enableAgentNetworkInjection: enableAgentNetworkInjection
    privateEndpointsSubnetId: networkTeamB.outputs.privateEndpointsSubnetId
    agentSubnetId: networkTeamB.outputs.agentSubnetId
    cognitivePrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxCognitive]
    openAiPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxOpenAi]
    aiServicesPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxAiServices]
    logAnalyticsWorkspaceId: observabilityTeamB.outputs.logAnalyticsWorkspaceId
  }
}

// -----------------------------------------------------------------------------
// Azure AI Gateway (hub). The gateway joins the hub integration subnet so its
// managed identity reaches central Foundry through the private endpoint. Each
// team gets its own alias (token limit + optional content safety) and a runtime
// role scoped to that alias only.
// -----------------------------------------------------------------------------

var aiGatewayName = take('aigw-${namePrefix}-${nameSuffix}-${uniqueSuffix}', 24)
var centralModelVersionOrEmpty = centralModelVersion == 'latest' ? '' : centralModelVersion

module aiGateway 'modules/ai-gateway.bicep' = {
  name: 'ai-gateway'
  scope: rgHub
  params: {
    gatewayName: aiGatewayName
    location: location
    tags: tags
    integrationSubnetId: networkHub.outputs.aiGatewaySubnetId
  }
}

// RBAC: only the gateway identity may call the central model (Foundry User).
module rbacCentral 'modules/rbac-central.bicep' = {
  name: 'rbac-central'
  scope: rgHub
  params: {
    centralAccountName: foundryCentral.outputs.accountName
    gatewayPrincipalId: aiGateway.outputs.principalId
  }
}

module aiGatewayModels 'modules/ai-gateway-models.bicep' = {
  name: 'ai-gateway-models'
  scope: rgHub
  params: {
    gatewayName: aiGateway.outputs.gatewayName
    foundryAccountId: foundryCentral.outputs.accountId
    foundryEndpoint: foundryCentral.outputs.accountEndpoint
    deploymentName: foundryCentral.outputs.modelDeploymentName
    modelVersion: centralModelVersionOrEmpty
    teamNames: teamNames
    teamTokenLimitsPerMinute: teamTokenLimitsPerMinute
    enableTokenLimitPolicy: enableTokenLimitPolicy
    enableContentSafetyPolicy: enableContentSafetyPolicy
  }
  dependsOn: [
    rbacCentral
  ]
}

module aiGatewayPrivateEndpoint 'modules/ai-gateway-private-endpoint.bicep' = if (deployAiGatewayPrivateEndpoint) {
  name: 'ai-gateway-private-endpoint'
  scope: rgHub
  params: {
    location: location
    tags: tags
    gatewayId: aiGateway.outputs.gatewayId
    gatewayHostName: aiGateway.outputs.hostName
    subnetId: networkHub.outputs.privateEndpointsSubnetId
    linkedVnetIds: [
      networkHub.outputs.vnetId
      networkTeamA.outputs.vnetId
      networkTeamB.outputs.vnetId
    ]
    privateEndpointName: 'pe-${aiGatewayName}'
  }
}

// -----------------------------------------------------------------------------
// RBAC: team identities -> own data only
// -----------------------------------------------------------------------------

module rbacTeamA 'modules/rbac-team.bicep' = {
  name: 'rbac-team-a'
  scope: rgTeamA
  params: {
    teamPrincipalId: foundryTeamA.outputs.accountPrincipalId
    storageName: teamAData.outputs.storageName
    searchName: teamAData.outputs.searchName
    cosmosName: teamAData.outputs.cosmosName
    keyVaultName: teamAData.outputs.keyVaultName
    deployKeyVault: true
  }
}

module rbacTeamB 'modules/rbac-team.bicep' = {
  name: 'rbac-team-b'
  scope: rgTeamB
  params: {
    teamPrincipalId: foundryTeamB.outputs.accountPrincipalId
    storageName: teamBData.outputs.storageName
    searchName: teamBData.outputs.searchName
    cosmosName: teamBData.outputs.cosmosName
    keyVaultName: teamBData.outputs.keyVaultName
    deployKeyVault: true
  }
}

// -----------------------------------------------------------------------------
// Standard-agent wiring: connect each team project to its BYO data (Cosmos =
// thread store, Storage = files, AI Search = vectors) and create the project
// capability host. Gated on agent network injection so the VNet-injected
// standard agent is only built when injection is enabled.
// -----------------------------------------------------------------------------

module agentTeamA 'modules/foundry-team-agent.bicep' = if (enableAgentNetworkInjection) {
  name: 'foundry-agent-team-a'
  scope: rgTeamA
  params: {
    accountName: foundryTeamA.outputs.accountName
    projectName: foundryTeamA.outputs.projectName
    projectPrincipalId: foundryTeamA.outputs.projectPrincipalId
    cosmosName: teamAData.outputs.cosmosName
    storageName: teamAData.outputs.storageName
    searchName: teamAData.outputs.searchName
    deployCapabilityHost: deployAgentCapabilityHost
  }
  dependsOn: [
    rbacTeamA
  ]
}

module agentTeamB 'modules/foundry-team-agent.bicep' = if (enableAgentNetworkInjection) {
  name: 'foundry-agent-team-b'
  scope: rgTeamB
  params: {
    accountName: foundryTeamB.outputs.accountName
    projectName: foundryTeamB.outputs.projectName
    projectPrincipalId: foundryTeamB.outputs.projectPrincipalId
    cosmosName: teamBData.outputs.cosmosName
    storageName: teamBData.outputs.storageName
    searchName: teamBData.outputs.searchName
    deployCapabilityHost: deployAgentCapabilityHost
  }
  dependsOn: [
    rbacTeamB
  ]
}

// -----------------------------------------------------------------------------
// Admin-connected model connections: surface each team's governed gateway alias
// in its project. The project identity gets AI Gateway Models User on its own
// alias only, so the gateway rejects calls to the other team's alias.
// -----------------------------------------------------------------------------

var aiGatewayConnectionName = '${aiGatewayName}-model-gateway'

module aliasRoleTeamA 'modules/ai-gateway-alias-role.bicep' = {
  name: 'aigw-alias-role-team-a'
  scope: rgHub
  params: {
    gatewayName: aiGateway.outputs.gatewayName
    aliasName: aiGatewayModels.outputs.aliasNames[0]
    principalId: foundryTeamA.outputs.projectPrincipalId
  }
}

module aliasRoleTeamB 'modules/ai-gateway-alias-role.bicep' = {
  name: 'aigw-alias-role-team-b'
  scope: rgHub
  params: {
    gatewayName: aiGateway.outputs.gatewayName
    aliasName: aiGatewayModels.outputs.aliasNames[1]
    principalId: foundryTeamB.outputs.projectPrincipalId
  }
}

module aliasRoleTester 'modules/ai-gateway-alias-role.bicep' = if (!empty(gatewayTestPrincipalId)) {
  name: 'aigw-alias-role-tester'
  scope: rgHub
  params: {
    gatewayName: aiGateway.outputs.gatewayName
    aliasName: aiGatewayModels.outputs.aliasNames[0]
    principalId: gatewayTestPrincipalId
    principalType: gatewayTestPrincipalType
  }
}

// The tester also needs Foundry User on the first team's account to call that
// project's connected model.
module foundryUserTester 'modules/foundry-user-role.bicep' = if (!empty(gatewayTestPrincipalId)) {
  name: 'foundry-user-tester-team-a'
  scope: rgTeamA
  params: {
    accountName: foundryTeamA.outputs.accountName
    principalId: gatewayTestPrincipalId
    principalType: gatewayTestPrincipalType
  }
}

module modelConnTeamA 'modules/foundry-model-connection.bicep' = {
  name: 'model-conn-team-a'
  scope: rgTeamA
  params: {
    foundryAccountName: foundryTeamA.outputs.accountName
    foundryProjectName: foundryTeamA.outputs.projectName
    connectionName: aiGatewayConnectionName
    gatewayId: aiGateway.outputs.gatewayId
    gatewayUrl: aiGateway.outputs.gatewayUrl
    gatewayLocation: location
    aliasName: aiGatewayModels.outputs.aliasNames[0]
    centralModelName: centralModelName
    centralModelVersion: centralModelVersionOrEmpty
    useResponsesApi: useResponsesApiUpstream
  }
}

module modelConnTeamB 'modules/foundry-model-connection.bicep' = {
  name: 'model-conn-team-b'
  scope: rgTeamB
  params: {
    foundryAccountName: foundryTeamB.outputs.accountName
    foundryProjectName: foundryTeamB.outputs.projectName
    connectionName: aiGatewayConnectionName
    gatewayId: aiGateway.outputs.gatewayId
    gatewayUrl: aiGateway.outputs.gatewayUrl
    gatewayLocation: location
    aliasName: aiGatewayModels.outputs.aliasNames[1]
    centralModelName: centralModelName
    centralModelVersion: centralModelVersionOrEmpty
    useResponsesApi: useResponsesApiUpstream
  }
}

// -----------------------------------------------------------------------------
// Optional in-network test VM (Team A apps subnet)
// -----------------------------------------------------------------------------

module testVm 'modules/test-vm.bicep' = if (deployTestVm) {
  name: 'test-vm'
  scope: rgTeamA
  params: {
    location: location
    tags: tags
    vmName: 'vm-test-${teamNames[0]}-${nameSuffix}'
    subnetId: networkTeamA.outputs.teamAppsSubnetId
    adminPassword: testVmAdminPassword
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output observabilityResourceGroup string = rgObservability.name
output hubResourceGroup string = rgHub.name
output teamAResourceGroup string = rgTeamA.name
output teamBResourceGroup string = rgTeamB.name
output logAnalyticsWorkspaceId string = observability.outputs.logAnalyticsWorkspaceId
output teamALogAnalyticsWorkspaceName string = observabilityTeamA.outputs.logAnalyticsWorkspaceName
output teamBLogAnalyticsWorkspaceName string = observabilityTeamB.outputs.logAnalyticsWorkspaceName
output teamAAppInsightsName string = observabilityTeamA.outputs.appInsightsName
output teamBAppInsightsName string = observabilityTeamB.outputs.appInsightsName
output teamAAppInsightsId string = observabilityTeamA.outputs.appInsightsId
output teamBAppInsightsId string = observabilityTeamB.outputs.appInsightsId
@secure()
output teamAAppInsightsConnectionString string = observabilityTeamA.outputs.appInsightsConnectionString
@secure()
output teamBAppInsightsConnectionString string = observabilityTeamB.outputs.appInsightsConnectionString
output teamALogAnalyticsWorkspaceId string = observabilityTeamA.outputs.logAnalyticsWorkspaceId
output teamBLogAnalyticsWorkspaceId string = observabilityTeamB.outputs.logAnalyticsWorkspaceId
output uniqueSuffix string = uniqueSuffix
output aiGatewayName string = aiGateway.outputs.gatewayName
output aiGatewayResourceGroup string = rgHub.name
output aiGatewayId string = aiGateway.outputs.gatewayId
output aiGatewayUrl string = aiGateway.outputs.gatewayUrl
output aiGatewayModelsEndpoint string = '${aiGateway.outputs.gatewayUrl}/default/models/openai/v1'
output teamAAlias string = aiGatewayModels.outputs.aliasNames[0]
output teamBAlias string = aiGatewayModels.outputs.aliasNames[1]
output networkAccessMode string = networkAccessMode
output allowedClientIpRanges array = effectiveAllowedClientIpRanges
output centralFoundryName string = foundryCentral.outputs.accountName
output centralFoundryEndpoint string = foundryCentral.outputs.accountEndpoint
output centralProjectName string = foundryCentral.outputs.projectName
output centralModelDeployment string = foundryCentral.outputs.modelDeploymentName
output teamAFoundryName string = foundryTeamA.outputs.accountName
output teamBFoundryName string = foundryTeamB.outputs.accountName
output teamAProjectName string = foundryTeamA.outputs.projectName
output teamBProjectName string = foundryTeamB.outputs.projectName
output teamAModelConnectionName string = modelConnTeamA.outputs.connectionName
output teamBModelConnectionName string = modelConnTeamB.outputs.connectionName
output teamAFoundryModel string = modelConnTeamA.outputs.foundryModel
output teamBFoundryModel string = modelConnTeamB.outputs.foundryModel
output teamAProjectEndpoint string = 'https://${foundryTeamA.outputs.accountName}.services.ai.azure.com/api/projects/${foundryTeamA.outputs.projectName}'
output teamBProjectEndpoint string = 'https://${foundryTeamB.outputs.accountName}.services.ai.azure.com/api/projects/${foundryTeamB.outputs.projectName}'
