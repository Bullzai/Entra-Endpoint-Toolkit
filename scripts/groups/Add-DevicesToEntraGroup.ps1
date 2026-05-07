<#
.DESCRIPTION
This tool will help you to add devices in bulk to Entra ID / Azure AD groups.

.EXAMPLE
.\Add-DevicesToEntraGroup.ps1 "group name"

.NOTES
Requires INPUT file devices.txt - 1 line per device name
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$GroupName
)

# -----------------------------
# config / validation
# -----------------------------

$InputFile = ".\devices.txt"
# $GroupName = "Group Name"

if (-not (Test-Path $InputFile)) {
  throw "Input file not found: $InputFile"
}

$scopes = @(
  "Group.ReadWrite.All",
  "Device.Read.All"
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

# -----------------------------
# main
# -----------------------------

# connect to graph
Connect-Graph -Scopes $scopes

$devices = Get-Content $InputFile |
ForEach-Object { $_.Trim() } |
Where-Object { $_ } |
Sort-Object -Unique

if (-not $devices) {
  throw "No device names found in file."
}

# get group once
$group = Get-MgGroup -Filter "displayName eq '$GroupName'"

if (-not $group) {
  throw "Group not found: $GroupName"
}

# get existing members once
$existingMembers = Get-MgGroupMember -GroupId $group.Id -All |
Select-Object -ExpandProperty Id

foreach ($device in $devices) {
  Write-Info "Processing $device ..."

  try {
    $entraDevice = Get-MgDevice -Filter "displayName eq '$device'" -ErrorAction Stop
  }
  catch {
    try {
      # fallback if exact match fails (partial match)
      $entraDevice = Get-MgDevice -Filter "startsWith(displayName,'$device')" -ErrorAction Stop |
      Select-Object -First 1
    }
    catch {
      Write-Warn "Not found in Entra ID: $device"
      continue
    }
  }

  if (-not $entraDevice) {
    Write-Warn "Not found in Entra ID: $device"
    continue
  }

  if ($existingMembers -contains $entraDevice.Id) {
    Write-Host "-> Already in group: $device" -ForegroundColor DarkYellow
    continue
  }

  try {
    New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $entraDevice.Id -ErrorAction Stop
    Write-Host "Added $device" -ForegroundColor Green
  }
  catch {
    Write-Warn "Failed to add $device : $($_.Exception.Message)"
  }
}