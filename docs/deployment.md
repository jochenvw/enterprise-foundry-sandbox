# Deployment

## Prerequisites

- Current stable Azure CLI and Bicep CLI (`az version`, `az bicep version`).
  The baseline below was checked with Azure CLI **2.93.0** and Bicep **0.49.2**.
- Python 3 for model preflight and local regression checks (standard library only;
  no pip packages). Set `PYTHON=python3` if your interpreter is named `python3`.
- Permission to create resource groups and role assignments at subscription scope
  (Owner or User Access Administrator + Contributor).
- A subscription with access to Azure AI Gateway and quota for
  Cognitive Services (AIServices), Cosmos DB, AI Search, and Storage in **Sweden Central**.
- Bash (the scripts use `set -euo pipefail`). On Windows use WSL or Git Bash.

### API baseline (2026-11-25)

Use the newest **published stable Bicep schema** supported by the existing resource
shape. Provider registration alone is not enough: it advertises newer undocumented
versions, including future-dated versions. No cloud resources are changed by checking
this baseline.

| Resource family | API version |
| --- | --- |
| Foundry accounts, deployments, projects, connections, project capability hosts | `2026-09-01` |
| Azure AI Gateway (`aigateways`, workspaces, model providers, models, aliases) | `2026-11-01` (GA service; not yet in the Bicep type index, `BCP081` suppressed) |
| VNets, peerings, NSGs, NICs, private endpoints and DNS zone groups | `2026-03-01` |
| Private DNS zones and VNet links | `2024-06-01` |
| Storage accounts and blob services | `2026-09-01` |
| Cosmos DB accounts and SQL role assignments | `2026-03-15` |
| AI Search | `2026-11-01` |
| Key Vault | `2026-05-15` |
| Virtual machines | `2026-04-01` |
| Log Analytics | `2026-03-01` |
| Resource groups | `2025-04-01` |
| Application Insights / role assignments | `2020-02-02` / `2022-04-01` (unchanged) |
| Diagnostic settings | `2021-05-01-preview` (retained for `categoryGroup`) |

