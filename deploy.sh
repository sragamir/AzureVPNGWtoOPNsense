#!/usr/bin/env bash
# deploy.sh - Deploy an OPNsense VM to replace Azure VPN Gateway
#
# Usage:
#   ./deploy.sh                           # uses defaults + prompts for subscription
#   ./deploy.sh -s <sub-id>               # specify subscription
#   source params.env && ./deploy.sh      # load all params from env file
#
# Environment variables (with defaults):
#   SUBSCRIPTION_ID   - (required) Azure subscription ID
#   RESOURCE_GROUP    - Resource group name          [rg-opnsense-vpn]
#   LOCATION          - Azure region                 [westeurope]
#   VNET_NAME         - Virtual network name         [vnet-opnsense]
#   VNET_CIDR         - VNet address space           [10.200.0.0/16]
#   SUBNET_WAN_NAME   - WAN subnet name              [snet-wan]
#   SUBNET_WAN_CIDR   - WAN subnet                  [10.200.0.0/24]
#   SUBNET_LAN_NAME   - LAN subnet name              [snet-lan]
#   SUBNET_LAN_CIDR   - LAN subnet                  [10.200.1.0/24]
#   VM_NAME           - VM name                      [opnsense-01-vm]
#   VM_SIZE           - VM size                      [Standard_B2ts_v2]
#   ADMIN_USER        - SSH admin user               [azureadmin]
#   ADMIN_PASSWORD    - VM password (prompted if empty)
#   OPNSENSE_VERSION  - OPNsense version to install  [25.1]
#   HOSTNAME_LABEL    - OPNsense hostname            [opn-vpn-01]
#   CONFIG_BASE_URL   - URL prefix for script files
#   FREEBSD_URN       - FreeBSD image URN
#   USE_EXISTING_VNET - Set to "true" to use existing VNet
#
set -euo pipefail

###############################################################################
# Parameters
###############################################################################
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-opnsense-vpn}"
LOCATION="${LOCATION:-westeurope}"
VNET_NAME="${VNET_NAME:-vnet-opnsense}"
VNET_CIDR="${VNET_CIDR:-10.200.0.0/16}"
SUBNET_WAN_NAME="${SUBNET_WAN_NAME:-snet-wan}"
SUBNET_LAN_NAME="${SUBNET_LAN_NAME:-snet-lan}"
SUBNET_WAN_CIDR="${SUBNET_WAN_CIDR:-10.200.0.0/24}"
SUBNET_LAN_CIDR="${SUBNET_LAN_CIDR:-10.200.1.0/24}"
VM_NAME="${VM_NAME:-opnsense-01-vm}"
VM_SIZE="${VM_SIZE:-Standard_B2ts_v2}"
ADMIN_USER="${ADMIN_USER:-azureadmin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
OPNSENSE_VERSION="${OPNSENSE_VERSION:-25.1}"
HOSTNAME_LABEL="${HOSTNAME_LABEL:-opn-vpn-01}"
CONFIG_BASE_URL="${CONFIG_BASE_URL:-https://raw.githubusercontent.com/sragamir/AzureVPNGWtoOPNsense/main/scripts}"
FREEBSD_URN="${FREEBSD_URN:-thefreebsdfoundation:freebsd-14_1:14_1-release-amd64-gen2-zfs:14.1.0}"
USE_EXISTING_VNET="${USE_EXISTING_VNET:-false}"

# Derive resource names from VM name prefix (e.g. opnsense-01-vm -> opnsense-01-nsg)
NAME_PREFIX="${VM_NAME%-vm}"
NSG_NAME="${NAME_PREFIX}-nsg"
PIP_NAME="${NAME_PREFIX}-pip"
NIC_WAN_NAME="${NAME_PREFIX}-nic-wan"
NIC_LAN_NAME="${NAME_PREFIX}-nic-lan"
RT_NAME="${NAME_PREFIX}-rt"

