#!/bin/sh
# configureopnsense.sh - Installs OPNsense on a FreeBSD 14.1 Azure VM
# Based on: github.com/HoussemDellai/azure-network-course/205_nva_opnsense
#
# Parameters:
#   $1 = Config base URL (where config-base.xml is hosted)
#   $2 = OPNsense version (e.g. "25.1")
#   $3 = Subnet gateway IP (first usable IP in WAN subnet)
#   $4 = Public IP of this VM

CONFIG_BASE_URL="${1:-https://raw.githubusercontent.com/sragamir/AzureVPNGWtoOPNsense/main/scripts}"
OPNSENSE_VERSION="${2:-25.1}"
GATEWAY_IP="${3}"
PUBLIC_IP="${4}"

LOG="/var/log/configureopnsense.log"
exec > "$LOG" 2>&1

echo "=== OPNsense bootstrap started at $(date) ==="
echo "Version: $OPNSENSE_VERSION | GW: $GATEWAY_IP | PIP: $PUBLIC_IP"

###############################################################################
# 1. Fetch and apply config.xml
###############################################################################
fetch "${CONFIG_BASE_URL}/config-base.xml"
if [ -n "$GATEWAY_IP" ]; then
  sed -i "" "s/%%TRUSTED_GW%%/$GATEWAY_IP/" config-base.xml
fi
if [ -n "$PUBLIC_IP" ]; then
  sed -i "" "s/%%PUBLIC_IP%%/$PUBLIC_IP/" config-base.xml
fi
cp config-base.xml /usr/local/etc/config.xml

###############################################################################
# 2. Download and run OPNsense bootstrap
###############################################################################
fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in

# Enable root SSH login
sed -i "" 's/#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config

# Patch bootstrap: disable set -e and delay reboot
sed -i "" "s/set -e/#set -e/g" opnsense-bootstrap.sh.in
sed -i "" "s/reboot/shutdown -r +1/g" opnsense-bootstrap.sh.in

echo "=== Running OPNsense bootstrap ==="
sh ./opnsense-bootstrap.sh.in -y -r "$OPNSENSE_VERSION"

###############################################################################
# 3. Install bash (required for Azure CustomScript extension) and FRR
###############################################################################
echo "=== Installing packages ==="
pkg install -y bash
pkg install -y os-frr

###############################################################################
# 4. Fix Azure route for metadata IP 168.63.129.16
###############################################################################
echo "=== Configuring Azure route fix ==="
mkdir -p /usr/local/etc/rc.syshook.d/start
cat > /usr/local/etc/rc.syshook.d/start/22-remoteroute <<EOL
#!/bin/sh
route delete 168.63.129.16
EOL
chmod +x /usr/local/etc/rc.syshook.d/start/22-remoteroute

###############################################################################
# 5. Static ARP for Azure load balancer health probe (168.63.129.16)
###############################################################################
echo "=== Configuring Azure ARP ==="
echo "# Add Azure Internal VIP" >> /etc/rc.conf
echo 'static_arp_pairs="azvip"' >> /etc/rc.conf
echo 'static_arp_azvip="168.63.129.16 12:34:56:78:9a:bc"' >> /etc/rc.conf
service static_arp start
# Persist across reboots via OPNsense syshook
echo "service static_arp start" >> /usr/local/etc/rc.syshook.d/start/20-freebsd

###############################################################################
# 6. Reset WebGUI certificate on first boot (self-deleting hook)
###############################################################################
echo "=== Configuring WebGUI cert renewal ==="
cat > /usr/local/etc/rc.syshook.d/start/94-restartwebgui <<'WEBGUI'
#!/bin/sh
configctl webgui restart renew
rm /usr/local/etc/rc.syshook.d/start/94-restartwebgui
WEBGUI
chmod +x /usr/local/etc/rc.syshook.d/start/94-restartwebgui

echo "=== Bootstrap complete. VM will reboot shortly. ==="
