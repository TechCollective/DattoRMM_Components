<#
.SYNOPSIS
    Datto RMM Component - Windows - Factory Reset [Win]
    Starts "Reset this PC" on a Windows 10/11 device remotely, after preflight checks.

.DESCRIPTION
    Uses the Windows MDM bridge (root\cimv2\mdm\dmmap, class MDM_RemoteWipe) to
    trigger the same reset that Settings > Reset this PC runs. No Intune or MDM
    enrolment is needed; the bridge only works as SYSTEM, which is how Datto runs
    a component.

    Nothing destructive happens unless every one of these holds:
      * usrConfirm is exactly ERASE (default No).
      * usrConfirmSerial equals this device's BIOS serial number (as shown on the
        Datto and Autotask device records).
      * usrTicketNumber looks like an Autotask ticket number (T20261028.0001).
      * Every preflight check passed.

    Preflight (always runs, even with usrConfirm=No, so a No run is a dry run):
      * Workstation OS, not a server or domain controller.
      * Windows 10 or later, with the MDM bridge present (Pro/Enterprise/Education).
      * Windows RE enabled (reagentc /info). The reset needs it.
      * BitLocker: if the OS volume is protected, the recovery-key protector IDs
        are printed (never the key) and usrBitLockerKeySaved must be Yes.
      * Not running on battery, unless usrIgnoreBattery is true.

    Reset modes (usrResetMode):
      RemoveEverything  - doWipeMethod. Settings > Reset this PC > Remove everything.
                          Can be rolled back if interrupted. The default.
      KeepMyFiles       - doWipePersistUserDataMethod. Reset this PC > Keep my files.
      Protected         - doWipeProtectedMethod. Keeps retrying until done and cleans
                          the partitions on failure. Microsoft: for lost/stolen devices;
                          "may leave the device unable to boot".

    After the method is accepted the device reboots on its own within minutes.
    The Datto agent is erased with everything else, so the device goes offline
    and does not come back. The Datto job itself may report a timeout or lost
    connection because the reboot interrupts the result upload; the device
    dropping offline is the confirmation.

    Exit codes:
      0 = STATUS=RESET_STARTED (wipe accepted) or STATUS=PREFLIGHT_ONLY (usrConfirm=No, all checks passed)
      1 = STATUS=REFUSED  (bad or missing input, or serial number mismatch)
      2 = STATUS=PREFLIGHT_FAILED (a safety check failed; nothing was changed)
      3 = STATUS=FAILED   (the wipe method was called and Windows rejected it)

.NOTES
    Category: Scripts | Script type: PowerShell | Runs as: SYSTEM
    Requires Windows 10/11 Pro, Enterprise or Education and PowerShell 5.1.
    Device-level quick job only. Never schedule this against a filter or a site.
    Source: https://github.com/TechCollective/DattoRMM_Components
#>

#region ----------------------------- Setup -----------------------------------

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$ScriptName = 'Windows - Factory Reset [Win]'

# Datto RMM component variables arrive as environment variables (always strings).
function Get-Var {
    param([string]$Name, [string]$Default = '')
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Write-Line { param([string]$Text) Write-Host $Text }

$script:ExitCode = 0
function Finish {
    param([string]$Status, [string]$Detail, [int]$Code)
    Write-Line ("DETAIL={0}" -f $Detail)
    Write-Line ("STATUS={0}" -f $Status)
    $script:ExitCode = $Code
    exit $Code
}

# Wipe methods on MDM_RemoteWipe, keyed by the usrResetMode selection value.
$WipeMethods = @{
    'RemoveEverything' = 'doWipeMethod'
    'KeepMyFiles'      = 'doWipePersistUserDataMethod'
    'Protected'        = 'doWipeProtectedMethod'
}

# 64-bit Windows tools, reachable from a 32-bit PowerShell host via Sysnative.
$Sys32 = Join-Path $env:windir 'System32'
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $Sys32 = Join-Path $env:windir 'Sysnative'
}