# Parse CLI args
while getopts "s:g:l:p:" opt; do
  case $opt in
    s) SUBSCRIPTION_ID="$OPTARG" ;;
    g) RESOURCE_GROUP="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    p) ADMIN_PASSWORD="$OPTARG" ;;
    *) echo "Usage: $0 [-s subscription_id] [-g resource_group] [-l location] [-p admin_password]"; exit 1 ;;
  esac
done

if [ -z "$SUBSCRIPTION_ID" ]; then
  echo "ERROR: SUBSCRIPTION_ID is required. Pass it via -s flag or environment variable."
  exit 1
fi

# Prompt for password if not provided
if [ -z "$ADMIN_PASSWORD" ]; then
  echo "Password must be 12-72 chars with uppercase, lowercase, digit, and special character."
  read -r -s -p "Enter admin password for VM: " ADMIN_PASSWORD
  echo ""
  read -r -s -p "Confirm password: " ADMIN_PASSWORD_CONFIRM
  echo ""
  if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
    echo "ERROR: Passwords do not match."
    exit 1
  fi
fi

echo "=== OPNsense VPN VM Deployment ==="
echo "Subscription: $SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP ($LOCATION)"
echo "VM: $VM_NAME ($VM_SIZE)"
echo ""

###############################################################################
# Set subscription
###############################################################################
az account set --subscription "$SUBSCRIPTION_ID"

###############################################################################
# Accept FreeBSD Marketplace terms
###############################################################################
echo "--- Accepting FreeBSD Marketplace terms ---"
az vm image terms accept --urn "$FREEBSD_URN" -o none 2>/dev/null || true

###############################################################################
# Resource Group
###############################################################################
echo "--- Creating resource group ---"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  -o none

###############################################################################
# Virtual Network + Subnets
###############################################################################
if [ "$USE_EXISTING_VNET" = "true" ]; then
  echo "--- Using existing VNet '$VNET_NAME' with subnets '$SUBNET_WAN_NAME' and '$SUBNET_LAN_NAME' ---"
  az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_WAN_NAME" -o none
  az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_LAN_NAME" -o none
else
  echo "--- Creating VNet and subnets ---"
  az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --address-prefix "$VNET_CIDR" \
    --subnet-name "$SUBNET_WAN_NAME" \
    --subnet-prefix "$SUBNET_WAN_CIDR" \
    -o none

  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_LAN_NAME" \
    --address-prefix "$SUBNET_LAN_CIDR" \
    -o none 2>/dev/null || true
fi

###############################################################################
# Network Security Group
###############################################################################
echo "--- Creating NSG ---"
az network nsg create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NSG_NAME" \
  -o none

declare -A NSG_RULES=(
  ["Allow-SSH"]="100 Tcp 22"
  ["Allow-HTTPS"]="110 Tcp 443"
  ["Allow-WireGuard"]="120 Udp 51820"
  ["Allow-IPsec-IKE"]="130 Udp 500"
  ["Allow-IPsec-NAT-T"]="140 Udp 4500"
  ["Allow-OpenVPN"]="150 Udp 1194"
  ["Allow-L2TP"]="160 Udp 1701"
)

for RULE_NAME in "${!NSG_RULES[@]}"; do
  read -r PRIORITY PROTOCOL PORT <<< "${NSG_RULES[$RULE_NAME]}"
  az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "$RULE_NAME" \
    --priority "$PRIORITY" \
    --direction Inbound \
    --access Allow \
    --protocol "$PROTOCOL" \
    --source-address-prefixes '*' \
    --destination-port-ranges "$PORT" \
    -o none 2>/dev/null || true
done

az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "Allow-ESP" \
  --priority 170 \
  --direction Inbound \
  --access Allow \
  --protocol Esp \
  --source-address-prefixes '*' \
  --destination-port-ranges '*' \
  -o none 2>/dev/null || true

###############################################################################
# Public IP
###############################################################################
echo "--- Creating Public IP ---"
az network public-ip create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PIP_NAME" \
  --sku Standard \
  --allocation-method Static \
  -o none

###############################################################################
# NICs (WAN + LAN) with IP forwarding
###############################################################################
echo "--- Creating NICs ---"
az network nic create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NIC_WAN_NAME" \
  --vnet-name "$VNET_NAME" \
  --subnet "$SUBNET_WAN_NAME" \
  --network-security-group "$NSG_NAME" \
  --public-ip-address "$PIP_NAME" \
  --ip-forwarding true \
  -o none

