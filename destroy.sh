#!/usr/bin/env bash
# destroy.sh — Tear down the OPNsense VPN deployment
#
# Usage:
#   ./destroy.sh -s <subscription-id> [-g resource-group]
#
set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-opnsense-vpn}"

while getopts "s:g:" opt; do
  case $opt in
    s) SUBSCRIPTION_ID="$OPTARG" ;;
    g) RESOURCE_GROUP="$OPTARG" ;;
    *) echo "Usage: $0 -s <subscription-id> [-g resource-group]"; exit 1 ;;
  esac
done

if [ -z "$SUBSCRIPTION_ID" ]; then
  echo "ERROR: SUBSCRIPTION_ID is required."
  exit 1
fi

az account set --subscription "$SUBSCRIPTION_ID"

echo "WARNING: This will delete resource group '$RESOURCE_GROUP' and ALL resources in it."
echo "Subscription: $SUBSCRIPTION_ID"
echo ""
read -r -p "Type the resource group name to confirm: " CONFIRM

if [ "$CONFIRM" != "$RESOURCE_GROUP" ]; then
  echo "Confirmation failed. Aborting."
  exit 1
fi

echo "--- Deleting resource group '$RESOURCE_GROUP' ---"
az group delete \
  --name "$RESOURCE_GROUP" \
  --yes \
  --no-wait

echo "Resource group deletion initiated (async). It may take a few minutes to complete."
