<#
.SYNOPSIS
    Migrate an Azure VM to a new VM with EncryptionAtHost (EAH) enabled by disk copy via AzCopy,
    preserving plan/license and optionally joining a domain. Supports dry-run and placement validation.

.DESCRIPTION
    - Disables ADE/BitLocker (OS or OS+Data) and waits for full decryption. 
    - Creates "Upload" managed disks with same size/sku/hyper-v generation, copies bits.
    - Makes source NIC(s) re-usable by deleting the source VM
    - Creates a new Encryption-At-Host VM using the source VM's Image/Plan/SKU and uses Source NIC 
    - Swaps OS disk with copied OS Disk and attaches the copied Data Disks. 
    - Domain Join will be manually done. Can be done through the ADDomain Extension or by Creating the Computer and adding it to the domain through an Invoke PS Command.

.PREREQUISITES
    - PowerShell Az modules: Az.Accounts, Az.Compute, Az.Network.
    - Powershell Version 7 required, might get formatting errors and bracket errors in older PS Versions. 
    - AzCopy installed and accessible via $AzCopyPath. (Have it installed locally)
    - Permissions to read/write disks, VMs, NICs, and accept marketplace terms.
    - Credentials for Local Admin to create the new Encryption at Host VM.

.PARAMETERS
    -ResourceGroupName: (Required) - Resource group containing the source VM.
    -SourceVMName: (Required) - Name of the source VM to migrate.
    -NewVMName: (Required) - Name for the new VM to be created with EncryptionAtHost enabled 
    -NewOSDiskName: (Optional) - Reference to rename the destination OS disk (defaults to <Source>-OSDisk-EAH).
    -VMSize: (Optional) - Custom VM Size; defaults to source VM size.
    -HasDataDisks: (Optional) - It is a Switch (no value needed) indicating data disks should be copied. (This is for ADE+Data Encrypted VMs)
    -AzCopyPath: (Required) - Path to azcopy (default 'azcopy' assumes in PATH).
    -DryRun: (Optional) - No-operation; prints intended actions and prints domain information (If Exists). 
    -ValidatePlacement: (Optional) - Checks SKU availability, zones, and EAH-related capability hints.

.CAUSE/EFFECTS
    - Stops and may delete the source VM.
    - Grants SAS then revokes SAS on managed disks.
    - Creates/attaches managed disks and network resources.
    - Creates new VM and then swaps out the disks with the copied disks.

.SECURITY NOTES
    - SAS tokens are short-lived; script revokes them after AzCopy to reduce exposure.
    - Source VM is deleted to free NIC 
    - After the Source VMs Disks are copied they remain detached and will require manual deletion (retained for fall back)
#>

param(
  [Parameter(Mandatory = $true)] [string]$ResourceGroupName,
  [Parameter(Mandatory = $true)] [string]$SourceVMName,
  [Parameter(Mandatory = $true)] [string]$NewVMName,

  [string]$NewOSDiskName,
  [string]$VMSize,
  [switch]$HasDataDisks,
  [string]$AzCopyPath = 'azcopy',

  [switch]$DryRun,
  [switch]$ValidatePlacement,
  [PSCredential]$AdminCredential = $(Get-Credential) # needed for image-provisioning path
)

$ErrorActionPreference = 'Stop'
$ConfirmPreference = 'None'
Set-StrictMode -Version Latest

# ===== Small log + safe access helpers =====
# Write-Info: Write a timestamped info-level message to the console (in cyan text).
function Write-Info([string]$m){
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Host "[$ts] $m" -ForegroundColor Cyan
}
# Write-Ok: Write a timestamped success message to the console (in green text).
function Write-Ok([string]$m){
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Host "[$ts] $m" -ForegroundColor Green
}
# Write-Warn: Write a timestamped warning message to the console (in yellow text).
function Write-Warn([string]$m){
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Host "[$ts] $m" -ForegroundColor Yellow
}
# Write-Err: Write a timestamped error message to the console (in red text).
function Write-Err([string]$m){
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Host "[$ts] $m" -ForegroundColor Red
}

# Has-Prop: Return $true if the object has a property with the specified name (handles null input safely).
function Has-Prop($obj, [string]$name){
  if (-not $obj) { return $false }
  return $null -ne $obj.PSObject.Properties[$name]
}
# Get-Prop: Safely retrieve the value of a named property from an object (returns $null if not found or object is $null).
function Get-Prop($obj, [string]$name){
  if (-not $obj) { return $null }
  $p = $obj.PSObject.Properties[$name]
  if ($p) { return $p.Value }
  return $null
}

# ===== Azure helpers =====
# Ensure-EAHFeatureRegistered: Check if Azure feature 'EncryptionAtHost' is registered; if not, register it (unless DryRun), and wait for completion.
function Ensure-EAHFeatureRegistered([switch]$DryRun){
  $f = Get-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost -ErrorAction SilentlyContinue
  if ($f -and $f.RegistrationState -eq 'Registered'){
    Write-Ok "EncryptionAtHost feature already registered."
    return
  }
  if ($DryRun){
    Write-Warn "[DRY-RUN] Would register Microsoft.Compute/EncryptionAtHost."
    return
  }
  Write-Info "Registering Microsoft.Compute/EncryptionAtHost..."
  Register-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost | Out-Null
  do {
    Start-Sleep 5
    $f = Get-AzProviderFeature -ProviderNamespace Microsoft.Compute -FeatureName EncryptionAtHost
  } until ($f.RegistrationState -eq 'Registered')
  Write-Ok "EncryptionAtHost feature registered."
}

