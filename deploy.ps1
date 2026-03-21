<#
.SYNOPSIS
    Deploy an OPNsense VM to replace Azure VPN Gateway.

.DESCRIPTION
    PowerShell deployment script for OPNsense VM using Azure CLI.
    Loads defaults from params.env if present, then applies CLI parameters.
    Supports deploying into an existing VNet/subnets.

.PARAMETER SubscriptionId
    Azure subscription ID (required).

.PARAMETER ResourceGroup
    Resource group name. Default: rg-opnsense-vpn

.PARAMETER Location
    Azure region. Default: westeurope

.PARAMETER VmSize
    VM size. Default: Standard_B2ts_v2

.PARAMETER UseExistingVnet
    If set, skips VNet and subnet creation - uses existing ones.

.EXAMPLE
    .\deploy.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\deploy.ps1 -SubscriptionId $sub -VnetName "existing-vnet" -SubnetWanName "WAN" -SubnetLanName "default" -UseExistingVnet
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$VnetName,
    [string]$VnetCidr,
    [string]$SubnetWanName,
    [string]$SubnetWanCidr,
    [string]$SubnetLanName,
    [string]$SubnetLanCidr,
    [string]$VmName,
    [string]$VmSize,
    [string]$AdminUser,
    [SecureString]$AdminPassword,
    [string]$OpnsenseVersion,
    [string]$HostnameLabel,
    [string]$ConfigBaseUrl,
    [string]$FreeBsdUrn,
    [switch]$UseExistingVnet
)

$ErrorActionPreference = "Stop"

###############################################################################
# Load params.env if it exists (key=value format, ignoring comments)
###############################################################################
$paramsFile = Join-Path $PSScriptRoot "params.env"
$envVars = @{}
if (Test-Path $paramsFile) {
    Write-Host "Loading parameters from params.env..." -ForegroundColor DarkGray
    Get-Content $paramsFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^(\w+)\s*=\s*"([^"]*)"') {
                $envVars[$Matches[1]] = $Matches[2]
            } elseif ($line -match '^(\w+)\s*=\s*(\S+)') {
                $envVars[$Matches[1]] = $Matches[2]
            }
        }
    }
}

# Apply defaults: CLI param > params.env > hardcoded default
function Resolve-Param([string]$CliValue, [string]$EnvKey, [string]$Default) {
    if ($CliValue) { return $CliValue }
    if ($envVars.ContainsKey($EnvKey) -and $envVars[$EnvKey]) { return $envVars[$EnvKey] }
    return $Default
}

$SubscriptionId  = Resolve-Param $SubscriptionId  "SUBSCRIPTION_ID"  ""
$ResourceGroup   = Resolve-Param $ResourceGroup   "RESOURCE_GROUP"   "rg-opnsense-vpn"
$Location        = Resolve-Param $Location        "LOCATION"         "westeurope"
$VnetName        = Resolve-Param $VnetName        "VNET_NAME"        "vnet-opnsense"
$VnetCidr        = Resolve-Param $VnetCidr        "VNET_CIDR"        "10.200.0.0/16"
$SubnetWanName   = Resolve-Param $SubnetWanName   "SUBNET_WAN_NAME"  "snet-wan"
$SubnetWanCidr   = Resolve-Param $SubnetWanCidr   "SUBNET_WAN_CIDR"  "10.200.0.0/24"
$SubnetLanName   = Resolve-Param $SubnetLanName   "SUBNET_LAN_NAME"  "snet-lan"
$SubnetLanCidr   = Resolve-Param $SubnetLanCidr   "SUBNET_LAN_CIDR"  "10.200.1.0/24"
$VmName          = Resolve-Param $VmName          "VM_NAME"          "opnsense-01-vm"
$VmSize          = Resolve-Param $VmSize          "VM_SIZE"          "Standard_B2ts_v2"
$AdminUser       = Resolve-Param $AdminUser       "ADMIN_USER"       "azureadmin"
$OpnsenseVersion = Resolve-Param $OpnsenseVersion "OPNSENSE_VERSION" "25.1"
$HostnameLabel   = Resolve-Param $HostnameLabel   "HOSTNAME_LABEL"   "opn-vpn-01"
$ConfigBaseUrl   = Resolve-Param $ConfigBaseUrl   "CONFIG_BASE_URL"  "https://raw.githubusercontent.com/sragamir/AzureVPNGWtoOPNsense/main/scripts"
$FreeBsdUrn      = Resolve-Param $FreeBsdUrn      "FREEBSD_URN"      "thefreebsdfoundation:freebsd-14_1:14_1-release-amd64-gen2-zfs:14.1.0"

