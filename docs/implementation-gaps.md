# Implementation gaps

These are the remaining provisioning and verification boundaries, rechecked on
2026-11-25. Azure AI Gateway is GA; specific networking and Foundry integration features
remain preview. Supported opt-ins and normal implementation choices are not API gaps.

## 1. Foundry project → AI Gateway model connection

**Templated, preview feature.** Each team project's admin-connected model
connection is created by `infra/modules/foundry-model-connection.bicep`. It mirrors the
connection the Foundry portal's "Add consuming project" creates: `category:
'ApiManagement'` with `metadata.apimResourceKind: 'AiGateway'`, `authType:
'ProjectManagedIdentity'`, audience `https://azure-api.net/aigateway`, target
`<gatewayUrl>/default/models/openai/v1`, a static `models` list with the team alias, and
`upstreamSurface: 'responses'` when `useResponsesApiUpstream=true`. Foundry shows the
model as `<connection>/<alias>`. `scripts/postdeploy-foundry-connections.sh` is a
read-only verifier and `scripts/test-foundry-project-through-gateway.sh` exercises the
path end to end.

**Boundary:** Foundry prompt-agent model connections remain preview, independently of
the gateway's GA status. The `authType` value is not yet in the Bicep type index
(`BCP036` is suppressed).

## 2. AI Gateway inbound private endpoint

**Gap:** Private Link remains preview. The inbound endpoint (`groupId: 'Gateway'`) requires the gated
subscription feature `Microsoft.Network/AllowPrivateEndpoints`, which is not registered
in this sandbox's subscription. Creation fails with `SubscriptionNotRegisteredForFeature`.

**Compensation:** `deployAiGatewayPrivateEndpoint` defaults to `false`, so gateway ingress
is public and protected by Entra ID plus alias-scoped RBAC (no API keys). Once the
feature is registered, set it to `true`: `infra/modules/ai-gateway-private-endpoint.bicep`
creates the endpoint and a private DNS zone named after the gateway host minus its first
label (e.g. `privatelink.swedencentral-01.ai.gateway.azure.com`), linked to the hub and
both spokes.

## 3. Foundry agent setup transition

**Existing setup retained.** `enableAgentNetworkInjection` defaults to `true`.
Each team Foundry account is injected into its spoke's dedicated agent subnet (delegated to
`Microsoft.App/environments`), and `infra/modules/foundry-team-agent.bicep` wires the team's
BYO data into the project as standard-agent connections — Cosmos DB (thread store), Storage
(file store), and AI Search (vector store), all AAD-auth — and creates the project
**capability host** (`capabilityHosts@2026-09-01`). The stable project capability-host
schema has no `capabilityHostKind` property. The module also
grants the **project** managed identity the roles the agent runtime and capability host
require (Storage Blob Data Contributor, Search Index/Service roles, Cosmos data-plane role,
and the control-plane **Cosmos DB Operator** role that must exist before the capability host
is created).

Current [standard-agent guidance](https://learn.microsoft.com/azure/foundry/agents/concepts/standard-agent-setup)
favors **capability settings** using BYO resource IDs; the
[capability-host article](https://learn.microsoft.com/azure/foundry/agents/concepts/capability-hosts)
is retained for reference. Account/project capability-settings fields are absent from
the published stable `2026-09-01` Bicep schemas. Project store settings cannot be changed
in place; switching them requires project recreation. This cleanup therefore does not
invent ARM fields or delete/recreate the working projects. A migration needs a verified
API/schema and an explicit data/project transition plan.

This repository has no hosted-agent source or pre-retirement hosted-agent deployment
to migrate. The model-routing tests do not validate a complete agent runtime or its
latest storage/identity lifecycle.

**Note (two-phase reliability):** the Microsoft foundry-samples reference deploys the project
capability host as a separate phase after the account, because capability-host
provisioning can be timing-sensitive. Here it is expressed inline with explicit `dependsOn`
ordering. If a capability-host create intermittently fails on first deployment, set
`deployAgentCapabilityHost=false`, deploy, then re-run with it `true` — the BYO connections and
role assignments are created either way, so only the capability host is deferred.

**Note (gateway egress):** network-injected agent runtimes in the spokes call the
AI Gateway's public endpoint (unless its inbound private endpoint is deployed). Outbound
access from the agent subnets to the gateway is expected but not verified in this
sandbox.

## 4. AI Gateway telemetry

**Gap:** The AI Gateway has no diagnostic settings for Log Analytics. Its OpenTelemetry
exporter (`aigateways/workspaces/telemetryExporters`) needs Application Insights OTLP
ingestion and **Monitoring Metrics Publisher** on a managed data collection rule, which
appear asynchronously after ingestion is enabled. The managed resource group's deny
assignment also prevents the usual Bicep role deployment. Gateway token metrics and request logs
therefore do not reach Log Analytics.

**Compensation:** The exporter itself is supported declaratively. Follow the
[official enterprise telemetry workflow](https://github.com/Azure/aigateway/tree/main/labs/21-enterprise-reference):
enable Application Insights OTLP ingestion, wait for its endpoints/DCR, grant the gateway
identity Monitoring Metrics Publisher on that DCR, then deploy the OpenTelemetry exporter
with payload capture disabled. This is an asynchronous post-deployment integration,
not an unsupported exporter feature. Central Foundry
diagnostics are configured, but visibility of gateway-identity calls and request-level
correlation have not been confirmed; do not rely on them as a substitute for gateway
telemetry.

## Supported opt-ins

Content safety is supported with the policy shape already in
`infra/modules/ai-gateway-models.bicep`; see the
[official policy sample](https://github.com/Azure/aigateway/blob/main/labs/08-content-safety/infra/safe-alias.bicep).
`enableContentSafetyPolicy=false` is an intentional default, not an API limitation.
When enabled, it screens prompts and responses at Medium severity across hate,
self-harm, sexual, and violence categories. Its enforcement is not exercised by the
default inference tests.
