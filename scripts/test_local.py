import copy
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from check_model import check_model
from client_ip_ranges import normalize


class ClientIpRangeTests(unittest.TestCase):
    def test_egress_ips_widen_dedupe_and_collapse(self):
        ranges = normalize(24, ["167.220.197.171", "167.220.197.43, 167.220.196.43"])
        self.assertEqual(ranges, ["167.220.196.0/23"])

    def test_exact_hosts_drop_32_and_skip_private_and_ipv6(self):
        ranges = normalize(32, ["8.8.8.8", "10.1.2.3", "2001:4860::8888", "20.50.0.0/24", "junk"])
        self.assertEqual(ranges, ["8.8.8.8", "20.50.0.0/24"])


class ModelAvailabilityTests(unittest.TestCase):
    def setUp(self):
        self.parameters = {
            "centralModelName": {"value": "custom-model"},
            "centralModelVersion": {"value": "current"},
            "centralModelSkuName": {"value": "GlobalStandard"},
        }
        self.catalog = [{
            "kind": "AIServices",
            "model": {
                "format": "OpenAI",
                "name": "custom-model",
                "version": "current",
                "isDefaultVersion": True,
                "skus": [{"name": "GlobalStandard"}],
            },
        }]

    def test_configured_model_and_default_version(self):
        check_model(self.parameters, self.catalog)
        self.parameters["centralModelVersion"]["value"] = "latest"
        check_model(self.parameters, self.catalog)

    def test_unavailable_version_or_sku_fails(self):
        for parameter in ("centralModelVersion", "centralModelSkuName"):
            with self.subTest(parameter=parameter):
                parameters = copy.deepcopy(self.parameters)
                parameters[parameter]["value"] = "unavailable"
                with self.assertRaises(ValueError):
                    check_model(parameters, self.catalog)

    def test_openai_only_listing_cannot_validate_aiservices(self):
        self.catalog[0]["kind"] = "OpenAI"
        with self.assertRaises(ValueError):
            check_model(self.parameters, self.catalog)


