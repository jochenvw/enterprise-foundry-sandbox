// =============================================================================
// Hub VNet: APIM outbound subnet (delegated), private endpoints, shared services
// =============================================================================

@description('Azure region.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('Hub VNet name.')
param vnetName string

@description('Hub VNet address space.')
param addressPrefix string = '10.10.0.0/16'

@description('APIM outbound integration subnet prefix. Delegated to Microsoft.Web/serverFarms (required by APIM Standard v2).')
param apimSubnetPrefix string = '10.10.1.0/24'

@description('Private endpoints subnet prefix.')
param privateEndpointsSubnetPrefix string = '10.10.2.0/24'

@description('Shared services subnet prefix.')
param sharedServicesSubnetPrefix string = '10.10.3.0/24'

var apimSubnetName = 'snet-apim-outbound'
var privateEndpointsSubnetName = 'snet-private-endpoints'
var sharedServicesSubnetName = 'snet-shared-services'

// APIM (Standard v2) VNet integration requires the outbound subnet to be
// associated with an NSG. These rules follow the documented minimum for the
// Standard v2 (workspace/stv2) gateway. See https://aka.ms/apimvnet
resource apimNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${apimSubnetName}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowApimManagement'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3443'
          sourceAddressPrefix: 'ApiManagement'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '6390'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
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
        // APIM Standard v2 outbound VNet integration requires delegation to
        // Microsoft.Web/serverFarms. The subnet must not host other resources.
        name: apimSubnetName
        properties: {
          addressPrefix: apimSubnetPrefix
          networkSecurityGroup: {
            id: apimNsg.id
          }
          delegations: [
            {
              name: 'apim-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
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
output apimSubnetId string = vnet.properties.subnets[0].id
output privateEndpointsSubnetId string = vnet.properties.subnets[1].id
output sharedServicesSubnetId string = vnet.properties.subnets[2].id
