<#
.DESCRIPTION
Allows removing and adding registered/owned device relationships
for a user, including bulk cleanup and primary user assignment.

.PARAMETER UPN
user@domain.com

.EXAMPLE
.\Set-UserDeviceOwnership.ps1 user@domain.com

.NOTES
Requires Microsoft Graph permissions:
- User.Read.All
- Device.Read.All
- Directory.Read.All
- Device.ReadWrite.All
- DeviceManagementManagedDevices.ReadWrite.All
#>

param (
  [Parameter(Mandatory = $true)]
  [string]$UserUPN
)

# -----------------------------
# config
# -----------------------------

$scopes = @(
  "User.Read.All",
  "Device.Read.All",
  "Directory.Read.All",
  "Device.ReadWrite.All",
  "DeviceManagementManagedDevices.ReadWrite.All"
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

# normalize devices and enrich with entra + intune data
function Normalize-Devices {
  param ($Devices, $Source)

  foreach ($d in $Devices) {
    if ($d.AdditionalProperties.'@odata.type' -ne '#microsoft.graph.device') {
      continue
    }

    # get entra device details
    $DeviceDetails = Get-MgDevice -DeviceId $d.Id -ErrorAction SilentlyContinue
    $AzureAdDeviceId = $DeviceDetails.DeviceId

    # map to intune managed device
    $ManagedDevice = $null
    if ($AzureAdDeviceId) {
      $ManagedDevice = Get-MgDeviceManagementManagedDevice `
        -Filter "azureADDeviceId eq '$AzureAdDeviceId'" `
        -ErrorAction SilentlyContinue |
      Select-Object -First 1
    }

    [PSCustomObject]@{
      Index           = 0
      Source          = $Source # registered/owned
      DeviceId        = $d.Id # Object ID in reality
      AzureAdDeviceId = $AzureAdDeviceId
      ManagedDeviceId = $ManagedDevice.Id
      DisplayName     = $d.AdditionalProperties.displayName
      OS              = $d.AdditionalProperties.operatingSystem
      TrustType       = $d.AdditionalProperties.trustType
      LastActivity    = $DeviceDetails.ApproximateLastSignInDateTime
      IsDuplicate     = $false
    }
  }
}

# -----------------------------
# main
# -----------------------------

# connect to graph
Connect-Graph -Scopes $scopes

# choose operation
Write-Host "`nChoose operation type:" -ForegroundColor Yellow
Write-Host "1 - remove relationships"
Write-Host "2 - add relationships"

$Operation = Read-Host "Selection (1/2)"

if ($Operation -notin '1', '2') {
  Write-Warn "Invalid selection"
  return
}

Write-Info "Using UPN: $UserUPN"

# resolve user
$User = Get-MgUser -UserId $UserUPN -ErrorAction SilentlyContinue

if (-not $User) {
  Write-Warn "User with UPN $UserUPN not found"
  return
}

# -----------------------------
# remove relationships
# -----------------------------

if ($Operation -eq '1') {

  # get user devices
  $RegisteredRaw = Get-MgUserRegisteredDevice -UserId $User.Id
  $OwnedRaw = Get-MgUserOwnedDevice -UserId $User.Id

  $RegisteredDevices = @(Normalize-Devices $RegisteredRaw "Registered")
  $OwnedDevices = @(Normalize-Devices $OwnedRaw "Owned")

  if (-not $RegisteredDevices -and -not $OwnedDevices) {
    Write-Warn "No devices found for user $UserUPN"
    return
  }

  # merge lists
  $Devices = @($RegisteredDevices + $OwnedDevices)

  # detect duplicates
  $DuplicateIds = $Devices |
  Group-Object DeviceId |
  Where-Object { $_.Count -gt 1 } |
  Select-Object -ExpandProperty Name

  $Devices |
  Where-Object { $DuplicateIds -contains $_.DeviceId } |
  ForEach-Object { $_.IsDuplicate = $true }

  # reindex
  $i = 1
  $Devices | ForEach-Object { $_.Index = $i; $i++ }

  Write-Host "`nDevices (Registered & Owned):`n" -ForegroundColor Yellow

  "{0,5}  {1,-28}  {2,-38}  {3,-10}  {4,-10}  {5,-10}  {6,-20}  {7}" -f `
    "Index", "DisplayName", "ObjectID", "OS", "TrustType", "Source", "Last Activity", "Registered AND Owned"

  "{0,5}  {1,-28}  {2,-38}  {3,-10}  {4,-10}  {5,-10}  {6}" -f `
    "-----", "-----------", "------------------------------------", "--", "---------", "------", "---------"

  foreach ($d in $Devices) {

    $lastSeen = if ($d.LastActivity) {
      (Get-Date $d.LastActivity).ToString("yyyy-MM-dd")
    }
    else {
      "Never"
    }

    $prefix = "{0,5}  {1,-28}  {2,-38}  {3,-10}  {4,-10}  {5,-10}  {6,-20}  " -f `
      $d.Index,
    $d.DisplayName,
    $d.DeviceId,
    $d.OS,
    $d.TrustType,
    $d.Source,
    $lastSeen

    Write-Host -NoNewline $prefix

    if ($d.IsDuplicate) {
      Write-Host "+"
    }
    else {
      Write-Host "X" -ForegroundColor Red
    }
  }

  # choose removal mode
  Write-Host "`nChoose removal action (method):" -ForegroundColor Yellow
  Write-Host "1 - remove Registered"
  Write-Host "2 - remove Owner"
  Write-Host "3 - remove Registered + Owner"
  Write-Host "4 - remove Registered + Owner for all devices except one"

  $Mode = Read-Host "Selection (1/2/3/4)"

  if ($Mode -notin '1', '2', '3', '4') {
    Write-Warn "Invalid selection"
    return
  }

  # bulk cleanup
  if ($Mode -eq '4') {

    $KeepIndex = Read-Host "`nEnter device index to KEEP (Q to quit)"

    if ($KeepIndex -match '^[Qq]$') { return }
    if ($KeepIndex -notmatch '^\d+$') {
      Write-Warn "Invalid index"
      return
    }

    $KeepDevice = $Devices | Where-Object { $_.Index -eq [int]$KeepIndex } | Select-Object -First 1

    if (-not $KeepDevice) {
      Write-Warn "Device index not found"
      return
    }

    $KeepDeviceId = $KeepDevice.DeviceId

    $UniqueDevicesToProcess = $Devices |
    Where-Object { $_.DeviceId -ne $KeepDeviceId } |
    Group-Object DeviceId |
    ForEach-Object { $_.Group[0] }

    if (-not $UniqueDevicesToProcess) {
      Write-Warn "Nothing to process"
      return
    }

    Write-Host "`nDevice to KEEP:`n" -ForegroundColor Green
    $Devices |
    Where-Object { $_.DeviceId -eq $KeepDeviceId } |
    Select-Object Index, DisplayName, Source, DeviceId, IsDuplicate |
    Format-Table -AutoSize

    Write-Warn "`nDevices that will have Registered User + Owner removed:`n"
    $UniqueDevicesToProcess |
    Select-Object DisplayName, DeviceId |
    Format-Table -AutoSize

    $Confirm = Read-Host "`nConfirm? (yes/y)"

    if ($Confirm.ToLower() -notin @('yes', 'y')) {
      Write-Warn "Operation cancelled"
      return
    }


    foreach ($Device in $UniqueDevicesToProcess) {

      Write-Info "Processing $($Device.DisplayName) [$($Device.DeviceId)]"

      try {
        Remove-MgDeviceRegisteredUserByRef -DeviceId $Device.DeviceId -DirectoryObjectId $User.Id -ErrorAction Stop
        Write-Info "Removed Registered User"
      }
      catch {}

      try {
        Remove-MgDeviceRegisteredOwnerByRef -DeviceId $Device.DeviceId -DirectoryObjectId $User.Id -ErrorAction Stop
        Write-Info "Removed Owner"
      }
      catch {}
    }

    Write-Info "Completed cleanup"
    return
  }

  # selective removal
  $Selection = Read-Host "`nEnter device index to UNASSIGN, comma-separated if multiple (Q to quit)"

  if ($Selection -match '^[Qq]$') { return }

  $Indexes = $Selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
  $SelectedDevices = $Devices | Where-Object { $Indexes -contains $_.Index.ToString() }

  if (-not $SelectedDevices) {
    Write-Warn "No valid selection"
    return
  }

  Write-Host "`nYou selected:`n" -ForegroundColor Yellow
  $SelectedDevices | Select-Object DisplayName, Source, DeviceId, IsDuplicate |
  Format-Table -AutoSize

  $Confirm = Read-Host "`nConfirm remove? (yes/y)"

  if ($Confirm.ToLower() -notin @('yes', 'y')) {
    Write-Warn "Operation cancelled"
    return
  }


  foreach ($Device in $SelectedDevices) {

    Write-Info "Processing $($Device.DisplayName)"

    if ($Mode -in '1', '3') {
      try {
        Remove-MgDeviceRegisteredUserByRef -DeviceId $Device.DeviceId -DirectoryObjectId $User.Id -ErrorAction Stop
        Write-Info "Removed Registered User"
      }
      catch {}
    }

    if ($Mode -in '2', '3') {
      try {
        Remove-MgDeviceRegisteredOwnerByRef -DeviceId $Device.DeviceId -DirectoryObjectId $User.Id -ErrorAction Stop
        Write-Info "Removed Owner"
      }
      catch {}
    }
  }

  Write-Info "Completed removal operation"
}

# -----------------------------
# add relationships
# -----------------------------

if ($Operation -eq '2') {

  Write-Host "`nChoose add action:" -ForegroundColor Yellow
  Write-Host "1 - add Registered"
  Write-Host "2 - add Owner"
  Write-Host "3 - add Registered + Owner"
  Write-Host "4 - add Registered + Owner + Primary"

  $AddMode = Read-Host "Selection"

  if ($AddMode -notin '1', '2', '3', '4') {
    Write-Warn "Invalid selection"
    return
  }

  $DeviceIdsInput = Read-Host "`nEnter device ObjectId, comma-separated if multiple"

  $AddDeviceIds = $DeviceIdsInput -split ',' |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' }

  if (-not $AddDeviceIds) {
    Write-Warn "No valid device ids"
    return
  }

  $Confirm = Read-Host "`nConfirm add? (yes/y)"

  if ($Confirm.ToLower() -notin @('yes', 'y')) {
    Write-Warn "Operation cancelled"
    return
  }

  foreach ($DeviceId in $AddDeviceIds) {

    Write-Info "Processing $DeviceId"

    # add registered
    if ($AddMode -in '1', '3', '4') {
      try {
        New-MgDeviceRegisteredUserByRef -DeviceId $DeviceId -BodyParameter @{
          '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($User.Id)"
        }
        Write-Info "Added Registered User"
      }
      catch {
        Write-Warn "Failed to add Registered User"
      }
    }

    # add owner
    if ($AddMode -in '2', '3', '4') {
      try {
        New-MgDeviceRegisteredOwnerByRef -DeviceId $DeviceId -BodyParameter @{
          '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($User.Id)"
        }
        Write-Info "Added Owner"
      }
      catch {
        Write-Warn "Failed to add Owner"
      }
    }

    # add primary
    if ($AddMode -eq '4') {

      $DeviceDetails = Get-MgDevice -DeviceId $DeviceId -ErrorAction SilentlyContinue
      $AzureAdDeviceId = $DeviceDetails.DeviceId

      if ($AzureAdDeviceId) {

        $ManagedDevice = Get-MgDeviceManagementManagedDevice `
          -Filter "azureADDeviceId eq '$AzureAdDeviceId'" |
        Select-Object -First 1

        if ($ManagedDevice -and $ManagedDevice.Id) {
          try {
            $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($ManagedDevice.Id)/users/`$ref"

            $body = @{
              "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($User.Id)"
            } | ConvertTo-Json

            Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType "application/json"

            Write-Info "Added Primary User"
          }
          catch {
            Write-Warn "Failed to set Primary User"
          }
        }
      }
    }
  }

  Write-Info "Completed add operation"
}