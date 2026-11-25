// =============================================================================
// RBAC: grant a team's Foundry account identity data-plane access to that
// team's OWN BYO resources only. No cross-team assignments are created, so
// Team A identity cannot reach Team B data and vice versa.
// =============================================================================

@description('Team Foundry account managed identity principal ID.')
param teamPrincipalId string

@description('Team Storage account name (this RG).')
param storageName string

@description('Team AI Search service name (this RG).')
param searchName string

@description('Team Cosmos DB account name (this RG).')
param cosmosName string

@description('Team Key Vault name (this RG). Empty when not deployed.')
param keyVaultName string = ''

@description('Whether a Key Vault was deployed for the team.')
param deployKeyVault bool = true

// Built-in role definition IDs.
var storageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var searchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var searchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var keyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
// Cosmos DB SQL built-in data-plane role: "Cosmos DB Built-in Data Contributor".
var cosmosDataContributor = '00000000-0000-0000-0000-000000000002'

resource storage 'Microsoft.Storage/storageAccounts@2026-09-01' existing = {
  name: storageName
}

resource search 'Microsoft.Search/searchServices@2026-11-01' existing = {
  name: searchName
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2026-03-15' existing = {
  name: cosmosName
}

resource keyVault 'Microsoft.KeyVault/vaults@2026-05-15' existing = if (deployKeyVault) {
  name: keyVaultName
}

resource storageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, teamPrincipalId, storageBlobDataContributor)
  scope: storage
  properties: {
    principalId: teamPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource searchIndexRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, teamPrincipalId, searchIndexDataContributor)
  scope: search
  properties: {
    principalId: teamPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributor)
    principalType: 'ServicePrincipal'
  }
}

resource searchServiceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, teamPrincipalId, searchServiceContributor)
  scope: search
  properties: {
    principalId: teamPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchServiceContributor)
    principalType: 'ServicePrincipal'
  }
}

resource keyVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployKeyVault) {
  name: guid(deployKeyVault ? keyVault.id : storage.id, teamPrincipalId, keyVaultSecretsUser)
  scope: keyVault
  properties: {
    principalId: teamPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUser)
    principalType: 'ServicePrincipal'
  }
}

// Cosmos DB data-plane RBAC uses the account-scoped sqlRoleAssignments resource.
resource cosmosRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2026-03-15' = {
  parent: cosmos
  name: guid(cosmos.id, teamPrincipalId, cosmosDataContributor)
  properties: {
    principalId: teamPrincipalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${cosmosDataContributor}'
    scope: cosmos.id
  }
}
