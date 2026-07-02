# Implementation gaps

This file documents anything not fully automated in Bicep because of current API or
platform limitations, and how it is compensated. It exists even when there is nothing to
report.

> Status: There are a small number of documented gaps below, each compensated with a
> script or a clearly described manual step. The Bicep template itself compiles with
> `az bicep build` and validates with `az deployment sub validate`.

## 1. Foundry project → APIM-backed model connection

**Resolved (templated).** Each team project's admin-connected model connection to the
APIM gateway is now created directly by Bicep in
`infra/modules/foundry-model-connection.bicep` (called from `infra/main.bicep`). The
connection uses `category: 'ApiManagement'`, `authType` controlled by the
`foundryToApimAuthType` parameter (default `ApiKey` — the team's APIM subscription key,
fetched at deploy time via `listSecrets`), targets the team's clean gateway route
`<gateway>/ai/<team>` (the provider-specific `/openai` segment is hidden behind the
gateway's backend base URL), and sets `metadata.deploymentInPath = 'true'` plus a
static `models` list so the central deployment (`enterprise-gpt5-mini`) surfaces in the
project. `scripts/postdeploy-foundry-connections.sh` no longer creates the connection — it
is now a read-only verifier, and the `scripts/test-team-*-through-apim.sh` scripts exercise
the path end to end. See `docs/byo-apim-ai-gateway.md` for the full pattern.

**Auth-type note:** `foundryToApimAuthType` also accepts `ProjectManagedIdentity` (mapped to
the platform `ManagedIdentity` value), but it is not usable today because the APIM team
Products are gated by subscription keys, not Entra tokens. `ApiKey` is the working default;
switch to managed identity only after configuring APIM to accept the project identity's
Entra token.

**Platform note:** `isSharedToAll` does not persist as `true` on these project-level
`ApiManagement` connections in the current API version (the service stores `false` even
when `true` is requested via Bicep or a direct PATCH). The connection is therefore owned by
and visible to the deploying identity; sharing it with every project member is the one
remaining manual portal step if required.

## 2. Disabling APIM public network access after the private endpoint exists

**Gap:** Setting `publicNetworkAccess: Disabled` on APIM Standard v2 at create time, before
the inbound private endpoint is fully provisioned, can make provisioning unreliable.

**Compensation:** The APIM service is created with public access enabled. After the
inbound `Gateway` private endpoint exists, disable public access as a post-deploy step:

```bash
az apim update --name <apim-name> --resource-group <hub-rg> \
  --set properties.publicNetworkAccess=Disabled
```

## 3. APIM content safety policy backend

**Gap:** The `llm-content-safety` policy requires an APIM backend
(`content-safety-backend`) that points at a deployed Azure AI Content Safety resource.
To keep the default deployment lean, that resource and backend are not deployed by
default.

**Compensation:** `enableContentSafetyPolicy` defaults to `false`. The policy fragment in
`infra/policies/content-safety-fragment.xml` is injected only when enabled. To use it,
deploy an Azure AI Content Safety account, add an APIM backend named
`content-safety-backend` targeting it, then set `enableContentSafetyPolicy=true`.

## 4. Reusable diagnostics module vs inline diagnostic settings

**Gap:** A single generic `modules/diagnostics.bicep` that attaches a diagnostic setting
to an arbitrary resource by `resourceId` is not achievable in Bicep, because diagnostic
settings are **extension resources** that require a typed symbolic `scope`, not a string
resource ID.

**Compensation:** Diagnostic settings are defined **inline** within each resource module
using explicit, per-resource category arrays (`categoryGroup: allLogs` + relevant
metrics). This is the approach the instructions explicitly permit ("define per-resource
category arrays carefully in the calling modules") and guarantees only valid categories
are used. Resources covered: APIM, central and team Foundry accounts, Storage (blob
service), Cosmos DB, AI Search, and Key Vault — all to the central Log Analytics
workspace.

## 5. Model version "latest"

**Note:** `centralModelVersion` defaults to `latest`. Some model/deployment combinations
require a concrete version string. `scripts/check-model-availability.sh` validates model
availability in the region before deployment and tells the operator which parameter to
change if the selected model/version is unavailable.

## 6. Foundry agent network injection

**Resolved (templated, default on).** `enableAgentNetworkInjection` now defaults to `true`.
Each team Foundry account is injected into its spoke's dedicated agent subnet (delegated to
`Microsoft.app/environments`), and `infra/modules/foundry-team-agent.bicep` wires the team's
BYO data into the project as standard-agent connections — Cosmos DB (thread store), Storage
(file store), and AI Search (vector store), all AAD-auth — and creates the project
**capability host** (`capabilityHosts@2025-04-01-preview`, kind `Agents`). The module also
grants the **project** managed identity the roles the agent runtime and capability host
require (Storage Blob Data Contributor, Search Index/Service roles, Cosmos data-plane role,
and the control-plane **Cosmos DB Operator** role that must exist before the capability host
is created).

**Note (two-phase reliability):** the Microsoft foundry-samples reference deploys the project
capability host as a separate phase after the account, because the preview capability-host
provisioning can be timing-sensitive. Here it is expressed inline with explicit `dependsOn`
ordering. If a capability-host create intermittently fails on first deployment, set
`deployAgentCapabilityHost=false`, deploy, then re-run with it `true` — the BYO connections and
role assignments are created either way, so only the capability host is deferred.

## 7. Native AI Gateway account-level association (auto-enroll projects)

**Gap:** The functional model-routing path — team projects consuming the central, governed
model **through** the APIM gateway — is fully templated via the project-level `ApiManagement`
connections (gap 1). The additional account-level **"AI Gateway"** association shown in the
Foundry Admin console (which makes the gateway a first-class object in the control plane and
**auto-enrolls** projects) is, as of this writing, a control-plane **preview** feature that is
primarily portal-driven and does not yet expose a stable, documented ARM/Bicep resource type.

**Verification (2026-06-30):** we probed the Azure Resource Manager (ARM) surface directly and
confirmed there is currently **no ARM resource type** for this association. A `PUT` to
`.../Microsoft.CognitiveServices/accounts/<central>/aiGateways/<name>` (and to the candidate
type names `gateways`, `modelGateways`, `apiManagementGateways`, `aiGatewayAssociations`, across
api-versions `2025-04-01-preview` / `2025-06-01`) returns
`400 UnsupportedAction: "The requested action '<type>/<name>' is not supported"`. We also probed
the Foundry data-plane endpoint (`https://<account>.services.ai.azure.com`) for a
`gateways` / `aiGateways` path and found none exposed. The association is therefore managed
entirely by the Foundry control plane (the ai.azure.com Admin console) and, as of this writing,
is **not** reachable from ARM, Bicep, or `az rest`. This is expected for a control-plane preview
feature and is likely to gain an ARM surface as it matures.

**Compensation:** `scripts/enable-ai-gateway.sh` attempts the association idempotently after
deployment (it reads the deployment outputs, checks for an existing association via `az rest`
GET, then `az rest` PUT). Because the preview API is not yet exposed, the script gracefully
detects the failure and prints the exact Foundry Admin console steps as a fallback. The
recommended path today is therefore the portal action below. The deployment is fully functional
without this step — it only adds control-plane visibility and project auto-enrollment governance
on top of the already-templated model-routing path.

**Portal steps (the supported path today):** in `https://ai.azure.com` (New Foundry on) →
**Operate → Admin → AI Gateway → Add AI Gateway → Use existing**, select Foundry account
`<central>` and APIM `<apim-name>` (must be a v2 tier — our deployed `StandardV2` qualifies),
name it, and Add. New projects auto-enroll; add existing projects via "Add project to gateway".

**Why APIM is not IP-filtered:** the operator-IP allowlist (`allowedClientIp`) is applied only
to the **data-plane** resources (Foundry accounts, Storage, Cosmos, AI Search, Key Vault).
The APIM gateway is intentionally **not** IP-filtered: Foundry agent → gateway traffic
originates from Azure-internal addresses, not the operator's IP, so an IP filter would break
agent routing. APIM stays publicly reachable and is gated by per-team subscription keys, which
keeps the gateway usable out-of-the-box while the data plane remains locked to the operator.
