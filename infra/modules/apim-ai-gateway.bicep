// =============================================================================
// APIM Standard v2 AI Gateway (hub): backend to central Foundry, per-team
// products/APIs/subscriptions, AI gateway policies, diagnostics, inbound PE.
// =============================================================================

@description('Azure region.')
param location string

@description('Tags to apply.')
param tags object = {}

@description('APIM service name.')
param apimName string

@description('Publisher email for APIM.')
param publisherEmail string = 'platform-team@contoso.com'

@description('Publisher organization name for APIM.')
param publisherName string = 'Enterprise Platform Team'

@description('APIM outbound integration subnet ID (delegated to Microsoft.Web/serverFarms).')
param apimSubnetId string

@description('Private endpoints subnet ID (hub) for the inbound gateway PE.')
param privateEndpointsSubnetId string

@description('APIM (azure-api.net) private DNS zone ID.')
param apimPrivateDnsZoneId string

@description('Deploy the inbound private endpoint for the gateway.')
param deployPrivateEndpoints bool = true

@description('Log Analytics workspace ID for diagnostics.')
param logAnalyticsWorkspaceId string

@description('Application Insights resource ID.')
param appInsightsId string

@description('Application Insights connection string.')
@secure()
param appInsightsConnectionString string

@description('Central Foundry OpenAI base URL, e.g. https://<account>.openai.azure.com.')
param centralOpenAiBaseUrl string

@description('Central model deployment name.')
param centralDeploymentName string

@description('Azure OpenAI inference API version.')
param openAiApiVersion string = '2024-10-21'

@description('Team keys, e.g. ["team-a","team-b"].')
param teamNames array

@description('Per-team tokens-per-minute limits, aligned by index with teamNames.')
param teamTokenLimitsPerMinute array = [
  1000
  1000
]

@description('Apply the azure-openai-token-limit policy per team.')
param enableTokenLimitPolicy bool = true

@description('Emit token metrics via azure-openai-emit-token-metric.')
param enableTokenMetricPolicy bool = true

@description('Log prompt/response bodies in APIM. Off by default.')
param enablePromptBodyLogging bool = false

@description('Enable the llm-content-safety policy (requires content-safety-backend).')
param enableContentSafetyPolicy bool = false

@description('Deploy a new APIM service. When false, an existing (BYO) APIM named apimName is used and only its AI-gateway configuration (products/APIs/policies) is authored.')
param deployApim bool = true

@description('APIM SKU name. Must be a v2 tier (native AI Gateway requirement). StandardV2 is required for VNet integration + inbound private endpoint.')
@allowed([
  'BasicV2'
  'StandardV2'
  'PremiumV2'
])
param apimSkuName string = 'StandardV2'

var contentSafetyFragment = enableContentSafetyPolicy ? loadTextContent('../policies/content-safety-fragment.xml') : ''
var teamApiPolicyTemplate = loadTextContent('../policies/team-api-policy.xml')

// -----------------------------------------------------------------------------
// APIM service (v2). Deployed only when deployApim=true; otherwise a BYO existing
// APIM (apimName) is referenced and we author the AI-gateway config onto it.
// -----------------------------------------------------------------------------

resource apimDeployed 'Microsoft.ApiManagement/service@2024-06-01-preview' = if (deployApim) {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: apimSkuName
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    // v2 outbound VNet integration into the delegated hub subnet.
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnetId
    }
    // Public access stays enabled so the operator AND the Foundry agent service can
    // reach the gateway out-of-the-box; access is gated by subscription keys. For a
    // fully private posture, disable public access via the documented post-deploy step.
    publicNetworkAccess: 'Enabled'
  }
}

// Single symbolic reference used as the parent for all gateway configuration,
// whether the service is freshly deployed (above) or brought by the customer (BYO).
resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

// -----------------------------------------------------------------------------
// Named values (runtime configuration referenced by policies)
// -----------------------------------------------------------------------------

resource nvBaseUrl 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'central-foundry-base-url'
  dependsOn: [ apimDeployed ]
  properties: {
    displayName: 'central-foundry-base-url'
    value: centralOpenAiBaseUrl
  }
}

resource nvDeployment 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'central-deployment'
  dependsOn: [ apimDeployed ]
  properties: {
    displayName: 'central-deployment'
    value: centralDeploymentName
  }
}

resource nvApiVersion 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'openai-api-version'
  dependsOn: [ apimDeployed ]
  properties: {
    displayName: 'openai-api-version'
    value: openAiApiVersion
  }
}

resource nvPromptLogging 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'enable-prompt-logging'
  dependsOn: [ apimDeployed ]
  properties: {
    displayName: 'enable-prompt-logging'
    value: toLower(string(enablePromptBodyLogging))
  }
}

// -----------------------------------------------------------------------------
// Backend -> central Foundry
// -----------------------------------------------------------------------------

resource backend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'central-foundry'
  dependsOn: [ apimDeployed ]
  properties: {
    title: 'Central Foundry model endpoint'
    url: '${centralOpenAiBaseUrl}/openai'
    protocol: 'http'
  }
}

// -----------------------------------------------------------------------------
// Application Insights logger + service diagnostic
// -----------------------------------------------------------------------------

