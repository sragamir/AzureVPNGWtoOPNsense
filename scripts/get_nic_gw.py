#!/usr/bin/env python3
"""Calculate the Azure subnet gateway IP from VM NIC metadata.

Azure reserves the first usable IP in each subnet as the default gateway.
For example, subnet 10.0.0.0/24 → gateway 10.0.0.1.

Usage:
    python3 get_nic_gw.py                  # auto-detect from IMDS
    python3 get_nic_gw.py 10.0.1.0/24      # manual subnet CIDR
"""

import ipaddress
import json
import sys
import urllib.request


IMDS_URL = (
    "http://169.254.169.254/metadata/instance/network/interface"
    "?api-version=2021-02-01"
)


def gateway_from_cidr(cidr: str) -> str:
    """Return first usable host IP (Azure gateway) for the given CIDR."""
    network = ipaddress.ip_network(cidr, strict=False)
    hosts = list(network.hosts())
    if not hosts:
        raise ValueError(f"No usable hosts in {cidr}")
    return str(hosts[0])


def fetch_imds_interfaces() -> list[dict]:
    """Fetch network interface metadata from Azure IMDS."""
    req = urllib.request.Request(IMDS_URL, headers={"Metadata": "true"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


def main() -> None:
    if len(sys.argv) > 1:
        cidr = sys.argv[1]
        print(gateway_from_cidr(cidr))
        return

    try:
        interfaces = fetch_imds_interfaces()
    except Exception as e:
        print(f"Error fetching IMDS: {e}", file=sys.stderr)
        print("Usage: python3 get_nic_gw.py [CIDR]", file=sys.stderr)
        sys.exit(1)

    for iface in interfaces:
        mac = iface.get("macAddress", "unknown")
        for subnet in iface.get("ipv4", {}).get("subnet", []):
            prefix = subnet["address"]
            mask = subnet["prefix"]
            cidr = f"{prefix}/{mask}"
            gw = gateway_from_cidr(cidr)
            print(f"Interface MAC {mac}: subnet {cidr} → gateway {gw}")


if __name__ == "__main__":
    main()
