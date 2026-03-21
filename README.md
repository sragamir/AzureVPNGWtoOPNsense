# Azure VPN Gateway Replacement with OPNsense

Replace expensive Azure VPN Gateways ($27-357/month each) with a FreeBSD VM running OPNsense (~$30/month on B2s). Supports WireGuard, IPsec, OpenVPN, and L2TP for both site-to-site and point-to-site VPN.

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │         Azure Subscription          │
                    │                                     │
Internet ──────────┤  ┌──────────┐    ┌──────────────┐   │
                    │  │ Public IP│────│  OPNsense VM │   │
                    │  └──────────┘    │  (FreeBSD)   │   │
                    │                  │              │   │
                    │       WAN NIC ───┤  hn0    hn1  ├───│── LAN Subnet
                    │    (snet-wan)    │              │   │   (snet-lan)
                    │                  └──────────────┘   │
                    │                                     │
                    │  VPN Protocols:                     │
                    │  • WireGuard  (UDP 51820)           │
                    │  • IPsec     (UDP 500/4500, ESP)    │
                    │  • OpenVPN   (UDP 1194)             │
                    │  • L2TP      (UDP 1701)             │
                    └─────────────────────────────────────┘
```

## Cost Comparison

| Solution | Monthly Cost | VPN Protocols |
|---|---|---|
| Azure VNG Basic | ~$27 | IPsec only |
| Azure VNG VpnGw1 | ~$140 | IPsec, OpenVPN |
| **OPNsense on B2s** | **~$30** | **All (WG, IPsec, OVPN, L2TP)** |

## Quick Start

### Prerequisites

- Azure CLI installed and logged in (`az login`)
- Bash shell (WSL, Git Bash, or Linux/macOS)
- VM uses password authentication (prompted during deploy)

### Deploy

```bash
# 1. Clone this repo and cd into it

# 2. Deploy (replace with your subscription ID)
./deploy.sh -s "00000000-0000-0000-0000-000000000000"

# 3. Wait 3-5 minutes for OPNsense bootstrap to complete

# 4. Access WebGUI at https://<public-ip>
#    Default credentials: root / opnsense
```

### PowerShell Alternative

```powershell
.\deploy.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

### Using Parameters File

```bash
cp examples/params.env.example params.env
# Edit params.env with your values
source params.env && ./deploy.sh
```

### Tear Down

```bash
./destroy.sh -s "00000000-0000-0000-0000-000000000000"
```

## VPN Configuration Guides

After deployment, configure VPN through the OPNsense WebGUI:

- **[WireGuard](docs/vpn-wireguard.md)** — Recommended. Fast, simple, S2S + P2S
- **[IPsec S2S](docs/vpn-ipsec-s2s.md)** — Site-to-site, Azure VNG compatible
- **[OpenVPN](docs/vpn-openvpn.md)** — P2S with certificate auth
- **[L2TP/IPsec](docs/vpn-l2tp.md)** — Legacy P2S (built-in OS clients)

## Migrating from Azure VPN Gateway

See **[Migration Guide](docs/migration-guide.md)** for step-by-step instructions to safely replace an existing VNG with OPNsense, including parallel operation and rollback.

## Golden Image

After testing, capture the configured VM as a reusable image for quick deployment to other subscriptions:

```bash
./golden-image.sh -s "00000000-0000-0000-0000-000000000000"
```

## Repository Structure

```
├── deploy.sh                  # Main deployment script (Bash)
├── deploy.ps1                 # PowerShell deployment wrapper
├── destroy.sh                 # Teardown script
├── golden-image.sh            # Capture VM as reusable image
├── scripts/
│   ├── configureopnsense.sh   # CustomScript extension payload
│   ├── config-base.xml        # OPNsense config template
│   └── get_nic_gw.py          # Subnet gateway calculator
├── docs/
│   ├── vpn-wireguard.md       # WireGuard setup guide
│   ├── vpn-ipsec-s2s.md       # IPsec S2S setup guide
│   ├── vpn-openvpn.md         # OpenVPN P2S setup guide
│   ├── vpn-l2tp.md            # L2TP/IPsec P2S setup guide
│   ├── migration-guide.md     # VNG → OPNsense migration
│   └── raw-info.txt           # Original research notes
└── examples/
    ├── params.env.example     # Sample parameters file
    └── deploy-basic.sh        # Minimal deployment example
```

## Defaults

| Parameter | Default |
|---|---|
| VM Size | Standard_B2s (~$30/month) |
| Location | westeurope |
| FreeBSD Image | 14.1-RELEASE (Gen2, ZFS) |
| OPNsense Version | 26.1 |
| VNet CIDR | 10.200.0.0/16 |
| WAN Subnet | 10.200.0.0/24 |
| LAN Subnet | 10.200.1.0/24 |

## Future Enhancements

- Active-Active HA with Azure Load Balancer (see [opnazure](https://github.com/dmauser/opnazure))
- Automated VPN configuration via OPNsense API (XML/REST)
- Multi-subscription deployment orchestrator
- Monitoring integration (Azure Monitor / Grafana)
