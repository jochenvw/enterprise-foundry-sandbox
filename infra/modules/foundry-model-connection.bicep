// =============================================================================
// Admin-connected model connection: surfaces the centrally governed model into
// a team Foundry project via the APIM AI Gateway.
//
// Foundry represents a "Bring Your Own Model" / admin-connected model as a
// standard connection of category 'ApiManagement'. The connection points at the
// team's APIM route (base URL, no /deployments suffix); with
// metadata.deploymentInPath = 'true' the Agents service calls
//   {target}/deployments/{deploymentName}/chat/completions?api-version={ver}
// which matches the per-team Azure OpenAI passthrough surface exposed by the
// gateway. Auth uses the team's APIM subscription key, so every call still flows
// through that team's product (token limits + isolation).
// =============================================================================

@description('Team Foundry account name that hosts the project.')
param foundryAccountName string

@description('Team Foundry project name that receives the connection.')
param foundryProjectName string

@description('Connection name as it appears in the project.')
param connectionName string = 'apim-central-models'

@description('APIM service name (in the hub resource group).')
param apimName string

@description('Resource group that contains the APIM service (the hub RG).')
param apimResourceGroupName string

@description('APIM subscription name whose key authenticates this team (e.g. sub-team-a).')
param apimSubscriptionName string

@description('APIM gateway base URL, e.g. https://apim-ai-gw-swc-dev.azure-api.net.')
param apimGatewayUrl string

@description('Team key used in the gateway route, e.g. team-a.')
param teamName string

@description('Central model deployment name surfaced through the gateway.')
param centralDeploymentName string

@description('Underlying central model name (e.g. gpt-5-mini).')
param centralModelName string

@description('Central model version. Informational metadata only; empty is allowed.')
param centralModelVersion string = ''

@description('Model API contract used to shape inference requests/responses.')
@allowed([
  'OpenAI'
  'AzureOpenAI'
])
param modelFormat string = 'OpenAI'

@description('Inference API version appended to gateway calls (?api-version=...).')
param inferenceApiVersion string = '2024-10-21'

@description('Auth type for the connection. ApiKey uses the team APIM subscription key; ProjectManagedIdentity uses the project identity (requires APIM to accept Entra tokens).')
@allowed([
  'ApiKey'
  'ProjectManagedIdentity'
])
param authType string = 'ApiKey'

@description('Share the connection with all members of the project.')
param isSharedToAll bool = true

// Existing APIM subscription in the hub RG; its primary key authenticates the
// connection. Cross-resource-group reference via the scope property.
resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' existing = {
  name: '${apimName}/${apimSubscriptionName}'
  scope: resourceGroup(apimResourceGroupName)
}

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryAccountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: account
  name: foundryProjectName
}

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: connectionName
  properties: {
    category: 'ApiManagement'
    // Base URL only (clean team route). deploymentInPath = 'true' makes the
    // Agents service append /deployments/{name}/chat/completions, matching the
    // gateway operation /ai/{team}/deployments/{name}/chat/completions.
    target: '${apimGatewayUrl}/ai/${teamName}'
    authType: authType == 'ApiKey' ? 'ApiKey' : 'ManagedIdentity'
    isSharedToAll: isSharedToAll
    // ApiKey: the team APIM subscription key, sent as the 'api-key' header (which
    // the team product requires). ProjectManagedIdentity: no stored key.
    credentials: authType == 'ApiKey'
      ? {
          key: apimSubscription.listSecrets(apimSubscription.apiVersion).primaryKey
        }
      : {}
    metadata: {
      // Required for ApiManagement connections; selects URL-path routing.
      deploymentInPath: 'true'
      inferenceAPIVersion: inferenceApiVersion
      // Static model list so the deployment surfaces without live discovery.
      models: string([
        {
          name: centralDeploymentName
          properties: {
            model: {
              name: centralModelName
              version: centralModelVersion
              format: modelFormat
            }
          }
        }
      ])
    }
  }
}

output connectionName string = connection.name
output connectionId string = connection.id
