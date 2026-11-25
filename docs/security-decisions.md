# Security decisions

This simulation makes deliberate security and governance choices. Each is listed with
its rationale.

## Central model governance
Approved models are deployed **only** on the central Foundry account in the hub. This
gives the platform team a single point to approve models, set capacity, and meter usage,
and prevents teams from independently standing up ungoverned frontier models.

## Teams consume through the gateway
Teams call their Azure AI Gateway alias, never the central model endpoint directly. The
gateway is where token limits and (optionally) content safety are enforced consistently.
Azure AI Gateway is in public preview with no SLA.

## Managed identity preferred over keys
The AI Gateway authenticates to the central Foundry using its **system-assigned managed
identity** (model provider with managed-identity auth). Callers and team projects
authenticate to the gateway with Entra ID. No API keys are created, embedded in Bicep,
outputs, or files; gateway API keys are gateway-wide, so they would also defeat team
isolation. The App Insights connection string is handled as a `@secure()` parameter and is
not emitted as an output.

## No gateway request logging by default
The template configures no gateway telemetry, so prompts and responses are not logged at
the gateway. Enabling the OpenTelemetry exporter is a deliberate post-deploy step; review
what it captures before enabling it.

## Private endpoints enabled
`deployPrivateEndpoints=true`. Storage (blob), Cosmos DB (Sql), AI Search, Key Vault, the
Foundry accounts are reachable over private endpoints with records in private DNS zones
linked to the hub and both spokes. The AI Gateway reaches central Foundry through hub VNet
integration and the central private endpoint. Its inbound private endpoint is optional
(`deployAiGatewayPrivateEndpoint=false`) because it requires a gated subscription feature.

## Network access mode (hybrid by default)
`networkAccessMode=hybridPePlusIp` (the default) keeps private endpoints **and** adds an
operator-IP allowlist so the environment is usable out-of-the-box. It sets
`publicNetworkAccess: Enabled` with **deny-by-default** network ACLs whose only allowed
public entry is the operator's egress ranges (`allowedClientIpRanges`, auto-detected by the
deploy script as /24s, because corporate NAT pools use several addresses)
on Storage, Cosmos, Search, Key Vault, and the Foundry accounts. Tenant governance
(MCAPS "modify" policies) forces `publicNetworkAccess: Disabled` on Storage, Cosmos and
Key Vault, which silently voids the allowlist; for demo environments
`exemptDataResourcesFromNetworkPolicy` applies the policy's own opt-out tag
(`SecurityControl=Ignore`) to those resources only. The tag exempts *all* rules in that
initiative, so the template pins what they enforced (Storage shared key off, Cosmos
local auth off, anonymous blob access off). Leave it `false` outside demo/dev. The other modes are
`privateOnly` (public access Disabled, private endpoints only — the original posture) and
`publicIpOnly` (IP allowlist without private endpoints). `publicIpOnly` blocks the
gateway's egress to central Foundry, so it is not a working mode for gateway inference.

> **Gateway exception:** the operator-IP allowlist is applied to the **data plane** only.
> The AI Gateway ingress is public and gated by Entra ID plus alias-scoped RBAC. Foundry
> project → gateway traffic originates from Azure, not the operator's IP, so an IP filter
> would break it. Network-injected agent runtimes in the spokes also need outbound access
> to the gateway's public endpoint (not verified in this sandbox).

`scripts/test-demo-access.sh` runs after deployment and fails closed if team resources
cannot be enumerated or required data resources are missing. It tests network
reachability, not user authorization or the portal UI. `scripts/allow-demo-access.sh`
adds a new network's ranges to existing rules without redeployment; the next deployment
replaces them with the current deployment's detected ranges. See
[`demo-access.md`](demo-access.md) for operational limits and the browser-versus-shell
egress caveat.

## Team isolation by alias / identity
Each team has its own gateway **alias** and its project identity holds **AI Gateway Models
User** scoped to that alias only, so Team A's identity cannot call Team B's alias
(`401`/`403`). Raw deployment names and unpublished models are not routed. The optional
test principal is granted the Team A alias only. There are no cross-team RBAC assignments, so neither team can read the other's
BYO data resources.

## Direct central model access not granted to teams
Team identities receive **no** Cognitive Services role on the central account. Combined
with private networking, teams have neither authorization nor a network path to call the
central model directly — only the AI Gateway managed identity is granted
**Foundry User** on the central account.

## No firewall, CMK, PTU, or zones — by design
These are intentionally excluded to keep the simulation focused and low-cost. See
`docs/architecture.md` for the rationale behind each exclusion.

## Role assignments (least privilege intent)
| Identity | Scope | Role |
|---|---|---|
| AI Gateway MSI | Central Foundry account | Foundry User |
| Team project MSI | Own team alias on the AI Gateway | AI Gateway Models User |
| Test principal (optional) | Team A alias; Team A Foundry account | AI Gateway Models User; Foundry User |
| Team Foundry MSI | Own Storage | Storage Blob Data Contributor |
| Team Foundry MSI | Own AI Search | Search Index Data Contributor, Search Service Contributor |
| Team Foundry MSI | Own Key Vault | Key Vault Secrets User |
| Team Foundry MSI | Own Cosmos account | Cosmos DB Built-in Data Contributor (SQL data-plane) |

Built-in role **definition IDs** (stable GUIDs) are used rather than display names, since
names can change but IDs do not.
