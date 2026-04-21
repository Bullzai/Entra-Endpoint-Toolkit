<#
.DESCRIPTION
If you need to generate and/or update already existing group with devices, that are in a specific location,
this tool will create you a group with all the devices in it, based on a user attribute you provided.
Works really well if user attributes can be trusted and is considered as source of truth.

- Matches users by given attribute (city for example)
- Finds Intune managed devices whose primary user is one of those users
- Keeps only Windows devices
- Resolves Intune managed devices to Entra device objects
- Creates the target security group if it does not exist
- Syncs membership so the group contains only the matching devices

.PARAMETER UserAttribute, UserValue, GroupName
-UserAttribute city
-UserValue "Kaunas"
-GroupName "Intune - Devices - CloudOnly - Kaunas"

.EXAMPLE
.\Sync-DeviceGroupByLocation.ps1 `
 -UserAttribute city `
 -UserValue "Kaunas" `
 -GroupName "Intune - Devices - CloudOnly - Kaunas"

.NOTES
Requires Microsoft Graph permissions:
- User.Read.All
- Group.ReadWrite.All
- Device.Read.All
- DeviceManagementManagedDevices.Read.All
#>

param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("officeLocation", "city")]
  [string]$UserAttribute,

  [Parameter(Mandatory = $true)]
  [string]$UserValue,

  [Parameter(Mandatory = $false)]
  [string]$GroupName = "",

  [Parameter(Mandatory = $false)]
  [string]$GroupDescription = "",

  [Parameter(Mandatory = $false)]
  [switch]$Test
)

# -----------------------------
# config / validation
# -----------------------------

$scopes = @(
  "User.Read.All",
  "Group.ReadWrite.All",
  "Device.Read.All",
  "DeviceManagementManagedDevices.Read.All"
)

if ([string]::IsNullOrWhiteSpace($GroupName)) {
  $GroupName = "DEVICES-Windows-$UserAttribute-$UserValue"
}

if ([string]::IsNullOrWhiteSpace($GroupDescription)) {
  $GroupDescription = "Windows devices for users where $UserAttribute = '$UserValue'"
}

# mail nickname must be unique-ish and contain no spaces
$mailNickname = (
  "dev-" + $UserAttribute + "-" + $UserValue
).ToLower() -replace '[^a-z0-9\-]', '-'

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

function Escape-ODataString {
  param([string]$Value)
  return $Value.Replace("'", "''")
}

function Get-OrCreateTargetGroup {
  param(
    [string]$DisplayName,
    [string]$Description,
    [string]$MailNickname
  )

  $safeName = Escape-ODataString $DisplayName
  $existing = Get-MgGroup -Filter "displayName eq '$safeName'" -All

  if ($existing.Count -gt 1) {
    throw "More than one group found with displayName '$DisplayName'. Please make the name unique."
  }

  if ($existing) {
    Write-Info "Found existing group: $($existing.DisplayName) [$($existing.Id)]"
    return $existing
  }

  Write-Info "Creating new security group: $DisplayName"

  if ($Test) {
    return [pscustomobject]@{
      Id          = "TEST-GROUP-ID"
      DisplayName = $DisplayName
    }
  }

  $newGroupParams = @{
    DisplayName     = $DisplayName
    Description     = $Description
    MailEnabled     = $false
    SecurityEnabled = $true
    MailNickname    = $MailNickname
  }

  $group = New-MgGroup @newGroupParams
  Write-Info "Created group: $($group.DisplayName) [$($group.Id)]"
  return $group
}

function Get-UsersByLocation {
  param(
    [string]$AttributeName,
    [string]$AttributeValue
  )

  $safeValue = Escape-ODataString $AttributeValue
  $filter = "$AttributeName eq '$safeValue'"

  Write-Info "Querying users where $AttributeName = '$AttributeValue'"

  $users = Get-MgUser -Filter $filter -ConsistencyLevel eventual -All `
    -Property Id, DisplayName, UserPrincipalName, OfficeLocation, City, AccountEnabled

  # keep only enabled users
  $users = $users | Where-Object { $_.AccountEnabled -eq $true }

  return $users
}