# Ensure-MarketplacePlanAccepted: If a marketplace plan is provided, ensure its terms are accepted (required for deploying marketplace images).
function Ensure-MarketplacePlanAccepted($Plan){
  if (-not $Plan) { return }
  $n   = Get-Prop $Plan 'Name'
  $pub = Get-Prop $Plan 'Publisher'
  $prod= Get-Prop $Plan 'Product'
  if (-not ($n -and $pub -and $prod)) { return }
  try{
    $t = Get-AzMarketplaceTerms -Publisher $pub -Product $prod -Name $n -ErrorAction Stop
    if (-not $t.Accepted){
      Write-Info "Accepting marketplace terms: $pub/$prod/$n..."
      Set-AzMarketplaceTerms -Publisher $pub -Product $prod -Name $n -Accept | Out-Null
    }
  } catch {
    Write-Warn "Marketplace terms check failed: $($_.Exception.Message)"
  }
}

# Apply-SourcePlanAndLicense: If the source VM has a marketplace plan or license type, apply them to the new VM's configuration.
function Apply-SourcePlanAndLicense($SourcePlan, $LicenseType, [ref]$VMConfig){
  $n   = Get-Prop $SourcePlan 'Name'
  $pub = Get-Prop $SourcePlan 'Publisher'
  $prod= Get-Prop $SourcePlan 'Product'
  if ($n -and $pub -and $prod){
    $VMConfig.Value = Set-AzVMPlan -VM $VMConfig.Value -Name $n -Publisher $pub -Product $prod
  }
  if ($LicenseType){
    $VMConfig.Value.LicenseType = $LicenseType
  }
}

# Validate-Placement: Verify that the VM size ($VmSize) is available in the specified $Location and supports EncryptionAtHost and any requested zones.
function Validate-Placement([string]$Location,[string]$VmSize,[string[]]$Zones,[string]$AvailabilitySetId){
  $asLeaf   = if($AvailabilitySetId){ Split-Path $AvailabilitySetId -Leaf } else { '-' }
  $zonesTxt = if($Zones){ $Zones -join ',' } else { '-' }
  Write-Info "Validating placement: $Location / $VmSize / AvSet: $asLeaf / Zones: $zonesTxt"

  $sku = Get-AzComputeResourceSku -Location $Location -ErrorAction SilentlyContinue |
         Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSize } |
         Select-Object -First 1
  if (-not $sku){
    Write-Err "VM size '$VmSize' unavailable in '$Location'."
    return $false
  }

  $caps = @{}
  foreach($c in ($sku.Capabilities | Where-Object { $_.Name })){
    $caps[$c.Name] = $c.Value
  }
  $eahKeys = @('EncryptionAtHost','EncryptionAtHostSupported','EncryptionAtHostEnabled')
  $eah = $eahKeys |
    ForEach-Object {
      if ($caps.ContainsKey($_) -and ($caps[$_] -match '^(?i:true|1)$')){ $true }
    } |
    Where-Object { $_ } |
    Measure-Object |
    Select-Object -ExpandProperty Count

  if ($eah -gt 0){
    Write-Ok "SKU indicates EAH support."
  } else {
    Write-Warn "EAH not explicitly advertised; cluster/subscription may still support it."
  }

  if ($Zones){
    $zoneSet = @()
    foreach ($li in ($sku.LocationInfo | Where-Object { $_.Location -eq $Location })) {
      if ($li.Zones){ $zoneSet += $li.Zones }
    }
    if (@($zoneSet).Count -eq 0){
      Write-Err "SKU '$VmSize' has no zones in '$Location' but zones requested."
      return $false
    }
  }
  return $true
}

# Ensure-UploadDisk: Create or reuse a managed disk (Upload) as target for copying the source disk. Matches source disk's size, SKU, location, etc.
function Ensure-UploadDisk($SourceDisk, [string]$TargetDiskName, [string]$ResourceGroupName, [string[]]$ZonesToApply, [switch]$DryRun){
  $existing = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $TargetDiskName -ErrorAction SilentlyContinue
  if ($existing){
    Write-Warn "Upload disk '$TargetDiskName' exists. Reusing."
    return $existing
  }
  if ($DryRun){
    Write-Warn "[DRY-RUN] Would create upload disk '$TargetDiskName' from '$((Get-Prop $SourceDisk 'Name'))'."
    return $null
  }
  $loc = Get-Prop $SourceDisk 'Location'
  if (-not $loc){
    $loc = (Get-AzResourceGroup -Name $ResourceGroupName).Location
  }
  $sku     = Get-Prop $SourceDisk 'Sku'
  $skuName = if ($sku) { Get-Prop $sku 'Name' } else { $null }

  $cfg = New-AzDiskConfig -Location $loc -SkuName $skuName -CreateOption Upload -UploadSizeInBytes ((Get-Prop $SourceDisk 'DiskSizeBytes') + 512) -HyperVGeneration (Get-Prop $SourceDisk 'HyperVGeneration')
  if (Has-Prop $SourceDisk 'OsType' -and (Get-Prop $SourceDisk 'OsType')){
    $cfg.OsType = (Get-Prop $SourceDisk 'OsType')
  }
  if ($ZonesToApply){
    $cfg.Zones = $ZonesToApply
  }
  $d = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $TargetDiskName -Disk $cfg
  Write-Ok "Upload disk '$TargetDiskName' created."
  return $d
}

