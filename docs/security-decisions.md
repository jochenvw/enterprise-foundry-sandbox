# Security decisions

This simulation makes deliberate security and governance choices. Each is listed with
its rationale.

## Central model governance
Approved models are deployed **only** on the central Foundry account in the hub. This
gives the platform team a single point to approve models, set capacity, and meter usage,
and prevents teams from independently standing up ungoverned frontier models.

## Teams consume through the gateway
Teams call APIM routes, never the central model endpoint directly. The gateway is where
throttling, metering, content safety, and logging are enforced consistently.

## Managed identity preferred over keys
APIM authenticates to the central Foundry using its **system-assigned managed identity**
(`authentication-managed-identity` policy). No API keys are embedded in Bicep, outputs,
or files. The App Insights connection string is handled as a `@secure()` parameter and is
not emitted as an output.

## Prompt body logging disabled by default
`enablePromptBodyLogging=false`. Only metadata (team, alias, deployment, status, latency,
request id, token counts) is logged. Prompt/response bodies are logged only when an
operator explicitly opts in.

## Private endpoints enabled
`deployPrivateEndpoints=true`. Storage (blob), Cosmos DB (Sql), AI Search, Key Vault, the
Foundry accounts, and the APIM gateway are reachable over private endpoints with records
in private DNS zones linked to the hub and both spokes.

## Network access mode (hybrid by default)
`networkAccessMode=hybridPePlusIp` (the default) keeps private endpoints **and** adds an
operator-IP allowlist so the environment is usable out-of-the-box. It sets
`publicNetworkAccess: Enabled` with **deny-by-default** network ACLs whose only allowed
public entry is the operator's IP (`allowedClientIp`, auto-detected by the deploy script)
on Storage, Cosmos, Search, Key Vault, and the Foundry accounts. The other modes are
`privateOnly` (public access Disabled, private endpoints only — the original posture) and
`publicIpOnly` (IP allowlist without private endpoints).

> **APIM exception:** the operator-IP allowlist is applied to the **data plane** only. The
> APIM gateway is intentionally **not** IP-filtered, because Foundry agent → gateway
> traffic originates from Azure-internal addresses rather than the operator's IP, so an IP
> filter would break agent routing. APIM stays publicly reachable and is gated by per-team
> subscription keys. The APIM service is also created with public access enabled to keep
> provisioning reliable; disabling it after the inbound private endpoint exists is a
> documented post-deploy step (see `docs/implementation-gaps.md`).

## Team isolation by route / product / identity
Each team has its own APIM **product**, **API**, and **subscription**. A team's
subscription key is scoped to its product only, so Team A's key cannot call Team B's
route. There are no cross-team RBAC assignments, so neither team can read the other's
BYO data resources.

## Direct central model access not granted to teams
Team identities receive **no** Cognitive Services role on the central account. Combined
with private networking, teams have neither authorization nor a network path to call the
central model directly — only the APIM managed identity is granted
`Cognitive Services OpenAI User` / `Cognitive Services User` on the central account.

## No firewall, CMK, PTU, or zones — by design
These are intentionally excluded to keep the simulation focused and low-cost. See
`docs/architecture.md` for the rationale behind each exclusion.

## Role assignments (least privilege intent)
| Identity | Scope | Role |
|---|---|---|
| APIM MSI | Central Foundry account | Cognitive Services OpenAI User, Cognitive Services User |
| Team Foundry MSI | Own Storage | Storage Blob Data Contributor |
| Team Foundry MSI | Own AI Search | Search Index Data Contributor, Search Service Contributor |
| Team Foundry MSI | Own Key Vault | Key Vault Secrets User |
| Team Foundry MSI | Own Cosmos account | Cosmos DB Built-in Data Contributor (SQL data-plane) |

Built-in role **definition IDs** (stable GUIDs) are used rather than display names, since
names can change but IDs do not.
