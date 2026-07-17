// =============================================================================
// Enterprise Microsoft Foundry simulation - subscription-scoped entrypoint
// -----------------------------------------------------------------------------
// Creates four resource groups (observability, hub, team-a, team-b) and calls
// resource-group-scoped modules to build a hub/spoke Foundry topology with a
// central APIM Standard v2 AI Gateway. Region: Sweden Central.
//
// Verified current API versions (az provider show, see docs/implementation-gaps.md):
//   OperationalInsights/workspaces     2025-02-01
//   Insights/components                2020-02-02
//   Insights/diagnosticSettings        2021-05-01-preview
//   Network/virtualNetworks            2024-05-01
//   Network/privateDnsZones            2024-06-01
//   Network/privateEndpoints           2024-05-01
//   CognitiveServices/accounts         2025-06-01 (+projects/deployments)
//   ApiManagement/service              2024-06-01-preview (Standard v2)
//   Storage/storageAccounts            2024-01-01
//   DocumentDB/databaseAccounts        2024-11-15
//   Search/searchServices              2024-06-01-preview
//   KeyVault/vaults                    2024-11-01
//   ManagedIdentity/userAssignedId.    2024-11-30
//   Authorization/roleAssignments      2022-04-01
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

@description('Deploy private endpoints for supported resources. Derived from networkAccessMode; override only for special cases.')
param deployPrivateEndpoints bool = networkAccessMode != 'publicIpOnly'

@description('''Network access posture for data-plane resources (Foundry accounts, APIM, Storage, Cosmos, Search, Key Vault):
- hybridPePlusIp: private endpoints PLUS an operator-IP allowlist on public access (reachable out-of-the-box). Default.
- publicIpOnly:   public access restricted to the operator IP allowlist; no private endpoints.
- privateOnly:    private endpoints only, public access disabled (access via VPN/jumpbox/test VM).''')
@allowed([
  'hybridPePlusIp'
  'publicIpOnly'
  'privateOnly'
])
param networkAccessMode string = 'hybridPePlusIp'

@description('Operator public IP or CIDR to allowlist on public access (e.g. 203.0.113.5 or 203.0.113.0/29). Required for hybridPePlusIp / publicIpOnly so you can reach resources; the deploy script auto-detects and passes it. Ignored for privateOnly.')
param allowedClientIp string = ''

@description('Full ARM resource ID of an EXISTING APIM (v2 tier) to use as the AI Gateway (BYO APIM). When empty, a Standard v2 APIM is deployed. Consumption/classic tiers are not supported by the native AI Gateway.')
param existingApimResourceId string = ''

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

@description('APIM SKU when deploying a new gateway. Must be a v2 tier (native AI Gateway requirement); StandardV2 supports VNet integration + inbound private endpoint.')
@allowed([
  'BasicV2'
  'StandardV2'
  'PremiumV2'
])
param apimSkuName string = 'StandardV2'

@description('Central model deployment name (stable alias-friendly name).')
param centralModelDeploymentName string = 'enterprise-gpt5-mini'

@description('Central model name. Availability varies by region/date - keep parameterized.')
param centralModelName string = 'gpt-5-mini'

@description('Central model version. Use a concrete version or "latest".')
param centralModelVersion string = 'latest'

@description('Central model deployment SKU name.')
param centralModelSkuName string = 'Standard'

@description('Central model deployment capacity (no PTU).')
@minValue(1)
param centralModelCapacity int = 1

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

@description('Enable the APIM content safety policy (requires content safety capability).')
param enableContentSafetyPolicy bool = true

@description('Log full prompt/completion bodies in APIM. Disabled by default for privacy.')
param enablePromptBodyLogging bool = false

@description('Per-team tokens-per-minute (TPM) limits applied at the APIM gateway, aligned by index with teamNames.')
param teamTokenLimitsPerMinute array = [
  1000
  1000
]

@description('Apply the per-team azure-openai-token-limit policy at the gateway.')
param enableTokenLimitPolicy bool = true

@description('Emit per-team token metrics at the gateway.')
param enableTokenMetricPolicy bool = true

@description('Inference API version enforced by the gateway and used by the team connections.')
param inferenceApiVersion string = '2024-10-21'

@description('Auth type for the team Foundry project -> APIM connection.')
@allowed([
  'ApiKey'
  'ProjectManagedIdentity'
])
param foundryToApimAuthType string = 'ApiKey'

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
var publicNetworkAccess = networkAccessMode == 'privateOnly' ? 'Disabled' : 'Enabled'