class GatewayScriptTests(unittest.TestCase):
    def setUp(self):
        git_bash = Path(os.environ.get("ProgramFiles", "")) / "Git" / "bin" / "bash.exe"
        self.bash = str(git_bash) if os.name == "nt" and git_bash.exists() else shutil.which("bash")
        if not self.bash:
            self.fail("Bash is required to run the script regression checks.")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bin = Path(self.temp.name)
        az = self.bin / "az"
        az.write_text("""#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *get-access-token* ]]; then
  [[ "${MOCK_FAILURE:-}" == token ]] && { echo 'ERROR: token unavailable' >&2; exit 1; }
  [[ "${MOCK_FAILURE:-}" == partial-token ]] && { echo partial-token; exit 1; }
  [[ "${MOCK_FAILURE:-}" == empty-token ]] && exit 0
fi
case "$*" in
  *get-access-token*https://ai.gateway.azure.com*) echo gateway-token ;;
  *get-access-token*https://ai.azure.com*) echo foundry-token ;;
  *get-access-token*) echo other-token ;;
  *properties.outputs.aiGatewayUrl.value*) echo https://gw.example ;;
  *properties.outputs.teamAAlias.value*) echo team-a-model ;;
  *properties.outputs.teamBAlias.value*) echo team-b-model ;;
  *properties.outputs.centralModelDeployment.value*) echo deployed-model ;;
  *properties.outputs.centralFoundryName.value*) echo central ;;
  *properties.outputs.teamAProjectEndpoint.value*) echo https://proj-a.example/api/projects/a ;;
  *properties.outputs.teamAFoundryModel.value*) echo conn/team-a-model ;;
  *properties.outputs.networkAccessMode.value*) echo hybridPePlusIp ;;
  *properties.outputs.teamAFoundryName.value*) echo team-a-acct ;;
  *properties.outputs.teamBFoundryName.value*) echo team-b-acct ;;
  *properties.outputs.*ProjectName.value*) echo proj ;;
  *properties.outputs.hubResourceGroup.value*) echo rg-hub ;;
  *properties.outputs.teamAResourceGroup.value*) echo rg-team-a ;;
  *properties.outputs.teamBResourceGroup.value*) echo rg-team-b ;;
  *properties.outputs.*) echo '' ;;
  *resource\\ list*)
    [[ "${MOCK_FAILURE:-}" == listing ]] && { echo 'ERROR: AuthorizationFailed' >&2; exit 1; }
    suffix="${4#rg-}"
    printf 'st%s\\tMicrosoft.Storage/storageAccounts\\n' "${suffix}"
    printf 'cosmos-%s\\tMicrosoft.DocumentDB/databaseAccounts\\n' "${suffix}"
    [[ "${MOCK_FAILURE:-}" == missing ]] || printf 'srch-%s\\tMicrosoft.Search/searchServices\\n' "${suffix}"
    printf 'kv-%s\\tMicrosoft.KeyVault/vaults\\n' "${suffix}"
    ;;
  *role\\ assignment\\ list*)
    [[ "${MOCK_FAILURE:-}" == roles ]] && { echo 'ERROR: AuthorizationFailed' >&2; exit 1; }
    if [[ "${MOCK_FAILURE:-}" == unnamed-role ]]; then
      [[ "$*" == *'[].id'* ]] && echo /subscriptions/test/providers/Microsoft.Authorization/roleAssignments/assigned
      exit 0
    fi
    [[ "${MOCK_FAILURE:-}" == direct ]] && echo 'Cognitive Services User' || true
    ;;
  *rest\\ --method\\ get*)
    [[ "${MOCK_FAILURE:-}" == missing-project-identity ]] || echo project-principal ;;
  *cognitiveservices\\ account\\ show*--query\\ identity.principalId*)
    [[ "${MOCK_FAILURE:-}" == missing-account-identity ]] || echo account-principal ;;
  *resource\\ show*properties.customerId*) echo workspace-guid ;;
  *rest\\ --method\\ post*api.loganalytics.azure.com*)
    [[ "${MOCK_FAILURE:-}" == trace ]] && echo 0 || echo 3 ;;
  *cognitiveservices\\ account\\ show*--query\\ id*) echo /subscriptions/test/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/acct ;;
  *account\\ show*) echo '{}' ;;
  *) exit 1 ;;
esac
""", encoding="utf-8", newline="\n")
        curl = self.bin / "curl"
        curl.write_text("""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "${MOCK_CALLS_FILE}"
request="$*"
fail() { [[ "${MOCK_FAILURE:-}" == "$1" ]]; }
out=""; prev=""
for arg in "$@"; do [[ "$prev" == "-o" ]] && out="$arg"; prev="$arg"; done
if [[ "$request" == *.services.ai.azure.com/api/projects/proj/connections* ]]; then
  code=200
  if fail demo; then
    code=403; printf '%s' 'Access denied due to Virtual Network/Firewall rules.' > "$out"
  fi
elif [[ "$request" != *Authorization* ]]; then
  code=401; fail health && code=200
elif [[ "$request" == *.blob.core.windows.net* || "$request" == *.documents.azure.com* ||
        "$request" == *.search.windows.net* || "$request" == *.vault.azure.net* ||
        "$request" == *.openai.azure.com/openai/v1/models* ]]; then
  code=200
  if fail upstream; then code=502; printf '%s' 'Bad Gateway' > "$out"; fi
  fail not-found && code=404
elif [[ "$request" == *central.openai.azure.com* ]]; then
  code=200
elif [[ "$request" == *proj-a.example/api/projects/a/agents/team-a-demo-agent?api-version=v1* ]]; then
  echo '{}'; exit 0
elif [[ "$request" == *proj-a.example/api/projects/a/agents/team-a-demo-agent/versions* && "$request" == *conn/team-a-model* ]]; then
  code=200
elif [[ "$request" == *proj-a.example/api/projects/a/openai/v1/responses* && "$request" == *agent_reference* && "$request" == *traceparent:\\ 00-* ]]; then
  code=200
  printf '%s' '{"status":"completed","output":[{"type":"message","content":[{"text":"Routing and policy."}]}]}' > "$out"
elif [[ "$request" == *proj-a.example/api/projects/a/openai/v1/responses* && "$request" == *conn/team-a-model* ]]; then
  code=200; fail project && code=500
elif [[ "$request" == *gw.example/default/models/openai/v1/* && "$request" == *gateway-token* && "$request" == *'"model":"team-a-model"'* ]]; then
  code=200; fail inference && code=500
  if fail propagation && [[ ! -e "${MOCK_CALLS_FILE}.retried" ]]; then
    touch "${MOCK_CALLS_FILE}.retried"; code=403
  fi
elif [[ "$request" == *'"model":"team-b-model"'* ]]; then
  code=403; fail isolation && code=200
else
  code=404; fail governance && code=200
fi
printf '%s' "$code"
""", encoding="utf-8", newline="\n")
        az.chmod(0o755)
        curl.chmod(0o755)

    def run_script(self, failure="", script="test-model-through-gateway.sh", attempts=1):
        calls = self.bin / "calls.txt"
        environment = {
            **os.environ,
            "MOCK_BIN": str(self.bin),
            "MOCK_CALLS_FILE": str(calls),
            "MOCK_FAILURE": failure,
            "RETRY_ATTEMPTS": "2",
            "RETRY_DELAY": "0",
            "DEMO_ACCESS_ATTEMPTS": str(attempts),
            "DEMO_ACCESS_DELAY": "0",
            "TRACE_WAIT_ATTEMPTS": "1",
            "SCRIPT_NAME": script,
        }
        for name in ("AI_GATEWAY_RESOURCE", "FOUNDRY_DATA_RESOURCE", "NETWORK_ACCESS_MODE",
                     "SEARCH_DATA_API_VERSION", "STORAGE_DATA_API_VERSION",
                     "KEY_VAULT_DATA_API_VERSION", "COSMOS_DATA_API_VERSION"):
            environment.pop(name, None)
        if os.name == "nt":
            command = (
                'export PATH="$(cygpath -u "$MOCK_BIN"):$PATH"; '
                'export MOCK_CALLS_FILE="$(cygpath -u "$MOCK_CALLS_FILE")"; '
                'bash "$SCRIPT_NAME"'
            )
        else:
            environment["PATH"] = f"{self.bin}{os.pathsep}{environment['PATH']}"
            command = 'bash "$SCRIPT_NAME"'
        result = subprocess.run(
            [self.bash, "-c", command],
            cwd=Path(__file__).resolve().parent,
            env=environment,
            text=True,
            capture_output=True,
            timeout=60,
        )
        return result, calls.read_text(encoding="utf-8") if calls.exists() else ""

    def test_entra_alias_routes_and_project_connection(self):
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("gw.example/default/models/openai/v1/chat/completions", calls)
        self.assertIn("gw.example/default/models/openai/v1/responses", calls)
        self.assertIn("Authorization: Bearer gateway-token", calls)
        self.assertIn("Authorization: Bearer foundry-token", calls)
        self.assertNotIn("api-key", calls)
        for call in calls.splitlines():
            if "/openai/v1/" in call:
                self.assertNotIn("api-version=", call)
        for endpoint in ("stteam-a.blob.core.windows.net", "cosmos-team-b.documents.azure.com",
                         "srch-team-a.search.windows.net", "srch-team-b.search.windows.net",
                         "kv-team-a.vault.azure.net"):
            self.assertIn(endpoint, calls)
        self.assertIn("central.openai.azure.com/openai/v1/models", calls)
        self.assertIn("x-ms-version: 2026-10-06", calls)
        self.assertIn("x-ms-version: 2018-12-31", calls)
        self.assertIn("indexes?api-version=2026-04-01", calls)
        self.assertIn("secrets?api-version=2026-04-01", calls)
        self.assertIn('"model":"deployed-model"', calls)
        self.assertIn("agents/team-a-demo-agent/versions?api-version=v1", calls)
        self.assertIn('"agent_reference"', calls)
        self.assertIn("PASS: one trace ID links", result.stdout)

    def test_missing_trace_fails(self):
        result, _ = self.run_script("trace", script="test-end-to-end-trace.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("did not reach both workspaces", result.stderr)

    def test_role_propagation_is_retried(self):
        result, calls = self.run_script("propagation")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("retrying", result.stdout)

    def test_demo_access_fails_closed_without_data_resources(self):
        for failure, message in (("listing", "Cannot list resources"), ("missing", "missing expected connected")):
            with self.subTest(failure=failure):
                result, _ = self.run_script(failure)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertNotIn("PASS: all Foundry", result.stdout)

    def test_demo_access_rejects_missing_tokens_and_uncertain_http(self):
        for failure in ("token", "empty-token", "upstream", "not-found"):
            with self.subTest(failure=failure):
                result, _ = self.run_script(failure, "test-demo-access.sh")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("UNVERIFIED", result.stdout + result.stderr)
                self.assertNotIn("PASS: all Foundry", result.stdout)

    def test_direct_access_audit_requires_roles_and_both_identities(self):
        for failure, message in (("roles", "Cannot inspect roles"),
                                 ("missing-account-identity", "Missing Team A managed identity"),
                                 ("missing-project-identity", "Missing Team A managed identity")):
            with self.subTest(failure=failure):
                result, _ = self.run_script(failure, "test-direct-central-foundry-blocked.sh")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertNotIn("PASS: team account/project", result.stdout)

    def test_demo_access_retries_do_not_reuse_failed_token_output(self):
        result, calls = self.run_script("partial-token", "test-demo-access.sh", attempts=2)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("UNVERIFIED", result.stderr)
        self.assertNotIn("PASS: all Foundry", result.stdout)
        self.assertEqual(calls, "")

    def test_direct_access_audit_detects_roles_without_display_names(self):
        result, _ = self.run_script("unnamed-role", "test-direct-central-foundry-blocked.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("role assignments /subscriptions/test/", result.stderr)
        self.assertNotIn("PASS: team account/project", result.stdout)

    def test_any_failed_check_fails_suite(self):
        for failure in ("demo", "health", "inference", "isolation", "governance", "project", "direct"):
            with self.subTest(failure=failure):
                result, _ = self.run_script(failure)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
