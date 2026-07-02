# Enterprise Microsoft Foundry Simulation (Bicep)

> ⚠️ **Personal sandbox — not official, not production.** This is my own experiment
> for learning how an enterprise Microsoft Foundry topology could be shaped. It is not
> affiliated with or endorsed by Microsoft, carries no support or guarantees, and may be
> incomplete or wrong in places. Use it for ideas, not as a reference architecture.

A production-shaped, hub/spoke Azure simulation of an enterprise Microsoft Foundry
topology: one **central Foundry** owning approved model deployments, two **team
Foundries** (Team A / Team B) in isolated spokes with BYO data, and a central **APIM
v2 AI Gateway** that teams must use to consume models. The gateway can be **deployed**
(Standard v2 by default) or you can **bring your own** existing v2 APIM. Region:
**Sweden Central**.

The environment is reachable **out-of-the-box**: by default it keeps private endpoints
**and** allowlists the operator's public IP on the data plane (hybrid network mode), and
the deploy script auto-detects that IP for you.

## What gets deployed

- **Observability**: Log Analytics Workspace + Application Insights, with diagnostic
  settings on every supported resource.
- **Hub** (`rg-ai-hub-swc-dev`): hub VNet, APIM v2 AI Gateway (deployed or BYO), central
  Foundry (`AIServices`) + project + model deployment, private DNS zones.
- **Spokes** (`rg-ai-team-a-swc-dev`, `rg-ai-team-b-swc-dev`): per-team VNet, Foundry
  account + project, BYO Storage / Cosmos DB / AI Search / Key Vault, private endpoints.
  Each project is set up as a **VNet-injected standard agent** — its BYO data is wired as
  Cosmos (thread) / Storage (file) / Search (vector) connections plus a capability host.
- **Networking**: hub↔spoke peering, private endpoints, private DNS linked to all VNets,
  optional operator-IP allowlist on the data plane.
- **Governance**: APIM products/APIs/subscriptions per team, AI-gateway policies
  (routing via managed identity, token limits, token metrics, optional content safety,
  metadata-only logging), and least-privilege RBAC.

## Layout

```
infra/
  main.bicep                 # subscription-scoped entrypoint
  main.parameters.dev.json
  modules/                   # observability, network, dns, foundry, data, apim, rbac, vm
  policies/                  # APIM policy XML
scripts/                     # validate / what-if / deploy / tests / cleanup
docs/                        # architecture, deployment, operations, security, gaps, troubleshooting
```

## Quick start

```bash
az login
./scripts/validate.sh        # az bicep build + az deployment sub validate
./scripts/what-if.sh         # preview
./scripts/deploy.sh          # deploy (auto-detects your IP; model connections in the template)
./scripts/postdeploy-foundry-connections.sh   # verify the templated connections
./scripts/test-model-through-apim.sh
./scripts/enable-ai-gateway.sh                 # optional: account-level native AI Gateway association
```

The gateway comes up first, then the Foundry accounts connect to it. To bring your own
APIM, set `existingApimResourceId` (it must be a **v2** tier — Consumption/serverless is
not supported by the native AI Gateway). To allowlist a specific IP instead of the
auto-detected one, set `ALLOWED_CLIENT_IP` before running `deploy.sh`; choose a different
posture with `NETWORK_ACCESS_MODE` (`hybridPePlusIp` | `publicIpOnly` | `privateOnly`).

See [`docs/deployment.md`](docs/deployment.md) for details and
[`docs/architecture.md`](docs/architecture.md) for the design and rationale.

## Key design points

- Teams call **APIM routes only**; they have no RBAC and (with private networking) no
  path to the central model directly.
- APIM authenticates to the central Foundry with its **managed identity** — no API keys.
- The operator-IP allowlist applies to the **data plane** (Foundry, Storage, Cosmos,
  Search, Key Vault) only. APIM is intentionally not IP-filtered, because agent → gateway
  traffic originates from Azure, not the operator's IP; it stays subscription-key gated.
- **Prompt body logging is off by default**; only metadata/token metrics are logged.
- No PTU, no Azure Firewall, no CMK, no availability zones — intentional, low-cost scope.

## Intentional gaps

A couple of items can't be fully expressed in Bicep today (disabling APIM public access
post-PE, the optional content-safety backend). Each is compensated with an idempotent
script and documented in [`docs/implementation-gaps.md`](docs/implementation-gaps.md). The
team project↔APIM model connections are now created by the template itself
(`infra/modules/foundry-model-connection.bicep`).

## Canonical source & acceleration

This sandbox is loosely modelled on, and best understood alongside, the official Microsoft
sample it draws from:

- **Canonical Bicep sample** — [Private network + Standard agent + APIM setup (`16-...`)](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/16-private-network-standard-agent-apim-setup)
  in `microsoft-foundry/foundry-samples`. Treat that as the authoritative reference; this repo is an experiment on top of those ideas.
- **GitHub Copilot for Azure skills** — the [plugin skills](https://github.com/microsoft/GitHub-Copilot-for-Azure/tree/main/plugin)
  can accelerate work like this (Foundry provisioning, private networking, model deployment, RBAC). Much of this sandbox was built with their help.
