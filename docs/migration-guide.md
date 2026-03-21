# Migration Guide: Azure VPN Gateway → OPNsense VM

## Overview

This guide covers replacing an existing Azure Virtual Network Gateway (VNG) with an OPNsense VM. The approach runs both in parallel during transition to minimize downtime.

## Prerequisites

- Existing VNG deployment documented (connections, PSKs, routes)
- OPNsense VM deployed and accessible via WebGUI
- Access to remote peer configurations (on-prem firewalls, other VNGs)
- Maintenance window agreed with stakeholders

## Step 1: Document Current VNG Configuration

Before touching anything, capture your current setup:

```bash
# List all VNG connections
az network vpn-connection list \
  --resource-group <rg-with-vng> \
  -o table

# Get connection details (including shared key)
az network vpn-connection show \
  --resource-group <rg-with-vng> \
  --name <connection-name> \
  -o json

# Get local network gateway config (remote peer info)
az network local-gateway show \
  --resource-group <rg-with-vng> \
  --name <local-gw-name> \
  -o json

# List effective routes
az network nic show-effective-route-table \
  --resource-group <rg> \
  --name <nic-name> \
  -o table

# Export P2S client config (if applicable)
az network vnet-gateway vpn-client generate \
  --resource-group <rg-with-vng> \
  --name <vng-name> \
  -o tsv
```

Save all outputs. You'll need:
- Remote peer public IPs
- Pre-shared keys
- Local and remote address spaces
- IKE/IPsec proposals
- Any BGP settings
- P2S address pools and client certificates

## Step 2: Deploy OPNsense Alongside VNG

Run `deploy.sh` in the **same VNet** or a **peered VNet**:

- If same VNet: Use different subnets for OPNsense WAN/LAN
- If peered VNet: Set up VNet peering first

The VNG continues handling all traffic during this phase.

## Step 3: Configure Matching VPN Tunnels

Recreate each VNG connection on OPNsense:

### For IPsec S2S Connections

1. Follow [docs/vpn-ipsec-s2s.md](vpn-ipsec-s2s.md)
2. Use the **same PSK and proposals** as the VNG connection
3. Use the **same local/remote subnets**
4. Do NOT enable the tunnel yet

### For P2S Connections

1. Choose protocol: WireGuard ([docs/vpn-wireguard.md](vpn-wireguard.md)) or OpenVPN ([docs/vpn-openvpn.md](vpn-openvpn.md))
2. Set up the server and create client configs
3. Distribute new client configs to users (but don't switch yet)

## Step 4: Test in Parallel

### 4a. Test S2S Tunnels

1. Coordinate with the remote peer admin
2. Add a **secondary tunnel** on the remote peer pointing to the OPNsense public IP
3. Enable the OPNsense tunnel
4. Test connectivity:
   - Ping across the tunnel
   - Test application traffic
   - Verify routing is correct
5. Monitor for 1-2 hours

### 4b. Test P2S Clients

1. Have 1-2 pilot users install the new VPN client config
2. Verify they can reach the same resources as through the VNG P2S
3. Test disconnection/reconnection

## Step 5: Cut Over

### Update Route Tables

```bash
# Get OPNsense LAN NIC IP
OPNSENSE_LAN_IP=$(az network nic show \
  --resource-group <rg> \
  --name nic-opnsense-lan \
  --query 'ipConfigurations[0].privateIpAddress' -o tsv)

# Update UDRs to point through OPNsense instead of VNG
az network route-table route update \
  --resource-group <rg> \
  --route-table-name <rt-name> \
  --name <route-name> \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address "$OPNSENSE_LAN_IP"
```

### Update Remote Peers

1. On each remote peer, change the primary tunnel endpoint to the OPNsense public IP
2. Remove or disable the tunnel pointing to the old VNG IP

### Switch P2S Clients

1. Push the new VPN client configuration to all users
2. Instruct users to disconnect old VPN and connect with new config

### Remove VNG Gateway Subnet Route

If the VNG was the default gateway via GatewaySubnet, remove that association.

## Step 6: Monitor

- Watch OPNsense **Firewall → Log Files → Live View** for unexpected blocks
- Check **VPN → [Protocol] → Status** for all tunnels
- Verify all applications work end-to-end
- Monitor for **24-48 hours** before decommissioning VNG

## Step 7: Decommission VNG

After confirming everything works:

```bash
# Delete VPN connections first
az network vpn-connection delete \
  --resource-group <rg-with-vng> \
  --name <connection-name>

# Delete local network gateways
az network local-gateway delete \
  --resource-group <rg-with-vng> \
  --name <local-gw-name>

# Delete the VPN gateway (takes 15-30 minutes)
az network vnet-gateway delete \
  --resource-group <rg-with-vng> \
  --name <vng-name>

# Delete GatewaySubnet (optional — no cost, can keep for rollback)
az network vnet subnet delete \
  --resource-group <rg-with-vng> \
  --vnet-name <vnet-name> \
  --name GatewaySubnet
```

## Rollback Plan

If issues are found during monitoring:

1. Re-enable the VNG tunnel on remote peers (they still have the config)
2. Revert route table entries to point to VNG
3. Switch P2S clients back to old config
4. Investigate the issue on OPNsense and retry

The VNG continues to exist (and bill) until explicitly deleted, so rollback is safe as long as you don't delete it prematurely.

## Cost Savings

| Component | VNG (Basic) | VNG (VpnGw1) | OPNsense B2s |
|---|---|---|---|
| Monthly cost | ~$27 | ~$140 | ~$30 |
| Per 5 subscriptions | ~$135 | ~$700 | ~$150 |
| VPN protocols | IPsec only | IPsec, OpenVPN | All (WG, IPsec, OVPN, L2TP) |
| P2S clients | Limited | 128-250 | Unlimited (VM capacity) |
