# Foundry live-demo access

Use this guide when the Foundry portal says the account is protected by network
access controls. The message describes a **data-plane network** block; Azure resource
management pages may still load.

## What must be reachable

The portal browser needs to reach the central and team Foundry account and project
endpoints, plus each team's connected Storage, Cosmos DB, AI Search, and Key Vault
endpoints. Network reachability is separate from authorization: this check proves that
the current shell can pass the network controls. It does not grant resource roles or
prove that a specific portal operation will succeed.

## After deployment

`scripts/deploy.sh` runs `scripts/test-demo-access.sh` by default. The check probes
each Foundry endpoint and enumerates each team's connected data resources before
probing them. It fails if it cannot enumerate resources, if an always-deployed
Storage, Cosmos DB, or AI Search resource is missing, or if an endpoint returns a
network-denial response. Token acquisition failures and uncertain HTTP results,
including proxy/upstream `5xx` or unexpected `404`, fail as `UNVERIFIED` rather than
being mistaken for reachability. An authorization `401`/`403` without a network-denial
message means the request reached the service; it does not mean the signed-in user
has permission to browse its data.

Use the same network and proxy path as the browser:

```bash
./scripts/test-demo-access.sh
```

In `privateOnly` mode, public probes are intentionally skipped. Open the portal from
inside the connected network (for example, through VPN or a VM in the VNet); a skipped
public check is not a pass.

## Before a demo from a different network

Add the current network's egress ranges to existing Foundry and data-service rules,
then verify them:

```bash
./scripts/allow-demo-access.sh
```

The script detects several shell egress addresses, widens each to `/24` by default,
merges them with existing rules, and runs the same reachability check. This updates
rules in place; it does not redeploy. Use `CLIENT_IP_PREFIX=32` for exact hosts, or set
`ALLOWED_CLIENT_IPS` when the browser's egress is known but differs from the shell's.
`EXTRA_CLIENT_IP_RANGES` adds ranges alongside detected addresses. A `/24` is
convenient for rotating corporate NAT pools but allows a broader set of source
addresses; use the narrowest range that works for the demo.

The next `scripts/deploy.sh` replaces the configured allowlist with the ranges detected
for that deployment. Re-run `allow-demo-access.sh` when the demo network changes.

## Tenant policy and the demo exemption

Storage, Cosmos DB, and Key Vault can be subject to tenant policy that forces
`publicNetworkAccess=Disabled`. In that state, service IP rules do not make those
endpoints reachable. The development parameter file opts those three resource types
out using the tenant's `SecurityControl=Ignore` tag:

```json
"exemptDataResourcesFromNetworkPolicy": { "value": true }
```

The template parameter defaults to `false`; the exemption is therefore not enabled
for other deployments unless explicitly requested. The tag exempts these resources
from the applicable policy initiative, not just its public-access rule. The template
keeps local authentication, Storage shared-key access, and anonymous blob access
disabled as compensating controls. Review the tenant policy and security requirements
before enabling the exemption outside an isolated demo or development environment.

`allow-demo-access.sh` changes IP rules only. It cannot reverse a policy-forced
`publicNetworkAccess=Disabled` state, or the template's fail-closed public-access setting
when it was deployed with an empty allowlist. If Storage, Cosmos DB, or Key Vault still reports
a network denial, verify the resource tag and effective public-network setting, then
redeploy with `exemptDataResourcesFromNetworkPolicy=true` only where policy permits.
Supply an operator range on that deployment; public access is never opened merely
because the allowlist is empty.

## Limits of the check

- The check runs from the shell, not from the browser. A browser proxy or separate
  network path can use a different egress range.
- Passing the check does not validate portal sign-in, Azure RBAC, data-plane roles,
  DNS configuration inside a private network, or every portal feature.
- Cosmos DB and Key Vault may return authorization errors for the probe. Those count
  as network-reachable only when the response does not contain a network-denial
  message.
- Gateway ingress has its own Entra ID and alias-scoped authorization. It is not
  controlled by these operator IP allowlists.