resource logger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = {
  parent: apim
  name: 'appinsights'
  dependsOn: [ apimDeployed ]
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for the AI gateway.'
    resourceId: appInsightsId
    credentials: {
      connectionString: appInsightsConnectionString
    }
  }
}

resource serviceDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2024-06-01-preview' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: logger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    verbosity: 'information'
  }
}

resource apimDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: apim
  dependsOn: [ apimDeployed ]
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Per-team products, APIs, operations, subscriptions, policies
// -----------------------------------------------------------------------------

resource products 'Microsoft.ApiManagement/service/products@2024-06-01-preview' = [
  for team in teamNames: {
    parent: apim
    name: team
    dependsOn: [ apimDeployed ]
    properties: {
      displayName: 'Team ${team}'
      description: 'Inference product scoped to ${team}. Cannot access other team APIs.'
      subscriptionRequired: true
      approvalRequired: false
      state: 'published'
    }
  }
]

resource apis 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = [
  for team in teamNames: {
    parent: apim
    name: '${team}-inference'
    dependsOn: [ apimDeployed ]
    properties: {
      displayName: 'Team ${team} Inference'
      path: 'ai/${team}'
      protocols: [
        'https'
      ]
      subscriptionRequired: true
      apiType: 'http'
      // Accept the APIM subscription key via the `api-key` header so that a
      // standard Azure OpenAI / Foundry connection (which sends `api-key`)
      // authenticates to the gateway without any custom header wiring.
      subscriptionKeyParameterNames: {
        header: 'api-key'
        query: 'api-key'
      }
    }
  }
]

// Clean, provider-agnostic team surface. The /openai segment is added by the
// policy's backend base URL, so teams call /ai/{team}/deployments/{name}/...
resource opChat 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = [
  for (team, i) in teamNames: {
    parent: apis[i]
    name: 'chat-completions'
    properties: {
      displayName: 'Chat Completions'
      method: 'POST'
      urlTemplate: '/deployments/{deploymentName}/chat/completions'
      templateParameters: [
        {
          name: 'deploymentName'
          description: 'Model deployment name surfaced by the gateway.'
          type: 'string'
          required: true
        }
      ]
    }
  }
]

// Link each product to its team API.
resource productApis 'Microsoft.ApiManagement/service/products/apiLinks@2024-06-01-preview' = [
  for (team, i) in teamNames: {
    parent: products[i]
    name: '${team}-inference-link'
    properties: {
      apiId: apis[i].id
    }
  }
]

// Per-team subscription scoped to that team's product only (team isolation).
resource subscriptions 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = [
  for (team, i) in teamNames: {
    parent: apim
    name: 'sub-${team}'
    properties: {
      displayName: 'Subscription ${team}'
      scope: products[i].id
      state: 'active'
      allowTracing: false
    }
  }
]

// API-scoped policy (routing, deployment guard, token limit, metrics, logging, optional content safety).
resource apiPolicies 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = [
  for (team, i) in teamNames: {
    parent: apis[i]
    name: 'policy'
    properties: {
      format: 'rawxml'
      value: replace(
        replace(
          replace(
            replace(teamApiPolicyTemplate, '{TEAM_NAME}', team),
            '{TOKEN_LIMIT_POLICY}',
            enableTokenLimitPolicy
              ? '<azure-openai-token-limit counter-key="${team}" tokens-per-minute="${string(teamTokenLimitsPerMinute[i])}" estimate-prompt-tokens="true" remaining-tokens-variable-name="remainingTokens" />'
              : ''
          ),
          '{TOKEN_METRIC_POLICY}',
          enableTokenMetricPolicy
            ? '<azure-openai-emit-token-metric namespace="enterprise-foundry"><dimension name="team" value="${team}" /><dimension name="environment" value="@(context.Deployment.ServiceName)" /><dimension name="apiName" value="@(context.Api.Name)" /><dimension name="operationName" value="@(context.Operation.Name)" /></azure-openai-emit-token-metric>'
            : ''
        ),
        '{CONTENT_SAFETY}',
        contentSafetyFragment
      )
    }
    dependsOn: [
      nvBaseUrl
      nvDeployment
      nvApiVersion
      nvPromptLogging
      backend
      opChat
    ]
  }
]

// -----------------------------------------------------------------------------
// Inbound private endpoint (Gateway subresource)
// -----------------------------------------------------------------------------

// Inbound private endpoint only for a freshly deployed APIM; a BYO APIM keeps its
// own (customer-managed) networking.
module pe 'private-endpoint.bicep' = if (deployApim && deployPrivateEndpoints) {
  name: 'pe-apim-gateway'
  params: {
    location: location
    tags: tags
    privateEndpointName: 'pe-${apimName}-gateway'
    subnetId: privateEndpointsSubnetId
    privateLinkServiceId: apim.id
    groupIds: [
      'Gateway'
    ]
    privateDnsZoneIds: [
      apimPrivateDnsZoneId
    ]
  }
  dependsOn: [
    apimDeployed
  ]
}

output apimId string = apim.id
output apimName string = apim.name
output apimPrincipalId string = deployApim ? apimDeployed!.identity.principalId : apim.identity.principalId
output gatewayUrl string = apim.properties.gatewayUrl