function Get-WindowsManagedDevicesForUsers {
  param(
    [array]$Users
  )

  if (-not $Users -or $Users.Count -eq 0) {
    return @()
  }

  $userIds = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($u in $Users) {
    [void]$userIds.Add($u.Id)
  }

  Write-Info "Fetching Intune Windows managed devices..."
  $allManagedDevices = Get-MgDeviceManagementManagedDevice `
    -All `
    -Filter "operatingSystem eq 'Windows'"

  $windowsManagedDevices = $allManagedDevices | Where-Object {
    $_.UserId -and $userIds.Contains($_.UserId)
  }

  return $windowsManagedDevices
}

function Get-ManagedDeviceEntraDeviceId {
  param(
    [Parameter(Mandatory = $true)]
    $ManagedDevice
  )

  # try common SDK/REST property names first
  $candidateProps = @(
    'AzureADDeviceId',
    'AzureAdDeviceId',
    'AzureActiveDirectoryDeviceId'
  )

  foreach ($prop in $candidateProps) {
    $p = $ManagedDevice.PSObject.Properties[$prop]
    if ($p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) {
      return [string]$p.Value
    }
  }

  # fallback to AdditionalProperties if the SDK placed it there
  if ($ManagedDevice.PSObject.Properties['AdditionalProperties']) {
    $ap = $ManagedDevice.AdditionalProperties
    if ($ap) {
      foreach ($key in @('azureADDeviceId', 'azureAdDeviceId', 'azureActiveDirectoryDeviceId')) {
        if ($ap.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$ap[$key])) {
          return [string]$ap[$key]
        }
      }
    }
  }

  return $null
}

