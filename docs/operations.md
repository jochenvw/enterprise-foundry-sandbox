# Operations

## Add a new central model deployment

1. Add a new `Microsoft.CognitiveServices/accounts/deployments` resource in
   `infra/modules/foundry-central.bicep` (or parameterize a second deployment) and expose
   its name as a module output.
2. Register it in `infra/modules/ai-gateway-models.bicep` (another `models` resource under
   the `foundry-central` provider) and add team aliases that point at it.
3. Grant each team's project identity AI Gateway Models User on its new alias
   (`infra/modules/ai-gateway-alias-role.bicep`) and add the alias to that team's
   connection `models` list (`infra/modules/foundry-model-connection.bicep`).
4. Re-run `./scripts/validate.sh` then `./scripts/deploy.sh`.

Aliases decouple callers from deployments: to swap the backing model, change the alias's
`backendModels` and callers keep using the same alias name.

## Add a new team

1. Append the team key to `teamNames` and a TPM value to `teamTokenLimitsPerMinute` in
   `infra/main.parameters.dev.json` (e.g. `"team-c"`). The gateway alias
   (`team-c-<deployment>`) is created by the loop in `ai-gateway-models.bicep`.
2. Add a spoke address space parameter and `network-spoke` + `observability` +
   `foundry-team` + `foundry-team-data` + `rbac-team` + `ai-gateway-alias-role` +
   `foundry-model-connection` module blocks in `infra/main.bicep` following the Team A/B
   pattern, and link the spoke VNet to the private DNS zones.
3. Validate and deploy.

## Adjust token quotas

Change `teamTokenLimitsPerMinute` (aligned by index with `teamNames`) and redeploy. The
`tokenLimit` policy on each alias counts tokens **per caller identity** (`counterKey:
identity`), so every identity calling an alias gets the full value. Keep one calling
identity per team (the project managed identity) for a true per-team budget. Disable the
policy with `enableTokenLimitPolicy=false`.

## Prepare Foundry for a live demo

1. Run `./scripts/test-demo-access.sh` from the same network path as the browser.
   Deployment runs this check automatically; it catches common corporate egress and
   tenant-policy exceptions before opening the portal.
2. From a new network, run `./scripts/allow-demo-access.sh`. It adds detected ranges
   to existing data-plane rules and verifies reachability without redeploying. The
   next deploy sets the allowlist to its detected ranges.
3. If an endpoint is still blocked, follow [`demo-access.md`](demo-access.md). In
   particular, IP rules cannot override a tenant policy that disables public access.

The dev parameters opt Storage, Cosmos DB, and Key Vault out of the applicable tenant
policy using `SecurityControl=Ignore`. This is broader than a network-rule exception;
the template retains disabled local authentication and other compensating settings.
Do not enable it outside an approved demo/development scope without reviewing the
tenant policy.

## Grant or revoke access to a team alias

Access is Azure RBAC, not keys. Assign **AI Gateway Models User**
(`a6b68e3d-a1f0-4c60-8678-237c050cf4ea`) at the alias scope:

```bash
ALIAS_ID="$(az deployment sub show -n enterprise-foundry --query properties.outputs.aiGatewayId.value -o tsv)/workspaces/default/aliases/team-a-enterprise-gpt5-mini"
az role assignment create --assignee <object-id> \
  --role a6b68e3d-a1f0-4c60-8678-237c050cf4ea --scope "${ALIAS_ID}"
```

Never assign the role at gateway or workspace scope; that would cross team boundaries.
Role changes can take a few minutes to apply.

## Inspect logs and usage

- **Gateway telemetry** is not configured by the template. Set up the AI Gateway
  OpenTelemetry exporter (`workspaces/telemetryExporters`) after deployment; it needs
  Application Insights OTLP ingestion and **Monitoring Metrics Publisher** on a managed
  data collection rule. See the
  [AI gateway documentation](https://learn.microsoft.com/azure/api-management/).
- **Central Log Analytics**: diagnostic settings from the central Foundry account,
  but gateway-identity call visibility and request-level correlation have not been
  confirmed.
- **Team Log Analytics**: diagnostic settings from that team's Foundry, Storage, Cosmos,
  Search, and Key Vault; team-built agents/apps can also use the team-local
  Application Insights instance.

## Trace a model call from team alias to central backend

1. Capture the client request time and response headers from the gateway call.
2. If the OpenTelemetry exporter is configured, find the gateway span in Application
   Insights and note the alias and status.
3. Central Foundry diagnostics may provide backend-side evidence, but request-level
   correlation to a gateway alias has not been verified. Do not treat this as a
   supported end-to-end trace until the gateway exporter is configured and validated.

## Estimate cost by team

Each team has its own alias, so per-alias token usage is the per-team attribution signal.
It requires the gateway's OpenTelemetry exporter. Without it, central Foundry metrics
show only the total for the shared deployment.
