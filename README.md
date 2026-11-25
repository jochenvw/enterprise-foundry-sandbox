# Enterprise Microsoft Foundry Simulation (Bicep)

> ⚠️ **Personal sandbox — not official, not production.** This is my own experiment
> for learning how an enterprise Microsoft Foundry topology could be shaped. It is not
> affiliated with or endorsed by Microsoft, carries no support or guarantees, and may be
> incomplete or wrong in places. Use it for ideas, not as a reference architecture.

A production-shaped, hub/spoke Azure simulation of an enterprise Microsoft Foundry
topology: one **central Foundry** owning approved model deployments, two **team
Foundries** (Team A / Team B) in isolated spokes with BYO data, and a central **Azure AI
Gateway** (`Microsoft.ApiManagement/aigateways`, public preview) that teams must use to
consume models. Region: **Sweden Central**.

The development environment is designed to support live demos: it keeps private
endpoints **and** allowlists the operator's egress ranges on the data plane (hybrid
network mode). The deploy script detects multiple egress addresses; the dev parameters
also opt Storage, Cosmos DB, and Key Vault out of the tenant policy that otherwise
forces public access off. This is a deliberate demo-only exception; see
[`docs/demo-access.md`](docs/demo-access.md).

## What gets deployed

- **Observability**: central Log Analytics Workspace + Application Insights for the hub,
  plus per-team Log Analytics Workspace + Application Insights in each spoke, with
  diagnostic settings on every supported resource.
- **Hub** (`rg-ai-hub-swc-dev`): hub VNet, Azure AI Gateway (VNet-integrated), central
  Foundry (`AIServices`) + project + model deployment, private DNS zones.
- **Spokes** (`rg-ai-team-a-swc-dev`, `rg-ai-team-b-swc-dev`): per-team VNet, Foundry
  account + project, BYO Storage / Cosmos DB / AI Search / Key Vault, private endpoints.
  Each project is set up as a **VNet-injected standard agent** — its BYO data is wired as
  Cosmos (thread) / Storage (file) / Search (vector) connections plus a capability host.
- **Networking**: hub↔spoke peering, private endpoints, private DNS linked to all VNets,
  optional operator-IP allowlist on the data plane.
- **Governance**: one gateway alias per team (`<team>-<deployment>`) with a token limit
  and optional content safety, routing to the central model with the gateway's managed
  identity, alias-scoped RBAC for team isolation, and least-privilege RBAC elsewhere.

## Layout

```
infra/
  main.bicep                 # subscription-scoped entrypoint
  main.parameters.dev.json
  modules/                   # observability, network, dns, foundry, data, ai-gateway, rbac, vm
scripts/                     # validate / what-if / deploy / tests / cleanup
docs/                        # architecture, AI Gateway, demo access, deployment, operations, security, gaps, troubleshooting
```

## Quick start

```bash
az login
./scripts/validate.sh        # az bicep build + az deployment sub validate
./scripts/what-if.sh         # preview
./scripts/deploy.sh          # deploy (auto-detects your IP; model connections in the template)
./scripts/postdeploy-foundry-connections.sh   # verify the templated connections
./scripts/test-model-through-gateway.sh       # health, inference, isolation, project, direct-blocked
```

`deploy.sh` grants the signed-in identity access to the Team A alias for the tests
(`SKIP_TEST_PRINCIPAL=1` to skip). It detects all of this network's egress addresses
(corporate NAT pools use several) and allowlists their /24 ranges; override with
`ALLOWED_CLIENT_IPS` / `EXTRA_CLIENT_IP_RANGES` / `CLIENT_IP_PREFIX`. Choose a different
posture with `NETWORK_ACCESS_MODE` (`hybridPePlusIp` | `privateOnly`; `publicIpOnly`
blocks the gateway's egress to central Foundry).

**Live demos:** every deploy runs `scripts/test-demo-access.sh` by default. It checks
that the current shell can reach all Foundry accounts and connected data resources,
and fails closed if resource enumeration fails. From a new network, run
`scripts/allow-demo-access.sh` to add its ranges in place and verify them, without
redeploying. This check is for network reachability, not portal sign-in or resource
permissions. See [`docs/demo-access.md`](docs/demo-access.md).

See [`docs/deployment.md`](docs/deployment.md) for details,
[`docs/architecture.md`](docs/architecture.md) for the design and rationale, and
[`docs/ai-gateway.md`](docs/ai-gateway.md) for the gateway pattern.

## Current API baseline

Azure APIs are aligned with published stable schemas as of **2026-11-25** (except the
preview AI Gateway API `2026-11-01`), using
Azure CLI **2.93.0** and Bicep **0.49.2**. There are no third-party package dependencies;
Python checks use only the standard library. See the version table and local checks
in [`docs/deployment.md`](docs/deployment.md).

Applications call `POST https://<gateway-host>/default/models/openai/v1/chat/completions`
(or `/responses`) with an Entra token for `https://ai.gateway.azure.com` and the team
alias in the JSON `model` field, e.g. `team-a-enterprise-gpt5-mini`. Team Foundry
projects use the model `<connection>/<alias>`. Azure AI Gateway is in **public preview
with no SLA** (API `2026-11-01`).

## Key design points

- Teams call **their gateway alias only**; they have no role on the central account and
  (with private networking) no path to the central model directly.
- Each team project identity holds **AI Gateway Models User on its own alias only**, so
  Team A cannot call Team B's alias.
- The gateway authenticates to the central Foundry with its **managed identity**
  (Foundry User) over hub VNet integration and the central private endpoint. No API keys
  are created anywhere; callers use Entra ID.
- The operator-IP allowlist applies to the **data plane** (Foundry, Storage, Cosmos,
  Search, Key Vault) only. Gateway ingress is public and Entra-ID gated; an inbound
  private endpoint is optional and needs a gated subscription feature.
- Demo access uses detected egress ranges, normally widened to `/24`; the development
  parameters opt Storage, Cosmos DB, and Key Vault out of the applicable tenant policy.
  Review the broader policy exemption before using it outside a demo environment.
- Gateway telemetry (OpenTelemetry exporter) is a manual post-deploy step.
- No PTU, no Azure Firewall, no CMK, no availability zones — intentional, low-cost scope.

## Intentional gaps

A few items are not automated today: gateway telemetry export, the gated inbound private
endpoint, and content safety while the policy aligns with the preview API. Each is
documented in [`docs/implementation-gaps.md`](docs/implementation-gaps.md). The team
project → gateway model connections are created by the template itself
(`infra/modules/foundry-model-connection.bicep`).

## Canonical source & acceleration

This sandbox is loosely modelled on, and best understood alongside, the official Microsoft
sample it draws from:

- **Canonical Bicep sample** — [Private network + Standard agent setup (`16-...`)](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/16-private-network-standard-agent-apim-setup)
  in `microsoft-foundry/foundry-samples` (its gateway layer used API Management; this repo
  uses Azure AI Gateway instead). Treat that as the authoritative reference; this repo is an experiment on top of those ideas.
- **Azure AI Gateway** — [documentation](https://learn.microsoft.com/azure/api-management/)
  and [samples](https://github.com/Azure/ai-gateway).
- **GitHub Copilot for Azure skills** — the [plugin skills](https://github.com/microsoft/GitHub-Copilot-for-Azure/tree/main/plugin)
  can accelerate work like this (Foundry provisioning, private networking, model deployment, RBAC). Much of this sandbox was built with their help.