if (-not $UseExistingVnet -and $envVars.ContainsKey("USE_EXISTING_VNET") -and $envVars["USE_EXISTING_VNET"] -eq "true") {
    $UseExistingVnet = [switch]::new($true)
}

# Validate subscription ID
if (-not $SubscriptionId) {
    $SubscriptionId = Read-Host -Prompt "Enter Azure Subscription ID"
}
if ($SubscriptionId -notmatch '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') {
    throw "Invalid Subscription ID format: $SubscriptionId"
}

# Derive resource names from VM name prefix (e.g. opnsense-01-vm -> opnsense-01-nsg)
$namePrefix = $VmName -replace '-vm$',''
$NsgName    = "$namePrefix-nsg"
$PipName    = "$namePrefix-pip"
$NicWanName = "$namePrefix-nic-wan"
$NicLanName = "$namePrefix-nic-lan"
$RtName     = "$namePrefix-rt"

###############################################################################
# Password
###############################################################################
if (-not $AdminPassword) {
    $envPwd = if ($envVars.ContainsKey("ADMIN_PASSWORD")) { $envVars["ADMIN_PASSWORD"] } else { "" }
    if ($envPwd) {
        $AdminPassword = ConvertTo-SecureString $envPwd -AsPlainText -Force
    } else {
        $AdminPassword = Read-Host -Prompt "Enter admin password for VM (12+ chars, upper+lower+digit+special)" -AsSecureString
    }
}
$PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword))

###############################################################################
# Helper to abort on az failure
###############################################################################
function Assert-AzSuccess([string]$Step) {
    if ($LASTEXITCODE -ne 0) {
        throw "FAILED at: $Step (exit code $LASTEXITCODE)"
    }
}

Write-Host "=== OPNsense VPN VM Deployment ===" -ForegroundColor Cyan
Write-Host "Subscription: $SubscriptionId"
Write-Host "Resource Group: $ResourceGroup ($Location)"
Write-Host "VM: $VmName ($VmSize)"
if ($UseExistingVnet) {
    Write-Host "VNet: $VnetName (existing) | WAN: $SubnetWanName | LAN: $SubnetLanName"
} else {
    Write-Host "VNet: $VnetName (new $VnetCidr) | WAN: $SubnetWanName ($SubnetWanCidr) | LAN: $SubnetLanName ($SubnetLanCidr)"
}
Write-Host ""

# Set subscription
az account set --subscription $SubscriptionId
Assert-AzSuccess "Set subscription"

# Accept FreeBSD Marketplace terms
Write-Host "--- Accepting FreeBSD Marketplace terms ---"
az vm image terms accept --urn $FreeBsdUrn -o none 2>$null

# Resource Group
Write-Host "--- Creating resource group ---"
az group create --name $ResourceGroup --location $Location -o none
Assert-AzSuccess "Create resource group"

