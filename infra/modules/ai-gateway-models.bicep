// =============================================================================
// Publishes the central Foundry deployment through the AI Gateway:
//   - one Foundry model provider that authenticates with the gateway identity
//   - one backend model registration for the central deployment
//   - one alias per team, each with its own token limit and optional content
//     safety. A team's runtime role is scoped to its alias only, which isolates
//     the teams.
// The gateway identity must already hold Foundry User on the central account
// (rbac-central.bicep).
// =============================================================================

@description('Existing AI Gateway name in this resource group.')
param gatewayName string

@description('Central Foundry account resource ID.')
param foundryAccountId string

@description('Central Foundry account endpoint, e.g. https://<name>.cognitiveservices.azure.com/.')
param foundryEndpoint string

@description('Central model deployment name.')
param deploymentName string

@description('Central model version, or empty.')
param modelVersion string = ''

@description('Model provider name in the gateway.')
param providerName string = 'foundry-central'

@description('Team identifiers. Each team gets the alias <team>-<deploymentName>.')
param teamNames array

@description('Per-team tokens per minute, aligned by index with teamNames.')
param teamTokenLimitsPerMinute array

@description('Apply the per-team tokenLimit policy on each alias.')
param enableTokenLimitPolicy bool = true

@description('Apply a contentSafety policy (Medium severity on all categories) on each alias.')
param enableContentSafetyPolicy bool = false

var normalizedEndpoint = endsWith(foundryEndpoint, '/') ? foundryEndpoint : '${foundryEndpoint}/'

var contentSafetyPolicy = {
  type: 'contentSafety'
  hateSeverity: 'Medium'
  selfHarmSeverity: 'Medium'
  sexualSeverity: 'Medium'
  violenceSeverity: 'Medium'
}

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
resource provider 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders@2026-11-01' = {
  parent: workspace
  name: providerName
  properties: {
    modelProviderType: 'Foundry'
    displayName: 'Central Foundry'
    description: 'Central platform Foundry account. The gateway calls it with its managed identity.'
    foundry: {
      endpoint: {
        url: normalizedEndpoint
      }
      resourceIds: [
        foundryAccountId
      ]
    }
    authentication: {
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com/'
      }
    }
  }
}

#disable-next-line BCP081
resource model 'Microsoft.ApiManagement/aigateways/workspaces/modelProviders/models@2026-11-01' = {
  parent: provider
  name: deploymentName
  properties: {
    displayName: deploymentName
    description: 'Central deployment ${deploymentName}.'
    supportedEndpoints: [
      '/openai/v1/chat/completions'
      '/openai/v1/responses'
    ]
    deployment: {
      resourceId: '${foundryAccountId}/deployments/${deploymentName}'
      modelName: deploymentName
      modelVersion: empty(modelVersion) ? null : modelVersion
    }
  }
}

#disable-next-line BCP081
resource aliases 'Microsoft.ApiManagement/aigateways/workspaces/aliases@2026-11-01' = [
  for (team, i) in teamNames: {
    parent: workspace
    name: '${team}-${deploymentName}'
    properties: {
      backendModels: [
        { resourceId: model.id }
      ]
      policies: concat(
        enableTokenLimitPolicy
          ? [
              {
                type: 'tokenLimit'
                count: teamTokenLimitsPerMinute[i]
                period: 'minute'
                counterKey: [
                  'identity'
                ]
              }
            ]
          : [],
        enableContentSafetyPolicy ? [contentSafetyPolicy] : []
      )
    }
  }
]

output providerName string = provider.name
output modelName string = model.name
output aliasNames array = [for (team, i) in teamNames: aliases[i].name]
