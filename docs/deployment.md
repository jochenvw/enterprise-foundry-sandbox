# Deployment

## Prerequisites

- Azure CLI 2.60+ with the Bicep CLI (`az bicep version`).
- Permission to create resource groups and role assignments at subscription scope
  (Owner or User Access Administrator + Contributor).
- A subscription with quota for APIM Standard v2, Cognitive Services (AIServices),
  Cosmos DB, AI Search, and Storage in **Sweden Central**.
- Bash (the scripts use `set -euo pipefail`). On Windows use WSL or Git Bash.

## 1. Log in and select the subscription

```bash
az login
az account set --subscription "<subscription-id>"
```

## 2. Register resource providers (first time only)

```bash
for ns in Microsoft.CognitiveServices Microsoft.ApiManagement Microsoft.DocumentDB \
          Microsoft.Search Microsoft.KeyVault Microsoft.Network \
          Microsoft.OperationalInsights Microsoft.Insights Microsoft.Storage; do
  az provider register --namespace "$ns"
done
```

## 3. Validate

```bash
./scripts/validate.sh
```

Runs `az bicep build` and `az deployment sub validate`.

## 4. Preview (what-if)

```bash
./scripts/what-if.sh
```

## 5. Check model availability (optional; deploy.sh runs it automatically)

```bash
./scripts/check-model-availability.sh
```

If `gpt-5-mini` is not available in Sweden Central, the script prints the available
models and the exact parameter to change (`centralModelName` /
`centralModelVersion` in `infra/main.parameters.dev.json`).

## 6. Deploy

```bash
./scripts/deploy.sh
```

> APIM v2 provisioning typically takes ~30–45 minutes. The deployment is
> subscription-scoped and creates the four resource groups. The AI gateway is deployed
> first, then the central and team Foundries connect to it.

The deploy script **auto-detects your public IP** and allowlists it on the data plane.
To allowlist a specific IP instead, set `ALLOWED_CLIENT_IP=<your.ip>`; to change the
posture, set `NETWORK_ACCESS_MODE` (`hybridPePlusIp` | `publicIpOnly` | `privateOnly`).
To bring your own gateway, set `existingApimResourceId` to an existing **v2** APIM in the
parameters file (Consumption/serverless is not supported).

## 7. Post-deploy: verify connections and (optionally) the native gateway

```bash
./scripts/postdeploy-foundry-connections.sh   # verify the templated model connections
./scripts/enable-ai-gateway.sh                 # optional: account-level native AI Gateway association
```

The team project → APIM model connections are created by the template itself; the first
script verifies them. `enable-ai-gateway.sh` adds the optional account-level association
(control-plane visibility + project auto-enroll). See `docs/implementation-gaps.md` for
why the association is a script rather than Bicep.

## 8. Run tests

```bash
./scripts/test-dns.sh                 # prints in-network DNS test commands
./scripts/test-apim-health.sh         # gateway reachability
./scripts/test-model-through-apim.sh  # team routes succeed + cross-team blocked
./scripts/test-direct-model-blocked.sh# direct central access blocked
```

> In `hybridPePlusIp` mode the gateway and Foundry endpoints are reachable from the
> allowlisted operator IP. In `privateOnly` mode they are only reachable from inside the
> network — run the network tests from a VM in a VNet (`deployTestVm=true`), a peered
> network, or over VPN/Bastion.

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
| `networkAccessMode` | `hybridPePlusIp` | Data-plane posture: private endpoints + operator-IP allowlist (`hybridPePlusIp`), allowlist only (`publicIpOnly`), or fully private (`privateOnly`). |
| `allowedClientIp` | `''` | Operator IP allowlisted on the data plane (deploy script auto-detects; `ALLOWED_CLIENT_IP` overrides). |
| `deployPrivateEndpoints` | derived | Create private endpoints (derived from `networkAccessMode`). |
| `existingApimResourceId` | `''` | BYO: reference an existing v2 APIM instead of deploying one. |
| `apimSkuName` | `StandardV2` | SKU when deploying a new gateway (must be a v2 tier). |
| `enableAgentNetworkInjection` | `true` | VNet-inject the agent runtime and wire BYO data as standard-agent connections. |
| `deployAgentCapabilityHost` | `true` | Create each project's standard-agent capability host. |
| `centralModelName` / `centralModelVersion` | `gpt-5-mini` / `latest` | Model selection. |
| `teamTokenLimitsPerMinute` | `[1000, 1000]` | Per-team TPM at the gateway. |
| `enablePromptBodyLogging` | `false` | Log prompt/response bodies (off by default). |
| `enableContentSafetyPolicy` | `false` | Enable llm-content-safety (needs a backend). |