Sources: [published Bicep types](https://github.com/Azure/bicep-types-az/blob/main/generated/index.json),
[ARM template references](https://learn.microsoft.com/azure/templates/),
and `az provider show`. AI Search now uses `hostingMode: 'Default'` and
`publicNetworkAccess: 'Enabled' | 'Disabled'`. Project capability hosts use their
stable schema without the unsupported `capabilityHostKind` property.

The AI Gateway is GA; its Private Link, VNet integration, and Foundry prompt-agent
model connections remain preview. See the
[GA announcement](https://techcommunity.microsoft.com/blog/IntegrationsonAzureBlog/azure-ai-gateway-is-now-generally-available-ship-faster-stay-in-control/4572644),
[documentation](https://aka.ms/aigateway/docs), and
[Azure/aigateway](https://github.com/Azure/aigateway). This repository uses the
[OpenAI v1](https://learn.microsoft.com/azure/foundry/openai/api-version-lifecycle)
surface (`/openai/v1/chat/completions` and `/openai/v1/responses`), so no `api-version`
is needed. The `gpt-5-mini` version `2025-08-07` remains the regional default and supports
`GlobalStandard`; model family, deployment alias and infrastructure SKUs are not
silently replaced with more expensive alternatives.

### Data-plane APIs and service capabilities

Rechecked against official service references and samples on **2026-11-25**.
Available capabilities are not automatically enabled or claimed as tested.

| Service | Current baseline and implementation boundary |
| --- | --- |
| Foundry / Azure OpenAI | OpenAI `v1`, with no dated inference query. Models remain centralized; local auth is disabled. The newer capability-settings workflow is recommended for new agent setups, but its fields are absent from the published stable schema. Existing capability hosts are retained; no hosted-agent runtime deployment is claimed. |
| AI Gateway | GA aliases, managed identities, routing/failover, token/request/cost limits, content safety, MCP federation/OBO, and OTLP export are available. This template uses aliases, token limits, MI routing, and optional content safety. Networking and Foundry model connections remain preview. |
| AI Search | Stable data-plane `2026-04-01`; roles-only with `disableLocalAuth=true` and no incompatible `authOptions`. Vector/hybrid search is available, but no index or ingestion pipeline is provisioned here. |
| Storage | Data-plane `2026-10-06` is the current GA SDK version supported in Sweden Central; rollout varies in EUAP tenants. Secure transfer, TLS 1.2 minimum, no shared keys/anonymous blobs, and private endpoints are retained. |
| Cosmos DB | REST `2018-12-31` is still the latest documented data-plane version. Serverless SQL, Entra data roles, local-auth/key-metadata-write disabling, and private endpoints are used. TLS 1.2 remains the supported ARM minimum setting, even though the transport supports TLS 1.3. |
| Key Vault | Secrets data-plane `2026-04-01` is the latest published stable spec. RBAC, soft delete, and private endpoints are used; irreversible purge protection is intentionally not enabled for disposable demos. |
| Azure networking / Private DNS | Latest stable schemas above; hub/spoke peering, private endpoints, DNS links, and subnet delegation are retained. Both supported modes always provision private endpoints; an empty operator allowlist disables public access. Peering is not an authorization boundary. |
| Virtual machines | Optional Ubuntu 26.04 LTS test VM, Trusted Launch, Secure Boot, and vTPM. No VM is deployed by default; production jump-host authentication/management is outside scope. |
| Azure Monitor / Log Analytics / Application Insights | Resource diagnostics remain typed, inline extension resources. Application Insights uses secure connection-string outputs. Gateway OTLP export is supported but needs asynchronous post-deployment configuration and DCR authorization; it is not configured here. |
| Azure RBAC / resource groups | Stable management versions above. Definition GUIDs and alias/resource scopes are retained; no new subscription-wide grants or policies are added. Existing operator privileges are outside the template's isolation claim. |

Sources: [OpenAI v1](https://learn.microsoft.com/azure/foundry/openai/api-version-lifecycle),
[Foundry standard setup](https://learn.microsoft.com/azure/foundry/agents/concepts/standard-agent-setup),
[Search API versions](https://learn.microsoft.com/rest/api/searchservice/search-service-api-versions)
and [roles-only authentication](https://learn.microsoft.com/azure/search/search-security-enable-roles),
[Storage versioning](https://learn.microsoft.com/rest/api/storageservices/versioning-for-the-azure-storage-services),
[Cosmos REST](https://learn.microsoft.com/rest/api/cosmos-db/)
and [minimum TLS enforcement](https://learn.microsoft.com/azure/cosmos-db/self-serve-minimum-tls-enforcement),
[Key Vault stable specs](https://github.com/Azure/azure-rest-api-specs/tree/main/specification/keyvault/data-plane/Secrets/stable/2026-04-01),
[Trusted Launch](https://learn.microsoft.com/azure/virtual-machines/trusted-launch),
and [Application Insights connection strings](https://learn.microsoft.com/azure/azure-monitor/app/connection-strings).

## 1. Log in and select the subscription

```bash
az login
az account set --subscription "<subscription-id>"
```

## 2. Register resource providers (first time only)

```bash
for ns in Microsoft.CognitiveServices Microsoft.ApiManagement Microsoft.App Microsoft.DocumentDB \
          Microsoft.Search Microsoft.KeyVault Microsoft.Network \
          Microsoft.OperationalInsights Microsoft.Insights Microsoft.Storage; do
  az provider register --namespace "$ns"
done
```

## 3. Validate

```bash
./scripts/validate.sh
```

Runs `az bicep build --stdout` (without generating `infra/main.json`) and
`az deployment sub validate`.

For compilation and offline regression checks without a login or deployment:

```bash
./scripts/validate.sh --local
python -B -m unittest discover -s scripts -p test_local.py -v
```

The regression checks mock Azure CLI and HTTP calls; they do not prove live gateway
policy or RBAC behavior. Run the integration scripts after deploying the updated template.

## 4. Preview (what-if)

```bash
./scripts/what-if.sh
```

## 5. Check model availability (optional; deploy.sh runs it automatically)

```bash
./scripts/check-model-availability.sh
```

Checks the configured model name, version and deployment SKU against the regional
AIServices catalog. An unavailable version/SKU or failed catalog request fails the
preflight instead of falling back silently to `gpt-5-mini`. This does not check quota.

## 6. Deploy

```bash
./scripts/deploy.sh
```

> The deployment is subscription-scoped and creates the four resource groups. The AI
> Gateway, its model provider and team aliases, the alias-scoped role assignments, and
> the team project connections are all part of the template.

The deploy script **auto-detects your network's egress** and allowlists it on the data
plane. Corporate networks NAT through several addresses, and different Azure front ends
(e.g. `*.openai.azure.com` vs `*.services.ai.azure.com`) can see different ones, so it
queries several echo services and allowlists each address's /24
(`CLIENT_IP_PREFIX=32` for exact hosts). `ALLOWED_CLIENT_IPS=<ip-or-cidr,...>` replaces
detection; `EXTRA_CLIENT_IP_RANGES` adds to it. To change the
posture, set `NETWORK_ACCESS_MODE` (`hybridPePlusIp` | `privateOnly`). Both provision
private endpoints, which the gateway needs for central Foundry. Hybrid deployment
fails before provisioning if no egress range can be detected or supplied. A direct ARM
deployment with an empty allowlist disables public data-plane access.

The script also passes the signed-in identity as `gatewayTestPrincipalId`, which grants
it AI Gateway Models User on the **Team A alias only** and Foundry User on the Team A
account, for the tests below. Set `SKIP_TEST_PRINCIPAL=1` to skip.

After deployment, the script runs `scripts/test-demo-access.sh` automatically to
confirm that the current shell can reach all Foundry and connected data endpoints.
It fails on enumeration errors, missing required resources/tokens, and uncertain HTTP results.
Set `SKIP_DEMO_ACCESS_CHECK=1` only when intentionally skipping this validation (for
example in continuous integration). In `privateOnly` mode the public probe is skipped;
run the portal check from inside the connected network. For a different demo network,
run `scripts/allow-demo-access.sh` to merge its egress ranges into the existing rules
without redeploying. See [`demo-access.md`](demo-access.md) for the network-policy
exemption and the distinction between reachability and authorization.

## 7. Post-deploy: verify connections

```bash
./scripts/postdeploy-foundry-connections.sh   # verify the templated model connections
```

The team project → AI Gateway model connections are created by the template; this
script only verifies them. Gateway telemetry (OpenTelemetry exporter) is a manual
post-deploy step, and the inbound private endpoint is opt-in
(`deployAiGatewayPrivateEndpoint`, gated feature); see `docs/implementation-gaps.md`.

## 8. Run tests

```bash
./scripts/test-dns.sh                          # prints in-network DNS test commands
./scripts/test-model-through-gateway.sh        # runs all of the following
./scripts/test-gateway-health.sh               # unauthenticated call -> 401/403
./scripts/test-gateway-inference.sh            # Team A alias, chat + responses -> 200
./scripts/test-team-isolation.sh               # Team B alias -> 401/403; raw/unpublished model -> 4xx
./scripts/test-foundry-project-through-gateway.sh  # Team A project, <connection>/<alias> -> 200
./scripts/test-direct-central-foundry-blocked.sh   # team roles absent; operator call informational
```

Positive checks retry on `401`/`403` while new role assignments propagate (tune with
`RETRY_ATTEMPTS`, default 10, and `RETRY_DELAY`, default 30 seconds).

> Gateway ingress is public (Entra ID only), so the gateway tests run from anywhere. The
> Foundry project test needs the Team A account endpoint: in `hybridPePlusIp` mode it is
> reachable from the allowlisted operator IP; in `privateOnly` mode run it from inside the
> network — a VM in a VNet (`deployTestVm=true`), a peered network, or over VPN/Bastion.

For Foundry portal demos, also run `./scripts/test-demo-access.sh` from the same
network path as the browser. A successful check confirms network reachability only;
Azure RBAC and data permissions remain separate. Use `./scripts/allow-demo-access.sh`
when the operator's egress network changes.

## 9. Clean up

```bash
./scripts/cleanup.sh
```

Deletes the four resource groups. Key Vaults are soft-deleted; purge separately if you
need to reuse the same names immediately.

## Parameters

All inputs live in `infra/main.parameters.dev.json`. Notable ones:

| Parameter | Default | Purpose |
|---|---|---|
| `location` | `swedencentral` | Region (location code). |
| `networkAccessMode` | `hybridPePlusIp` | Private endpoints plus operator-IP allowlist, or fully private (`privateOnly`). |
| `allowedClientIpRanges` | `[]` | Operator IPs/CIDRs allowlisted on the data plane (`ALLOWED_CLIENT_IPS` overrides detection). Empty disables public access. |
| `exemptDataResourcesFromNetworkPolicy` | `false` (`true` in dev params) | Tag Storage, Cosmos DB and Key Vault with `networkPolicyExemptionTag` (default `SecurityControl=Ignore`) so tenant "modify" policies don't force `publicNetworkAccess=Disabled`, which would make the IP allowlist ineffective. Local auth stays disabled in the template. |
| `networkPolicyExemptionTag` | `SecurityControl=Ignore` | Tenant-policy opt-out tag applied only when `exemptDataResourcesFromNetworkPolicy=true`. It exempts the resources from the applicable policy initiative, not only its network rule; review before enabling outside demo/dev. |
| `enableAgentNetworkInjection` | `true` | VNet-inject the agent runtime and wire BYO data as standard-agent connections. |
| `deployAgentCapabilityHost` | `true` | Create each project's standard-agent capability host. |
| `centralModelName` / `centralModelVersion` | `gpt-5-mini` / `2025-08-07` | Model selection. |
| `centralModelSkuName` | `GlobalStandard` | Supported non-PTU model deployment SKU. |
| `centralModelCapacity` | `50` | Central capacity in thousands of TPM (50K TPM). |
| `teamTokenLimitsPerMinute` | `[20000, 20000]` | TPM on each alias, counted per caller identity. |
| `enableTokenLimitPolicy` | `true` | Apply the `tokenLimit` policy on each alias. |
| `enableContentSafetyPolicy` | `false` | Opt into supported prompt/response content safety at Medium severity across all categories. |
| `useResponsesApiUpstream` | `true` | Project connections send Responses API requests to the gateway (false = Chat Completions). |
| `deployAiGatewayPrivateEndpoint` | `false` | Inbound gateway private endpoint; needs the gated feature `Microsoft.Network/AllowPrivateEndpoints`. |
| `gatewayTestPrincipalId` / `gatewayTestPrincipalType` | `''` / `User` | Test identity granted the Team A alias (set by `deploy.sh`). |
