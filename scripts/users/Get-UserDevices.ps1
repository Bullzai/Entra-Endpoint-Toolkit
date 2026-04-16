<#
.DESCRIPTION
Retrieves & exports devices for users that they are most likely using.

.PARAMETER InputFile
Path to file containing UPNs (one per line).

.EXAMPLE
.\Get-UserDevices.ps1

.NOTES
Requires Microsoft Graph permissions:
- User.Read.All
- Device.Read.All
- Directory.Read.All
- DeviceManagementManagedDevices.Read.All
#>

param(
  [string]$InputFile = ".\input\upns.txt",
  [string]$OutputAll = ".\output\User-WindowsDevices-All.csv",
  [string]$OutputNewest = ".\output\User-WindowsDevices-NewestOnly.csv"
)

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

function Get-ActivityTimestamp {
  param(
    [Nullable[datetime]]$IntuneLastSync,
    [Nullable[datetime]]$EntraApproxLastSignIn
  )

  if ($null -ne $IntuneLastSync) { return $IntuneLastSync }
  if ($null -ne $EntraApproxLastSignIn) { return $EntraApproxLastSignIn }
  return $null
}

# -----------------------------
# config
# -----------------------------

$scopes = @(
  "User.Read.All",
  "Device.Read.All",
  "Directory.Read.All",
  "DeviceManagementManagedDevices.Read.All"
)

# -----------------------------
# main
# -----------------------------

# import modules
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop

# connect to graph
Connect-Graph -Scopes $scopes

# validate input file
if (-not (Test-Path $InputFile)) {
  throw "input file not found: $InputFile"
}

$upns = Get-Content $InputFile |
ForEach-Object { $_.Trim() } |
Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
Sort-Object -Unique

if (-not $upns -or $upns.Count -eq 0) {
  throw "no upns found in input file"
}

# load intune managed windows devices
Write-Info "Loading intune managed windows devices..."