// Operator IP allowlist is only meaningful when public access is enabled.
var effectiveAllowedClientIp = networkAccessMode == 'privateOnly' ? '' : allowedClientIp

// BYO APIM: when an existing APIM resource ID is supplied, do not deploy one.
var deployApim = empty(existingApimResourceId)

// Resource group names.
var rgObservabilityName = 'rg-${namePrefix}-observability-${nameSuffix}'
var rgHubName = 'rg-${namePrefix}-hub-${nameSuffix}'
var rgTeamAName = 'rg-${namePrefix}-${teamNames[0]}-${nameSuffix}'
var rgTeamBName = 'rg-${namePrefix}-${teamNames[1]}-${nameSuffix}'

// -----------------------------------------------------------------------------
// Resource groups
// -----------------------------------------------------------------------------

resource rgObservability 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgObservabilityName
  location: location
  tags: tags
}

resource rgHub 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgHubName
  location: location
  tags: tags
}

resource rgTeamA 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgTeamAName
  location: location
  tags: tags
}

resource rgTeamB 'Microsoft.Resources/resourceGroups@2024-03-01' = {
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
    apimSubnetPrefix: '${hubBase}.1.0/24'
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
  'privatelink.azure-api.net' // APIM gateway private endpoint
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
var zoneIdxApi = 0
var zoneIdxCognitive = 1
var zoneIdxOpenAi = 2
var zoneIdxAiServices = 3
var zoneIdxSearch = 4
var zoneIdxCosmos = 5
var zoneIdxBlob = 6
var zoneIdxVault = 7

// -----------------------------------------------------------------------------
// Team BYO data resources (Storage / Cosmos / Search / Key Vault)
// -----------------------------------------------------------------------------

module teamAData 'modules/foundry-team-data.bicep' = {
  name: 'team-a-data'
  scope: rgTeamA
  params: {
    location: location
    tags: tags
    teamName: teamNames[0]
    uniqueSuffix: uniqueSuffix
    nameSuffix: nameSuffix
    deployPrivateEndpoints: deployPrivateEndpoints
    publicNetworkAccess: publicNetworkAccess
    allowedClientIp: effectiveAllowedClientIp
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
    tags: tags
    teamName: teamNames[1]
    uniqueSuffix: uniqueSuffix
    nameSuffix: nameSuffix
    deployPrivateEndpoints: deployPrivateEndpoints
    publicNetworkAccess: publicNetworkAccess
    allowedClientIp: effectiveAllowedClientIp
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
    allowedClientIp: effectiveAllowedClientIp
    deployPrivateEndpoints: deployPrivateEndpoints
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
    allowedClientIp: effectiveAllowedClientIp
    enableAgentNetworkInjection: enableAgentNetworkInjection
    deployPrivateEndpoints: deployPrivateEndpoints
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
    allowedClientIp: effectiveAllowedClientIp
    enableAgentNetworkInjection: enableAgentNetworkInjection
    deployPrivateEndpoints: deployPrivateEndpoints
    privateEndpointsSubnetId: networkTeamB.outputs.privateEndpointsSubnetId
    agentSubnetId: networkTeamB.outputs.agentSubnetId
    cognitivePrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxCognitive]
    openAiPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxOpenAi]
    aiServicesPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxAiServices]
    logAnalyticsWorkspaceId: observabilityTeamB.outputs.logAnalyticsWorkspaceId
  }
}

// -----------------------------------------------------------------------------
// AI Gateway (hub): deployed Standard v2 APIM, or BYO existing v2 APIM.
// Deployed first / in parallel with the Foundry accounts; the team projects
// connect to it afterwards (gateway-first ordering).
// -----------------------------------------------------------------------------

var centralFoundryAccountName = 'fndry-central-${nameSuffix}'
var centralOpenAiBaseUrl = 'https://${centralFoundryAccountName}.openai.azure.com'

// BYO APIM resolution: when existingApimResourceId is supplied, reference it
// (name + resource group derived from the ARM ID); otherwise deploy a new APIM.
var apimDeployName = 'apim-${namePrefix}-gw-${nameSuffix}'
var existingApimParts = split(existingApimResourceId, '/')
var apimEffectiveName = deployApim ? apimDeployName : last(existingApimParts)
var apimResourceGroupName = deployApim ? rgHubName : existingApimParts[4]

