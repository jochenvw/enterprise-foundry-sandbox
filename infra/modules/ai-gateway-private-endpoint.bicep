// =============================================================================
// Optional inbound private endpoint to the AI Gateway (group ID 'Gateway').
// The private DNS zone follows the gateway host name without its first label,
// e.g. privatelink.swedencentral-01.ai.gateway.azure.com.
// Requires the subscription feature Microsoft.Network/AllowPrivateEndpoints
// (gated preview); creation fails with SubscriptionNotRegisteredForFeature
// otherwise.
// =============================================================================

@description('Azure region.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('Gateway resource ID.')
param gatewayId string

@description('Gateway runtime host name (no scheme).')
param gatewayHostName string

@description('Subnet that holds the private endpoint.')
param subnetId string

@description('VNets to link the private DNS zone to.')
param linkedVnetIds array

@description('Private endpoint name.')
param privateEndpointName string

var dnsZoneName = 'privatelink.${join(skip(split(gatewayHostName, '.'), 1), '.')}'

resource dnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: dnsZoneName
  location: 'global'
  tags: tags
}

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnetId in linkedVnetIds: {
    parent: dnsZone
    name: '${last(split(vnetId, '/'))}-link'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnetId
      }
    }
  }
]

module pe 'private-endpoint.bicep' = {
  name: 'pe-ai-gateway'
  params: {
    location: location
    tags: tags
    privateEndpointName: privateEndpointName
    subnetId: subnetId
    privateLinkServiceId: gatewayId
    groupIds: [
      'Gateway'
    ]
    privateDnsZoneIds: [
      dnsZone.id
    ]
  }
}

output dnsZoneName string = dnsZone.name
