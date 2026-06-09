<#
.DESCRIPTION
Checks the version & reg path for the given software name from a list of devices.

.EXAMPLE
.\Get-AppVersionFromDevices.ps1 `
-NamesFile devices.txt `
-SoftwareName visual_studio_2019 `
-TenantId YourTenantId `
-ClientId YourClientId `
-ClientSecret YourClientSecret

.NOTES
Requires Microsoft App Registration with these API perms:
- AdvancedQuery.Read.All
- Machine.Read.All
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$NamesFile,

  [Parameter(Mandatory = $true)]
  [string]$SoftwareName,

  [Parameter(Mandatory = $true)]
  [string]$TenantId,

  [Parameter(Mandatory = $true)]
  [string]$ClientId,

  [Parameter(Mandatory = $true)]
  [string]$ClientSecret
)

# -----------------------------
# config / validation
# -----------------------------

$defenderDeviceNameSuffix = ".your.company.suffix"

if (-not (Test-Path $NamesFile)) {
  throw "Names file not found: $NamesFile"
}

$deviceNames = Get-Content $NamesFile |
ForEach-Object { $_.Trim() } |
Where-Object { $_ }

if (-not $deviceNames) {
  throw "No device names found"
}

# -----------------------------
# helpers
# -----------------------------

function Get-MdeToken {
  param($TenantId, $ClientId, $ClientSecret)

  $body = @{
    resource      = "https://api.securitycenter.microsoft.com"
    client_id     = $ClientId
    client_secret = $ClientSecret
    grant_type    = "client_credentials"
  }

  (Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/token" `
    -Body $body `
    -ContentType "application/x-www-form-urlencoded").access_token
}

function Invoke-MdeAdvancedHunting {
  param($Token, $Query)

  $headers = @{
    "Authorization" = "Bearer $Token"
    "Content-Type"  = "application/json"
  }

  $body = @{ Query = $Query } | ConvertTo-Json -Depth 5

  (Invoke-RestMethod -Method Post `
    -Uri "https://api.security.microsoft.com/api/advancedqueries/run" `
    -Headers $headers `
    -Body $body).Results
}

function Get-ContextFromRegistry {
  param($RegistryPaths)

  if (-not $RegistryPaths) { return "Unknown" }

  if ($RegistryPaths -match "HKEY_USERS") { return "User" }
  if ($RegistryPaths -match "HKEY_LOCAL_MACHINE") { return "System" }

  return "Unknown"
}

# -----------------------------
# main
# -----------------------------
$token = Get-MdeToken $TenantId $ClientId $ClientSecret

$allResults = foreach ($device in $deviceNames) {

  Write-Host "`nProcessing $device..." -ForegroundColor Cyan

  $safeDevice = $device.Replace("'", "''") + $defenderDeviceNameSuffix
  $safeSoftware = $SoftwareName.Replace("'", "''")

  $query = @"
DeviceTvmSoftwareInventory
| where DeviceName == '$safeDevice'
| where SoftwareName contains '$safeSoftware'
| project DeviceName, DeviceId, SoftwareName, SoftwareVersion
| join kind=leftouter (
    DeviceTvmSoftwareEvidenceBeta
    | project DeviceId, SoftwareName, RegistryPaths
) on DeviceId, SoftwareName
| project DeviceName, SoftwareName, SoftwareVersion, RegistryPaths
"@

  $results = Invoke-MdeAdvancedHunting -Token $token -Query $query

  if (-not $results) {
    [PSCustomObject]@{
      Device   = $device
      Software = $SoftwareName
      Version  = "Not found"
      Context  = "-"
    }
    continue
  }

  foreach ($r in $results) {

    [PSCustomObject]@{
      Device   = $r.DeviceName.Replace($defenderDeviceNameSuffix, '')
      Software = $r.SoftwareName
      Version  = $r.SoftwareVersion
      Context  = $r.RegistryPaths
    }
  }
}

# output
$allResults | Sort-Object Device | Format-Table -AutoSize