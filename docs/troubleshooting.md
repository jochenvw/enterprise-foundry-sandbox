# Troubleshooting

## Bicep build fails
- Run `az bicep version` and `az bicep upgrade` to ensure a recent compiler.
- Run `./scripts/validate.sh --local` and read the first error; later errors are
  often cascades of the first.

## `az deployment sub validate` fails on quota or SKU
- AI Search Basic or Cognitive Services S0 may be quota-limited in the
  subscription/region. Request quota or change SKU/region.
- Confirm the region is `swedencentral` (location code, not a display name) and that the
  subscription can create `Microsoft.ApiManagement/aigateways` (GA service).
- Bicep warns `BCP081` for the AI Gateway types; it is suppressed because API
  `2026-11-01` is not yet in the type index. ARM validates the resources at deployment.

## Model deployment fails ("model not found" / "not available")
- Run `./scripts/check-model-availability.sh`. Change `centralModelName` /
  `centralModelVersion` in `infra/main.parameters.dev.json` to an available model.
- `latest` may be rejected for some models; use a concrete version.

## AI Gateway private endpoint fails with `SubscriptionNotRegisteredForFeature`
- The inbound private endpoint needs the gated feature
  `Microsoft.Network/AllowPrivateEndpoints`. Keep `deployAiGatewayPrivateEndpoint=false`
  (the default) unless the feature is registered for your subscription.

## Gateway calls return 401/403 right after deployment
- New alias role assignments can take several minutes to apply. The test scripts retry
  (`RETRY_ATTEMPTS`, `RETRY_DELAY`).
- Use a token for `https://ai.gateway.azure.com` (or `https://azure-api.net/aigateway`),
  not the Cognitive Services audience.
- Confirm the caller holds AI Gateway Models User on **that alias**. With `deploy.sh`,
  the signed-in user has it on the Team A alias only (unless `SKIP_TEST_PRINCIPAL=1`).

## Gateway returns 404 `model_not_found` or 429
- The gateway resolves the `model` alias **before** authenticating, so an unknown alias
  returns `404 model_not_found` even without a token. Use the alias names from the
  `teamAAlias`/`teamBAlias` outputs (`<team>-<central deployment name>`).
- `429 rate_limit_exceeded` from the backend means the central deployment's
  `centralModelCapacity` (thousands of TPM) is too small. Positive test checks retry on 429.
  Keep `teamTokenLimitsPerMinute` within that capacity.

## Gateway returns 5xx or a backend authorization/network error
- Confirm the gateway identity holds Foundry User on the central account
  (`rbac-central.bicep`).
- Both supported modes retain the central private endpoint. Confirm it is approved
  and that the gateway resolves central Foundry to its private address.
- Confirm `snet-aigw-integration` is delegated to `Microsoft.App/environments` and the
  central Foundry private DNS zones are linked to the hub VNet.

## Cannot reach the gateway or Foundry endpoints
- Gateway ingress is public unless you deployed its private endpoint; reachability
  failures there are usually DNS or local proxy issues (`./scripts/test-gateway-health.sh`
  expects `401`/`403`).
- In `hybridPePlusIp` mode, data-plane endpoints accept the allowlisted operator IP. In
  `privateOnly` mode they resolve to private IPs and are only reachable from inside the
  hub/spoke network — use a VM in the VNet (`deployTestVm=true`), a peered network, or
  VPN/Bastion. Use `./scripts/test-dns.sh` for the exact checks.
- A direct call to central Foundry succeeding from the operator's machine is expected
  when the operator holds a data role (e.g. subscription-level Foundry User) and the
  network allows it. `./scripts/test-direct-central-foundry-blocked.sh` enforces the
  template's role boundary instead: no team account/project identity holds any role on
  central, including inherited/group assignments. Missing identities or failed role
  queries fail the check.
- If a data-plane call (or the Foundry portal: "This Foundry account is protected by
  network access controls…") is denied even though `ipRules` contains your public IP:
  1. Azure is seeing a different source address — corporate networks NAT through several
     addresses, and `*.openai.azure.com`, `*.services.ai.azure.com`, Search and Cosmos
     can each see a different one. Run `./scripts/test-demo-access.sh`: it lists every
     blocked endpoint and, for Cosmos/Key Vault, the address Azure saw. Fix in place
     with `./scripts/allow-demo-access.sh` (allowlists this network's /24s).
  2. `publicNetworkAccess` was flipped to `Disabled` by a tenant "modify" policy (Storage,
     Cosmos DB, Key Vault), so IP rules are ignored. Check with
     `az storage account show -n <name> --query publicNetworkAccess`; redeploy with
     `exemptDataResourcesFromNetworkPolicy=true` (dev parameters default).
  3. The browser may use a proxy or egress path different from the shell. Run the
     check from the same path as the browser, or set the browser's egress range with
     `ALLOWED_CLIENT_IPS` when running `scripts/allow-demo-access.sh`.
  4. A successful network probe does not imply the signed-in user has the Azure RBAC
     or data-plane permissions required by the portal. See [`demo-access.md`](demo-access.md).
- `UNVERIFIED` demo checks indicate missing tokens or unexpected HTTP results such as
  proxy/service `5xx` or `404`. Resolve those errors; do not add network exceptions
  merely to hide an unverified result.
- If deployed directly with an empty operator allowlist, public data-plane access is
  deliberately disabled. Redeploy with an explicit range or use `privateOnly` access.

## Cross-team call unexpectedly succeeds
- Check the caller's role assignments: AI Gateway Models User must be scoped to a single
  alias, never to the gateway or the `default` workspace.
  `az role assignment list --assignee <object-id> --all -o table`
- Verify the caller is using the intended alias in the `model` field.

## Direct central model call unexpectedly succeeds
- The calling identity has a Cognitive Services role on the central account. Ensure team
  identities have **no** central-account role; only the AI Gateway identity should.
- If running from inside the network, a 401/403 (not a connection error) is still the
  correct "blocked" outcome.

## Role assignment "PrincipalNotFound"
- Managed identity principal IDs can take a few seconds to propagate. Re-run the
  deployment; ARM is idempotent and will complete the role assignments.

## Key Vault name already exists / soft-deleted
- Key Vault names are globally unique and soft-deleted on cleanup. Purge with
  `az keyvault purge --name <kv-name> --location swedencentral`, or change the
  `uniqueSuffixOverride` parameter.

## Foundry project call with `<connection>/<alias>` fails
- Run `./scripts/postdeploy-foundry-connections.sh` to confirm the connection exists with
  category `ApiManagement`.
- The caller needs Foundry User on the team account; the project identity needs AI
  Gateway Models User on the team alias. Allow a few minutes for propagation.
- Foundry → AI Gateway model connections remain preview. See
  `docs/implementation-gaps.md` §1.
