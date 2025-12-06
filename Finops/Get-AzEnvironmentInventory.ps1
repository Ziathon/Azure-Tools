<#
.SYNOPSIS
  Collects an Azure-wide resource inventory using Azure Resource Graph.

.EXAMPLE
  ./Get-AzEnvironmentInventory.ps1 -OutputPath .\output\cust1
  ./Get-AzEnvironmentInventory.ps1 -SubscriptionIds "sub-id-1","sub-id-2" -OutputPath .\out
#>

[CmdletBinding()]
param(
    [string[]] $SubscriptionIds,
    [string]   $OutputPath = ".\output"
)

$ErrorActionPreference = 'Stop'

# Required modules
$requiredModules = @(
    'Az.Accounts',
    'Az.Resources',
    'Az.ResourceGraph'
)

foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Host "Installing module $m..." -ForegroundColor Cyan
        Install-Module -Name $m -Scope CurrentUser -Force
    }
    Import-Module $m -ErrorAction Stop
}

# Auth
if (-not (Get-AzContext)) {
    Write-Host "Connecting to Azure..." -ForegroundColor Cyan
    Connect-AzAccount -ErrorAction Stop | Out-Null
}

# Output folder
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

# Determine subscriptions
if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
    $subscriptions = Get-AzSubscription | Where-Object { $SubscriptionIds -contains $_.Id }
} else {
    $subscriptions = Get-AzSubscription
}

if (-not $subscriptions) {
    throw "No subscriptions found in scope."
}

$allResources = @()

foreach ($sub in $subscriptions) {
    Write-Host "Querying inventory for subscription $($sub.Name) ($($sub.Id))..." -ForegroundColor Green

    # NOTE: -First 5000 is the per-call max. If a subscription has >5000 resources,
    # you will need to add pagination using the -SkipToken parameter.
    $query = @"
Resources
| project
    subscriptionId,
    resourceGroup,
    name,
    type,
    location,
    tags,
    skuName = tostring(sku.name),
    skuTier = tostring(sku.tier),
    kind,
    managedBy,
    tenantId
"@

    $results = Search-AzGraph -Query $query -Subscription $sub.Id -First 5000

    $allResources += $results | ForEach-Object {
        $_ | Add-Member -NotePropertyName subscriptionName -NotePropertyValue $sub.Name -PassThru
    }
}

$inventoryPath = Join-Path $OutputPath "inventory.csv"

$allResources |
    Select-Object `
        subscriptionId,
        subscriptionName,
        resourceGroup,
        name,
        type,
        location,
        skuName,
        skuTier,
        kind,
        managedBy,
        tenantId,
        tags |
    Export-Csv -Path $inventoryPath -NoTypeInformation -Encoding UTF8

Write-Host "Inventory exported to $inventoryPath" -ForegroundColor Yellow
