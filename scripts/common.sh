#!/usr/bin/env bash
# Shared configuration sourced by the other scripts.
set -euo pipefail

# Deployment name and location for the subscription-scoped deployment.
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-enterprise-foundry}"
export LOCATION="${LOCATION:-swedencentral}"

# Resolve repo paths relative to this file so scripts work from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export TEMPLATE_FILE="${REPO_ROOT}/infra/main.bicep"
export PARAMETERS_FILE="${REPO_ROOT}/infra/main.parameters.dev.json"

# Network access mode passed to the template. hybridPePlusIp keeps private
# endpoints AND allowlists the operator's public IP so the environment is usable
# out-of-the-box. Override with NETWORK_ACCESS_MODE (hybridPePlusIp|publicIpOnly|privateOnly).
export NETWORK_ACCESS_MODE="${NETWORK_ACCESS_MODE:-hybridPePlusIp}"

# Detect the operator's public IP for the data-plane allowlist. Honors an
# explicit ALLOWED_CLIENT_IP override; otherwise queries ipify (falls back to
# ifconfig.me). Echoes a bare IP (no CIDR suffix), or empty string on failure.
detect_client_ip() {
  if [[ -n "${ALLOWED_CLIENT_IP:-}" ]]; then
    echo "${ALLOWED_CLIENT_IP}"
    return 0
  fi
  local ip
  ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  fi
  echo "${ip}"
}

# Read a deployment output value by name (empty string if unavailable).
deployment_output() {
  local name="$1"
  az deployment sub show \
    --name "${DEPLOYMENT_NAME}" \
    --query "properties.outputs.${name}.value" \
    -o tsv 2>/dev/null || true
}

require_login() {
  if ! az account show >/dev/null 2>&1; then
    echo "ERROR: Not logged in. Run 'az login' first." >&2
    exit 1
  fi
}
