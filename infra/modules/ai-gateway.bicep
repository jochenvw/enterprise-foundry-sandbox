// =============================================================================
// Azure AI Gateway (Microsoft.ApiManagement/aigateways), the standalone AI
// gateway that replaces API Management for model governance. The gateway has a
// system-assigned identity, which it uses to call the central Foundry account.
// Outbound VNet integration places that traffic in the hub so it reaches central
// Foundry through its private endpoint.
//
// AI Gateway is in public preview. The Bicep type index does not list
// 2026-11-01 yet, so BCP081 is suppressed, as it is in the official samples:
// https://github.com/Azure/ai-gateway
// =============================================================================

@description('Gateway name. It becomes the first label of the runtime host name (3-24 lowercase letters, digits, and hyphens).')
@minLength(3)
@maxLength(24)
param gatewayName string

@description('Azure region where AI Gateway is available.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('Hub subnet delegated to Microsoft.App/environments for outbound VNet integration. Empty means the gateway calls backends over public networking.')
param integrationSubnetId string = ''

#disable-next-line BCP081
resource gateway 'Microsoft.ApiManagement/aigateways@2026-11-01' = {
  name: gatewayName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: empty(integrationSubnetId) ? {} : { backend: { subnet: { id: integrationSubnetId } } }
}

output gatewayId string = gateway.id
output gatewayName string = gateway.name
output principalId string = gateway.identity.principalId
output hostName string = gateway.properties.frontend.defaultHostname
output gatewayUrl string = 'https://${gateway.properties.frontend.defaultHostname}'
