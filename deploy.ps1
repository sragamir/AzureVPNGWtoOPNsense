<#
.SYNOPSIS
    Deploy an OPNsense VM to replace Azure VPN Gateway.

.DESCRIPTION
    PowerShell wrapper for OPNsense VM deployment using Azure CLI.
    Calls the same az commands as deploy.sh with PowerShell parameter validation.

.PARAMETER SubscriptionId
    Azure subscription ID (required).

.PARAMETER ResourceGroup
    Resource group name. Default: rg-opnsense-vpn

.PARAMETER Location
    Azure region. Default: westeurope

.PARAMETER VmSize
    VM size. Default: Standard_B2s

.EXAMPLE
    .\deploy.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\deploy.ps1 -SubscriptionId $sub -Location northeurope -VmSize Standard_B2ms
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$')]
    [string]$SubscriptionId,

    [string]$ResourceGroup = "rg-opnsense-vpn",
    [string]$Location = "westeurope",
    [string]$VnetName = "vnet-opnsense",
    [string]$VnetCidr = "10.200.0.0/16",
    [string]$SubnetWanCidr = "10.200.0.0/24",
    [string]$SubnetLanCidr = "10.200.1.0/24",
    [string]$VmName = "vm-opnsense-01",

    [ValidateSet("Standard_B2s", "Standard_B2ms", "Standard_B4ms", "Standard_D2s_v3")]
    [string]$VmSize = "Standard_B2s",

    [string]$AdminUser = "azureadmin",

    [SecureString]$AdminPassword,
    [string]$OpnsenseVersion = "26.1",
    [string]$HostnameLabel = "opn-vpn-01",
    [string]$ConfigBaseUrl = "https://raw.githubusercontent.com/sragamir/AzureVPNGWtoOPNsense/main/scripts",
    [string]$FreeBsdUrn = "thefreebsdfoundation:freebsd-14_1:14_1-release-amd64-gen2-zfs:14.1.0"
)

$ErrorActionPreference = "Stop"

$SubnetWanName = "snet-wan"
$SubnetLanName = "snet-lan"
$NsgName = "nsg-opnsense"
$PipName = "pip-opnsense"
$NicWanName = "nic-opnsense-wan"
$NicLanName = "nic-opnsense-lan"
$RtName = "rt-opnsense-lan"

# Prompt for password if not provided
if (-not $AdminPassword) {
    $AdminPassword = Read-Host -Prompt "Enter admin password for VM" -AsSecureString
}
$PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword))

Write-Host "=== OPNsense VPN VM Deployment ===" -ForegroundColor Cyan
Write-Host "Subscription: $SubscriptionId"
Write-Host "Resource Group: $ResourceGroup ($Location)"
Write-Host "VM: $VmName ($VmSize)"
Write-Host ""

# Set subscription
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription" }

# Accept FreeBSD Marketplace terms
Write-Host "--- Accepting FreeBSD Marketplace terms ---"
az vm image terms accept --urn $FreeBsdUrn -o none 2>$null

# Resource Group
Write-Host "--- Creating resource group ---"
az group create --name $ResourceGroup --location $Location -o none

# VNet + Subnets
Write-Host "--- Creating VNet and subnets ---"
az network vnet create `
    --resource-group $ResourceGroup `
    --name $VnetName `
    --address-prefix $VnetCidr `
    --subnet-name $SubnetWanName `
    --subnet-prefix $SubnetWanCidr `
    -o none

az network vnet subnet create `
    --resource-group $ResourceGroup `
    --vnet-name $VnetName `
    --name $SubnetLanName `
    --address-prefix $SubnetLanCidr `
    -o none 2>$null

# NSG
Write-Host "--- Creating NSG ---"
az network nsg create --resource-group $ResourceGroup --name $NsgName -o none

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

# ESP rule (separate — no port)
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

az network nic create `
    --resource-group $ResourceGroup `
    --name $NicLanName `
    --vnet-name $VnetName `
    --subnet $SubnetLanName `
    --ip-forwarding true `
    -o none

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
    --security-type Standard `
    -o none

# CustomScript extension
Write-Host "--- Running OPNsense bootstrap via CustomScript extension ---"
$extensionSettings = @{
    fileUris = @(
        "$ConfigBaseUrl/configureopnsense.sh",
        "$ConfigBaseUrl/config-base.xml",
        "$ConfigBaseUrl/get_nic_gw.py"
    )
    commandToExecute = "sh configureopnsense.sh '$OpnsenseVersion' '$HostnameLabel' '$ConfigBaseUrl'"
} | ConvertTo-Json -Compress

az vm extension set `
    --resource-group $ResourceGroup `
    --vm-name $VmName `
    --name CustomScript `
    --publisher Microsoft.Azure.Extensions `
    --version 2.1 `
    --settings $extensionSettings `
    -o none

# Route table
Write-Host "--- Creating route table ---"
$lanNicIp = az network nic show `
    --resource-group $ResourceGroup `
    --name $NicLanName `
    --query 'ipConfigurations[0].privateIpAddress' -o tsv

az network route-table create --resource-group $ResourceGroup --name $RtName -o none

az network route-table route create `
    --resource-group $ResourceGroup `
    --route-table-name $RtName `
    --name "route-via-opnsense" `
    --address-prefix "0.0.0.0/0" `
    --next-hop-type VirtualAppliance `
    --next-hop-ip-address $lanNicIp `
    -o none

az network vnet subnet update `
    --resource-group $ResourceGroup `
    --vnet-name $VnetName `
    --name $SubnetLanName `
    --route-table $RtName `
    -o none

# Output
$publicIp = az network public-ip show `
    --resource-group $ResourceGroup `
    --name $PipName `
    --query ipAddress -o tsv

Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Green
Write-Host "Public IP:    $publicIp"
Write-Host "SSH:          ssh ${AdminUser}@${publicIp}  (password auth)"
Write-Host "WebGUI:       https://${publicIp}"
Write-Host "Credentials:  root / opnsense (change immediately!)"
Write-Host ""
Write-Host "The VM will reboot in ~1 minute to finalize OPNsense installation."
Write-Host "Wait 3-5 minutes, then access the WebGUI."
