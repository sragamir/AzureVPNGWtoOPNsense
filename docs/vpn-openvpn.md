# OpenVPN Point-to-Site Configuration

## Overview

OpenVPN P2S with certificate authentication. Good for clients that can't use WireGuard (corporate-managed devices, legacy OS).

## Server Setup

### 1. Create Certificate Authority

1. **System → Trust → Authorities** → **+**
2. Configure:
   - **Descriptive Name**: `OPNsense-CA`
   - **Method**: Create an internal Certificate Authority
   - **Key length**: 4096
   - **Digest Algorithm**: SHA256
   - **Lifetime**: 3650 (10 years)
   - **Country, Org, CN**: Fill as appropriate
3. Save

### 2. Create Server Certificate

1. **System → Trust → Certificates** → **+**
2. Configure:
   - **Method**: Create an internal Certificate
   - **Certificate Authority**: `OPNsense-CA`
   - **Type**: Server Certificate
   - **Key length**: 4096
   - **CN**: `openvpn-server`
   - **Lifetime**: 3650
3. Save

### 3. Create OpenVPN Server

1. **VPN → OpenVPN → Servers** → **+**
2. Configure:
   - **Server Mode**: Remote Access (SSL/TLS)
   - **Protocol**: UDP on IPv4 only
   - **Device Mode**: tun
   - **Interface**: WAN
   - **Local Port**: 1194
   - **TLS Authentication**: Enabled (auto-generate key)
   - **Peer Certificate Authority**: `OPNsense-CA`
   - **Server Certificate**: `openvpn-server`
   - **Encryption Algorithm**: AES-256-GCM
   - **Auth Digest**: SHA256
   - **IPv4 Tunnel Network**: `10.10.1.0/24`
   - **IPv4 Local Network**: `10.200.0.0/16` (Azure VNet — what clients can reach)
   - **Compression**: No Preference (disabled for security)
   - **DNS Server 1**: `168.63.129.16`
3. Save

### 4. Firewall Rules

1. **Firewall → Rules → WAN**: Add rule to allow UDP 1194 inbound (should exist from NSG setup)
2. **Firewall → Rules → OpenVPN**: Add rule to allow all traffic from the tunnel network to LAN

### 5. Create Client Certificates

For each client:

1. **System → Trust → Certificates** → **+**
2. Configure:
   - **Method**: Create an internal Certificate
   - **Certificate Authority**: `OPNsense-CA`
   - **Type**: Client Certificate
   - **CN**: `client-username` (unique per client)
   - **Lifetime**: 365
3. Save

### 6. Export Client Configuration

Install the **os-openvpn-client-export** plugin:

1. **System → Firmware → Plugins** → search for `os-openvpn-client-export` → Install
2. **VPN → OpenVPN → Client Export**
3. Select the server and client certificate
4. Download the `.ovpn` file for the appropriate client OS
5. Import into the client's OpenVPN app

## Client Setup

### Windows
1. Install [OpenVPN Connect](https://openvpn.net/client/)
2. Import the `.ovpn` file
3. Connect

### macOS
1. Install [Tunnelblick](https://tunnelblick.net/) or OpenVPN Connect
2. Import the `.ovpn` file
3. Connect

### Linux
```bash
sudo apt install openvpn
sudo openvpn --config client.ovpn
```

## Certificate Revocation

To revoke a client's access:

1. **System → Trust → Certificates**
2. Find the client certificate → click the revoke icon
3. The CRL is automatically updated and the client can no longer connect

## Troubleshooting

- **VPN → OpenVPN → Connection Status** — check connected clients
- **VPN → OpenVPN → Log File** — detailed connection logs
- Verify NSG allows UDP 1194
- Ensure client's `.ovpn` file has the correct public IP
- Check time sync — certificate validation fails if clocks are off
