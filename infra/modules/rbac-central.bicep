// =============================================================================
// RBAC: grant the APIM managed identity permission to invoke the central
// Foundry model deployment. Teams are intentionally NOT granted this access.
// =============================================================================

@description('Central Foundry (AIServices) account name in this resource group.')
param centralAccountName string

@description('APIM system-assigned managed identity principal ID.')
param apimPrincipalId string

// Built-in role definition IDs (stable GUIDs; names can change, IDs do not).
var cognitiveServicesOpenAiUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var cognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'

resource centralAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: centralAccountName
}

resource apimOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(centralAccount.id, apimPrincipalId, cognitiveServicesOpenAiUser)
  scope: centralAccount
  properties: {
    principalId: apimPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUser)
    principalType: 'ServicePrincipal'
  }
}

resource apimCognitiveUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(centralAccount.id, apimPrincipalId, cognitiveServicesUser)
  scope: centralAccount
  properties: {
    principalId: apimPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUser)
    principalType: 'ServicePrincipal'
  }
}