#endregion

#region ----------------------------- Inputs ----------------------------------

$Confirm      = Get-Var 'usrConfirm'          'No'
$ConfirmSerial = Get-Var 'usrConfirmSerial'    ''
$Ticket       = Get-Var 'usrTicketNumber'     ''
$Mode         = Get-Var 'usrResetMode'        'RemoveEverything'
$KeySaved     = Get-Var 'usrBitLockerKeySaved' 'No'
$IgnoreBatt   = Get-Var 'usrIgnoreBattery'    'false'

$ThisHost   = $env:COMPUTERNAME
$ThisSerial = ''
try { $ThisSerial = [string](Get-CimInstance -ClassName Win32_BIOS).SerialNumber } catch { $ThisSerial = '' }
$ThisSerial = $ThisSerial.Trim()

Write-Line ("{0}" -f $ScriptName)
Write-Line ("Device: {0}" -f $ThisHost)
Write-Line ("Serial: {0}" -f $(if ($ThisSerial) { $ThisSerial } else { '(none reported)' }))
Write-Line ("Ticket: {0}" -f $Ticket)
Write-Line ("Mode:   {0}" -f $Mode)

# Input validation. Anything malformed is refused before any check runs.
if ($Confirm -notin @('No', 'ERASE')) {
    Finish 'REFUSED' ("usrConfirm must be No or ERASE, got '{0}'." -f $Confirm) 1
}
if (-not $WipeMethods.ContainsKey($Mode)) {
    Finish 'REFUSED' ("usrResetMode must be one of {0}, got '{1}'." -f ($WipeMethods.Keys -join ', '), $Mode) 1
}
if ($Ticket -notmatch '^T\d{8}\.\d{4}$') {
    Finish 'REFUSED' ("usrTicketNumber must be an Autotask ticket number like T20261028.0001, got '{0}'." -f $Ticket) 1
}
if ([string]::IsNullOrWhiteSpace($ConfirmSerial)) {
    Finish 'REFUSED' 'usrConfirmSerial is required: type the serial number of the device to erase, as shown on its Datto or Autotask record.' 1
}
if ($KeySaved -notin @('No', 'Yes')) {
    Finish 'REFUSED' ("usrBitLockerKeySaved must be Yes or No, got '{0}'." -f $KeySaved) 1
}
if ($IgnoreBatt -notin @('true', 'false')) {
    Finish 'REFUSED' ("usrIgnoreBattery must be true or false, got '{0}'." -f $IgnoreBatt) 1
}

#endregion

#region ----------------------------- Preflight -------------------------------

$Failures = New-Object System.Collections.Generic.List[string]
function Fail-Check { param([string]$Why) $Failures.Add($Why); Write-Line ("  FAIL  {0}" -f $Why) }
function Pass-Check { param([string]$What) Write-Line ("  ok    {0}" -f $What) }

Write-Line 'Preflight:'

# --- 1. Operating system: workstation only, Windows 10 or later -----------------
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    switch ([int]$os.ProductType) {
        1 { Pass-Check ("Workstation OS: {0} (build {1})" -f $os.Caption, $build) }
        2 { Fail-Check ("This is a domain controller ({0}). Refusing." -f $os.Caption) }
        3 { Fail-Check ("This is a server operating system ({0}). Refusing." -f $os.Caption) }
        default { Fail-Check ("Unknown ProductType {0}. Refusing." -f $os.ProductType) }
    }
    if ($build -lt 10240) { Fail-Check ("Windows build {0} is older than Windows 10; the MDM reset bridge does not exist." -f $build) }
} catch {
    Fail-Check ("Could not read the operating system details: {0}" -f $_.Exception.Message)
}

