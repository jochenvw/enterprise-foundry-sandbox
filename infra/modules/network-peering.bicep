// =============================================================================
// VNet peering (one direction). Deploy twice (once per RG) for bidirectional.
// =============================================================================

@description('Name of the local (existing) VNet that owns this peering.')
param localVnetName string

@description('Resource ID of the remote VNet to peer with.')
param remoteVnetId string

@description('Peering name.')
param peeringName string

resource localVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: localVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: localVnet
  name: peeringName
  properties: {
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

output peeringId string = peering.id
