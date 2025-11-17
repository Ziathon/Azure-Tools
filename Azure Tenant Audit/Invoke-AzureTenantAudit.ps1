<#
.SYNOPSIS
    Azure Tenant Audit Tool

.DESCRIPTION
    Enumerates all resources in all Azure subscriptions in the tenant,
    exports inventories and costs to CSV, pulls Azure Advisor recommendations,
    and generates HTML charts for resource and cost distributions.

.PARAMETER OutputRoot
    Root folder where all output will be written.

.PARAMETER CostStartDate
    Start date for cost data (default: 1 month ago, beginning of day).

.PARAMETER CostEndDate
    End date for cost data (default: today).

.EXAMPLE
    .\Invoke-AzureTenantAudit.ps1

.EXAMPLE
    .\Invoke-AzureTenantAudit.ps1 -OutputRoot "C:\Temp\AzureAudit" -CostStartDate "2025-10-01" -CostEndDate "2025-10-31"
#>

param(
    [string]$OutputRoot = ".\AzureAuditOutput",
    [datetime]$CostStartDate = (Get-Date).AddMonths(-1).Date,
    [datetime]$CostEndDate = (Get-Date).Date
)

# -------------------------------
# 0. Ensure required modules
# -------------------------------
$requiredModules = @(
    "Az.Accounts",
    "Az.Resources",
    "Az.ResourceGraph",
    "Az.Advisor",
    "Az.CostManagement"
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module: $module ..." -ForegroundColor Cyan
        try {
            Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to install module $module. Error: $_"
        }
    }
}

Import-Module Az.Accounts -ErrorAction SilentlyContinue
Import-Module Az.Resources -ErrorAction SilentlyContinue
Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue
Import-Module Az.Advisor -ErrorAction SilentlyContinue
Import-Module Az.CostManagement -ErrorAction SilentlyContinue

# -------------------------------
# 1. Login & subscriptions
# -------------------------------
Write-Host "Connecting to Azure..." -ForegroundColor Green
Connect-AzAccount -ErrorAction Stop | Out-Null

$subscriptions = Get-AzSubscription
if (-not $subscriptions) {
    Write-Warning "No subscriptions found for this account."
    return
}

# Ensure output root
try {
    $resolved = Resolve-Path -Path $OutputRoot -ErrorAction Stop
    $OutputRoot = $resolved.ProviderPath
}
catch {
    $OutputRoot = (New-Item -ItemType Directory -Path $OutputRoot -Force).FullName
}

Write-Host "Using output root: $OutputRoot" -ForegroundColor Green