# --- 2. Role: not a domain controller by role either ---------------------------
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    if ([int]$cs.DomainRole -ge 4) { Fail-Check ("DomainRole {0} is a domain controller. Refusing." -f $cs.DomainRole) }
    $loggedOn = $cs.UserName
    if ([string]::IsNullOrWhiteSpace($loggedOn)) { Write-Line '  info  No interactive user is logged on.' }
    else { Write-Line ("  info  Logged-on user: {0}. They lose their session when the reset starts." -f $loggedOn) }
} catch {
    Fail-Check ("Could not read the computer system details: {0}" -f $_.Exception.Message)
}

# --- 3. The MDM bridge instance exists (Pro/Enterprise/Education, SYSTEM) -------
$WipeNamespace = 'root\cimv2\mdm\dmmap'
$WipeInstance  = $null
try {
    $WipeInstance = Get-CimInstance -Namespace $WipeNamespace -ClassName 'MDM_RemoteWipe' `
        -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'"
    if ($null -eq $WipeInstance) { Fail-Check 'MDM_RemoteWipe instance not found. Windows Home edition, or not running as SYSTEM.' }
    else { Pass-Check 'MDM RemoteWipe bridge is present.' }
} catch {
    Fail-Check ("MDM RemoteWipe bridge unavailable ({0}). Windows Home edition, or not running as SYSTEM." -f $_.Exception.Message)
}

# --- 4. Windows RE is enabled; the reset runs from it ----------------------------
try {
    $reagentc = Join-Path $Sys32 'ReAgentc.exe'
    if (-not (Test-Path -LiteralPath $reagentc)) { throw "$reagentc not found" }
    $info = & $reagentc /info 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw ("reagentc /info exit code {0}: {1}" -f $LASTEXITCODE, $info.Trim()) }
    if ($info -match 'Windows RE status:\s*(\S+)') {
        $reStatus = $Matches[1]
        if ($reStatus -ieq 'Enabled') { Pass-Check 'Windows RE is enabled.' }
        else { Fail-Check ("Windows RE status is '{0}'. The reset cannot run without it. Fix with 'reagentc /enable' on the device and check again." -f $reStatus) }
    } else {
        # Fail closed: non-English Windows prints a different label and we will not guess.
        Fail-Check 'Could not read the Windows RE status from reagentc /info (non-English Windows?). Check it by hand before resetting.'
    }
} catch {
    Fail-Check ("Could not check Windows RE: {0}" -f $_.Exception.Message)
}

# --- 5. BitLocker: protected OS volume needs the key confirmed as saved ---------
try {
    $sysDrive = $env:SystemDrive
    # No -ErrorAction SilentlyContinue here: an access error must fail the check, not
    # read as "no BitLocker". A null result from a query that succeeded is the only
    # thing that means the volume is not encryptable.
    $vol = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName 'Win32_EncryptableVolume' `
        -Filter ("DriveLetter='{0}'" -f $sysDrive)
    if ($null -eq $vol) {
        Pass-Check ("BitLocker is not available on {0} (no encryptable volume)." -f $sysDrive)
    } else {
        $prot = (Invoke-CimMethod -InputObject $vol -MethodName 'GetProtectionStatus').ProtectionStatus
        if ([int]$prot -eq 1) {
            # Type 3 = numerical password = the recovery key. Print its ID only, never the key.
            $kp = Invoke-CimMethod -InputObject $vol -MethodName 'GetKeyProtectors' -Arguments @{ KeyProtectorType = [uint32]3 }
            $ids = @($kp.VolumeKeyProtectorID)
            Write-Line ("  info  BitLocker is ON for {0}. Recovery key protector ID(s): {1}" -f $sysDrive, ($(if ($ids.Count) { $ids -join ', ' } else { 'none' })))
            if ($KeySaved -eq 'Yes') { Pass-Check 'BitLocker recovery key confirmed saved (usrBitLockerKeySaved=Yes).' }
            else { Fail-Check 'BitLocker is on and usrBitLockerKeySaved is No. Confirm the recovery key matching the ID above is escrowed, then rerun with Yes.' }
        } else {
            Pass-Check ("BitLocker protection is off for {0}." -f $sysDrive)
        }
    }
} catch {
    Fail-Check ("Could not check BitLocker: {0}" -f $_.Exception.Message)
}

