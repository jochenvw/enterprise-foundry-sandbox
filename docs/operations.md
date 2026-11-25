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
MSYS_NO_PATHCONV=1 az role assignment create --assignee-object-id <object-id> \
  --role a6b68e3d-a1f0-4c60-8678-237c050cf4ea --scope "${ALIAS_ID}"
```

Never assign the role at gateway or workspace scope; that would cross team boundaries.
Role changes can take a few minutes to apply. The environment prefix prevents Git Bash
from converting the ARM scope to a local Windows path; it is harmless on other Bash hosts.

## Inspect logs and usage

- **Gateway telemetry**: the AI Gateway OpenTelemetry exporter (configured by
  `scripts/postdeploy-gateway-telemetry.sh`) sends spans, logs, and metrics to the
  platform Application Insights. Query `OTelSpans`/`OTelLogs` in the central Log
  Analytics workspace, or open the Monitoring page in the
  [AI Gateway portal](https://ai.gateway.azure.com). Caller identity is in
  `azure.ai_gateway.identity.claims.oid` / `.appid`; the alias is `gen_ai.request.model`.
- **Central Log Analytics**: also receives diagnostic settings from the central Foundry
  account.
- **Team Log Analytics**: diagnostic settings from that team's Foundry, Storage, Cosmos,
  Search, and Key Vault. The team Foundry account has an `AppInsights` connection
  (`<account>-appinsights`), so agent runs appear in the team's Application Insights
  (`AppDependencies`) and on the project's **Tracing** page in the Foundry portal.

```kusto
// Central workspace: gateway calls per alias and caller
OTelSpans
| where Name == "POST /default/models/*"
| extend alias = tostring(Attributes["gen_ai.request.model"]),
         caller = tostring(Attributes["azure.ai_gateway.identity.claims.oid"]),
         status = toint(Attributes["http.response.status_code"])
| summarize calls = count() by alias, caller, status
```

## Trace a call from team agent to central backend

`./scripts/test-end-to-end-trace.sh` does this automatically. Manually:

1. Note the W3C trace ID of the agent run (the `traceparent` sent to the project, or the
   `OperationId` of the `invoke_agent` span in the team's Application Insights).
2. In the team workspace: `AppDependencies | where OperationId == "<trace-id>"` shows
   `invoke_agent <agent>` and `chat <connection>/<alias>`.
3. In the central workspace: `OTelSpans | where TraceId == "<trace-id>"` shows the
   gateway spans (`inbound`, `policy tokenLimit`, `backend`, `outbound`) for the same call.

## Estimate cost by team

Each team has its own alias, so per-alias token usage is the per-team attribution signal.
It comes from the gateway's OpenTelemetry data in the central workspace; central Foundry
metrics alone show only the total for the shared deployment.

Gateway billing starts January 1, 2027. Review the current request allowance, paid tiers,
and service fee in the
[GA announcement](https://techcommunity.microsoft.com/blog/IntegrationsonAzureBlog/azure-ai-gateway-is-now-generally-available-ship-faster-stay-in-control/4572644);
do not assume the former preview pricing persists.