# VNet + Subnets
if ($UseExistingVnet) {
    Write-Host "--- Using existing VNet '$VnetName' with subnets '$SubnetWanName' and '$SubnetLanName' ---"
    az network vnet subnet show --resource-group $ResourceGroup --vnet-name $VnetName --name $SubnetWanName -o none
    Assert-AzSuccess "Verify WAN subnet '$SubnetWanName' exists"
    az network vnet subnet show --resource-group $ResourceGroup --vnet-name $VnetName --name $SubnetLanName -o none
    Assert-AzSuccess "Verify LAN subnet '$SubnetLanName' exists"
} else {
    Write-Host "--- Creating VNet and subnets ---"
    az network vnet create `
        --resource-group $ResourceGroup `
        --name $VnetName `
        --address-prefix $VnetCidr `
        --subnet-name $SubnetWanName `
        --subnet-prefix $SubnetWanCidr `
        -o none
    Assert-AzSuccess "Create VNet"

    az network vnet subnet create `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --name $SubnetLanName `
        --address-prefix $SubnetLanCidr `
        -o none 2>$null
}

# NSG
Write-Host "--- Creating NSG ---"
az network nsg create --resource-group $ResourceGroup --name $NsgName -o none
Assert-AzSuccess "Create NSG"

$nsgRules = @(
    @{ Name = "Allow-SSH";          Priority = 100; Protocol = "Tcp"; Port = "22" }
    @{ Name = "Allow-HTTPS";        Priority = 110; Protocol = "Tcp"; Port = "443" }
    @{ Name = "Allow-WireGuard";    Priority = 120; Protocol = "Udp"; Port = "51820" }
    @{ Name = "Allow-IPsec-IKE";    Priority = 130; Protocol = "Udp"; Port = "500" }
    @{ Name = "Allow-IPsec-NAT-T";  Priority = 140; Protocol = "Udp"; Port = "4500" }
    @{ Name = "Allow-OpenVPN";      Priority = 150; Protocol = "Udp"; Port = "1194" }
    @{ Name = "Allow-L2TP";         Priority = 160; Protocol = "Udp"; Port = "1701" }
)

foreach ($rule in $nsgRules) {
    az network nsg rule create `
        --resource-group $ResourceGroup `
        --nsg-name $NsgName `
        --name $rule.Name `
        --priority $rule.Priority `
        --direction Inbound `
        --access Allow `
        --protocol $rule.Protocol `
        --source-address-prefixes '*' `
        --destination-port-ranges $rule.Port `
        -o none 2>$null
}

az network nsg rule create `
    --resource-group $ResourceGroup `
    --nsg-name $NsgName `
    --name "Allow-ESP" `
    --priority 170 `
    --direction Inbound `
    --access Allow `
    --protocol Esp `
    --source-address-prefixes '*' `
    --destination-port-ranges '*' `
    -o none 2>$null

# Public IP
Write-Host "--- Creating Public IP ---"
az network public-ip create `
    --resource-group $ResourceGroup `
    --name $PipName `
    --sku Standard `
    --allocation-method Static `
    -o none
Assert-AzSuccess "Create Public IP"

# NICs
Write-Host "--- Creating NICs ---"
az network nic create `
    --resource-group $ResourceGroup `
    --name $NicWanName `
    --vnet-name $VnetName `
    --subnet $SubnetWanName `
    --network-security-group $NsgName `
    --public-ip-address $PipName `
    --ip-forwarding true `
    -o none
Assert-AzSuccess "Create WAN NIC"

az network nic create `
    --resource-group $ResourceGroup `
    --name $NicLanName `
    --vnet-name $VnetName `
    --subnet $SubnetLanName `
    --ip-forwarding true `
    -o none
Assert-AzSuccess "Create LAN NIC"

# VM
Write-Host "--- Creating FreeBSD VM ---"
az vm create `
    --resource-group $ResourceGroup `
    --name $VmName `
    --image $FreeBsdUrn `
    --size $VmSize `
    --admin-username $AdminUser `
    --admin-password $PlainPassword `
    --authentication-type password `
    --nics $NicWanName $NicLanName `
    --os-disk-size-gb 30 `
    --storage-sku StandardSSD_LRS `
    -o none
Assert-AzSuccess "Create VM"

# Get public IP and calculate gateway
$publicIp = az network public-ip show `
    --resource-group $ResourceGroup `
    --name $PipName `
    --query ipAddress -o tsv

$wanSubnetPrefix = az network vnet subnet show `
    --resource-group $ResourceGroup `
    --vnet-name $VnetName `
    --name $SubnetWanName `
    --query "addressPrefix" -o tsv
$gatewayIp = ($wanSubnetPrefix -replace '/\d+$','') -replace '\.\d+$','.1'
Write-Host "    WAN Gateway IP: $gatewayIp" -ForegroundColor DarkGray

# Install bash via SSH (required by CustomScript extension handler)
Write-Host "--- Installing bash on FreeBSD ---"
$installBash = "echo '$PlainPassword' | sudo -S pkg install -y bash"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${AdminUser}@${publicIp}" $installBash
Assert-AzSuccess "Install bash on VM"

# Run OPNsense bootstrap via CustomScriptForLinux v1.5 (works on FreeBSD)
Write-Host "--- Running OPNsense bootstrap via CustomScript extension ---"
Write-Host "    This will take 10-15 minutes..." -ForegroundColor DarkGray

$settingsObj = @{
    fileUris = @(
        "$ConfigBaseUrl/configureopnsense.sh"
        "$ConfigBaseUrl/config-base.xml"
    )
    commandToExecute = "sh configureopnsense.sh '$ConfigBaseUrl' '$OpnsenseVersion' '$gatewayIp' '$publicIp'"
}
$settingsFile = Join-Path $env:TEMP "opnsense-extension-settings.json"
$settingsObj | ConvertTo-Json -Depth 3 | Set-Content -Path $settingsFile -Encoding UTF8

az vm extension set `
    --resource-group $ResourceGroup `
    --vm-name $VmName `
    --name CustomScriptForLinux `
    --publisher Microsoft.OSTCExtensions `
    --version 1.5 `
    --settings $settingsFile `
    -o none
if ($LASTEXITCODE -ne 0) {
    Write-Host "    Extension reported non-zero exit (expected if VM rebooted during bootstrap)." -ForegroundColor Yellow
}

Remove-Item $settingsFile -ErrorAction SilentlyContinue

# Route table
Write-Host "--- Creating route table ---"
$LASTEXITCODE = 0
$lanNicIp = (az network nic show `
    --resource-group $ResourceGroup `
    --name $NicLanName `
    --query "ipConfigurations[0].privateIpAddress" -o tsv 2>$null)

