// =============================================================================
// Private DNS zones (hub RG) + VNet links to hub and both spokes.
// Add zones by extending the zoneNames parameter - links are created for all.
// =============================================================================

@description('Private DNS zone names to create.')
param zoneNames array

@description('VNet IDs to link every zone to (hub + spokes).')
param linkedVnetIds array

@description('Tags to apply.')
param tags object = {}

var vnetCount = length(linkedVnetIds)

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zone in zoneNames: {
    name: zone
    location: 'global'
    tags: tags
  }
]

// Flattened cross product: index i maps to (zone = i / vnetCount, vnet = i % vnetCount).
resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for i in range(0, length(zoneNames) * vnetCount): {
    name: '${zoneNames[i / vnetCount]}/link-${uniqueString(linkedVnetIds[i % vnetCount])}'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: linkedVnetIds[i % vnetCount]
      }
    }
    dependsOn: [
      zones
    ]
  }
]

output zoneNames array = zoneNames
output zoneIds array = [for (zone, i) in zoneNames: zones[i].id]
