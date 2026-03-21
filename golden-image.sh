#!/usr/bin/env bash
# golden-image.sh — Capture a configured OPNsense VM as a reusable Azure image
#
# Prerequisites:
#   - VM is fully configured and tested (VPN working, WebGUI accessible)
#   - SSH access to the VM
#
# Usage:
#   ./golden-image.sh -s <subscription-id> [-g resource-group] [-v vm-name] [-i image-name]
#
set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-opnsense-vpn}"
VM_NAME="${VM_NAME:-opnsense-01-vm}"
IMAGE_NAME="${IMAGE_NAME:-img-opnsense-golden}"
IMAGE_RG="${IMAGE_RG:-$RESOURCE_GROUP}"
ADMIN_USER="${ADMIN_USER:-azureadmin}"

while getopts "s:g:v:i:" opt; do
  case $opt in
    s) SUBSCRIPTION_ID="$OPTARG" ;;
    g) RESOURCE_GROUP="$OPTARG" ;;
    v) VM_NAME="$OPTARG" ;;
    i) IMAGE_NAME="$OPTARG" ;;
    *) echo "Usage: $0 -s <sub-id> [-g rg] [-v vm-name] [-i image-name]"; exit 1 ;;
  esac
done

if [ -z "$SUBSCRIPTION_ID" ]; then
  echo "ERROR: SUBSCRIPTION_ID is required."
  exit 1
fi

az account set --subscription "$SUBSCRIPTION_ID"

# Get VM public IP for SSH
PUBLIC_IP=$(az vm list-ip-addresses \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query '[0].virtualMachine.network.publicIpAddresses[0].ipAddress' -o tsv)

echo "=== Golden Image Capture ==="
echo "VM: $VM_NAME ($RESOURCE_GROUP)"
echo "Image: $IMAGE_NAME"
echo "Public IP: $PUBLIC_IP"
echo ""

###############################################################################
# Step 1: Deprovision the VM (remove machine-specific data)
###############################################################################
echo "--- Step 1: Deprovisioning VM via SSH ---"
echo "This will remove SSH host keys, DHCP leases, and user-specific data."
read -r -p "Continue? (y/N): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "Aborted."
  exit 0
fi

ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no \
  "${ADMIN_USER}@${PUBLIC_IP}" \
  "sudo waagent -deprovision+user -force"

###############################################################################
# Step 2: Deallocate the VM
###############################################################################
echo "--- Step 2: Deallocating VM ---"
az vm deallocate \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME"

###############################################################################
# Step 3: Generalize the VM
###############################################################################
echo "--- Step 3: Generalizing VM ---"
az vm generalize \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME"

###############################################################################
# Step 4: Create the image
###############################################################################
echo "--- Step 4: Creating managed image ---"
VM_ID=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query id -o tsv)

az image create \
  --resource-group "$IMAGE_RG" \
  --name "$IMAGE_NAME" \
  --source "$VM_ID" \
  --hyper-v-generation V2 \
  -o none

IMAGE_ID=$(az image show \
  --resource-group "$IMAGE_RG" \
  --name "$IMAGE_NAME" \
  --query id -o tsv)

echo ""
echo "=== Golden Image Created ==="
echo "Image Name: $IMAGE_NAME"
echo "Image ID:   $IMAGE_ID"
echo ""
echo "To deploy a new VM from this image, set FREEBSD_URN to the image ID:"
echo ""
echo "  FREEBSD_URN=\"$IMAGE_ID\" ./deploy.sh -s <sub-id>"
echo ""
echo "NOTE: The source VM ($VM_NAME) is now generalized and cannot be restarted."
echo "Delete it and redeploy if you need a running instance."
