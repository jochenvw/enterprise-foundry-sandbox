#!/usr/bin/env bash
# End-to-end checks: demo (portal) reachability, gateway reachability, inference,
# isolation and governance, Foundry project connection, the Team A agent with its
# end-to-end trace (agent + gateway spans), and the blocked direct path to central Foundry.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${SCRIPT_DIR}/test-demo-access.sh"
bash "${SCRIPT_DIR}/test-gateway-health.sh"
bash "${SCRIPT_DIR}/test-gateway-inference.sh"
bash "${SCRIPT_DIR}/test-team-isolation.sh"
bash "${SCRIPT_DIR}/test-foundry-project-through-gateway.sh"
bash "${SCRIPT_DIR}/test-end-to-end-trace.sh"
bash "${SCRIPT_DIR}/test-direct-central-foundry-blocked.sh"
