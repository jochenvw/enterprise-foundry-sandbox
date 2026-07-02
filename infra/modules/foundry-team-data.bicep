// =============================================================================
// Team BYO data resources: Storage, Cosmos DB (serverless SQL), AI Search,
// Key Vault. Private endpoints + diagnostics. Public access disabled when PE on.
// =============================================================================

@description('Azure region.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('Team key, e.g. team-a.')
param teamName string

@description('Globally-unique suffix for storage / search names.')
param uniqueSuffix string

@description('Short region+env suffix, e.g. swc-dev.')
param nameSuffix string

@description('Deploy private endpoints.')
param deployPrivateEndpoints bool = true

@description('Public network access where supported: Enabled (with optional IP allowlist) or Disabled.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Disabled'

@description('Operator IP/CIDR to allowlist when public access is Enabled. Empty leaves no IP rule. Use a bare IP (no /32) for Storage/Key Vault compatibility.')
param allowedClientIp string = ''

@description('Private endpoints subnet ID (in this team spoke).')
param privateEndpointsSubnetId string

@description('Log Analytics workspace ID for diagnostics.')
param logAnalyticsWorkspaceId string

@description('Private DNS zone ID for blob.')
param blobPrivateDnsZoneId string

@description('Private DNS zone ID for Cosmos (documents).')
param cosmosPrivateDnsZoneId string

@description('Private DNS zone ID for AI Search.')
param searchPrivateDnsZoneId string

@description('Private DNS zone ID for Key Vault.')
param keyVaultPrivateDnsZoneId string

@description('Deploy a Key Vault for this team.')
param deployKeyVault bool = true

@description('AI Search SKU. basic is the smallest tier that supports private endpoints; switch (e.g. to standard) if a region lacks basic capacity.')
@allowed([
  'basic'
  'standard'
  'standard2'
  'standard3'
])
param searchSkuName string = 'basic'

// team-a -> teama ; strip non-alphanumerics for name compliance.
var teamCompact = replace(teamName, '-', '')
var storageName = take('st${teamCompact}${uniqueSuffix}', 24)
var cosmosName = 'cosmos-${teamName}-${nameSuffix}'
var searchName = take('srch-${teamName}-${nameSuffix}', 60)
var keyVaultName = take('kv-${teamCompact}-${uniqueSuffix}', 24)

var hasIpRule = !empty(allowedClientIp)
var publicAccessLower = toLower(publicNetworkAccess)
var networkDefaultAction = (hasIpRule || publicNetworkAccess == 'Disabled') ? 'Deny' : 'Allow'

// -----------------------------------------------------------------------------
// Storage
// -----------------------------------------------------------------------------

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      defaultAction: networkDefaultAction
      bypass: 'AzureServices'
      ipRules: hasIpRule ? [ { value: allowedClientIp, action: 'Allow' } ] : []
    }
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
}

resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: blobService
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
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Cosmos DB (serverless, SQL API)
// -----------------------------------------------------------------------------

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    publicNetworkAccess: publicNetworkAccess
    ipRules: hasIpRule ? [ { ipAddressOrRange: allowedClientIp } ] : []
    disableKeyBasedMetadataWriteAccess: false
    minimalTlsVersion: 'Tls12'
  }
}

resource cosmosDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: cosmos
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
        category: 'Requests'
        enabled: true
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Azure AI Search
// -----------------------------------------------------------------------------

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchName
  location: location
  tags: tags
  sku: {
    name: searchSkuName
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: publicAccessLower
    networkRuleSet: {
      ipRules: hasIpRule ? [ { value: allowedClientIp } ] : []
    }
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
}

resource searchDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: search
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

// -----------------------------------------------------------------------------
// Key Vault (RBAC authorization)
// -----------------------------------------------------------------------------

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = if (deployKeyVault) {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      defaultAction: networkDefaultAction
      bypass: 'AzureServices'
      ipRules: hasIpRule ? [ { value: allowedClientIp } ] : []
    }
  }
}

resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployKeyVault) {
  name: 'diag-to-law'
  scope: keyVault
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

// -----------------------------------------------------------------------------
// Private endpoints
// -----------------------------------------------------------------------------

module peStorage 'private-endpoint.bicep' = if (deployPrivateEndpoints) {
  name: 'pe-${teamName}-blob'
  params: {
    location: location
    tags: tags
    privateEndpointName: 'pe-${storageName}-blob'
    subnetId: privateEndpointsSubnetId
    privateLinkServiceId: storage.id
    groupIds: [
      'blob'
    ]
    privateDnsZoneIds: [ blobPrivateDnsZoneId ]
  }
}

module peCosmos 'private-endpoint.bicep' = if (deployPrivateEndpoints) {
  name: 'pe-${teamName}-cosmos'
  params: {
    location: location
    tags: tags
    privateEndpointName: 'pe-${cosmosName}-sql'
    subnetId: privateEndpointsSubnetId
    privateLinkServiceId: cosmos.id
    groupIds: [
      'Sql'
    ]
    privateDnsZoneIds: [ cosmosPrivateDnsZoneId ]
  }
}

module peSearch 'private-endpoint.bicep' = if (deployPrivateEndpoints) {
  name: 'pe-${teamName}-search'
  params: {
    location: location
    tags: tags
    privateEndpointName: 'pe-${searchName}'
    subnetId: privateEndpointsSubnetId
    privateLinkServiceId: search.id
    groupIds: [
      'searchService'
    ]
    privateDnsZoneIds: [ searchPrivateDnsZoneId ]
  }
}

module peKeyVault 'private-endpoint.bicep' = if (deployPrivateEndpoints && deployKeyVault) {
  name: 'pe-${teamName}-kv'
  params: {
    location: location
    tags: tags
    privateEndpointName: 'pe-${keyVaultName}'
    subnetId: privateEndpointsSubnetId
    privateLinkServiceId: keyVault.id
    groupIds: [
      'vault'
    ]
    privateDnsZoneIds: [ keyVaultPrivateDnsZoneId ]
  }
}

output storageId string = storage.id
output storageName string = storage.name
output cosmosId string = cosmos.id
output cosmosName string = cosmos.name
output searchId string = search.id
output searchName string = search.name
output keyVaultId string = deployKeyVault ? keyVault.id : ''
output keyVaultName string = deployKeyVault ? keyVault.name : ''
