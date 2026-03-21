#!/usr/bin/env bash
# deploy-basic.sh — Minimal OPNsense deployment example
#
# Usage: ./examples/deploy-basic.sh <subscription-id>

set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <subscription-id>"
  exit 1
fi

export SUBSCRIPTION_ID="$1"
export RESOURCE_GROUP="rg-opnsense-vpn"
export LOCATION="westeurope"
export VM_SIZE="Standard_B2s"

# Run the main deployment script
"$(dirname "$0")/../deploy.sh"
