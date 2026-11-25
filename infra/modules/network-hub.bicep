// =============================================================================
// Hub VNet: AI Gateway integration subnet (delegated), private endpoints,
// shared services
// =============================================================================

@description('Azure region.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('Hub VNet name.')
param vnetName string

@description('Hub VNet address space.')
param addressPrefix string = '10.10.0.0/16'

@description('AI Gateway outbound integration subnet prefix (/27 minimum). Delegated to Microsoft.App/environments and dedicated to the gateway.')
param aiGatewaySubnetPrefix string = '10.10.1.0/24'

@description('Private endpoints subnet prefix.')
param privateEndpointsSubnetPrefix string = '10.10.2.0/24'

@description('Shared services subnet prefix.')
param sharedServicesSubnetPrefix string = '10.10.3.0/24'

var aiGatewaySubnetName = 'snet-aigw-integration'
var privateEndpointsSubnetName = 'snet-private-endpoints'
var sharedServicesSubnetName = 'snet-shared-services'

// AI Gateway VNet integration requires an NSG on the subnet but no custom rules:
// the gateway reaches backends over TCP 443 inside the virtual network.
resource aiGatewayNsg 'Microsoft.Network/networkSecurityGroups@2026-03-01' = {
  name: '${aiGatewaySubnetName}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2026-03-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: aiGatewaySubnetName
        properties: {
          addressPrefix: aiGatewaySubnetPrefix
          networkSecurityGroup: {
            id: aiGatewayNsg.id
          }
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: privateEndpointsSubnetName
        properties: {
          addressPrefix: privateEndpointsSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: sharedServicesSubnetName
        properties: {
          addressPrefix: sharedServicesSubnetPrefix
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output aiGatewaySubnetId string = vnet.properties.subnets[0].id
output privateEndpointsSubnetId string = vnet.properties.subnets[1].id
output sharedServicesSubnetId string = vnet.properties.subnets[2].id
