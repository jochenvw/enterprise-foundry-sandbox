// =============================================================================
// Admin-connected model connection: surfaces the centrally governed model in a
// team Foundry project through the Azure AI Gateway.
//
// This is the same connection that the Foundry portal's "Add consuming project"
// creates on an AI Gateway (category ApiManagement, apimResourceKind AiGateway).
// The project signs in to the gateway with its own managed identity. That
// identity holds AI Gateway Models User on the team's alias only, so the
// project can call its governed alias and no other. Foundry shows the model as
// <connection name>/<alias>.
// =============================================================================

@description('Team Foundry account name that hosts the project.')
param foundryAccountName string

@description('Team Foundry project name that receives the connection.')
param foundryProjectName string

@description('Connection name. The Foundry portal uses <gateway>-model-gateway.')
param connectionName string

@description('AI Gateway resource ID.')
param gatewayId string

@description('AI Gateway runtime base URL, e.g. https://<name>.swedencentral-01.ai.gateway.azure.com.')
param gatewayUrl string

@description('AI Gateway region.')
param gatewayLocation string

@description('Team alias published by the gateway.')
param aliasName string

@description('Underlying central model name (e.g. gpt-5-mini).')
param centralModelName string

@description('Central model version. Informational metadata only; empty is allowed.')
param centralModelVersion string = ''

@description('Send the project\'s requests to the gateway\'s Responses API. When false, the gateway receives Chat Completions requests.')
param useResponsesApi bool = true

var gatewayIdParts = split(gatewayId, '/')

var gatewayResource = {
  id: gatewayId
  name: last(gatewayIdParts)
  gatewayUrl: gatewayUrl
  location: gatewayLocation
  subscriptionId: gatewayIdParts[2]
  resourceGroup: gatewayIdParts[4]
}

var models = [
  {
    name: aliasName
    properties: {
      model: {
        name: centralModelName
        version: centralModelVersion
        format: 'OpenAI'
      }
    }
  }
]

resource account 'Microsoft.CognitiveServices/accounts@2026-09-01' existing = {
  name: foundryAccountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2026-09-01' existing = {
  parent: account
  name: foundryProjectName
}

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-09-01' = {
  parent: project
  name: connectionName
  properties: {
    category: 'ApiManagement'
    target: '${gatewayUrl}/default/models/openai/v1'
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    audience: 'https://azure-api.net/aigateway'
    isSharedToAll: false
    // Metadata values are strings; apimResource and models are JSON documents.
    metadata: union(
      {
        apimResourceKind: 'AiGateway'
        apimResource: string(gatewayResource)
        deploymentInPath: 'false'
        inferenceAPIVersion: ''
        models: string(models)
      },
      useResponsesApi ? { upstreamSurface: 'responses' } : {}
    )
  }
}

output connectionName string = connection.name
output connectionId string = connection.id
output foundryModel string = '${connection.name}/${aliasName}'
