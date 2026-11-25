// =============================================================================
// RBAC: grant the AI Gateway managed identity permission to invoke the central
// Foundry model deployments. Teams are intentionally NOT granted this access.
// =============================================================================

@description('Central Foundry (AIServices) account name in this resource group.')
param centralAccountName string

@description('AI Gateway system-assigned managed identity principal ID.')
param gatewayPrincipalId string

// Foundry User (stable built-in role GUID). AI Gateway requires it on Foundry backends.
var foundryUser = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource centralAccount 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: centralAccountName
}

resource gatewayFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(centralAccount.id, gatewayPrincipalId, foundryUser)
  scope: centralAccount
  properties: {
    principalId: gatewayPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUser)
    principalType: 'ServicePrincipal'
  }
}

output roleAssignmentName string = gatewayFoundryUser.name
