# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a planning and scripting repository for replacing Azure VPN Gateway with a self-managed, cost-effective solution using OPNsense on FreeBSD VMs across multiple Azure subscriptions. The goal is to support site-to-site VPN connectivity using L2TP, OpenVPN, or WireGuard while paying only for Azure compute.

## Recommended Approach

**FreeBSD + OPNsense bootstrap** (no VHD upload required):

1. Accept FreeBSD Marketplace terms (once per subscription):
   ```bash
   az vm image terms accept --urn thefreebsdfoundation:freebsd-14_1:14_1-release-amd64-gen2-zfs:14.1.0 -o none
   ```

2. Deploy a FreeBSD 14.1 VM from Azure Marketplace (free image).

3. SSH in and install OPNsense via bootstrap:
   ```bash
   fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh
   sh ./opnsense-bootstrap.sh
   ```

4. Reboot → Access OPNsense UI at `https://<public-ip>`.

## Deployment Options

| Method | Source | Effort |
|---|---|---|
| FreeBSD + bootstrap (recommended) | Azure Marketplace + GitHub script | Easy |
| VHDX download + convert | github.com/maurice-w/opnsense-vm-images | Hard |
| OVA from Deciso | Paid, from Deciso directly | Medium + cost |

## Key External Resources

- **Automated Azure template** (VNet, dual NICs, NSG, optional HA with load balancer): `github.com/dmauser/opnazure`
- **Pre-built VHDX images** (if VHD route needed): `github.com/maurice-w/opnsense-vm-images`
- **OPNsense bootstrap script**: `github.com/opnsense/update`

## Architecture Notes

- Each Azure subscription requires its own OPNsense VM deployment.
- Recommended VM network config: 2 NICs (WAN + LAN) with appropriate NSG rules for VPN protocols.
- For high availability: Active-Active OPNsense pair behind an Azure Load Balancer (see `opnazure` template).
- OPNsense supports all required VPN protocols natively (L2TP, OpenVPN, WireGuard).

## Repository Structure

```
├── deploy.sh                  # Main deployment script (Bash)
├── deploy.ps1                 # PowerShell deployment wrapper
├── destroy.sh                 # Teardown script
├── golden-image.sh            # Capture VM as reusable image
├── scripts/
│   ├── configureopnsense.sh   # CustomScript extension payload (runs inside VM)
│   ├── config-base.xml        # OPNsense config template (%%HOSTNAME%%, %%TRUSTED_GW%%)
│   └── get_nic_gw.py          # Python helper — calculates Azure subnet gateway IP
├── docs/
│   ├── vpn-wireguard.md       # WireGuard S2S + P2S guide
│   ├── vpn-ipsec-s2s.md       # IPsec site-to-site guide
│   ├── vpn-openvpn.md         # OpenVPN P2S guide
│   ├── vpn-l2tp.md            # L2TP/IPsec P2S guide (legacy)
│   ├── migration-guide.md     # VNG → OPNsense migration steps
│   └── raw-info.txt           # Original research notes
└── examples/
    ├── params.env.example     # Sample parameters file
    └── deploy-basic.sh        # Minimal deployment example
```

## Deployment Flow

1. `deploy.sh` creates Azure resources (RG, VNet, NSG, NICs, VM)
2. CustomScript extension runs `scripts/configureopnsense.sh` inside the VM
3. Bootstrap installs OPNsense, applies `config-base.xml`, reinstalls WALinuxAgent
4. VM reboots → OPNsense WebGUI available at `https://<public-ip>`
5. VPN protocols configured via WebGUI (see docs/)
6. `golden-image.sh` captures configured VM for reuse across subscriptions

## Key Parameters

- `CONFIG_BASE_URL` — URL where scripts are hosted (for CustomScript extension to download)
- `FREEBSD_URN` — Can point to Marketplace image or a golden image ID
- All parameters have sensible defaults; only `SUBSCRIPTION_ID` is required