# --- 6. Power: a laptop on battery can fail or stall the reset -------------------
try {
    $batt = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    if ($batt.Count -eq 0) {
        Pass-Check 'No battery (desktop, or mains only).'
    } else {
        $discharging = @($batt | Where-Object { [int]$_.BatteryStatus -eq 1 })
        $charge = ($batt | ForEach-Object { $_.EstimatedChargeRemaining }) -join '/'
        if ($discharging.Count -gt 0) {
            if ($IgnoreBatt -eq 'true') { Write-Line ("  warn  On battery ({0}% left) but usrIgnoreBattery=true." -f $charge) }
            else { Fail-Check ("Device is running on battery ({0}% left). Plug it in, or set usrIgnoreBattery=true." -f $charge) }
        } else {
            Pass-Check ("On mains power (battery {0}%)." -f $charge)
        }
    }
} catch {
    Fail-Check ("Could not check the power state: {0}" -f $_.Exception.Message)
}

if ($Failures.Count -gt 0) {
    Finish 'PREFLIGHT_FAILED' ("{0} check(s) failed; nothing was changed. First: {1}" -f $Failures.Count, $Failures[0]) 2
}
Write-Line 'Preflight passed.'

#endregion

#region ----------------------------- Confirmation gate -----------------------

if ($Confirm -ne 'ERASE') {
    Finish 'PREFLIGHT_ONLY' ("usrConfirm is No. Preflight passed on {0} (serial {1}); rerun with usrConfirm=ERASE and usrConfirmSerial={1} to reset it." -f $ThisHost, $ThisSerial) 0
}
# Serials that are blank or an OEM placeholder cannot identify a device, so they never match.
$Placeholders = @('', 'To Be Filled By O.E.M.', 'Default string', 'System Serial Number', 'None', '0', '00000000')
if ($Placeholders -contains $ThisSerial) {
    Finish 'REFUSED' ("This device reports no usable BIOS serial number ('{0}'), so it cannot be confirmed by serial. Nothing was changed." -f $ThisSerial) 1
}
if ($ConfirmSerial -ine $ThisSerial) {
    Finish 'REFUSED' ("usrConfirmSerial '{0}' does not match this device's serial '{1}'. Nothing was changed." -f $ConfirmSerial, $ThisSerial) 1
}

#endregion

#region ----------------------------- Reset -----------------------------------

$method = $WipeMethods[$Mode]
Write-Line ("Starting reset: {0} via MDM_RemoteWipe.{1} for ticket {2}" -f $Mode, $method, $Ticket)

try {
    $session = New-CimSession
    $params  = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
    $params.Add([Microsoft.Management.Infrastructure.CimMethodParameter]::Create('param', '', 'String', 'In'))
    $result  = $session.InvokeMethod($WipeNamespace, $WipeInstance, $method, $params)
    $rv = $null
    if ($null -ne $result -and $null -ne $result.ReturnValue) { $rv = $result.ReturnValue.Value }
    if ($null -ne $rv -and [int]$rv -ne 0) {
        Finish 'FAILED' ("Windows rejected {0} with return value {1}. Nothing was changed." -f $method, $rv) 3
    }
} catch {
    Finish 'FAILED' ("{0} threw: {1}" -f $method, $_.Exception.Message) 3
}

Write-Line ("TICKET={0} HOST={1} SERIAL={2} MODE={3} METHOD={4}" -f $Ticket, $ThisHost, $ThisSerial, $Mode, $method)
Write-Line 'The device will reboot into recovery within a few minutes and drop out of Datto RMM. That is expected.'
Finish 'RESET_STARTED' ("Reset accepted on {0}, serial {1} ({2}). Record this in ticket {3}." -f $ThisHost, $ThisSerial, $Mode, $Ticket) 0

#endregion
