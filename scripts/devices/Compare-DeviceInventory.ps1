<#
.DESCRIPTION
Some devices might be on-prem, but not in Intune, but they should.
This tool will help you compile & dump a list of those devices.

.EXAMPLE
.\Compare-DeviceInventory.ps1 -GroupName "group name"

.NOTES
Requires Microsoft Graph permissions:
- "Device.Read.All",
- "DeviceManagementManagedDevices.Read.All"
#>

# -----------------------------
# config / validation
# -----------------------------

$StaleDays = 60
$StaleCutoff = (Get-Date).AddDays(-$StaleDays)

$DefaultExcludePatterns = @(
  "iphone",
  "ipad",
  "android"
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = Get-Location }

$scopes = @(
  "Device.Read.All",
  "DeviceManagementManagedDevices.Read.All"
)

# merge + normalize exclusions
$ExcludePatterns = ($DefaultExcludePatterns + $args) |
Where-Object { $_ } |
ForEach-Object { $_.ToLowerInvariant() } |
Sort-Object -Unique

# -----------------------------
# helpers
# -----------------------------

function Write-Info {
  param([string]$Message)
  Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
  param([string]$Message)
  Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Connect-Graph {
  param([string[]]$Scopes)

  Write-Info "Connecting to microsoft graph..."
  Connect-MgGraph -Scopes $Scopes -NoWelcome
}

function Filter-ExcludedDevices {
  param (
    [Parameter(Mandatory)]
    [array]$Devices,

    [Parameter(Mandatory)]
    [string[]]$ExcludePatterns
  )

  return $Devices | Where-Object {
    $name = $_.DeviceName
    if (-not $name) { return $false }

    $nameLower = $name.ToLowerInvariant()

    foreach ($pattern in $ExcludePatterns) {
      if ($nameLower -like "*$pattern*") {
        return $false
      }
    }

    return $true
  }
}

function Get-IntuneDevices {
  Write-Host "Getting InTune devices.." -ForegroundColor Yellow
  Get-MgDeviceManagementManagedDevice -All |
  Select-Object DeviceName, AzureADDeviceId |
  Sort-Object DeviceName
}

function Get-OnPremDevices {
  Write-Host "Getting On-Prem devices.." -ForegroundColor Yellow
  Get-ADComputer -Filter * -Properties DistinguishedName, LastLogonTimestamp, Enabled, OperatingSystem |
  Select-Object `
  @{Name = "DeviceName"; Expression = { $_.Name } },
  @{Name = "OU"; Expression = { ($_.DistinguishedName -replace '^CN=[^,]+,', '') } },
  @{Name = "OperatingSystem"; Expression = { $_.OperatingSystem } },
  @{Name = "LastLogonDate"; Expression = {
      if ($_.LastLogonTimestamp) {
        [DateTime]::FromFileTime($_.LastLogonTimestamp)
      }
    }
  },
  Enabled
}

function Get-EntraDevices {
  Write-Host "Getting Entra ID devices.." -ForegroundColor Yellow
  Get-MgDevice -All |
  Select-Object DisplayName, Id, ApproximateLastSignInDateTime, AccountEnabled
}

# -----------------------------
# main
# -----------------------------

# connect to graph
Connect-Graph -Scopes $scopes

Write-Host "Excluding non-server devices (based on OS) & names containing:" -ForegroundColor Yellow
$ExcludePatterns | ForEach-Object { Write-Host " * $_" }

$IntuneDevicesRaw = Get-IntuneDevices
$OnPremDevicesRaw = Get-OnPremDevices
$EntraDevices = Get-EntraDevices

# apply exclude list
$IntuneDevices = Filter-ExcludedDevices -Devices $IntuneDevicesRaw -ExcludePatterns $ExcludePatterns
$OnPremDevices = Filter-ExcludedDevices -Devices $OnPremDevicesRaw     -ExcludePatterns $ExcludePatterns

# filter out servers, keep win10 / win11 clients only
$OnPremDevices = $OnPremDevices |
Where-Object {
  $_.OperatingSystem -and
  $_.OperatingSystem -notlike "*server*" -and
  (
    $_.OperatingSystem -like "*Windows 10*" -or
    $_.OperatingSystem -like "*Windows 11*"
  )
}

# sort results
$IntuneDevices = $IntuneDevices | Sort-Object DeviceName
$OnPremDevices = $OnPremDevices     | Sort-Object OU, DeviceName

# filter stale (inactive) on-prem devices
$ActiveOnPremDevices = $OnPremDevices |
Where-Object {
  $_.Enabled -eq $true -and
  $_.LastLogonDate -and
  $_.LastLogonDate -ge $StaleCutoff
}

# derive site prefix from device name
$ActiveOnPremDevices = $ActiveOnPremDevices | ForEach-Object {
  $site = if ($_.DeviceName.Length -ge 5) {
    $_.DeviceName.Substring(0, 5)
  }
  else {
    $_.DeviceName
  }

  $_ | Add-Member -NotePropertyName Site -NotePropertyValue $site -Force
  $_
}

# lookup & sort devices names
$IntuneLookup = $IntuneDevices.DeviceName | Sort-Object -Unique
$EntraLookup = $EntraDevices.DisplayName | Sort-Object -Unique

$OnPremOnlyDetailed = $ActiveOnPremDevices |
Where-Object { $_.DeviceName -notin $IntuneLookup } |
ForEach-Object {
  $existsInEntra = $_.DeviceName -in $EntraLookup

  [PSCustomObject]@{
    DeviceName    = $_.DeviceName
    OU            = $_.OU
    LastLogonDate = $_.LastLogonDate
    ExistsInEntra = $existsInEntra
    Status        = if ($existsInEntra) {
      "Hybrid -> Cloud transition / stale Entra object"
    }
    else {
      "ACTIVE ON-PREM DEVICE NOT IN INTUNE (ACTION REQUIRED)"
    }
  }
}

# build per-site summary
$SiteSummary = $ActiveOnPremDevices |
Group-Object Site |
ForEach-Object {

  $siteDevices = $_.Group
  $siteName = $_.Name

  $enabled = ($siteDevices | Where-Object Enabled).Count
  $disabled = ($siteDevices | Where-Object { -not $_.Enabled }).Count

  $inIntune = ($siteDevices | Where-Object {
      $_.DeviceName -in $IntuneLookup
    }).Count

  $notInIntune = $enabled - $inIntune

  [PSCustomObject]@{
    Site        = $siteName
    Total       = $siteDevices.Count
    Enabled     = $enabled
    Disabled    = $disabled
    InIntune    = $inIntune
    NotInIntune = $notInIntune
  }
}

# -----------------------------
# output
# -----------------------------

# Write-Host "`nActionable devices (NOT in InTune):" -ForegroundColor Red
# $OnPremOnlyDetailed |
# Where-Object { $_.Status -like "*ACTION REQUIRED*" } |
# Sort-Object OU, DeviceName |
# Format-Table -AutoSize

Write-Host "===== SUMMARY =====" -ForegroundColor Cyan

# debug to see all count
Write-Host "DEBUG: InTune raw count: $($IntuneDevicesRaw.Count)"
Write-Host "DEBUG: On-Prem raw count    : $($OnPremDevicesRaw.Count)"
Write-Host "DEBUG: Entra raw count : $($EntraDevices.Count)"

Write-Host "`nInTune devices            : $($IntuneDevices.Count)"
Write-Host "Active On-Prem devices checked : $($ActiveOnPremDevices.Count)"
Write-Host "`nOn-Prem devices missing in InTune : $($OnPremOnlyDetailed.Count)" -ForegroundColor Red

Write-Host "`n===== PER-SITE SUMMARY =====" -ForegroundColor Cyan

$SiteSummary |
Sort-Object Site |
Format-Table `
@{Label = "Site"; Expression = { $_.Site } },
@{Label = "Total"; Expression = { $_.Total } },
@{Label = "Enabled"; Expression = { $_.Enabled } },
@{Label = "Disabled"; Expression = { $_.Disabled } },
@{Label = "In InTune"; Expression = { $_.InInTune } },
@{Label = "Not In InTune"; Expression = { $_.NotInInTune } },
@{Label = "Coverage %"; Expression = {
    if ($_.Enabled -gt 0) {
      [Math]::Round(($_.InIntune / $_.Enabled) * 100, 1)
    }
    else {
      0
    }
  }
}`
  -AutoSize

# export
$ExportPath = Join-Path $ScriptDir "OnPrem_Active_Not_In_InTune_Detailed_Device_List.csv"

$OnPremOnlyDetailed |
Sort-Object Status, OU, DeviceName |
Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8

Write-Host "`nDevice list CSV created:"
Write-Host $ExportPath -ForegroundColor Yellow

$SiteSummaryPath = Join-Path $ScriptDir "OnPrem_InTune_Comparison_Per_Site_Summary.csv"

$SiteSummary |
Sort-Object Site |
Export-Csv -Path $SiteSummaryPath -NoTypeInformation -Encoding UTF8

Write-Host "`nSite summary CSV created:"
Write-Host $SiteSummaryPath -ForegroundColor Yellow