# -------------------------------
# 2. Helper function: HTML chart
# -------------------------------
function New-SubscriptionSummaryHtml {
    param(
        [string]$SubscriptionName,
        [string]$SubscriptionId,
        [array]$ResourceTypeCounts,   # @([PSCustomObject]@{ Name="type"; Count=123 }, ...)
        [array]$CostByCategory,       # @([PSCustomObject]@{ Category="Compute"; Cost=123.45 }, ...)
        [string]$OutputPath
    )

    $resourceDataRows = @()
    foreach ($item in $ResourceTypeCounts) {
        $safeName = ($item.Name -replace "'", "ʼ")  # soften quotes
        $resourceDataRows += "['$safeName', $($item.Count)]"
    }
    $resourceDataString = $resourceDataRows -join ",`n            "

    $costDataRows = @()
    foreach ($item in $CostByCategory) {
        $safeCat = ($item.Category -replace "'", "ʼ")
        $costRounded = [math]::Round($item.Cost, 2)
        $costDataRows += "['$safeCat', $costRounded]"
    }
    $costDataString = $costDataRows -join ",`n            "

    $today = Get-Date

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>Azure Subscription Summary - $SubscriptionName</title>
    <script type="text/javascript" src="https://www.gstatic.com/charts/loader.js"></script>
    <script type="text/javascript">
      google.charts.load('current', {'packages':['corechart']});
      google.charts.setOnLoadCallback(drawCharts);

      function drawCharts() {
        // Resources by type
        var resData = new google.visualization.DataTable();
        resData.addColumn('string', 'Resource Type');
        resData.addColumn('number', 'Count');
        resData.addRows([
            $resourceDataString
        ]);

        var resOptions = {
            title: 'Resources by Type (Top 20)',
            legend: { position: 'none' },
            chartArea: {width: '70%', height: '70%'}
        };

        var resChart = new google.visualization.ColumnChart(document.getElementById('resources_by_type'));
        resChart.draw(resData, resOptions);

        // Cost by Meter Category
        var costData = new google.visualization.DataTable();
        costData.addColumn('string', 'Meter Category');
        costData.addColumn('number', 'Cost');
        costData.addRows([
            $costDataString
        ]);

        var costOptions = {
            title: 'Cost by Meter Category (Top 20)',
            legend: { position: 'none' },
            chartArea: {width: '70%', height: '70%'}
        };

        var costChart = new google.visualization.ColumnChart(document.getElementById('cost_by_category'));
        costChart.draw(costData, costOptions);
      }
    </script>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1, h2 { color: #333; }
        .chart-container { width: 100%; height: 400px; margin-bottom: 40px; }
        .meta { font-size: 0.9em; color: #666; margin-bottom: 20px; }
        code { background-color: #f4f4f4; padding: 2px 4px; }
    </style>
</head>
<body>
    <h1>Azure Subscription Summary</h1>
    <div class="meta">
        <strong>Subscription:</strong> $SubscriptionName<br />
        <strong>Subscription ID:</strong> $SubscriptionId<br />
        <strong>Generated:</strong> $today
    </div>

    <h2>Resource Distribution</h2>
    <div id="resources_by_type" class="chart-container"></div>

    <h2>Cost Distribution</h2>
    <div id="cost_by_category" class="chart-container"></div>

    <h2>Files</h2>
    <ul>
        <li><code>AllResources.csv</code></li>
        <li><code>Resources_&lt;ResourceType&gt;.csv</code></li>
        <li><code>RawCosts.csv</code>, <code>CostByMeterCategory.csv</code></li>
        <li><code>AdvisorRecommendations.csv</code></li>
    </ul>
</body>
</html>
"@

    $html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
}

# -------------------------------
# 3. Main loop per subscription
# -------------------------------
foreach ($sub in $subscriptions) {
    Write-Host "Processing subscription: $($sub.Name) [$($sub.Id)]" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Subscription-specific output folder
    $safeSubName = ($sub.Name -replace '[^a-zA-Z0-9\-]', '_')
    $subFolder = Join-Path $OutputRoot $safeSubName
    if (-not (Test-Path $subFolder)) {
        New-Item -ItemType Directory -Path $subFolder -Force | Out-Null
    }

    # 3.1 Get all resources via Azure Resource Graph
    Write-Host "  - Querying resources via Resource Graph..." -ForegroundColor Cyan
    $resourceQuery = @"
Resources
| project name, type, resourceGroup, subscriptionId, location, tags, sku, kind
"@

    $resources = @()
    try {
        $resources = Search-AzGraph -Query $resourceQuery -Subscription $sub.Id -First 100000 -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to query Resource Graph for subscription $($sub.Id). Error: $_"
    }

    if ($resources) {
        $allResPath = Join-Path $subFolder "AllResources.csv"
        $resources | Export-Csv -Path $allResPath -NoTypeInformation

        # 3.1.a Per-resource-type CSVs
        Write-Host "  - Exporting per-resource-type CSVs..." -ForegroundColor Cyan
        $resources | Group-Object type | ForEach-Object {
            $typeName = $_.Name
            $safeTypeName = ($typeName -replace '[^a-zA-Z0-9\.\-]', '_')
            $typePath = Join-Path $subFolder ("Resources_{0}.csv" -f $safeTypeName)
            $_.Group | Export-Csv -Path $typePath -NoTypeInformation
        }
    }
    else {
        Write-Warning "No resources found or query failed for subscription $($sub.Id)."
    }

    # 3.2 Cost data
    $usage = $null
    $costByCategory = @()
    Write-Host "  - Pulling cost data..." -ForegroundColor Cyan
    try {
        # Get-AzConsumptionUsageDetail may be replaced in future; adjust to your environment if needed
        $usage = Get-AzConsumptionUsageDetail -StartDate $CostStartDate -EndDate $CostEndDate -ErrorAction Stop

        if ($usage) {
            $usagePath = Join-Path $subFolder "RawCosts.csv"
            $usage | Export-Csv -Path $usagePath -NoTypeInformation

            # Summarise by MeterCategory
            $costByCategory = $usage |
                Group-Object MeterCategory |
                ForEach-Object {
                    [PSCustomObject]@{
                        Category = $_.Name
                        Cost     = ($_.Group | Measure-Object -Property PretaxCost -Sum).Sum
                    }
                } |
                Sort-Object Cost -Descending

            $costByCategory |
                Export-Csv -Path (Join-Path $subFolder "CostByMeterCategory.csv") -NoTypeInformation
        }
    }
    catch {
        Write-Warning "Failed to pull cost data for subscription $($sub.Id). Error: $_"
    }

    # 3.3 Azure Advisor recommendations
    Write-Host "  - Retrieving Azure Advisor recommendations..." -ForegroundColor Cyan
    try {
        $advisorRecs = Get-AzAdvisorRecommendation -ErrorAction Stop
        if ($advisorRecs) {
            $advisorPath = Join-Path $subFolder "AdvisorRecommendations.csv"
            $advisorRecs | Export-Csv -Path $advisorPath -NoTypeInformation
        }
        else {
            Write-Host "    No Advisor recommendations found for this subscription." -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Warning "Failed to get Advisor recommendations for subscription $($sub.Id). Error: $_"
    }

    # 3.4 Build per-subscription HTML summary
    Write-Host "  - Generating HTML summary..." -ForegroundColor Cyan

    $resourceTypeCounts = @()
    if ($resources) {
        $resourceTypeCounts = $resources |
            Group-Object type |
            Sort-Object Count -Descending |
            Select-Object -First 20 |
            ForEach-Object {
                [PSCustomObject]@{
                    Name  = $_.Name
                    Count = $_.Count
                }
            }
    }

    $topCostCats = @()
    if ($costByCategory) {
        $topCostCats = $costByCategory | Select-Object -First 20
    }

    $htmlPath = Join-Path $subFolder "Summary.html"
    New-SubscriptionSummaryHtml `
        -SubscriptionName $sub.Name `
        -SubscriptionId $sub.Id `
        -ResourceTypeCounts $resourceTypeCounts `
        -CostByCategory $topCostCats `
        -OutputPath $htmlPath

    Write-Host "  - Subscription output written to: $subFolder" -ForegroundColor Green
}

Write-Host "Azure Tenant Audit complete. Root output folder: $OutputRoot" -ForegroundColor Green
