# Troubleshooting

## Bicep build fails
- Run `az bicep version` and `az bicep upgrade` to ensure a recent compiler.
- Run `az bicep build --file infra/main.bicep` and read the first error; later errors are
  often cascades of the first.

## `az deployment sub validate` fails on quota or SKU
- APIM Standard v2, AI Search Basic, or Cognitive Services S0 may be quota-limited in the
  subscription/region. Request quota or change SKU/region.
- Confirm the region is `swedencentral` (location code, not a display name).

## Model deployment fails ("model not found" / "not available")
- Run `./scripts/check-model-availability.sh`. Change `centralModelName` /
  `centralModelVersion` in `infra/main.parameters.dev.json` to an available model.
- `latest` may be rejected for some models; use a concrete version.

## APIM deployment is slow
- Standard v2 provisioning commonly takes ~30–45 minutes. This is expected; do not cancel.

## Cannot reach the gateway or Foundry endpoints
- In `hybridPePlusIp` mode, data-plane endpoints accept the allowlisted operator IP. In
  `privateOnly` mode they resolve to private IPs and are only reachable from inside the
  hub/spoke network — use a VM in the VNet (`deployTestVm=true`), a peered network, or
  VPN/Bastion. Use `./scripts/test-dns.sh` for the exact checks.

## Cross-team call unexpectedly succeeds
- Confirm each API requires a subscription (`subscriptionRequired: true`) and that the
  subscription `scope` is the team product (not the global "all APIs" scope).
- Verify the caller is using the correct team key (`sub-team-a` vs `sub-team-b`).

## Direct central model call unexpectedly succeeds
- The calling identity has a Cognitive Services role on the central account. Ensure team
  identities have **no** central-account role; only the APIM MSI should.
- If running from inside the network, a 401/403 (not a connection error) is still the
  correct "blocked" outcome.

## Role assignment "PrincipalNotFound"
- Managed identity principal IDs can take a few seconds to propagate. Re-run the
  deployment; ARM is idempotent and will complete the role assignments.

## Key Vault name already exists / soft-deleted
- Key Vault names are globally unique and soft-deleted on cleanup. Purge with
  `az keyvault purge --name <kv-name> --location swedencentral`, or change the
  `uniqueSuffixOverride` parameter.

## Foundry project connection (postdeploy) prints manual steps
- This is an expected fallback when the REST connection call is not accepted. Follow the
  printed portal steps. See `docs/implementation-gaps.md` §1.