$allManagedWindows = Get-MgDeviceManagementManagedDevice -All -Property `
  "id,deviceName,userPrincipalName,model,manufacturer,operatingSystem,osVersion,azureADDeviceId,lastSyncDateTime,serialNumber,managedDeviceOwnerType,managementAgent,complianceState" |
Where-Object { $_.OperatingSystem -eq "Windows" }

# group devices by UPN
$managedByUpn = @{}
foreach ($md in $allManagedWindows) {
  $mdUpn = $md.UserPrincipalName
  if ([string]::IsNullOrWhiteSpace($mdUpn)) { continue }

  $key = $mdUpn.ToLowerInvariant()
  if (-not $managedByUpn.ContainsKey($key)) {
    $managedByUpn[$key] = New-Object System.Collections.Generic.List[object]
  }
  $managedByUpn[$key].Add($md)
}

# process users
$results = New-Object System.Collections.Generic.List[object]

foreach ($upn in $upns) {
  Write-Info "Processing $upn"

  $userResults = New-Object System.Collections.Generic.List[object]
  $seenKeys = @{}
  $upnKey = $upn.ToLowerInvariant()

  # intune devices first
  if ($managedByUpn.ContainsKey($upnKey)) {
    foreach ($md in $managedByUpn[$upnKey]) {

      $dedupeKey = if ($md.AzureADDeviceId) {
        "AAD:$($md.AzureADDeviceId)"
      }
      elseif ($md.SerialNumber) {
        "SERIAL:$($md.SerialNumber)"
      }
      else {
        "INTUNE:$($md.Id)"
      }

      $seenKeys[$dedupeKey] = $true
      $activity = Get-ActivityTimestamp $md.LastSyncDateTime $null

      $userResults.Add([pscustomobject]@{
          UserPrincipalName       = $upn
          DeviceName              = $md.DeviceName
          Model                   = $md.Model
          Manufacturer            = $md.Manufacturer
          OperatingSystem         = $md.OperatingSystem
          OSVersion               = $md.OsVersion
          EntraDeviceId           = $md.AzureADDeviceId
          IntuneManagedDeviceId   = $md.Id
          IntuneLastSyncDateTime  = $md.LastSyncDateTime
          EntraLastSignInDateTime = $null
          LastActivityDateTime    = $activity
          ActivitySource          = "Intune"
          ManagementAgent         = $md.ManagementAgent
          ManagedDeviceOwnerType  = $md.ManagedDeviceOwnerType
          ComplianceState         = $md.ComplianceState
        })
    }
  }

  # entra fallback
  try {
    $registered = @(Get-MgUserRegisteredDevice -UserId $upn -All -ErrorAction Stop)
    $owned = @(Get-MgUserOwnedDevice -UserId $upn -All -ErrorAction Stop)
  }
  catch {
    Write-Warn "Failed to read devices for $upn : $($_.Exception.Message)"
    $registered = @()
    $owned = @()
  }

  $deviceRefs = @($registered + $owned) |
  Where-Object { $_.Id } |
  Group-Object Id |
  ForEach-Object { $_.Group[0] }

  foreach ($deviceRef in $deviceRefs) {
    try {
      $d = Get-MgDevice -DeviceId $deviceRef.Id -Property `
        "id,deviceId,displayName,operatingSystem,operatingSystemVersion,approximateLastSignInDateTime"

      if ($d.OperatingSystem -ne "Windows") { continue }

      $dedupeKey = if ($d.DeviceId) { "AAD:$($d.DeviceId)" } else { "OBJ:$($d.Id)" }

      if ($seenKeys.ContainsKey($dedupeKey)) { continue }

      $seenKeys[$dedupeKey] = $true
      $activity = Get-ActivityTimestamp $null $d.ApproximateLastSignInDateTime

      $userResults.Add([pscustomobject]@{
          UserPrincipalName       = $upn
          DeviceName              = $d.DisplayName
          Model                   = $null
          Manufacturer            = $null
          OperatingSystem         = $d.OperatingSystem
          OSVersion               = $d.OperatingSystemVersion
          EntraDeviceId           = $d.DeviceId
          IntuneManagedDeviceId   = $null
          IntuneLastSyncDateTime  = $null
          EntraLastSignInDateTime = $d.ApproximateLastSignInDateTime
          LastActivityDateTime    = $activity
          ActivitySource          = "Entra"
          ManagementAgent         = $null
          ManagedDeviceOwnerType  = $null
          ComplianceState         = $null
        })
    }
    catch {
      Write-Warn "Failed resolving device $($deviceRef.Id) for $upn"
    }
  }

  # no device case
  if ($userResults.Count -eq 0) {
    $results.Add([pscustomobject]@{
        UserPrincipalName = $upn
        ActivitySource    = "No device found"
      })
    continue
  }

  # sort per user
  $sorted = $userResults | Sort-Object `
  @{ Expression = { if ($_.LastActivityDateTime) { [datetime]$_.LastActivityDateTime } else { [datetime]"1900-01-01" } }; Descending = $true },
  DeviceName

  foreach ($row in $sorted) {
    $results.Add($row)
  }
}

# export all
$results |
Sort-Object UserPrincipalName,
@{ Expression = { if ($_.LastActivityDateTime) { [datetime]$_.LastActivityDateTime } else { [datetime]"1900-01-01" } }; Descending = $true },
DeviceName |
Export-Csv -Path $OutputAll -NoTypeInformation -Encoding UTF8

# export newest per user
$results |
Group-Object UserPrincipalName |
ForEach-Object {
  $_.Group |
  Sort-Object @{
    Expression = { if ($_.LastActivityDateTime) { [datetime]$_.LastActivityDateTime } else { [datetime]"1900-01-01" } }
    Descending = $true
  }, DeviceName |
  Select-Object -First 1
} |
Export-Csv -Path $OutputNewest -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Info "Exporting..."
Write-Info "All devices: $OutputAll"
Write-Info "Newest per user: $OutputNewest"