# Azure AI Gateway for Microsoft Foundry

This document explains how the repository governs model access with the standalone
**Azure AI Gateway** (`Microsoft.ApiManagement/aigateways`, API `2026-11-01`). Everything
on the routing path — gateway, model provider, per-team aliases and policies, alias-scoped
RBAC, and the team project connections — is deployed by Bicep. There are no API keys,
policy XML files, or post-deploy portal steps.

> **GA service, feature-specific previews.** Azure AI Gateway became generally available
> on November 17, 2026. Private Link, VNet integration, and Foundry prompt-agent model
> connections remain preview. The Bicep type index does not list `2026-11-01` yet, so
> the modules suppress `BCP081`, as official samples do. See the
> [GA announcement](https://techcommunity.microsoft.com/blog/IntegrationsonAzureBlog/azure-ai-gateway-is-now-generally-available-ship-faster-stay-in-control/4572644),
> [documentation](https://aka.ms/aigateway/docs), and [samples](https://github.com/Azure/aigateway).

## How it works

1. **One gateway in the hub.** `aigw-<prefix>-<suffix>-<unique>` (max 24 characters) is
   deployed in the hub resource group (`infra/modules/ai-gateway.bicep`) with a
   system-assigned managed identity. Outbound **VNet integration** places it in
   `snet-aigw-integration`, so its calls to central Foundry use the central private
   endpoint and the hub's private DNS zones.

2. **The gateway is the sanctioned team route to the central model.** Its identity holds
   **Foundry User** on the central Foundry account (`infra/modules/rbac-central.bicep`).
   Teams get no role there.

3. **The central deployment is published once.** `infra/modules/ai-gateway-models.bicep`
   creates a Foundry model provider (`foundry-central`, managed-identity auth) and a
   model registration for the central deployment that supports
   `/openai/v1/chat/completions` and `/openai/v1/responses`.

4. **Each team gets its own alias.** The alias name is `<team>-<deploymentName>`, for
   example `team-a-enterprise-gpt5-mini`. Each alias carries:
   - a `tokenLimit` policy (tokens per minute from `teamTokenLimitsPerMinute`,
     `counterKey: identity`), and
   - an optional, supported `contentSafety` policy (`enableContentSafetyPolicy`,
     off by default), screening prompts and responses at Medium severity in all
     four harm categories.

5. **Team isolation is alias-scoped RBAC.** `infra/modules/ai-gateway-alias-role.bicep`
   grants **AI Gateway Models User** on **one alias**. Each team project's managed
   identity gets its own alias only, so a call to another team's alias returns
   `401`/`403`. Raw deployment names and unpublished models are not routed.

6. **Team projects consume the alias through a connection.**
   `infra/modules/foundry-model-connection.bicep` creates the same connection that the
   Foundry portal's "Add consuming project" creates:

   | Property | Value |
   | --- | --- |
   | Name | `<gateway>-model-gateway` |
   | Category | `ApiManagement` (metadata `apimResourceKind: AiGateway`) |
   | Auth | `ProjectManagedIdentity`, audience `https://azure-api.net/aigateway` |
   | Target | `<gatewayUrl>/default/models/openai/v1` |
   | Models | the team alias (static list) |
   | Upstream | `upstreamSurface: responses` when `useResponsesApiUpstream=true` |

   Foundry shows the model as `<connection>/<alias>`
   (outputs `teamAFoundryModel` / `teamBFoundryModel`).

7. **Ingress is public, Entra ID only.** The gateway endpoint is public; no API keys are
   created. AI Gateway API keys (`aigateways/apiKeys`) are gateway-wide rather than
   per team, so they would break team isolation and are intentionally unused. An inbound
   private endpoint is optional (`deployAiGatewayPrivateEndpoint`, see
   [Caveats](#caveats)).

## Calling the gateway

```text
POST https://<gateway-host>/default/models/openai/v1/chat/completions
POST https://<gateway-host>/default/models/openai/v1/responses
Authorization: Bearer <Entra token for https://ai.gateway.azure.com>

{ "model": "team-a-enterprise-gpt5-mini", ... }
```

`https://azure-api.net/aigateway` is also accepted as the token audience. No
`api-version` is needed. For an OpenAI client, set `base_url` to the
`aiGatewayModelsEndpoint` output and pass the Entra token as the API key / bearer token.

```bash
TOKEN=$(az account get-access-token --resource https://ai.gateway.azure.com --query accessToken -o tsv)
curl -sS "$(az deployment sub show -n enterprise-foundry --query properties.outputs.aiGatewayModelsEndpoint.value -o tsv)/responses" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"team-a-enterprise-gpt5-mini","input":"hello","max_output_tokens":64}'
```

Through a team Foundry project, call `<project-endpoint>/openai/v1/responses` with an
Entra token for `https://ai.azure.com` and `"model": "<connection>/<alias>"`.

## Architecture

```mermaid
flowchart LR
    subgraph HUB["Hub"]
        AIGW["Azure AI Gateway\naliases: team-a-*, team-b-*"]
        CF["Central Foundry\nenterprise-gpt5-mini"]
    end

    subgraph TEAM_A["Team A"]
        TAP["Team A project\nMI: Models User on team-a alias"]
    end

    subgraph TEAM_B["Team B"]
        TBP["Team B project\nMI: Models User on team-b alias"]
    end

    TAP -->|connection, Entra ID| AIGW
    TBP -->|connection, Entra ID| AIGW
    AIGW -->|VNet integration + PE\nMI: Foundry User| CF
```

## Related parameters

| Parameter | Purpose | Default |
| --- | --- | --- |
| `teamTokenLimitsPerMinute` | TPM per caller identity on each alias (aligned with `teamNames`) | `[20000, 20000]` |
| `enableTokenLimitPolicy` | Apply the `tokenLimit` policy | `true` |
| `enableContentSafetyPolicy` | Apply a `contentSafety` policy (Medium, all categories) | `false` |
| `useResponsesApiUpstream` | Project connections send Responses API requests (false = Chat Completions) | `true` |
| `deployAiGatewayPrivateEndpoint` | Inbound private endpoint + DNS zone (gated feature) | `false` |
| `gatewayTestPrincipalId` / `gatewayTestPrincipalType` | Test identity: Models User on the first team alias + Foundry User on that team's account | `''` / `User` |
| `networkAccessMode` | Data-plane posture (`hybridPePlusIp` \| `privateOnly`), always with private endpoints | `hybridPePlusIp` |

## Tests

`./scripts/test-model-through-gateway.sh` runs all of these:

| Script | Asserts |
| --- | --- |
| `scripts/test-gateway-health.sh` | Unauthenticated call → `401`/`403` |
| `scripts/test-gateway-inference.sh` | Team A alias, Chat Completions and Responses → `200` |
| `scripts/test-team-isolation.sh` | Team B alias → `401`/`403`; raw deployment name / unpublished model → `4xx` |
| `scripts/test-foundry-project-through-gateway.sh` | Team A project, `<connection>/<alias>` via Responses → `200` |
| `scripts/test-agent-through-gateway.sh` | Creates/keeps prompt agent `team-a-demo-agent` (model `<connection>/<alias>`) and runs one turn → `completed` |
| `scripts/test-end-to-end-trace.sh` | Runs the agent with a known trace ID; that ID appears in Team A App Insights (agent spans) and platform App Insights (gateway spans) |
| `scripts/test-direct-central-foundry-blocked.sh` | Team account/project identities have no central roles, including inherited/group assignments; operator's direct v1 call is informational |

`deploy.sh` passes the signed-in identity as `gatewayTestPrincipalId` (set
`SKIP_TEST_PRINCIPAL=1` to skip). Positive checks retry on `401`/`403`
(`RETRY_ATTEMPTS`, `RETRY_DELAY`) while new role assignments propagate.

## Caveats

- **Networking and Foundry connections remain preview**, although the gateway service is GA.
  Review feature terms and current pricing rather than assuming a blanket preview/no-SLA status.
- **Foundry portal reachability is separate from gateway access.** The operator IP
  allowlist covers Foundry and connected data endpoints, not gateway ingress.
  `scripts/test-demo-access.sh` checks the current shell's network path; see
  [`demo-access.md`](demo-access.md) for live-demo preparation and policy-exemption
  limits.
- **Inbound private endpoint is gated.** It needs the subscription feature
  `Microsoft.Network/AllowPrivateEndpoints`; without it, creation fails with
  `SubscriptionNotRegisteredForFeature`. When enabled, the module creates a
  `Gateway` private endpoint and a zone named after the host minus its first label
  (for example `privatelink.swedencentral-01.ai.gateway.azure.com`), linked to the hub
  and both spokes.
- **Telemetry is OpenTelemetry, not diagnostic settings.** The gateway has no diagnostic
  settings. `deploy.sh` runs `scripts/postdeploy-gateway-telemetry.sh`, which waits for
  the platform Application Insights OTLP endpoints and data collection rule (DCR), grants
  the gateway identity Monitoring Metrics Publisher on that DCR, and deploys
  `infra/modules/ai-gateway-telemetry.bicep` (`workspaces/telemetryExporters`, payload
  capture off). A deny assignment on the managed DCR resource group prevents doing this
  inside the main template. Set `SKIP_GATEWAY_TELEMETRY=1` to skip. Spans land in
  `OTelSpans`/`OTelLogs` in the central Log Analytics workspace and on the Monitoring page
  of the [AI Gateway portal](https://ai.gateway.azure.com).
- **Token limits are per caller identity per alias.** Every identity that calls a team
  alias gets that team's full budget; with one project identity per team this equals a
  per-team budget.
- **Agent runtimes in spokes** need outbound access to the gateway's public endpoint
  (not verified in this sandbox).
- **Foundry → AI Gateway connections** remain preview; the connection
  metadata mirrors what the portal creates today.

## Other available capabilities

The GA service also supports model routing/failover, request and cost limits, MCP
federation, on-behalf-of tool identity, and OTLP export. This repository deploys model
aliases, managed-identity routing, token limits, and optional content safety; it does not
claim those other capabilities are configured or tested. Model Router and some Agent365
protections remain preview. Billing starts January 1, 2027; review the announced free
request allowance, paid tiers, and monthly service fee before increasing demo usage.