# Copy-DiskWithAzCopy: Copy the contents of the source disk to the target disk using AzCopy (via temporary SAS URLs for read/write access).
function Copy-DiskWithAzCopy($SourceDisk, $TargetDisk, [int]$SasDurationHours = 24, [switch]$DryRun){
  if ($DryRun){
    Write-Warn "[DRY-RUN] Would AzCopy disk '$((Get-Prop $SourceDisk 'Name'))' -> '$((Get-Prop $TargetDisk 'Name'))'."
    return
  }

  $srcRg  = Get-Prop $SourceDisk 'ResourceGroupName'
  $srcName= Get-Prop $SourceDisk 'Name'
  $dstRg  = Get-Prop $TargetDisk 'ResourceGroupName'
  $dstName= Get-Prop $TargetDisk 'Name'

  Write-Info "Granting SAS on source/target disks..."
  $srcSas = Grant-AzDiskAccess -ResourceGroupName $srcRg -DiskName $srcName -Access Read  -DurationInSecond ($SasDurationHours * 3600)
  $dstSas = Grant-AzDiskAccess -ResourceGroupName $dstRg -DiskName $dstName -Access Write -DurationInSecond ($SasDurationHours * 3600)

  try {
    $az = Get-Command $script:AzCopyPath -ErrorAction SilentlyContinue
    if (-not $az){
      Write-Err "AzCopy not found at '$($script:AzCopyPath)'."
      exit 11
    }

    $args = @('copy', $srcSas.AccessSAS, $dstSas.AccessSAS, '--blob-type','PageBlob','--overwrite','true')
    Write-Info "Starting AzCopy..."
    $p = Start-Process -FilePath $az.Source -ArgumentList $args -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0){
      Write-Err "AzCopy failed (exit $($p.ExitCode)). See $env:USERPROFILE\.azcopy\ logs."
      exit 12
    }
    Write-Ok "AzCopy completed."
  } finally {
    Write-Info "Revoking SAS..."
    try { Revoke-AzDiskAccess -ResourceGroupName $srcRg -DiskName $srcName | Out-Null } catch {}
    try { Revoke-AzDiskAccess -ResourceGroupName $dstRg -DiskName $dstName | Out-Null } catch {}
  }
}

# Get-DataDiskMap: Gather details of all data disks attached to a VM (name, LUN, size, caching, SKU, etc.) for preparing disk copy operations.
function Get-DataDiskMap($VmObject, [string]$ResourceGroupName){
  $out = @()
  $sp  = Get-Prop $VmObject 'StorageProfile'
  $dds = if ($sp) { Get-Prop $sp 'DataDisks' } else { $null }
  if (-not $dds){ return $out }

  foreach ($dd in $dds){
    $ddName  = Get-Prop $dd 'Name'
    $ddLun   = Get-Prop $dd 'Lun'
    $ddCache = Get-Prop $dd 'Caching'
    $disk    = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $ddName

    $loc = Get-Prop $disk 'Location'
    if (-not $loc){
      $loc = (Get-AzResourceGroup -Name $ResourceGroupName).Location
    }
    $sku     = Get-Prop $disk 'Sku'
    $skuName = if ($sku) { Get-Prop $sku 'Name' } else { $null }

    $out += [pscustomobject]@{
      Name         = $ddName
      Lun          = $ddLun
      Caching      = $ddCache
      DiskSizeBytes= (Get-Prop $disk 'DiskSizeBytes')
      SkuName      = $skuName
      Location     = $loc
      HyperVGen    = (Get-Prop $disk 'HyperVGeneration')
      Zones        = (Get-Prop $disk 'Zones')
      Object       = $disk
    }
  }
  return $out
}

# Get-SourceDomainInfo: Run a script on the VM to check if it's domain-joined and retrieve its domain name and computer name.
function Get-SourceDomainInfo([string]$ResourceGroupName,[string]$VMName){
  try{
    $script = @'
$ci = Get-ComputerInfo
"{0}|{1}|{2}" -f $ci.CsPartOfDomain, $ci.CsDomain, $env:COMPUTERNAME
'@
    $r = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName -CommandId 'RunPowerShellScript' -ScriptString $script -ErrorAction Stop
    $raw  = $r.Value | ForEach-Object { $_.Message }
    $line = ($raw -join "`n").Trim()
    $p    = $line.Split('|')
    return [pscustomobject]@{
      PartOfDomain = [bool]::Parse($p[0])
      Domain       = $p[1]
      ComputerName = $p[2]
    }
  } catch {
    Write-Warn "Domain discovery failed: $($_.Exception.Message)"
    return $null
  }
}

# Wait-For-Decryption: Poll the VM's BitLocker encryption status until the OS (and data, if specified) volumes are fully decrypted.
function Wait-For-Decryption([string]$ResourceGroupName,[string]$VMName,[switch]$IncludeDataDisks,[switch]$DryRun){
  if ($DryRun){
    Write-Warn "[DRY-RUN] Would wait for BitLocker decryption."
    return
  }

  $scopeText = if ($IncludeDataDisks){ 'OS + Data' } else { 'OS only' }
  Write-Info ("Waiting for BitLocker decryption: Scope = {0}" -f $scopeText)

  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($true){
    try{
      $run = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $VMName -CommandId 'RunPowerShellScript' -ScriptString 'manage-bde -status' -ErrorAction Stop
      $out = ($run.Value | ForEach-Object { $_.Message }) -join "`n"

      # Parse manage-bde output for per-volume percentage
      $progress   = @{}
      $currentVol = $null
      foreach ($line in ($out -split "`n")){
        if ($line -match '^\s*Volume\s+([A-Z]:)'){
          $currentVol = $matches[1]
          continue
        }
        if ($line -match 'Percentage Encrypted:\s*([\d\.]+%)'){
          if ($currentVol){
            $progress[$currentVol] = $matches[1]
          }
        }
      }

      if ($progress.Count -gt 0){
        $summary = ($progress.Keys | Sort-Object | ForEach-Object { "$($_): $($progress[$_])" }) -join ', '
        Write-Info ("BitLocker status: {0} (Elapsed {1:N1} min)" -f $summary, $sw.Elapsed.TotalMinutes)
      } else {
        Write-Info ("BitLocker status: <no percentage output> (Elapsed {0:N1} min)" -f $sw.Elapsed.TotalMinutes)
      }

      # Preserve original break conditions
      if ($IncludeDataDisks){
        if ($out -notmatch 'Decryption in progress' -and $out -notmatch 'Percentage Encrypted:\s*[1-9]'){ break }
      } else {
        if ($out -match 'Fully Decrypted' -and $out -match 'Percentage Encrypted:\s*0\.0%'){ break }
      }
    } catch {
      Write-Warn "manage-bde query failed; retrying... $($_.Exception.Message)"
    }
    Start-Sleep 30
  }

  $sw.Stop()
  Write-Ok ("Decryption finished. Elapsed {0:N1} min." -f $sw.Elapsed.TotalMinutes)
}

