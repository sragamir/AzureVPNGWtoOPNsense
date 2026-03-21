# L2TP/IPsec Point-to-Site VPN Configuration

## Overview

L2TP/IPsec for legacy clients (built into Windows, macOS, iOS, Android without extra software). Use WireGuard or OpenVPN if possible — L2TP is slower and less flexible.

## Caveats

- **No split tunneling** on most built-in L2TP clients (all traffic goes through VPN)
- **NAT-T required** — uses UDP 500, 4500, and 1701
- **PSK mode** is simpler but less secure than certificate auth
- **Double encapsulation** (IPsec + L2TP) = higher overhead than WireGuard/OpenVPN
- Some corporate firewalls block L2TP ports

## Server Setup

### 1. Enable L2TP Server

1. **VPN → L2TP → Configuration**
2. Configure:
   - **Enable**: Checked
   - **Interface**: WAN
   - **Server Address**: `10.10.2.1` (L2TP tunnel server IP)
   - **Remote Address Range**: `10.10.2.10 - 10.10.2.50`
   - **Subnet Mask**: `255.255.255.0`
   - **DNS Servers**: `168.63.129.16`
   - **Authentication Type**: CHAP / MS-CHAPv2
   - **Secret**: *(leave empty for L2TP/IPsec — IPsec handles encryption)*
3. Save

### 2. Create L2TP Users

1. **VPN → L2TP → Users** → **+**
2. For each user:
   - **Username**: `user@domain`
   - **Password**: Strong password
   - **IP Address**: Leave empty for dynamic, or assign static
3. Save

### 3. Configure IPsec Transport for L2TP

1. **VPN → IPsec → Tunnel Settings** → **+** Phase 1:
   - **Key Exchange**: IKEv1 (required for L2TP compatibility)
   - **Interface**: WAN
   - **Remote gateway**: `0.0.0.0` (any — for road warriors)
   - **Authentication**: Mutual PSK
   - **Pre-Shared Key**: `<your-psk>`
   - **Encryption**: AES-256
   - **Hash**: SHA256
   - **DH Group**: 14
   - **NAT Traversal**: Force
2. Phase 2:
   - **Mode**: Transport
   - **Protocol**: ESP
   - **Encryption**: AES-256
   - **Hash**: SHA256
   - **PFS**: Off
3. Enable IPsec, Save and Apply

### 4. Firewall Rules

1. **Firewall → Rules → L2TP VPN**: Allow all traffic from L2TP clients to LAN
2. Verify NSG has UDP 500, 4500, 1701, and ESP allowed (done by deploy script)

## Client Setup

### Windows 10/11

1. **Settings → Network & Internet → VPN → Add VPN**
2. Configure:
   - **VPN provider**: Windows (built-in)
   - **Connection name**: `Azure VPN`
   - **Server**: `<opnsense-public-ip>`
   - **VPN type**: L2TP/IPsec with pre-shared key
   - **Pre-shared key**: `<your-psk>`
   - **Username/Password**: L2TP user credentials
3. Connect

**Important**: If behind NAT, you may need to add a registry key:

```
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\PolicyAgent
DWORD: AssumeUDPEncapsulationContextOnSendRule = 2
```

Reboot after adding.

### macOS

1. **System Settings → VPN → Add VPN Configuration → L2TP over IPSec**
2. Configure:
   - **Server Address**: `<opnsense-public-ip>`
   - **Account Name**: L2TP username
   - **Authentication Settings**: Password + Shared Secret (PSK)
3. Connect

### iOS / Android

Built-in VPN settings → L2TP/IPsec PSK → enter server IP, credentials, and PSK.

## Troubleshooting

- **VPN → L2TP → Status** — check connected clients
- Windows NAT-T issue is the most common problem — apply the registry fix
- If Phase 1 fails, check that IKEv1 is selected (not IKEv2)
- Verify the PSK matches exactly on both sides
- L2TP requires ESP (protocol 50) — some networks block this