az network nic create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NIC_LAN_NAME" \
  --vnet-name "$VNET_NAME" \
  --subnet "$SUBNET_LAN_NAME" \
  --ip-forwarding true \
  -o none

###############################################################################
# FreeBSD VM
###############################################################################
echo "--- Creating FreeBSD VM ---"
az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --image "$FREEBSD_URN" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --admin-password "$ADMIN_PASSWORD" \
  --authentication-type password \
  --nics "$NIC_WAN_NAME" "$NIC_LAN_NAME" \
  --os-disk-size-gb 30 \
  --storage-sku StandardSSD_LRS \
  -o none

###############################################################################
# Get public IP and calculate gateway
###############################################################################
PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$PIP_NAME" \
  --query ipAddress -o tsv)

WAN_SUBNET_PREFIX=$(az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_WAN_NAME" \
  --query "addressPrefix" -o tsv)
GATEWAY_IP=$(echo "$WAN_SUBNET_PREFIX" | sed 's|/.*||; s|\.[0-9]*$|.1|')
echo "    WAN Gateway IP: $GATEWAY_IP"

###############################################################################
# Install bash (required for CustomScript extension handler)
###############################################################################
echo "--- Installing bash on FreeBSD ---"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${ADMIN_USER}@${PUBLIC_IP}" \
  "echo '${ADMIN_PASSWORD}' | sudo -S pkg install -y bash"

###############################################################################
# Run OPNsense bootstrap via CustomScriptForLinux v1.5 (works on FreeBSD)
###############################################################################
echo "--- Running OPNsense bootstrap via CustomScript extension ---"
echo "    This will take 10-15 minutes..."

az vm extension set \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --name CustomScriptForLinux \
  --publisher Microsoft.OSTCExtensions \
  --version 1.5 \
  --settings "{
    \"fileUris\": [
      \"${CONFIG_BASE_URL}/configureopnsense.sh\",
      \"${CONFIG_BASE_URL}/config-base.xml\"
    ],
    \"commandToExecute\": \"sh configureopnsense.sh '${CONFIG_BASE_URL}' '${OPNSENSE_VERSION}' '${GATEWAY_IP}' '${PUBLIC_IP}'\"
  }" \
  -o none || echo "    Extension reported non-zero exit (expected if VM rebooted during bootstrap)."

###############################################################################
# Route Table
###############################################################################
echo "--- Creating route table ---"
LAN_NIC_IP=$(az network nic show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NIC_LAN_NAME" \
  --query 'ipConfigurations[0].privateIpAddress' -o tsv 2>/dev/null || echo "")

if [ -z "$LAN_NIC_IP" ]; then
  echo "    Could not auto-detect LAN NIC IP."
  read -r -p "    Enter LAN NIC private IP (or press Enter to skip): " LAN_NIC_IP
fi

if [ -n "$LAN_NIC_IP" ]; then
  echo "    LAN NIC IP: $LAN_NIC_IP"

  az network route-table create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$RT_NAME" \
    -o none

  az network route-table route create \
    --resource-group "$RESOURCE_GROUP" \
    --route-table-name "$RT_NAME" \
    --name "route-via-opnsense" \
    --address-prefix "0.0.0.0/0" \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address "$LAN_NIC_IP" \
    -o none

  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_LAN_NAME" \
    --route-table "$RT_NAME" \
    -o none
else
  echo "    Skipped route table creation."
fi

###############################################################################
# Output
###############################################################################
echo ""
echo "=== Deployment Complete ==="
echo "Public IP:    $PUBLIC_IP"
echo "SSH:          ssh root@${PUBLIC_IP}  (password: opnsense)"
echo "WebGUI:       https://${PUBLIC_IP}"
echo "Credentials:  root / opnsense (change immediately!)"
echo ""
echo "The VM will reboot in ~1 minute to finalize OPNsense installation."
echo "Wait 3-5 minutes, then access the WebGUI."