module apimGateway 'modules/apim-ai-gateway.bicep' = {
  name: 'apim-ai-gateway'
  scope: resourceGroup(apimResourceGroupName)
  params: {
    location: location
    tags: tags
    apimName: apimEffectiveName
    deployApim: deployApim
    apimSkuName: apimSkuName
    apimSubnetId: networkHub.outputs.apimSubnetId
    privateEndpointsSubnetId: networkHub.outputs.privateEndpointsSubnetId
    apimPrivateDnsZoneId: privateDns.outputs.zoneIds[zoneIdxApi]
    deployPrivateEndpoints: deployPrivateEndpoints
    logAnalyticsWorkspaceId: observability.outputs.logAnalyticsWorkspaceId
    appInsightsId: observability.outputs.appInsightsId
    appInsightsConnectionString: observability.outputs.appInsightsConnectionString
    centralOpenAiBaseUrl: centralOpenAiBaseUrl
    centralDeploymentName: centralModelDeploymentName
    openAiApiVersion: inferenceApiVersion
    teamNames: teamNames
    teamTokenLimitsPerMinute: teamTokenLimitsPerMinute
    enableTokenLimitPolicy: enableTokenLimitPolicy
    enableTokenMetricPolicy: enableTokenMetricPolicy
    enablePromptBodyLogging: enablePromptBodyLogging
    enableContentSafetyPolicy: enableContentSafetyPolicy
  }
  dependsOn: [
    rgHub
  ]
}

// -----------------------------------------------------------------------------
// RBAC: APIM -> central model (only APIM); team identities -> own data only
// -----------------------------------------------------------------------------

module rbacCentral 'modules/rbac-central.bicep' = {
  name: 'rbac-central'
  scope: rgHub
  params: {
    centralAccountName: centralFoundryAccountName
    apimPrincipalId: apimGateway.outputs.apimPrincipalId
  }
  dependsOn: [
    foundryCentral
  ]
}

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
// Admin-connected model connections: surface the central, APIM-governed model
// into each team project (replaces the old post-deploy REST script).
// -----------------------------------------------------------------------------

module modelConnTeamA 'modules/foundry-model-connection.bicep' = {
  name: 'model-conn-team-a'
  scope: rgTeamA
  params: {
    foundryAccountName: foundryTeamA.outputs.accountName
    foundryProjectName: foundryTeamA.outputs.projectName
    apimName: apimGateway.outputs.apimName
    apimResourceGroupName: apimResourceGroupName
    apimSubscriptionName: 'sub-${teamNames[0]}'
    apimGatewayUrl: apimGateway.outputs.gatewayUrl
    teamName: teamNames[0]
    centralDeploymentName: centralModelDeploymentName
    centralModelName: centralModelName
    centralModelVersion: centralModelVersion == 'latest' ? '' : centralModelVersion
    inferenceApiVersion: inferenceApiVersion
    authType: foundryToApimAuthType
  }
}

module modelConnTeamB 'modules/foundry-model-connection.bicep' = {
  name: 'model-conn-team-b'
  scope: rgTeamB
  params: {
    foundryAccountName: foundryTeamB.outputs.accountName
    foundryProjectName: foundryTeamB.outputs.projectName
    apimName: apimGateway.outputs.apimName
    apimResourceGroupName: apimResourceGroupName
    apimSubscriptionName: 'sub-${teamNames[1]}'
    apimGatewayUrl: apimGateway.outputs.gatewayUrl
    teamName: teamNames[1]
    centralDeploymentName: centralModelDeploymentName
    centralModelName: centralModelName
    centralModelVersion: centralModelVersion == 'latest' ? '' : centralModelVersion
    inferenceApiVersion: inferenceApiVersion
    authType: foundryToApimAuthType
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
output apimName string = apimGateway.outputs.apimName
output apimResourceGroup string = apimResourceGroupName
output apimResourceId string = apimGateway.outputs.apimId
output apimGatewayUrl string = apimGateway.outputs.gatewayUrl
output networkAccessMode string = networkAccessMode
output allowedClientIp string = effectiveAllowedClientIp
output centralFoundryName string = foundryCentral.outputs.accountName
output centralFoundryEndpoint string = foundryCentral.outputs.accountEndpoint
output centralModelDeployment string = foundryCentral.outputs.modelDeploymentName
output teamAFoundryName string = foundryTeamA.outputs.accountName
output teamBFoundryName string = foundryTeamB.outputs.accountName
output teamAProjectName string = foundryTeamA.outputs.projectName
output teamBProjectName string = foundryTeamB.outputs.projectName
output teamAModelConnectionName string = modelConnTeamA.outputs.connectionName
output teamBModelConnectionName string = modelConnTeamB.outputs.connectionName
