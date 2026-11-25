# Implementation gaps

This file documents anything not fully automated in Bicep because of current API or
platform limitations, and how it is compensated. It exists even when there is nothing to
report.

> Status: There are a small number of documented gaps below, each compensated with a
> default or a clearly described manual step. Azure AI Gateway itself is in public
> preview with no SLA. The Bicep template itself compiles with
> `az bicep build` and validates with `az deployment sub validate`.

## 1. Foundry project → AI Gateway model connection

**Resolved (templated), emerging capability.** Each team project's admin-connected model
connection is created by `infra/modules/foundry-model-connection.bicep`. It mirrors the
connection the Foundry portal's "Add consuming project" creates: `category:
'ApiManagement'` with `metadata.apimResourceKind: 'AiGateway'`, `authType:
'ProjectManagedIdentity'`, audience `https://azure-api.net/aigateway`, target
`<gatewayUrl>/default/models/openai/v1`, a static `models` list with the team alias, and
`upstreamSurface: 'responses'` when `useResponsesApiUpstream=true`. Foundry shows the
model as `<connection>/<alias>`. `scripts/postdeploy-foundry-connections.sh` is a
read-only verifier and `scripts/test-foundry-project-through-gateway.sh` exercises the
path end to end.

**Note:** Foundry → AI Gateway connections are new; the metadata shape may change while
both services are in preview. The `authType` value is not yet in the Bicep type index
(`BCP036` is suppressed).

## 2. AI Gateway inbound private endpoint

**Gap:** The inbound private endpoint (`groupId: 'Gateway'`) requires the gated
subscription feature `Microsoft.Network/AllowPrivateEndpoints`, which is not registered
in this sandbox's subscription. Creation fails with `SubscriptionNotRegisteredForFeature`.

**Compensation:** `deployAiGatewayPrivateEndpoint` defaults to `false`, so gateway ingress
is public and protected by Entra ID plus alias-scoped RBAC (no API keys). Once the
feature is registered, set it to `true`: `infra/modules/ai-gateway-private-endpoint.bicep`
creates the endpoint and a private DNS zone named after the gateway host minus its first
label (e.g. `privatelink.swedencentral-01.ai.gateway.azure.com`), linked to the hub and
both spokes.

## 3. AI Gateway content safety policy

**Gap:** The alias `contentSafety` policy is still aligning with API `2026-11-01`.

**Compensation:** `enableContentSafetyPolicy` defaults to `false`. When `true`, each team
alias gets a `contentSafety` policy with Medium severity on all categories
(`infra/modules/ai-gateway-models.bicep`). Validate it in your subscription before
relying on it.

## 4. Reusable diagnostics module vs inline diagnostic settings

**Gap:** A single generic `modules/diagnostics.bicep` that attaches a diagnostic setting
to an arbitrary resource by `resourceId` is not achievable in Bicep, because diagnostic
settings are **extension resources** that require a typed symbolic `scope`, not a string
resource ID.

**Compensation:** Diagnostic settings are defined **inline** within each resource module
using explicit, per-resource category arrays (`categoryGroup: allLogs` + relevant
metrics). This is the approach the instructions explicitly permit ("define per-resource
category arrays carefully in the calling modules") and guarantees only valid categories
are used. Resources covered: the central Foundry to the central Log Analytics workspace;
each team Foundry account plus Storage (blob service), Cosmos DB, AI Search,
and Key Vault to that team's Log Analytics workspace. The AI Gateway has no diagnostic
settings (see gap 7).

## 5. Model version selection

**Note:** `centralModelVersion` defaults to the verified concrete version `2025-08-07`.
`scripts/check-model-availability.sh` checks the configured model, version and SKU
against the regional AIServices catalog before deployment. If explicitly using `latest`,
the preflight checks the catalog's default version; use a concrete version if the
deployment API rejects that alias. Quota and capacity are still deployment-time checks.

## 6. Foundry agent network injection

**Resolved (templated, default on).** `enableAgentNetworkInjection` now defaults to `true`.
Each team Foundry account is injected into its spoke's dedicated agent subnet (delegated to
`Microsoft.app/environments`), and `infra/modules/foundry-team-agent.bicep` wires the team's
BYO data into the project as standard-agent connections — Cosmos DB (thread store), Storage
(file store), and AI Search (vector store), all AAD-auth — and creates the project
**capability host** (`capabilityHosts@2026-09-01`). The stable project capability-host
schema has no `capabilityHostKind` property. The module also
grants the **project** managed identity the roles the agent runtime and capability host
require (Storage Blob Data Contributor, Search Index/Service roles, Cosmos data-plane role,
and the control-plane **Cosmos DB Operator** role that must exist before the capability host
is created).

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

## 7. AI Gateway telemetry

**Gap:** The AI Gateway has no diagnostic settings for Log Analytics. Its OpenTelemetry
exporter (`aigateways/workspaces/telemetryExporters`) needs Application Insights OTLP
ingestion and **Monitoring Metrics Publisher** on a managed data collection rule, which
cannot be wired reliably in this template today. Gateway token metrics and request logs
therefore do not reach Log Analytics.

**Compensation:** Configure the exporter manually after deployment, following the
[AI gateway documentation](https://learn.microsoft.com/azure/api-management/) and the
[Azure/ai-gateway samples](https://github.com/Azure/ai-gateway). Central Foundry
diagnostics are configured, but visibility of gateway-identity calls and request-level
correlation have not been confirmed; do not rely on them as a substitute for gateway
telemetry.

## 8. Token limits are per caller identity

**Note:** Each alias's `tokenLimit` policy uses `counterKey: identity`, so the limit
applies per caller identity per alias. Every identity granted a team alias gets that
team's full budget. The template grants each alias to one project identity (plus the
optional test principal on the Team A alias), which approximates a per-team budget.

## 9. `publicIpOnly` network mode and the gateway

**Gap:** In `publicIpOnly` mode there is no central Foundry private endpoint. The gateway
egresses from its hub VNet integration, which is not on central Foundry's IP allowlist,
so gateway calls to the central model are blocked.

**Compensation:** Use `hybridPePlusIp` (default) or `privateOnly`.
