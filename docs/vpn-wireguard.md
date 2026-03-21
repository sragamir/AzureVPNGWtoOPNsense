# WireGuard VPN Configuration

## Overview

WireGuard is the recommended VPN protocol for this deployment — it's fast, simple, and works well for both site-to-site (S2S) and point-to-site (P2S) connections.

## Site-to-Site Configuration

### On OPNsense (Hub)

#### 1. Create WireGuard Instance

1. Navigate to **VPN → WireGuard → Instances**
2. Click **+** to add:
   - **Name**: `wg0`
   - **Listen Port**: `51820`
   - **Tunnel Address**: `10.10.0.1/24` (WireGuard tunnel network)
   - Click **Generate** to create a key pair
   - **Save** the public key — you'll need it for the remote peer
3. Save and Apply

#### 2. Add Remote Peer

1. Go to **VPN → WireGuard → Peers**
2. Click **+**:
   - **Name**: `remote-site-01`
   - **Public Key**: `<remote-peer-public-key>`
   - **Allowed IPs**: `10.10.0.2/32, 10.100.0.0/16` (tunnel IP + remote LAN)
   - **Endpoint Address**: `<remote-peer-public-ip>`
   - **Endpoint Port**: `51820`
   - **Keepalive**: `25` (important for Azure — keeps NAT mappings alive)
3. Save and Apply

#### 3. Assign Interface

1. Go to **Interfaces → Assignments**
2. Assign `wg0` as a new interface (e.g., `OPT1`)
3. Enable the interface, set IPv4 to the tunnel address `10.10.0.1/24`
4. Save and Apply

#### 4. Firewall Rules

1. **Firewall → Rules → WireGuard**:
   - Allow traffic from `10.10.0.0/24` (tunnel network) to LAN subnet
2. **Firewall → Rules → LAN**:
   - Allow traffic from LAN to `10.100.0.0/16` (remote network)

#### 5. Static Route (if needed)

1. **System → Routes → Configuration**
2. Add route: `10.100.0.0/16` via `10.10.0.2` (gateway = remote tunnel IP)

### On Remote Peer

Use the same WireGuard configuration mirrored. The remote peer's config:

```ini
[Interface]
PrivateKey = <remote-private-key>
Address = 10.10.0.2/24
ListenPort = 51820

[Peer]
PublicKey = <opnsense-public-key>
AllowedIPs = 10.10.0.1/32, 10.200.0.0/16
Endpoint = <opnsense-public-ip>:51820
PersistentKeepalive = 25
```

## Point-to-Site Configuration

### 1. Create WireGuard Instance

Same as S2S above — reuse `wg0` or create a separate instance on a different port.

### 2. Add Client Peers

For each P2S client, add a peer:

1. **VPN → WireGuard → Peers** → **+**
2. Configure:
   - **Name**: `client-laptop-01`
   - **Public Key**: `<client-public-key>`
   - **Allowed IPs**: `10.10.0.10/32` (unique tunnel IP per client)
   - **Endpoint**: Leave empty (clients initiate)
3. Save and Apply

### 3. Client Configuration Template

Generate this for each client (replace values):

```ini
[Interface]
PrivateKey = <client-private-key>
Address = 10.10.0.10/24
DNS = 168.63.129.16

[Peer]
PublicKey = <opnsense-public-key>
AllowedIPs = 10.200.0.0/16, 10.10.0.0/24
Endpoint = <opnsense-public-ip>:51820
PersistentKeepalive = 25
```

**Split tunnel** (only Azure traffic through VPN): Use specific `AllowedIPs` like above.

**Full tunnel** (all traffic through VPN): Set `AllowedIPs = 0.0.0.0/0`.

### 4. Client Key Generation

On the client machine:

```bash
# Linux/macOS
wg genkey | tee privatekey | wg pubkey > publickey

# Windows (PowerShell) — use the WireGuard GUI or:
# Install WireGuard, then use the "Add Empty Tunnel" option
```

## Azure-Specific Notes

- NSG must allow UDP 51820 inbound
- Keep `PersistentKeepalive = 25` on all peers — Azure's NAT drops idle UDP flows after ~4 minutes
- For S2S between two Azure OPNsense VMs, update route tables in both VNets

## Troubleshooting

- **VPN → WireGuard → Diagnostics** — check handshake status
- No handshake = firewall/NAT issue or wrong public keys
- `Latest handshake` should update every ~2 minutes with keepalive
- Check **Firewall → Log Files → Live View** for blocked WireGuard traffic