if (-not $lanNicIp) {
    Write-Host "    Could not auto-detect LAN NIC IP." -ForegroundColor Yellow
    $lanNicIp = Read-Host -Prompt "    Enter LAN NIC private IP (or press Enter to skip route table)"
}

if ($lanNicIp) {
    Write-Host "    LAN NIC IP: $lanNicIp" -ForegroundColor DarkGray

    az network route-table create --resource-group $ResourceGroup --name $RtName -o none
    Assert-AzSuccess "Create route table"

    az network route-table route create `
        --resource-group $ResourceGroup `
        --route-table-name $RtName `
        --name "route-via-opnsense" `
        --address-prefix "0.0.0.0/0" `
        --next-hop-type VirtualAppliance `
        --next-hop-ip-address $lanNicIp `
        -o none
    Assert-AzSuccess "Create route"

    az network vnet subnet update `
        --resource-group $ResourceGroup `
        --vnet-name $VnetName `
        --name $SubnetLanName `
        --route-table $RtName `
        -o none
    Assert-AzSuccess "Associate route table"
} else {
    Write-Host "    Skipped route table creation." -ForegroundColor Yellow
}

# Output
Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Green
Write-Host "Public IP:    $publicIp"
Write-Host "SSH:          ssh root@${publicIp}  (password: opnsense)"
Write-Host "WebGUI:       https://${publicIp}"
Write-Host "Credentials:  root / opnsense (change immediately!)"
Write-Host ""
Write-Host "The VM will reboot in ~1 minute to finalize OPNsense installation."
Write-Host "Wait 3-5 minutes, then access the WebGUI."
