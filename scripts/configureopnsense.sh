#!/bin/sh
# configureopnsense.sh — Azure CustomScript extension payload
# Installs OPNsense on a FreeBSD 14.1 VM and applies base configuration.
#
# Parameters (passed as CustomScript arguments):
#   $1 = OPNsense version (e.g. "26.1")
#   $2 = hostname (e.g. "opn-vpn-01")
#   $3 = config base URL (where config-base.xml and get_nic_gw.py are hosted)

OPNSENSE_VERSION="${1:-26.1}"
HOSTNAME_LABEL="${2:-opnsense}"
CONFIG_BASE_URL="${3:-https://raw.githubusercontent.com/sragamir/AzureVPNGWtoOPNsense/main/scripts}"

LOG="/var/log/configureopnsense.log"
exec > "$LOG" 2>&1

echo "=== OPNsense bootstrap started at $(date) ==="
echo "Version: $OPNSENSE_VERSION | Hostname: $HOSTNAME_LABEL"

###############################################################################
# 1. Fetch and patch the OPNsense bootstrap script
###############################################################################
cd /tmp || exit 1
fetch -o opnsense-bootstrap.sh \
  https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in

# Remove set -e so the script doesn't abort on non-fatal errors
sed -i '' 's/^set -e/#set -e/' opnsense-bootstrap.sh

# Replace immediate reboot with a delayed reboot so we can finish setup
sed -i '' 's|reboot$|# reboot deferred|g' opnsense-bootstrap.sh

echo "=== Running OPNsense bootstrap ==="
sh ./opnsense-bootstrap.sh -y -r "$OPNSENSE_VERSION"

###############################################################################
# 2. Reinstall WALinuxAgent (OPNsense bootstrap removes it)
###############################################################################
echo "=== Reinstalling WALinuxAgent ==="
if command -v python3 > /dev/null 2>&1; then
  PYTHON=python3
else
  PYTHON=python
fi

cd /tmp || exit 1
fetch -o waagent.tar.gz \
  https://github.com/Azure/WALinuxAgent/archive/refs/tags/v2.11.1.4.tar.gz
tar xzf waagent.tar.gz
cd WALinuxAgent-2.11.1.4 || exit 1
$PYTHON setup.py install
# Enable waagent service
sysrc waagent_enable=YES
service waagent start || true

###############################################################################
# 3. Set static ARP for Azure fabric IP
###############################################################################
echo "=== Configuring Azure fabric ARP ==="
FABRIC_IP="168.63.129.16"

# Determine WAN (hn0) MAC address
WAN_MAC=$(ifconfig hn0 | grep ether | awk '{print $2}')

# Get the Azure gateway IP for the WAN subnet
WAN_GW=$($PYTHON /tmp/get_nic_gw_local.py 2>/dev/null || echo "")
if [ -z "$WAN_GW" ]; then
  # Fallback: parse from routing table
  WAN_GW=$(route -n get default 2>/dev/null | grep gateway | awk '{print $2}')
fi

# Static ARP so health probes work even after OPNsense clears ARP
arp -s "$FABRIC_IP" "$WAN_MAC" 2>/dev/null || true

###############################################################################
# 4. Fetch and apply the config template
###############################################################################
echo "=== Applying OPNsense config ==="
fetch -o /tmp/get_nic_gw_local.py "$CONFIG_BASE_URL/get_nic_gw.py" 2>/dev/null || true
fetch -o /tmp/config-base.xml "$CONFIG_BASE_URL/config-base.xml"

# Calculate trusted gateway from IMDS
TRUSTED_GW=""
if [ -x "$(command -v $PYTHON)" ]; then
  TRUSTED_GW=$($PYTHON /tmp/get_nic_gw_local.py 2>/dev/null | head -1 | grep -o '[0-9.]*$')
fi
if [ -z "$TRUSTED_GW" ] && [ -n "$WAN_GW" ]; then
  TRUSTED_GW="$WAN_GW"
fi

# Substitute placeholders
sed "s/%%HOSTNAME%%/$HOSTNAME_LABEL/g; s/%%TRUSTED_GW%%/$TRUSTED_GW/g" \
  /tmp/config-base.xml > /usr/local/etc/config.xml

###############################################################################
# 5. Create startup hook to remove Azure-injected default route
###############################################################################
echo "=== Creating startup route fix ==="
cat > /usr/local/etc/rc.d/azure_route_fix.sh << 'ROUTEFIX'
#!/bin/sh
# Remove Azure's injected default route that conflicts with OPNsense routing.
# OPNsense manages its own default route via the WAN gateway.
sleep 10
AZURE_ROUTE=$(route -n get default 2>/dev/null | grep gateway | awk '{print $2}')
if [ -n "$AZURE_ROUTE" ]; then
  route delete default "$AZURE_ROUTE" 2>/dev/null || true
fi
ROUTEFIX
chmod +x /usr/local/etc/rc.d/azure_route_fix.sh

# Also add to OPNsense's syshook for persistence across config reloads
mkdir -p /usr/local/etc/rc.syshook.d/start
cat > /usr/local/etc/rc.syshook.d/start/99-azure-route-fix << 'SYSHOOK'
#!/bin/sh
# Remove Azure-injected default route on every OPNsense start
sleep 5
AZURE_ROUTE=$(route -n get default 2>/dev/null | grep gateway | awk '{print $2}')
if [ -n "$AZURE_ROUTE" ]; then
  route delete default "$AZURE_ROUTE" 2>/dev/null || true
fi
# Re-add static ARP for Azure fabric
FABRIC_IP="168.63.129.16"
WAN_MAC=$(ifconfig hn0 | grep ether | awk '{print $2}')
arp -s "$FABRIC_IP" "$WAN_MAC" 2>/dev/null || true
SYSHOOK
chmod +x /usr/local/etc/rc.syshook.d/start/99-azure-route-fix

###############################################################################
# 6. Schedule delayed reboot
###############################################################################
echo "=== Bootstrap complete. Rebooting in 1 minute ==="
shutdown -r +1 "OPNsense bootstrap complete — rebooting"
