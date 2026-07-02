// =============================================================================
// Reusable private endpoint + private DNS zone group.
// =============================================================================

@description('Azure region.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('Private endpoint name.')
param privateEndpointName string

@description('Subnet resource ID to place the private endpoint in.')
param subnetId string

@description('Resource ID of the service the private endpoint connects to.')
param privateLinkServiceId string

@description('Group IDs (subresources), e.g. ["blob"], ["Sql"], ["account"], ["searchService"], ["vault"], ["Gateway"].')
param groupIds array

@description('One or more private DNS zone resource IDs to register the private endpoint records in.')
param privateDnsZoneIds array

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-conn'
        properties: {
          privateLinkServiceId: privateLinkServiceId
          groupIds: groupIds
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      for (zoneId, i) in privateDnsZoneIds: {
        name: 'config-${i}'
        properties: {
          privateDnsZoneId: zoneId
        }
      }
    ]
  }
}

output privateEndpointId string = privateEndpoint.id
output privateEndpointName string = privateEndpoint.name
