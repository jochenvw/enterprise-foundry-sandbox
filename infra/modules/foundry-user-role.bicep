// =============================================================================
// Grants Foundry User on a Foundry account (data-plane use of its projects,
// playground, agents, and connected models).
// =============================================================================

@description('Foundry account name in this resource group.')
param accountName string

@description('Object ID of the identity to grant.')
param principalId string

@description('Principal type.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param principalType string = 'User'

var foundryUser = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: accountName
}

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(account.id, principalId, foundryUser)
  scope: account
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUser)
  }
}
