<#
.Author
    AliAlame - CYBERSYSTEM
.SYNOPSIS
    Renames an AAD-joined Intune device to "<OrderID>-<SerialTail>" (≤15 chars)
    —with verbose console output for troubleshooting.

.NOTES
    • Requires Graph application permission Device.Read.All  (app registration)
    • Fill in $TenantId  $ClientId  $ClientSecret  below
    • Logs + console: C:\ProgramData\IntuneDeviceRenamer\logs\
#>
# authenticate to graph
# user.read.all
# group.read.all

# ========= 0.  SETTINGS =========
$TenantId     = 'XXXXXXXXXXXXXXXXXXXXXXX'
$ClientId     = 'XXXXXXXXXXXXXXXXXXXXXXX'
$ClientSecret = 'XXXXXXXXXXXXXXXXXXXXXXX'
$DebugMode    = $false          # true = no rename, no reboot, prints extra


# === 1. Logging ===
$LogDir = 'C:\ProgramData\IntuneDeviceRenamer\logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir ("Rename_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
function Log { param($m, $l='INFO'); ("{0:o} [{1}] {2}" -f (Get-Date), $l, $m) | Tee-Object -FilePath $LogFile -Append }

Log "=== Rename-From-GroupTag START ==="

# === 2. BIOS Serial (RAW) ===
$Serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()
if (-not $Serial) { Log 'ERR: BIOS serial empty.' 'ERROR'; exit 1 }
Log "Serial (raw) = $Serial"

# === 3. Graph Token ===
try {
    $Body = "client_id=$ClientId" +
            "&scope=https%3A%2F%2Fgraph.microsoft.com%2F.default" +
            "&client_secret=$([uri]::EscapeDataString($ClientSecret))" +
            "&grant_type=client_credentials"

    $AccessToken = (Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body $Body -ContentType 'application/x-www-form-urlencoded' `
        -Verbose:$DebugMode).access_token
    Log "Token OK (len=$($AccessToken.Length))"
} catch {
    Log "ERR: Token request failed. $_" 'ERROR'; exit 1
}

# === 4. Query Autopilot Devices (NO $filter) ===
$Uri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities"

try {
    $AllDevices = Invoke-RestMethod -Uri $Uri -Headers @{Authorization="Bearer $AccessToken"} -Method GET -Verbose:$DebugMode
    $Device = $AllDevices.value | Where-Object { $_.serialNumber -eq $Serial }
    if (-not $Device) { Log "ERR: No Autopilot record found for serial $Serial" 'ERROR'; exit 1 }

    $GroupTag = $Device.groupTag
    Log "Found GroupTag = $GroupTag"
} catch {
    Log "ERR: Graph query failed. $_" 'ERROR'; exit 1
}

if (-not $GroupTag) { Log "ERR: GroupTag is empty." 'ERROR'; exit 1 }

# === 5. Build New Name ===

# Clean serial for naming
$SerialClean = ($Serial -replace '[^0-9A-Za-z]', '')
Log "Serial (cleaned) = $SerialClean"

$MaxLen   = 15
$BaseLen  = $GroupTag.Length + 1  # +1 for hyphen
$AvailLen = $MaxLen - $BaseLen

if ($AvailLen -le 0) { Log "ERR: GroupTag too long for NetBIOS limit." 'ERROR'; exit 1 }

# Use cleaned serial for SerialTail
$SerialTail = if ($SerialClean.Length -le $AvailLen) { $SerialClean }
              else { $SerialClean.Substring($SerialClean.Length - $AvailLen, $AvailLen) }

$NewName = "$GroupTag-$SerialTail"
Log "Proposed new name = $NewName"

# === 6. Rename Computer ===
if ($env:COMPUTERNAME -ieq $NewName) {
    Log "Already correctly named. EXIT."
    exit 0
}

try {
    Rename-Computer -NewName $NewName -Force -ErrorAction Stop
    Log "Rename-Computer succeeded."
} catch {
    Log "ERR: Rename-Computer failed. $_" 'ERROR'; exit 1
}

# === 7. Handle Reboot ===
$Cs = Get-CimInstance Win32_ComputerSystem
if ($Cs.UserName -match 'defaultUser') {
    Log "In ESP/OOBE — Exiting 1641 for forced reboot"
    exit 1641
} else {
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show(
            "Device name was updated to:`n$NewName`n`nThe system will reboot automatically in 10 minutes, or you can reboot manually now.",
            "Device Renamed",
            "OK",
            "Info"
        ) | Out-Null

        shutdown.exe /g /t 600 /f /c "Restarting after device rename to $NewName."
    } catch {
        Log "Fallback: shutdown command triggered."
        shutdown.exe /g /t 600 /f /c "Restarting after device rename to $NewName."
    }
    exit 0
}