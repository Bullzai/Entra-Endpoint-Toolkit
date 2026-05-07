<#
.DESCRIPTION
This tool will help you to add devices in bulk to on-prem AD groups.

.EXAMPLE
.\Add-DevicesToOnPremGroup.ps1

.NOTES
Requires INPUT file devices.txt - 1 line per device name
#>

# -----------------------------
# config / validation
# -----------------------------

$InputFile = ".\devices.txt"
$GroupName = "Group Name"

if (-not (Test-Path $InputFile)) {
  throw "Input file not found: $InputFile"
}

# -----------------------------
# main
# -----------------------------

Import-Module ActiveDirectory

$devices = Get-Content $InputFile |
ForEach-Object { $_.Trim() } |
Where-Object { $_ } |
Sort-Object -Unique

if (-not $devices) {
  throw "No device names found in file."
}

# get group once
$group = Get-ADGroup -Identity $GroupName -ErrorAction Stop

# get existing members once
$existingMembers = Get-ADGroupMember -Identity $GroupName |
Select-Object -ExpandProperty DistinguishedName

foreach ($device in $devices) {
  Write-Host "Processing $device ..." -ForegroundColor Cyan

  try {
    $computer = Get-ADComputer -Identity $device -ErrorAction Stop
  }
  catch {
    try {
      # fallback if identity fails (partial match)
      $computer = Get-ADComputer -Filter "Name -like '$device*'" -ErrorAction Stop | Select-Object -First 1
    }
    catch {
      Write-Warning "Not found in AD: $device"
      continue
    }
  }

  if (-not $computer) {
    Write-Warning "Not found in AD: $device"
    continue
  }

  if ($existingMembers -contains $computer.DistinguishedName) {
    Write-Host "-> Already in group: $device" -ForegroundColor DarkYellow
    continue
  }

  try {
    Add-ADGroupMember -Identity $group -Members $computer -ErrorAction Stop
    Write-Host "Added $device" -ForegroundColor Green
  }
  catch {
    Write-Warning "Failed to add $device : $($_.Exception.Message)"
  }
}