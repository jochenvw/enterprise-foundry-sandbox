// =============================================================================
// Standard-agent wiring for a team Foundry project: BYO data connections
// (Cosmos = thread store, Storage = file store, AI Search = vector store) plus
// the project capability host that turns the project into a VNet-injected
// standard agent. Also grants the PROJECT managed identity the data-plane and
// control-plane roles the agent runtime and capability host require.
//
// Connection + capabilityHost shapes follow the Microsoft foundry-samples
// "standard agent" reference (capabilityHosts@2025-04-01-preview, AAD-auth
// connections of category CosmosDB / AzureStorageAccount / CognitiveSearch).
// =============================================================================

@description('Team Foundry account name (this RG).')
param accountName string

@description('Team Foundry project name (child of the account).')
param projectName string

@description('Project system-assigned managed identity principal ID.')
param projectPrincipalId string

@description('Team Cosmos DB account name (this RG).')
param cosmosName string

@description('Team Storage account name (this RG).')
param storageName string

@description('Team AI Search service name (this RG).')
param searchName string

@description('Create the project capability host (standard agent). The connections and role assignments are created regardless so the BYO data is wired into the project.')
param deployCapabilityHost bool = true

@description('Capability host name on the project.')
param capabilityHostName string = 'agents-caphost'

// Built-in role definition IDs.
var storageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var searchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var searchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var cosmosDataContributor = '00000000-0000-0000-0000-000000000002'
// "Cosmos DB Operator" (control plane) - required before the capability host is created.
var cosmosOperator = '230815da-be43-4aae-9cb4-875f7bd000aa'

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosName
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageName
}

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' existing = {
  name: searchName
}

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: account
  name: projectName
}

// -----------------------------------------------------------------------------
// Project connections to the BYO data (AAD auth; no keys stored)
// -----------------------------------------------------------------------------

resource cosmosConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: cosmosName
  properties: {
    category: 'CosmosDB'
    target: cosmos.properties.documentEndpoint
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: cosmos.id
      location: cosmos.location
    }
  }
}

resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: storageName
  properties: {
    category: 'AzureStorageAccount'
    target: storage.properties.primaryEndpoints.blob
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: storage.id
      location: storage.location
    }
  }
  dependsOn: [
    cosmosConnection
  ]
}

resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: searchName
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${searchName}.search.windows.net'
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: search.id
      location: search.location
    }
  }
  dependsOn: [
    storageConnection
  ]
}

// -----------------------------------------------------------------------------
// Project-identity role assignments required by the agent runtime + capability host
// -----------------------------------------------------------------------------

resource storageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, projectPrincipalId, storageBlobDataContributor)
  scope: storage
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource searchIndexRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, projectPrincipalId, searchIndexDataContributor)
  scope: search
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource searchServiceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, projectPrincipalId, searchServiceContributor)
  scope: search
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchServiceContributor)
    principalType: 'ServicePrincipal'
  }
}

resource cosmosOperatorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cosmos.id, projectPrincipalId, cosmosOperator)
  scope: cosmos
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cosmosOperator)
    principalType: 'ServicePrincipal'
  }
}

resource cosmosDataRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmos
  name: guid(cosmos.id, projectPrincipalId, cosmosDataContributor)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${cosmosDataContributor}'
    scope: cosmos.id
  }
}

// -----------------------------------------------------------------------------
// Project capability host (standard agent). Depends on the connections and the
// Cosmos DB Operator role, which must exist before the capability host is created.
// -----------------------------------------------------------------------------

resource capabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = if (deployCapabilityHost) {
  parent: project
  name: capabilityHostName
  properties: {
    capabilityHostKind: 'Agents'
    threadStorageConnections: [ cosmosName ]
    storageConnections: [ storageName ]
    vectorStoreConnections: [ searchName ]
  }
  dependsOn: [
    cosmosConnection
    storageConnection
    searchConnection
    cosmosOperatorRole
    cosmosDataRole
    storageBlobRole
    searchIndexRole
    searchServiceRole
  ]
}

output cosmosConnectionName string = cosmosConnection.name
output storageConnectionName string = storageConnection.name
output searchConnectionName string = searchConnection.name
output capabilityHostName string = deployCapabilityHost ? capabilityHost.name : ''