# Get-EncryptionScope: Determine from the encryption status which volumes (OS and data) are encrypted (returns booleans for each).
function Get-EncryptionScope($EncStatus){
  $osDisk  = Get-Prop $EncStatus 'OsDisk'
  $dataDisk= Get-Prop $EncStatus 'DataDisk'
  $osState   = $null
  $dataState = $null

  if ($osDisk -and (Has-Prop $osDisk 'Status')){ $osState = Get-Prop $osDisk 'Status' }
  if (-not $osState){ $osState = Get-Prop $EncStatus 'OsVolumeEncrypted' }
  if (-not $osState){ $osState = Get-Prop $EncStatus 'OsVolumeEncryptionState' }

  if ($dataDisk -and (Has-Prop $dataDisk 'Status')){ $dataState = Get-Prop $dataDisk 'Status' }
  if (-not $dataState){ $dataState = Get-Prop $EncStatus 'DataVolumesEncrypted' }
  if (-not $dataState){ $dataState = Get-Prop $EncStatus 'DataVolumeEncrypted' }

  $no = @('NotEncrypted','NotEncryptedOrDisabled','NotMounted','NoDiskFound',$null,'')

  [pscustomobject]@{
    OsEncrypted   = ($osState)   -and -not ($no -contains $osState)
    DataEncrypted = ($dataState) -and -not ($no -contains $dataState)
  }
}

# Resolve-Placement: Extract the source VM's placement info (location, availability set ID, zones) to use for the new VM's configuration.
function Resolve-Placement($vm, [string]$fallbackLocation){
  $availabilitySetId = $null
  $asRef = Get-Prop $vm 'AvailabilitySetReference'
  if ($asRef){
    $availabilitySetId = Get-Prop $asRef 'Id'
  }
  if (-not $availabilitySetId){
    $as = Get-Prop $vm 'AvailabilitySet'
    if ($as){
      $availabilitySetId = Get-Prop $as 'Id'
    }
  }
  $zones = $null
  if (Has-Prop $vm 'Zones'){
    $zones = Get-Prop $vm 'Zones'
  }
  $loc = if (Has-Prop $vm 'Location') { Get-Prop $vm 'Location' } else { $fallbackLocation }
  [pscustomobject]@{
    Location       = $loc
    AvailabilitySet= $availabilitySetId
    Zones          = $zones
  }
}

# ===== Post-migration output (DNS + reference only) =====
# Emit-PostMigrationChecklist: Print a checklist of recommended steps to perform after migration (especially for domain-joined VMs).
function Emit-PostMigrationChecklist($DomainInfo, [string]$NewVMName, [string]$ResourceGroupName){
  Write-Host ""
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === POST-MIGRATION CHECKLIST ===" -ForegroundColor White

  if (-not $DomainInfo -or -not $DomainInfo.PartOfDomain){
    Write-Host "- Source VM was not domain-joined. No domain steps required." -ForegroundColor Green
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === END CHECKLIST ===" -ForegroundColor White
    return
  }

  $domain = $DomainInfo.Domain
  Write-Host ("- Source VM was domain-joined: {0}" -f $domain) -ForegroundColor Cyan
  Write-Host "- NICs re-used -> DNS settings preserved." -ForegroundColor Green
  Write-Host "  DNS refresh on the new VM:" -ForegroundColor Cyan
  Write-Host "    ipconfig /flushdns" -ForegroundColor White
  Write-Host "    ipconfig /registerdns" -ForegroundColor White
  Write-Host ("    nltest /dsgetdc:{0}" -f $domain) -ForegroundColor White
  Write-Host "    Test-ComputerSecureChannel -Verbose" -ForegroundColor White

  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === END CHECKLIST ===" -ForegroundColor White
}

