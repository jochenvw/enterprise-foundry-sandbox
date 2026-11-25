// =============================================================================
// Grants an AI Gateway runtime role on ONE alias. Scoping the role to the alias
// (not the gateway or workspace) means a caller can invoke only that team's
// governed model. Other aliases return 403.
// =============================================================================

@description('Existing AI Gateway name in this resource group.')
param gatewayName string

@description('Alias name to scope the role to.')
param aliasName string

@description('Object ID of the identity to grant.')
param principalId string

@description('Principal type.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param principalType string = 'ServicePrincipal'

// AI Gateway Models User: invoke models through the gateway.
var aiGatewayModelsUser = 'a6b68e3d-a1f0-4c60-8678-237c050cf4ea'
var roleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aiGatewayModelsUser)

#disable-next-line BCP081
resource gateway 'Microsoft.ApiManagement/aigateways@2026-11-01' existing = {
  name: gatewayName
}

#disable-next-line BCP081
resource workspace 'Microsoft.ApiManagement/aigateways/workspaces@2026-11-01' existing = {
  parent: gateway
  name: 'default'
}

#disable-next-line BCP081
resource alias 'Microsoft.ApiManagement/aigateways/workspaces/aliases@2026-11-01' existing = {
  parent: workspace
  name: aliasName
}

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: alias
  name: guid(alias.id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
  }
}

output roleAssignmentId string = assignment.id
