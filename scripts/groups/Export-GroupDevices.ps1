<#
.DESCRIPTION
Exports devices from an Entra group (including nested groups)
and resolves primary user via Intune where available

.PARAMETER GroupId, GroupName, OutCsv (not mandatory)
-GroupName "group name" -OutCsv ".\path\to\devices.csv"
-GroupName "group name"
bb2f7dc7-1722-4c43-11ae-e83ae2a37e1d

.EXAMPLE
.\Export-GroupDevices.ps1 -GroupName "group name" -OutCsv ".\path\to\devices.csv"
.\Export-GroupDevices.ps1 -GroupId "bb2f7dc7-1722-4c43-11ae-e83ae2a37e1d" -OutCsv ".\path\to\devices.csv"
.\Export-GroupDevices.ps1 -GroupName "group name"
.\Export-GroupDevices.ps1 bb2f7dc7-1722-4c43-11ae-e83ae2a37e1d

.NOTES
Requires Microsoft Graph permissions:
- "Device.Read.All",
- "DeviceManagementManagedDevices.Read.All",
- "User.Read.All"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false, Position = 0)]
  [string]$GroupId,

  [Parameter(Mandatory = $false)]
  [string]$GroupName,

  [Parameter(Mandatory = $false)]
  [string]$OutCsv = ".\GroupDevices_PrimaryUsers.csv"
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

function Escape-ODataString {
  param([Parameter(Mandatory)] [string]$Value)
  return $Value.Replace("'", "''")
}

function Get-DeviceMembersRecursive {
  param(
    [Parameter(Mandatory)] [string]$GroupObjectId
  )

  # prevent loops
  if (-not $visitedGroups.Add($GroupObjectId)) {
    return
  }

  $members = Get-MgGroupMember -GroupId $GroupObjectId -All

  foreach ($m in $members) {
    $type = $m.AdditionalProperties.'@odata.type'
    switch ($type) {
      '#microsoft.graph.device' {
        [void]$deviceObjectIds.Add($m.Id)
      }
      '#microsoft.graph.group' {
        # recurse into nested group
        Get-DeviceMembersRecursive -GroupObjectId $m.Id
      }
      default {
        # ignore users, servicePrincipals, etc.
      }
    }
  }
}

# -----------------------------
# config / validation
# -----------------------------

$scopes = @(
  "Device.Read.All",
  "DeviceManagementManagedDevices.Read.All",
  "User.Read.All"
)

# allow calling with a bare GUID: .\Export-GroupDevices.ps1 <guid>
if (-not [string]::IsNullOrWhiteSpace($GroupId) -and $GroupId -match '^[0-9a-fA-F-]{36}$' -and [string]::IsNullOrWhiteSpace($GroupName)) {
  # ok
}
elseif ([string]::IsNullOrWhiteSpace($GroupId) -and [string]::IsNullOrWhiteSpace($GroupName)) {
  throw "Provide either -GroupId or -GroupName (or pass groupId as first arg)."
}

# -----------------------------
# main
# -----------------------------

# connect to graph
Connect-MgGraph -Scopes $scopes | Out-Null

# resolve group
if (-not [string]::IsNullOrWhiteSpace($GroupId)) {
  $rootGroup = Get-MgGroup -GroupId $GroupId -ErrorAction Stop
}
else {
  $escapedName = Escape-ODataString -Value $GroupName
  $rootGroup = Get-MgGroup -Filter "displayName eq '$escapedName'" -ConsistencyLevel eventual -All |
  Select-Object -First 1
  if (-not $rootGroup) { throw "No group found for displayName: $GroupName" }
}

Write-Info "Root Group:" $rootGroup.DisplayName "(" $rootGroup.Id ")"

# recursively collect device objectIds from nested groups
$visitedGroups = New-Object 'System.Collections.Generic.HashSet[string]'
$deviceObjectIds = New-Object 'System.Collections.Generic.HashSet[string]'

Get-DeviceMembersRecursive -GroupObjectId $rootGroup.Id

Write-Info ("Total unique device member(s) found (incl. nested): {0}" -f $deviceObjectIds.Count)
Write-Info ("Total groups visited (incl. nested): {0}" -f $visitedGroups.Count)

# for each device, match to Intune managedDevice and pull primary user
$results = New-Object System.Collections.Generic.List[object]

foreach ($deviceObjectId in $deviceObjectIds) {

  try {
    $aadDevice = Get-MgDevice -DeviceId $deviceObjectId -Property "id,displayName,deviceId" -ErrorAction Stop
  }
  catch {
    Write-Warning "Failed to read Entra device $deviceObjectId : $($_.Exception.Message)"
    continue
  }

  $managedDevice = $null
  if (-not [string]::IsNullOrWhiteSpace($aadDevice.DeviceId)) {
    $filter = "azureADDeviceId eq '$($aadDevice.DeviceId)'"
    try {
      $managedDevice = Get-MgDeviceManagementManagedDevice `
        -Filter $filter `
        -Property "id,deviceName,azureADDeviceId,userId,userDisplayName,userPrincipalName" `
        -All |
      Select-Object -First 1
    }
    catch {
      Write-Warning "Failed Intune lookup for Entra deviceId $($aadDevice.DeviceId): $($_.Exception.Message)"
    }
  }

  $primaryUserDisplayName = $null
  $primaryUserUPN = $null

  if ($managedDevice) {
    $primaryUserDisplayName = $managedDevice.UserDisplayName
    $primaryUserUPN = $managedDevice.UserPrincipalName

    # fallback of sorts - resolve via userId for authoritative values
    if (-not [string]::IsNullOrWhiteSpace($managedDevice.UserId)) {
      try {
        $u = Get-MgUser -UserId $managedDevice.UserId -Property "displayName,userPrincipalName" -ErrorAction Stop
        if ($u) {
          $primaryUserDisplayName = $u.DisplayName
          $primaryUserUPN = $u.UserPrincipalName
        }
      }
      catch {
        # keep Intune values
      }
    }
  }

  $deviceName = if ($managedDevice -and $managedDevice.DeviceName) { $managedDevice.DeviceName } else { $aadDevice.DisplayName }

  $results.Add([pscustomobject]@{
      RootGroup      = $rootGroup.DisplayName
      DeviceName     = $deviceName
      PrimaryUser    = $primaryUserDisplayName
      PrimaryUserUPN = $primaryUserUPN
      # extra info for troubleshooting:
      # EntraDeviceObjId = $aadDevice.Id
      # EntraDeviceIdGuid = $aadDevice.DeviceId
      # IntuneManagedDeviceId = if ($managedDevice) { $managedDevice.Id } else { $null }
    })
}

$results | Sort-Object DeviceName | Format-Table -AutoSize
$results | Sort-Object DeviceName | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutCsv
Write-Info "Saved CSV: $OutCsv"