# ===== Main =====
try{
  # Pre-flight: Validate prerequisites (modules, login, AzCopy) and gather source VM details for migration.
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === PRE-FLIGHT ===" -ForegroundColor White

  if (-not $NewOSDiskName){
    $NewOSDiskName = "$SourceVMName-OSDisk-EAH"
  }

  foreach ($m in @('Az.Accounts','Az.Compute','Az.Network')){
    if (-not (Get-Module -ListAvailable -Name $m)){
      Write-Err "Missing Az module '$m'. Install-Module Az"
      exit 1
    }
  }

  $ctx = Get-AzContext -ErrorAction SilentlyContinue
  if (-not $ctx -or -not $ctx.Subscription){
    Write-Err "Not logged in / no subscription. Run Connect-AzAccount; Select-AzSubscription."
    exit 2
  }
  Write-Ok ("Subscription: {0} ({1})" -f $ctx.Subscription.Name, $ctx.Subscription.Id)

  $azcopyCmd = Get-Command $AzCopyPath -ErrorAction SilentlyContinue
  if (-not $azcopyCmd -and -not $DryRun){
    Write-Err "AzCopy not found at '$AzCopyPath'."
    exit 3
  }

  # Make sure EncryptionAtHost feature is registered (register now if needed, unless DryRun).
  Ensure-EAHFeatureRegistered -DryRun:$DryRun

  # Retrieve the source VM object and its location/placement info (availability set, zones).
  $srcVM  = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $SourceVMName -ErrorAction Stop
  $rgLoc  = (Get-AzResourceGroup -Name $ResourceGroupName).Location
  $placement = Resolve-Placement -vm $srcVM -fallbackLocation $rgLoc
  Write-Ok ("Source VM: {0} in {1}" -f (Get-Prop $srcVM 'Name'), $placement.Location)

  $sec = Get-Prop $srcVM 'SecurityProfile'
  # If the source VM already has EncryptionAtHost enabled, no migration is needed (exit).
  if ($sec -and (Get-Prop $sec 'EncryptionAtHost')){
    Write-Warn "Source already EAH. Nothing to do."
    exit 4
  }

  # Determine the VM size for the new VM (use provided $VMSize if given, otherwise use source VM's size).
  $hw      = Get-Prop $srcVM 'HardwareProfile'
  $srcSize = if ($hw) { Get-Prop $hw 'VmSize' } else { $null }
  $plannedSize = if ($VMSize){ $VMSize } else { $srcSize }

  $doValidate = $DryRun -or $ValidatePlacement
  # If DryRun or placement validation is requested, validate the VM size and zone availability now; exit if invalid.
  if ($doValidate){
    if (-not (Validate-Placement -Location $placement.Location -VmSize $plannedSize -Zones $placement.Zones -AvailabilitySetId $placement.AvailabilitySet)){
      exit 7
    }
  }

  # Ensure the source VM has an OS disk in its storage profile; exit if not.
  $sp = Get-Prop $srcVM 'StorageProfile'
  if (-not $sp -or -not (Has-Prop $sp 'OsDisk') -or -not (Get-Prop $sp 'OsDisk')){
    Write-Err "Source VM missing OS disk."
    exit 8
  }

  # Get the source VM's OS disk name and fetch the disk resource object.
  $osDiskRef = Get-Prop $sp 'OsDisk'
  $osDiskName= Get-Prop $osDiskRef 'Name'
  $srcOsDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $osDiskName

  $dataMap = @()
  $ddList  = Get-Prop $sp 'DataDisks'
  # If including data disks and the source VM has them, gather all data disk info (for copying).
  if ($HasDataDisks -and $ddList){
    $dataMap = Get-DataDiskMap -VmObject $srcVM -ResourceGroupName $ResourceGroupName
  }

  $net = Get-Prop $srcVM 'NetworkProfile'
  $nicRefs = if ($net) { @((Get-Prop $net 'NetworkInterfaces')) } else { @() }
  if (@($nicRefs).Count -eq 0){
    Write-Err "Source VM has no NICs."
    exit 9
  }
  $primaryNicRef = @($nicRefs | Where-Object { Get-Prop $_ 'Primary' })[0]
  if (-not $primaryNicRef){
    $primaryNicRef = $nicRefs[0]
  }
  $primaryNicId = Get-Prop $primaryNicRef 'Id'
  $primaryNic   = Get-AzNetworkInterface -ResourceId $primaryNicId
  $ipcfg        = (Get-Prop $primaryNic 'IpConfigurations')[0]
  $primarySubnet= Get-Prop $ipcfg 'Subnet'
  $primarySubnetId = if ($primarySubnet) { Get-Prop $primarySubnet 'Id' } else { $null }
  # Determine if the primary NIC had an associated public IP (for informational purposes).
  $hadPublicIp  = [bool](Get-Prop $ipcfg 'PublicIpAddress')

  $imgRef = $null
  $imageRef = if ($sp) { Get-Prop $sp 'ImageReference' } else { $null }
  # Check if the source VM was created from a marketplace image. Prepare for image-based creation if possible.
  if ($imageRef){
    $pub   = Get-Prop $imageRef 'Publisher'
    $offer = Get-Prop $imageRef 'Offer'
    $sku   = Get-Prop $imageRef 'Sku'
    if ($pub -and $offer -and $sku -and $AdminCredential){
      $imgRef = $imageRef
    }
    elseif ($pub -and $offer -and $sku -and -not $AdminCredential){
      Write-Warn "Image detected but no admin credential; falling back to disk-attach path."
    }
  }

  $domainInfo = $null
  try {
    $domainInfo = Get-SourceDomainInfo -ResourceGroupName $ResourceGroupName -VMName $SourceVMName
  } catch {
    $domainInfo = $null
  }

  if ($DryRun){
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === DRY RUN ===" -ForegroundColor White

    $asLeaf   = if ($placement.AvailabilitySet){ Split-Path $placement.AvailabilitySet -Leaf } else { '-' }
    $zonesTxt = if ($placement.Zones){ ($placement.Zones -join ',') } else { '-' }

    Write-Host ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Placement: {0} | Size: {1} | AvSet: {2} | Zones: {3}" -f $placement.Location,$plannedSize,$asLeaf,$zonesTxt)

    $encStatus = Get-AzVMDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $SourceVMName -ErrorAction SilentlyContinue
    $scope     = Get-EncryptionScope -EncStatus $encStatus
    $decryptScope = if ($HasDataDisks -and $ddList){ 'OS + Data' } else { 'OS only' }

    Write-Host ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ADE decryption scope: {0}" -f $decryptScope)
    Write-Host ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] OS disk copy: {0} -> {1}" -f (Get-Prop $srcOsDisk 'Name'), $NewOSDiskName)

    if (@($dataMap).Count -gt 0){
      foreach($d in ($dataMap | Sort-Object Lun)){
        Write-Host ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Data LUN {0}: '{1}' -> '{2}-Data-L{0}-EAH'" -f $d.Lun, $d.Name, $NewVMName)
      }
    } else {
      Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] No data disks."
    }

    Write-Host ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] NIC plan: DELETE source VM; primary NIC: {0}" -f (Split-Path $primaryNicId -Leaf))

    $srcPlan    = Get-Prop $srcVM 'Plan'
    $srcLicense = Get-Prop $srcVM 'LicenseType'
    if ($srcPlan){
      Write-Host ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Plan will be preserved; license: {0}" -f ($srcLicense ? $srcLicense : '<none>'))
    }

    if ($imgRef){
      Write-Host ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Create from image {0}/{1}/{2}/{3}, then swap OS disk." -f (Get-Prop $imgRef 'Publisher'), (Get-Prop $imgRef 'Offer'), (Get-Prop $imgRef 'Sku'), (Get-Prop $imgRef 'Version'))
    } else {
      Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Fallback: create by attaching copied disks."
    }

    if ($domainInfo){
      Write-Host ("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Source domain: PartOfDomain={0}, Domain={1}, Name={2}" -f $domainInfo.PartOfDomain, ($domainInfo.Domain ? $domainInfo.Domain : '<none>'), $domainInfo.ComputerName)
    } else {
      Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Domain: <unknown>"
    }

    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === END DRY RUN ===" -ForegroundColor White
    exit 0
  }

  # === ADE DECRYPTION ===
  # Azure Disk Encryption: If BitLocker (ADE) is enabled on the VM, turn it off and wait until the disks are fully decrypted.
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === ADE DECRYPTION ===" -ForegroundColor White
  $encStatus = Get-AzVMDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $SourceVMName -ErrorAction SilentlyContinue
  $scope     = Get-EncryptionScope -EncStatus $encStatus
  $decryptAll = ($HasDataDisks -and $ddList)

  if ($decryptAll){
    Write-Info "Disabling ADE on OS+Data..."
    Disable-AzVMDiskEncryption -ResourceGroupName $ResourceGroupName -VMName $SourceVMName -VolumeType All -Confirm:$false | Out-Null
  } else {
    if ($scope.OsEncrypted){
      Write-Info "Disabling ADE on OS..."
      Disable-AzVMDiskEncryption -ResourceGroupName $ResourceGroupName -VMName $SourceVMName -VolumeType OS -Confirm:$false | Out-Null
    } else {
      Write-Ok "OS not encrypted; skipping ADE disable."
    }
  }

  try {
    Remove-AzVMDiskEncryptionExtension -ResourceGroupName $ResourceGroupName -VMName $SourceVMName -Force -ErrorAction SilentlyContinue
  } catch {}

  Wait-For-Decryption -ResourceGroupName $ResourceGroupName -VMName $SourceVMName -IncludeDataDisks:$decryptAll -DryRun:$false

  # === STOP SOURCE VM ===
  # Stop source VM: Deallocate the VM to detach its disks (required before copying).
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === STOP SOURCE VM ===" -ForegroundColor White
  Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $SourceVMName -Force | Out-Null
  Write-Ok "Source VM deallocated."

  # === DISK COPY (OS) ===
  # Disk copy (OS): Prepare a new managed disk and use AzCopy to clone the source OS disk into it.
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === DISK COPY (OS) ===" -ForegroundColor White
  $targetZones = $placement.Zones
  $dstOsDisk = Ensure-UploadDisk -SourceDisk $srcOsDisk -TargetDiskName $NewOSDiskName -ResourceGroupName $ResourceGroupName -ZonesToApply $targetZones -DryRun:$false
  if (-not $dstOsDisk){
    $dstOsDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $NewOSDiskName -ErrorAction Stop
  }
  Write-Info ("Copying OS disk '{0}' -> '{1}'..." -f (Get-Prop $srcOsDisk 'Name'), (Get-Prop $dstOsDisk 'Name'))
  Copy-DiskWithAzCopy -SourceDisk $srcOsDisk -TargetDisk $dstOsDisk -DryRun:$false

  # === DISK COPY (DATA) ===
  # Disk copy (Data): For each data disk, create a new disk and copy the source disk's data into it.
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === DISK COPY (DATA) ===" -ForegroundColor White
  $copiedDataDisks = @()
  if ($HasDataDisks -and $ddList){
    if (@($dataMap).Count -eq 0){
      $dataMap = Get-DataDiskMap -VmObject $srcVM -ResourceGroupName $ResourceGroupName
    }
    foreach ($d in ($dataMap | Sort-Object Lun)){
      $targetName = "$NewVMName-Data-L$($d.Lun)-EAH"
      Write-Info ("Preparing data disk L{0}: {1} -> {2}" -f $d.Lun, $d.Name, $targetName)

      $targetDataDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $targetName -ErrorAction SilentlyContinue
      if (-not $targetDataDisk){
        $cfg = New-AzDiskConfig -Location $d.Location -SkuName $d.SkuName -CreateOption Upload -UploadSizeInBytes ($d.DiskSizeBytes + 512) -HyperVGeneration $d.HyperVGen
        if ($targetZones){
          $cfg.Zones = $targetZones
        }
        $targetDataDisk = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $targetName -Disk $cfg
      }

      Write-Info ("Copying data disk '{0}' (LUN {1}) -> '{2}'..." -f $d.Name, $d.Lun, $targetName)
      Copy-DiskWithAzCopy -SourceDisk $d.Object -TargetDisk $targetDataDisk -DryRun:$false

      $copiedDataDisks += [pscustomobject]@{
        Name   = $targetName
        Id     = $targetDataDisk.Id
        Lun    = $d.Lun
        Caching= $d.Caching
      }
    }
  } else {
    Write-Warn "No data disks to copy."
  }

  # === NIC HANDLING ===
  # NIC handling: Delete the source VM to free its NIC(s) for reuse in the new VM.
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === NIC HANDLING ===" -ForegroundColor White
  $nicIdsForTarget   = @()
  $primaryTargetNicId= $null

  Write-Info "Deleting source VM to free NICs..."
  $existingVM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $SourceVMName -ErrorAction SilentlyContinue
  if ($existingVM){
    Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $SourceVMName -Force
  }

  $nicIdsForTarget = @(
    $nicRefs | ForEach-Object {
      (Get-Prop (Get-AzNetworkInterface -ResourceId (Get-Prop $_ 'Id')) 'Id')
    }
  )
  $primaryTargetNicId = $primaryNicId
  Write-Ok "Source VM removed. NICs reusable."

  # === CREATE NEW VM (EAH) ===
  # Create new VM: Set up a new VM with EncryptionAtHost enabled, using the copied disks (or image) and original NICs.
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === CREATE NEW VM (EAH) ===" -ForegroundColor White
  $already = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName -ErrorAction SilentlyContinue
  if ($already){
    Write-Warn "Target VM '$NewVMName' already exists. Skipping creation."
  }
  else {
    $srcPlan    = Get-Prop $srcVM 'Plan'
    $srcLicense = Get-Prop $srcVM 'LicenseType'

    # Use image-based creation (with the same image as source, if credentials allow), then swap in the copied OS disk.
    if ($imgRef){
      Write-Info "Creating from image with EAH..."
      $vm = New-AzVMConfig -VMName $NewVMName -VMSize $plannedSize -EncryptionAtHost
      if ($placement.AvailabilitySet){
        $vm = Set-AzVMAvailabilitySet -VM $vm -AvailabilitySetId $placement.AvailabilitySet
      } elseif ($placement.Zones){
        $vm.Zones = $placement.Zones
      }

      $vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $NewVMName -Credential $AdminCredential -ProvisionVMAgent -EnableAutoUpdate
      $vm = Set-AzVMSourceImage -VM $vm -PublisherName (Get-Prop $imgRef 'Publisher') -Offer (Get-Prop $imgRef 'Offer') -Skus (Get-Prop $imgRef 'Sku') -Version (Get-Prop $imgRef 'Version')

      # Attach all source VM's NICs to the new VM configuration (mark the same one as primary).
      foreach ($id in $nicIdsForTarget){
        if ($id -eq $primaryTargetNicId){
          $vm = Add-AzVMNetworkInterface -VM $vm -Id $id -Primary
        } else {
          $vm = Add-AzVMNetworkInterface -VM $vm -Id $id
        }
      }

      # Configure Boot Diagnostics on the new VM the same way as the source VM (enable with same storage or disable).
      try{
        $diag = Get-Prop $srcVM 'DiagnosticsProfile'
        $bd   = if ($diag){ Get-Prop $diag 'BootDiagnostics' } else { $null }
        $bdEnabled = $bd -and (Get-Prop $bd 'Enabled')
        if ($bdEnabled){
          $uri = Get-Prop $bd 'StorageUri'
          if ($uri){
            $vm = Set-AzVMBootDiagnostic -VM $vm -Enable -StorageUri $uri
          } else {
            $vm = Set-AzVMBootDiagnostic -VM $vm -Enable
          }
        } else {
          $vm = Set-AzVMBootDiagnostic -VM $vm -Disable
        }
      } catch {
        Write-Warn "Boot Diagnostics clone failed; disabling."
        $vm = Set-AzVMBootDiagnostic -VM $vm -Disable
      }

      # Accept marketplace terms (if needed) and apply source VM's plan/license to the new VM config.
      Ensure-MarketplacePlanAccepted -Plan $srcPlan
      Apply-SourcePlanAndLicense -SourcePlan $srcPlan -LicenseType $srcLicense -VMConfig ([ref]$vm)

      New-AzVM -ResourceGroupName $ResourceGroupName -Location $placement.Location -VM $vm -ErrorAction Stop | Out-Null
      Write-Ok "VM created from image. Swapping OS disk..."

      # VM is deployed from image; now stop it and replace its OS disk with the copied disk, and attach data disks.
      Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName -Force | Out-Null
      $vmPost = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName -ErrorAction Stop
      $vmPost = Set-AzVMOSDisk -VM $vmPost -ManagedDiskId (Get-Prop $dstOsDisk 'Id') -Name (Get-Prop $dstOsDisk 'Name') -Windows

      $spPost = Get-Prop $vmPost 'StorageProfile'
      if ($spPost) {
        if (-not (Get-Prop $spPost 'DataDisks')) {
          try {
            $spPost.DataDisks = [System.Collections.Generic.List[Microsoft.Azure.Management.Compute.Models.DataDisk]]::new()
          } catch {
            $spPost.DataDisks = @()
          }
        } else {
          try {
            $null = $spPost.DataDisks.Clear()
          } catch {
            $spPost.DataDisks = @()
          }
        }
      } else {
        Write-Warn "StorageProfile not found on VM object after OS disk swap."
      }

      if (@($copiedDataDisks).Count -gt 0){
        foreach($dd in $copiedDataDisks){
          $cache = if ([string]::IsNullOrWhiteSpace($dd.Caching)){'None'}else{$dd.Caching}
          $vmPost = Add-AzVMDataDisk -VM $vmPost -Name $dd.Name -ManagedDiskId $dd.Id -Lun $dd.Lun -Caching $cache -CreateOption Attach
        }
      }

      Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vmPost -ErrorAction Stop | Out-Null
      Start-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName | Out-Null
      Write-Ok "OS/data disks swapped and VM started."
    } else {
      Write-Info "Creating by attaching copied disks (fallback) with EAH..."
      # If image-based creation isn't used, create the new VM by attaching the copied OS and data disks directly (EAH enabled).
      $vm = New-AzVMConfig -VMName $NewVMName -VMSize $plannedSize -EncryptionAtHost
      if ($placement.AvailabilitySet){
        $vm = Set-AzVMAvailabilitySet -VM $vm -AvailabilitySetId $placement.AvailabilitySet
      } elseif ($placement.Zones){
        $vm.Zones = $placement.Zones
      }

      $vm = Set-AzVMOSDisk -VM $vm -ManagedDiskId (Get-Prop $dstOsDisk 'Id') -Name (Get-Prop $dstOsDisk 'Name') -Windows

      if (@($copiedDataDisks).Count -gt 0){
        foreach($dd in $copiedDataDisks){
          $cache = if ([string]::IsNullOrWhiteSpace($dd.Caching)){'None'}else{$dd.Caching}
          $vm = Add-AzVMDataDisk -VM $vm -Name $dd.Name -ManagedDiskId $dd.Id -Lun $dd.Lun -Caching $cache -CreateOption Attach
        }
      }

      foreach ($id in $nicIdsForTarget){
        if ($id -eq $primaryTargetNicId){
          $vm = Add-AzVMNetworkInterface -VM $vm -Id $id -Primary
        } else {
          $vm = Add-AzVMNetworkInterface -VM $vm -Id $id
        }
      }

      # Set Boot Diagnostics on the new VM (enable or disable to match source).
      try{
        $diag = Get-Prop $srcVM 'DiagnosticsProfile'
        $bd   = if ($diag){ Get-Prop $diag 'BootDiagnostics' } else { $null }
        $bdEnabled = $bd -and (Get-Prop $bd 'Enabled')
        if ($bdEnabled){
          $uri = Get-Prop $bd 'StorageUri'
          if ($uri){
            $vm = Set-AzVMBootDiagnostic -VM $vm -Enable -StorageUri $uri
          } else {
            $vm = Set-AzVMBootDiagnostic -VM $vm -Enable
          }
        } else {
          $vm = Set-AzVMBootDiagnostic -VM $vm -Disable
        }
      } catch {
        Write-Warn "Boot Diagnostics clone failed; disabling."
        $vm = Set-AzVMBootDiagnostic -VM $vm -Disable
      }

      # Accept marketplace terms and apply plan/license from source VM (if any) to new VM config.
      Ensure-MarketplacePlanAccepted -Plan $srcPlan
      Apply-SourcePlanAndLicense -SourcePlan $srcPlan -LicenseType $srcLicense -VMConfig ([ref]$vm)

      New-AzVM -ResourceGroupName $ResourceGroupName -Location $placement.Location -VM $vm -ErrorAction Stop | Out-Null
      Write-Ok "VM created with EAH (fallback path)."
    }
  }

  # === VERIFY EAH ===
  # Verification: Confirm that the new VM has EncryptionAtHost enabled in its security profile.
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === VERIFY EAH ===" -ForegroundColor White
  $newVM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName
  $newSec = Get-Prop $newVM 'SecurityProfile'
  if ($newSec -and (Get-Prop $newSec 'EncryptionAtHost')) {
    Write-Ok ("SUCCESS: '{0}' has EncryptionAtHost enabled." -f $NewVMName)
  }
  else {
    Write-Warn ("WARNING: '{0}' does not show EncryptionAtHost enabled." -f $NewVMName)
  }

  # === INIT DATA DISKS ===
  if ($copiedDataDisks -and $copiedDataDisks.Count -gt 0) {
    Write-Info "Initializing data disks inside '$NewVMName'..."
    $initScript = @'
$disks = Get-Disk | Where-Object PartitionStyle -eq 'raw' | Sort-Object Number
$letters = 70..89 | ForEach-Object { [char]$_ }
$count = 0
$labels = @()
for ($i = 1; $i -le ($disks.Count); $i++) {
    $labels += "data$($i)"
}
foreach ($disk in $disks) {
    $driveLetter = $letters[$count].ToString()
    $partitionStyle = 'MBR'
    if ($disk.Size -ge 2199023255552) {
        $partitionStyle = 'GPT'
    }
    $disk |
        Initialize-Disk -PartitionStyle $partitionStyle -PassThru |
        New-Partition -UseMaximumSize -DriveLetter $driveLetter |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel $labels[$count] -Confirm:$false -Force
    $count++
}
'@
    try {
      $rc = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $NewVMName `
        -CommandId 'RunPowerShellScript' -ScriptString $initScript -ErrorAction Stop
      # Log the output from the VM initialization script
      if ($rc.Value -and $rc.Value[0] -and $rc.Value[0].Message) {
        ($rc.Value[0].Message -split "`r?`n") | ForEach-Object {
          if ($_ -ne '') { Write-Info "[$NewVMName] $_" }
        }
      }
      Write-Info "Rebooting $NewVMName to settle volumes..."
      Start-Sleep -Seconds 10
      Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName | Out-Null
      Start-Sleep -Seconds 15
      Write-Ok "$NewVMName rebooted after disk initialization."
    }
    catch {
      Write-Warn "Disk initialization script failed: $($_.Exception.Message)"
    }
  }
  else {
    Write-Warn "No data disks to initialize."
  }

  # === DISK SUMMARY ===
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === DISK SUMMARY ===" -ForegroundColor White
  # If a reboot was initiated above, wait for the VM to be running again
  if ($copiedDataDisks -and $copiedDataDisks.Count -gt 0) {
    Write-Info "Waiting for $NewVMName to restart..."
    $maxWait = 18  # ~3 minutes max wait
    for ($i = 1; $i -le $maxWait; $i++) {
      $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $NewVMName -Status -ErrorAction SilentlyContinue
      if ($vmStatus -and ($vmStatus.Statuses | Where-Object { $_.Code -match 'PowerState/' -and $_.DisplayStatus -eq 'VM running' })) {
        break
      }
      Start-Sleep -Seconds 10
    }
    if (-not $vmStatus -or -not ($vmStatus.Statuses | Where-Object { $_.Code -match 'PowerState/' -and $_.DisplayStatus -eq 'VM running' })) {
      Write-Warn "VM is not in a running state; skipping volume summary."
    }
    else {
      Write-Ok "$NewVMName is running. Gathering volume information..."
    }
  }
  try {
    $volScript = @'
Get-Volume | Where-Object FileSystem -ne $null | ForEach-Object {
    "{0}: Label='{1}', FS={2}, Size={3:N1} GB, Free={4:N1} GB" -f `
        $_.DriveLetter, $_.FileSystemLabel, $_.FileSystem, ($_.Size/1GB), ($_.SizeRemaining/1GB)
}
'@
    $rc2 = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -Name $NewVMName `
      -CommandId 'RunPowerShellScript' -ScriptString $volScript -ErrorAction Stop
    if ($rc2.Value -and $rc2.Value[0] -and $rc2.Value[0].Message) {
      ($rc2.Value[0].Message -split "`r?`n") | ForEach-Object {
        if ($_ -ne '') { Write-Info "[$NewVMName] $_" }
      }
    }
  }
  catch {
    Write-Warn "Failed to retrieve disk/volume information from $NewVMName = $($_.Exception.Message)"
  }

  # === POST OUTPUT (DNS + reference only) ===
  # Post-migration output: Invoke the checklist function to output DNS/domain refresh steps (if needed).
  Emit-PostMigrationChecklist -DomainInfo $domainInfo -NewVMName $NewVMName -ResourceGroupName $ResourceGroupName

  # Completed: All migration steps finished. The new VM is running with EncryptionAtHost enabled.
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] === COMPLETED ===" -ForegroundColor White
  exit 0
}
catch {
  # If any error occurs during the process, log it and exit with a non-zero code.
  Write-Err ("ERROR: {0}" -f $_.Exception.Message)
  exit 99
}