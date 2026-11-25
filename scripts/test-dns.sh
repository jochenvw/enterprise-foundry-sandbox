#!/usr/bin/env bash
# Print DNS resolution test commands. Private endpoint records only resolve to
# private IPs from inside the VNet (or a peered network / VPN). This script
# prints the hostnames and the commands to run from an in-network machine.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_login

GATEWAY_URL="$(deployment_output aiGatewayUrl)"
CENTRAL="$(deployment_output centralFoundryName)"
TEAM_A="$(deployment_output teamAFoundryName)"
TEAM_B="$(deployment_output teamBFoundryName)"

cat <<EOF
Private DNS / private endpoint resolution test
==============================================
Private endpoints resolve to PRIVATE IPs only from inside the hub/spoke network.
From a public machine these names resolve to public IPs (or NXDOMAIN). Run the
following from a VM inside one of the VNets (deploy one with deployTestVm=true),
from a peered network, or over VPN/Bastion:

  nslookup ${GATEWAY_URL#https://}   # private IP only with deployAiGatewayPrivateEndpoint=true
  nslookup ${CENTRAL:-<central-foundry>}.openai.azure.com
  nslookup ${CENTRAL:-<central-foundry>}.cognitiveservices.azure.com
  nslookup ${TEAM_A:-<team-a-foundry>}.cognitiveservices.azure.com
  nslookup ${TEAM_B:-<team-b-foundry>}.cognitiveservices.azure.com

Expected: addresses in the 10.10/10.20/10.30 ranges for private-endpoint-enabled
resources. Public IPs mean you are resolving from outside the private network.
EOF