function Resolve-EntraDevicesFromManagedDevices {
  param(
    [array]$ManagedDevices
  )

  $resolved = @()
  $seenEntraObjectIds = [System.Collections.Generic.HashSet[string]]::new()

  foreach ($md in $ManagedDevices) {
    $managedDeviceEntraId = Get-ManagedDeviceEntraDeviceId -ManagedDevice $md

    if ([string]::IsNullOrWhiteSpace($managedDeviceEntraId)) {
      Write-Warn "Skipping managed device '$($md.DeviceName)' because no Entra device ID property was found on the managedDevice object."
      continue
    }

    $safeDeviceId = Escape-ODataString $managedDeviceEntraId

    try {
      # managedDevice azureAD/azureActiveDirectory device id maps to Entra device.deviceId
      $entraDevice = Get-MgDevice `
        -Filter "deviceId eq '$safeDeviceId'" `
        -All `
        -Property Id, DeviceId, DisplayName, TrustType, EnrollmentType

      if (-not $entraDevice) {
        Write-Warn "No Entra device object found for managed device '$($md.DeviceName)' (deviceId: $managedDeviceEntraId)"
        continue
      }

      foreach ($d in $entraDevice) {
        if (-not $seenEntraObjectIds.Contains($d.Id)) {
          [void]$seenEntraObjectIds.Add($d.Id)
          $resolved += [pscustomobject]@{
            EntraDeviceObjectId = $d.Id
            EntraDeviceId       = $d.DeviceId
            EntraDisplayName    = $d.DisplayName
            TrustType           = $d.TrustType
            EnrollmentType      = $d.EnrollmentType
            ManagedDeviceId     = $md.Id
            ManagedDeviceName   = $md.DeviceName
            UserId              = $md.UserId
            UserPrincipalName   = $md.UserPrincipalName
            OperatingSystem     = $md.OperatingSystem
          }
        }
      }
    }
    catch {
      Write-Warn "Failed resolving Entra device for managed device '$($md.DeviceName)': $($_.Exception.Message)"
    }
  }

  return $resolved
}
function Get-CurrentDeviceMembers {
  param(
    [string]$GroupId
  )

  # always return a hashset, even when the group has no members yet
  $ids = [System.Collections.Generic.HashSet[string]]::new()

  try {
    $members = @(Get-MgGroupMember -GroupId $GroupId -All -ErrorAction Stop)
  }
  catch {
    Write-Warn "Could not read current members for group $GroupId : $($_.Exception.Message)"
    return $ids
  }

  if (-not $members -or $members.Count -eq 0) {
    return $ids
  }

  foreach ($m in $members) {
    $odataType = $null

    if ($m.PSObject.Properties['AdditionalProperties'] -and $m.AdditionalProperties) {
      if ($m.AdditionalProperties.ContainsKey('@odata.type')) {
        $odataType = $m.AdditionalProperties['@odata.type']
      }
    }

    if ($odataType -eq '#microsoft.graph.device' -and $m.Id) {
      [void]$ids.Add($m.Id)
    }
  }

  return $ids
}

function Sync-GroupMembership {
  param(
    [string]$GroupId,
    [array]$TargetEntraDevices
  )

  $targetIds = [System.Collections.Generic.HashSet[string]]::new()
  $deviceNameById = @{}

  foreach ($d in @($TargetEntraDevices)) {
    if ($d.EntraDeviceObjectId) {
      [void]$targetIds.Add($d.EntraDeviceObjectId)

      $friendlyName = $null
      if (-not [string]::IsNullOrWhiteSpace($d.ManagedDeviceName)) {
        $friendlyName = $d.ManagedDeviceName
      }
      elseif (-not [string]::IsNullOrWhiteSpace($d.EntraDisplayName)) {
        $friendlyName = $d.EntraDisplayName
      }
      else {
        $friendlyName = "UnknownDeviceName"
      }

      $deviceNameById[$d.EntraDeviceObjectId] = $friendlyName
    }
  }

  $currentIds = Get-CurrentDeviceMembers -GroupId $GroupId

  if (-not $currentIds) {
    $currentIds = [System.Collections.Generic.HashSet[string]]::new()
  }

  $toAdd = @()
  foreach ($id in $targetIds) {
    if (-not $currentIds.Contains($id)) {
      $toAdd += $id
    }
  }

  $toRemove = @()
  foreach ($id in $currentIds) {
    if (-not $targetIds.Contains($id)) {
      $toRemove += $id
    }
  }

  Write-Info "Devices to add   : $($toAdd.Count)"
  Write-Info "Devices to remove: $($toRemove.Count)"

  # test mode
  if ($Test) {
    Write-Host ""
    Write-Host "TEST MODE" -ForegroundColor Green
    Write-Host "Would add devices:"
    foreach ($id in $toAdd) {
      $name = if ($deviceNameById.ContainsKey($id)) { $deviceNameById[$id] } else { "UnknownDeviceName" }
      Write-Host "  $name [$id]"
    }

    Write-Host "Would remove devices:"
    foreach ($id in $toRemove) {
      $name = if ($deviceNameById.ContainsKey($id)) { $deviceNameById[$id] } else { "UnknownDeviceName" }
      Write-Host "  $name [$id]"
    }
    return
  }

  foreach ($id in $toAdd) {
    try {
      New-MgGroupMemberByRef -GroupId $GroupId -OdataId "https://graph.microsoft.com/v1.0/devices/$id" | Out-Null
      $name = $deviceNameById[$id]
      Write-Info "Added device $name [$id]"
    }
    catch {
      Write-Warn "Failed to add device $id : $($_.Exception.Message)"
    }
  }

  # remove devices that do not exist anymore or should not be there
  foreach ($id in $toRemove) {
    try {
      Remove-MgGroupMemberByRef -GroupId $GroupId -DirectoryObjectId $id
      $name = if ($deviceNameById.ContainsKey($id)) { $deviceNameById[$id] } else { "UnknownDeviceName" }
      Write-Info "Removed device $name [$id]"
    }
    catch {
      Write-Warn "Failed to remove device $id : $($_.Exception.Message)"
    }
  }
}

function Test-Devices23H2Count {
  param(
    [array]$ManagedDevices
  )

  # print to debug the versions for match formula
  $ManagedDevices | Select-Object -First 10 DeviceName, OsVersion | Format-Table
  
  # count only windows 23h2 devices
  $filtered = @($ManagedDevices | Where-Object {
      $_.OperatingSystem -eq "Windows" -and
      (
        $_.OsVersion -match "^10\.0\.22631" # win11 23h2
      )
    })

  $total = if ($ManagedDevices) { $ManagedDevices.Count } else { 0 }
  $count23H2 = $filtered.Count

  Write-Host ""
  Write-Host "Device summary (Test mode - 23H2 only)" -ForegroundColor Cyan
  Write-Host "Total matched Windows devices : $total"
  Write-Host "Windows 23H2 devices         : $count23H2" -ForegroundColor Green
}

# -----------------------------
# main
# -----------------------------

try {
  # connect to graph
  Connect-Graph -Scopes $scopes

  $group = Get-OrCreateTargetGroup -DisplayName $GroupName -Description $GroupDescription -MailNickname $mailNickname

  $users = Get-UsersByLocation -AttributeName $UserAttribute -AttributeValue $UserValue
  Write-Info "Matched users: $($users.Count)"

  if (-not $users -or $users.Count -eq 0) {
    Write-Warn "No users found for $UserAttribute = '$UserValue'."
    if (-not $Test -and $group.Id -ne "TEST-GROUP-ID") {
      Write-Info "Group was created/found, but no members will be added."
    }
    return
  }

  $managedDevices = Get-WindowsManagedDevicesForUsers -Users $users
  Write-Info "Matched Windows managed devices: $($managedDevices.Count)"

  if ($Test) {
    Test-Devices23H2Count -ManagedDevices $managedDevices
    return
  }

  if (-not $managedDevices -or $managedDevices.Count -eq 0) {
    Write-Warn "No Windows managed devices found for the matched users."
    if ($group.Id -ne "TEST-GROUP-ID") {
      Sync-GroupMembership -GroupId $group.Id -TargetEntraDevices @()
    }
    return
  }

  $entraDevices = Resolve-EntraDevicesFromManagedDevices -ManagedDevices $managedDevices
  Write-Info "Resolved Entra device objects: $($entraDevices.Count)"

  $entraDevices = @($entraDevices | Where-Object {
      $_.TrustType -eq 'AzureAd' -and $_.EnrollmentType -ne 'OnPremiseCoManaged'
    })

  Write-Info "Cloud-only Entra joined Windows devices: $($entraDevices.Count)"

  if (-not $entraDevices -or $entraDevices.Count -eq 0) {
    Write-Warn "No Entra device objects could be resolved from the Windows managed devices."
    if ($group.Id -ne "TEST-GROUP-ID") {
      Sync-GroupMembership -GroupId $group.Id -TargetEntraDevices @()
    }
    return
  }

  Write-Host ""
  Write-Host "Devices that will define group membership:" -ForegroundColor Green
  $entraDevices |
  Sort-Object UserPrincipalName, ManagedDeviceName |
  Select-Object UserPrincipalName, ManagedDeviceName, EntraDisplayName, OperatingSystem, TrustType, EnrollmentType, EntraDeviceObjectId |
  Format-Table -AutoSize

  if ($group.Id -ne "TEST-GROUP-ID") {
    Write-Info "Target group id: $($group.Id)"
    Write-Info "Target Entra devices to sync: $($entraDevices.Count)"
    Sync-GroupMembership -GroupId $group.Id -TargetEntraDevices $entraDevices
    Write-Host ""
    Write-Host "Done. Group '$($group.DisplayName)' now reflects Windows devices for $UserAttribute = '$UserValue'." -ForegroundColor Green
  }
}
catch {
  Write-Error $_.Exception.Message
  throw
}