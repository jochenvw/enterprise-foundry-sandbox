#!/usr/bin/env bash
# Shared configuration sourced by the other scripts.
set -euo pipefail

# Deployment name and location for the subscription-scoped deployment.
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-enterprise-foundry}"
export LOCATION="${LOCATION:-swedencentral}"
export FOUNDRY_API_VERSION="${FOUNDRY_API_VERSION:-2026-09-01}"
export INFERENCE_API_VERSION="${INFERENCE_API_VERSION:-2024-10-21}"
# Entra token audiences: AI Gateway runtime and Foundry project data plane.
export AI_GATEWAY_RESOURCE="${AI_GATEWAY_RESOURCE:-https://ai.gateway.azure.com}"
export FOUNDRY_DATA_RESOURCE="${FOUNDRY_DATA_RESOURCE:-https://ai.azure.com}"
# New role assignments can take a few minutes to apply; positive checks retry.
export RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-10}"
export RETRY_DELAY="${RETRY_DELAY:-30}"
export PYTHON="${PYTHON:-python}"

# Resolve repo paths relative to this file so scripts work from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export TEMPLATE_FILE="${REPO_ROOT}/infra/main.bicep"
export PARAMETERS_FILE="${REPO_ROOT}/infra/main.parameters.dev.json"

# Network access mode passed to the template. hybridPePlusIp keeps private
# endpoints AND allowlists the operator's public IP so the environment is usable
# out-of-the-box. Override with NETWORK_ACCESS_MODE (hybridPePlusIp|publicIpOnly|privateOnly).
export NETWORK_ACCESS_MODE="${NETWORK_ACCESS_MODE:-hybridPePlusIp}"

# Detect the operator's public egress for the data-plane allowlist and print it
# as a JSON array of CIDRs. Corporate networks NAT through several addresses
# (and Azure front ends may see different ones), so several echo services are
# queried and each address is widened to its /CLIENT_IP_PREFIX (default 24).
#   ALLOWED_CLIENT_IPS / ALLOWED_CLIENT_IP  replace detection (comma/space list)
#   EXTRA_CLIENT_IP_RANGES                  added to detected ranges
#   CLIENT_IP_PREFIX                        widening prefix (32 = exact hosts)
export CLIENT_IP_PREFIX="${CLIENT_IP_PREFIX:-24}"
CLIENT_IP_ECHO_URLS=(
  https://api.ipify.org
  https://ipv4.icanhazip.com
  https://checkip.amazonaws.com
  https://ifconfig.me/ip
)

detect_client_ip_ranges() {
  local entries=() url ip i
  if [[ -n "${ALLOWED_CLIENT_IPS:-}${ALLOWED_CLIENT_IP:-}" ]]; then
    entries+=("${ALLOWED_CLIENT_IPS:-}" "${ALLOWED_CLIENT_IP:-}")
  else
    for url in "${CLIENT_IP_ECHO_URLS[@]}"; do
      # Repeat each probe: some NAT pools rotate addresses between connections.
      for i in 1 2 3; do
        ip="$(curl -4 -fsS --max-time 8 "${url}" 2>/dev/null | tr -d '[:space:]' || true)"
        [[ -n "${ip}" ]] && entries+=("${ip}")
      done
    done
  fi
  entries+=("${EXTRA_CLIENT_IP_RANGES:-}")
  "${PYTHON}" "${SCRIPT_DIR}/client_ip_ranges.py" "${CLIENT_IP_PREFIX}" "${entries[@]}"
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

access_token() {
  az account get-access-token --resource "$1" --query accessToken -o tsv
}

# POST a JSON payload with a bearer token. Writes the body to RESPONSE_FILE and
# echoes the HTTP status (000 on connection failure).
post_json() {
  local url="$1" token="$2" payload="$3"
  curl -sS --max-time 120 -o "${RESPONSE_FILE}" -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d "${payload}" "${url}" || true
}

# expect_status LABEL URL TOKEN PAYLOAD EXPECTED_REGEX
# Expected 2xx checks retry on 401/403 while new role assignments propagate,
# and on 429 when the backend deployment's rate limit is hit.
# Sets FAIL=1 on mismatch.
expect_status() {
  local label="$1" url="$2" token="$3" payload="$4" expected="$5"
  local attempt=1 code
  while true; do
    code="$(post_json "${url}" "${token}" "${payload}")"
    if [[ "${expected}" == 2* && "${code}" =~ ^(401|403|429)$ && "${attempt}" -lt "${RETRY_ATTEMPTS}" ]]; then
      echo "    ${label}: HTTP ${code}, retrying in ${RETRY_DELAY}s (${attempt}/${RETRY_ATTEMPTS})"
      attempt=$((attempt + 1))
      sleep "${RETRY_DELAY}"
      continue
    fi
    break
  done
  echo "==> ${label}: HTTP ${code}"
  if [[ "${code}" =~ ^(${expected})$ ]]; then
    echo "    PASS"
  else
    echo "    FAIL: expected ${expected}." >&2
    head -c 400 "${RESPONSE_FILE}" >&2 2>/dev/null || true
    echo >&2
    FAIL=1
  fi
}
