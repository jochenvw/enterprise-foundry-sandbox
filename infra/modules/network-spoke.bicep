// =============================================================================
// Spoke VNet (per team): dedicated Foundry agent subnet, private endpoints,
// team apps subnet. Each Foundry gets its OWN agent subnet (no sharing).
// =============================================================================

@description('Azure region.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('Spoke VNet name.')
param vnetName string

@description('Spoke VNet address space.')
param addressPrefix string

@description('Foundry agent runtime subnet prefix (third octet derived from VNet).')
param agentSubnetPrefix string

@description('Private endpoints subnet prefix.')
param privateEndpointsSubnetPrefix string

@description('Team apps subnet prefix.')
param teamAppsSubnetPrefix string

@description('Delegation service for the Foundry agent subnet. Foundry standard agent injection delegates to Microsoft.app/environments.')
param agentSubnetDelegation string = 'Microsoft.app/environments'

var agentSubnetName = 'snet-foundry-agents'
var privateEndpointsSubnetName = 'snet-private-endpoints'
var teamAppsSubnetName = 'snet-team-apps'

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
        name: agentSubnetName
        properties: {
          addressPrefix: agentSubnetPrefix
          delegations: [
            {
              name: 'foundry-agent-delegation'
              properties: {
                serviceName: agentSubnetDelegation
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
        name: teamAppsSubnetName
        properties: {
          addressPrefix: teamAppsSubnetPrefix
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output agentSubnetId string = vnet.properties.subnets[0].id
output privateEndpointsSubnetId string = vnet.properties.subnets[1].id
output teamAppsSubnetId string = vnet.properties.subnets[2].id
