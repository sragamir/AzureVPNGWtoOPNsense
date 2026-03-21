# IPsec Site-to-Site VPN Configuration

## Overview

Configure an IKEv2 IPsec tunnel between OPNsense and a remote site (another OPNsense, Azure VNG, on-prem firewall, etc.).

## Phase 1 (IKE) Settings

These settings are compatible with Azure VPN Gateway and most enterprise firewalls:

| Setting | Value |
|---|---|
| Key Exchange | IKEv2 |
| Authentication | Mutual PSK |
| Encryption | AES-256-GCM |
| Hash | SHA-256 |
| DH Group | 14 (2048-bit MODP) |
| Lifetime | 28800 seconds |

## Phase 2 (IPsec SA) Settings

| Setting | Value |
|---|---|
| Protocol | ESP |
| Encryption | AES-256-GCM |
| Hash | SHA-256 |
| PFS Group | 14 |
| Lifetime | 3600 seconds |

## OPNsense Configuration Steps

### 1. Add Phase 1

1. Navigate to **VPN → IPsec → Tunnel Settings**
2. Click **+** to add a new Phase 1
3. Configure:
   - **Connection method**: Default
   - **Key Exchange version**: V2
   - **Internet Protocol**: IPv4
   - **Interface**: WAN
   - **Remote gateway**: `<remote-peer-public-ip>`
   - **Authentication method**: Mutual PSK
   - **Pre-Shared Key**: `<your-strong-psk>` (min 32 characters recommended)
   - **Encryption Algorithm**: AES → 256 bits → GCM
   - **Hash Algorithm**: SHA256
   - **DH Group**: 14
   - **Lifetime**: 28800
4. Save

### 2. Add Phase 2

1. Click **Show Phase 2 Entries** → **+**
2. Configure:
   - **Mode**: Tunnel IPv4
   - **Local Network**: LAN subnet (e.g., `10.200.1.0/24`)
   - **Remote Network**: Remote LAN subnet (e.g., `10.100.1.0/24`)
   - **Protocol**: ESP
   - **Encryption Algorithms**: AES → 256 bits → GCM
   - **Hash Algorithms**: SHA256
   - **PFS Key Group**: 14
   - **Lifetime**: 3600
3. Save

### 3. Enable IPsec

1. Go to **VPN → IPsec → Tunnel Settings**
2. Check **Enable IPsec**
3. Save and Apply

### 4. Firewall Rules

1. Go to **Firewall → Rules → IPsec**
2. Add a rule:
   - **Action**: Pass
   - **Protocol**: Any
   - **Source**: Remote LAN subnet
   - **Destination**: Local LAN subnet
3. Save and Apply

### 5. Azure Route Table

If the remote site is another Azure VNet, add a route in the remote VNet's route table pointing the local subnet through the remote OPNsense LAN NIC IP.

## Connecting to Azure VPN Gateway

If the remote end is an Azure VNG:

1. Create a **Local Network Gateway** in Azure pointing to the OPNsense public IP
2. Create a **Connection** (Site-to-Site) with the same PSK
3. Ensure the IKE/IPsec proposals match exactly (Azure is strict about this)
4. Azure VNG custom policy must specify: IKEv2, AES256GCM, SHA256, DHGroup14

## Troubleshooting

- **VPN → IPsec → Status Overview** — check SA status
- **VPN → IPsec → Log File** — detailed negotiation logs
- Verify NSG allows UDP 500, 4500, and ESP (protocol 50)
- Check that IP forwarding is enabled on both Azure NICs
- Ensure no overlapping subnets between local and remote networks
