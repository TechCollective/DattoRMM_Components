<#
.SYNOPSIS
    Datto RMM Component - Windows 11 - Apply Clean UI Defaults [Win]
    Applies the taskbar, Start, Explorer, privacy, visual-effect and power
    settings a technician would otherwise click through on every new Windows 11
    setup.

.DESCRIPTION
    Writes the same per-user registry values that the Settings toggles write, so
    every change is a user preference, not a policy: a user who wants something
    back can flip it in Settings. The one machine policy is Edge's first-run
    experience (HKLM), which has no preference equivalent.

    Per-user settings are applied to every local profile on the machine (by
    loading each profile's NTUSER.DAT and UsrClass.dat when it is not already
    loaded) and to the Default profile, so users created later inherit them.

    What it sets, per user:
      Taskbar   Search hidden, Task view off, Widgets off, Copilot button off,
                icons aligned left, Pen menu icon off.
      Start     Recommendations for tips/new apps off, account-related
                notifications off, "More pins" layout.
      Privacy   Start/Settings/lock-screen suggestions and tips off, silently
                installed promo apps off, Advertising ID off, the post-setup
                "Get even more out of Windows" screen off.
      Explorer  Classic (Windows 10) right-click menu; file extensions shown.
      Visuals   Animation effects off (menu/tooltip fades, window min/max,
                taskbar animations). Font smoothing, thumbnails and drop
                shadows are left alone.

    Machine-wide:
      Edge      First-run experience hidden (policy).
      Power     Active plan: sleep and hibernate on AC set to Never. Display
                timeout and every on-battery setting are left alone.

    Taskbar pins are not touched - unpinning is left to the technician.

    Input variables (all arrive as text):
      usrScope              All (default) = every existing profile plus Default.
                            DefaultOnly = only the Default profile.
      usrNeverSleepOnAC     true (default) = apply the power change.
      usrRestartExplorer    true (default) = restart Explorer so the context
                            menu and visual changes apply to logged-on users.
      usrAllowUnsupportedOs false (default). true = run on Windows 10 or a
                            server OS anyway. For testing only.

    Exit codes:
      0 = STATUS=APPLIED           every targeted profile written
      1 = STATUS=REFUSED           bad input, nothing changed
      2 = STATUS=PREFLIGHT_FAILED  not a Windows 11 workstation, nothing changed
      3 = STATUS=PARTIAL           one or more profiles could not be written; the
                                   rest were. Read the per-profile lines.

.NOTES
    Category: Scripts | Script type: PowerShell | Runs as: SYSTEM
    Requires Windows 11 and PowerShell 5.1. Idempotent: a second run changes 0.
    Source: https://github.com/TechCollective/DattoRMM_Components
#>

#region ----------------------------- Setup -----------------------------------

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function Get-Var {
    param([string]$Name, [string]$Default = '')
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Write-Line { param([string]$Text) Write-Host $Text }

function Finish {
    param([string]$Status, [string]$Detail, [int]$Code)
    Write-Line ("DETAIL={0}" -f $Detail)
    Write-Line ("STATUS={0}" -f $Status)
    exit $Code
}

function Get-Bool {
    # Datto passes booleans as the text true/false. Anything else is refused.
    param([string]$Name, [string]$Default)
    $v = (Get-Var -Name $Name -Default $Default).ToLowerInvariant()
    if ($v -eq 'true')  { return $true }
    if ($v -eq 'false') { return $false }
    Finish -Status 'REFUSED' -Detail ("{0} must be true or false, got '{1}'" -f $Name, $v) -Code 1
}

#endregion

#region ----------------------------- Input -----------------------------------

$Scope = Get-Var -Name 'usrScope' -Default 'All'
if ($Scope -notin @('All', 'DefaultOnly')) {
    Finish -Status 'REFUSED' -Detail ("usrScope must be All or DefaultOnly, got '{0}'" -f $Scope) -Code 1
}
$NeverSleepOnAC   = Get-Bool -Name 'usrNeverSleepOnAC'     -Default 'true'
$RestartExplorer  = Get-Bool -Name 'usrRestartExplorer'    -Default 'true'
$AllowUnsupported = Get-Bool -Name 'usrAllowUnsupportedOs' -Default 'false'

#endregion

#region ----------------------------- Preflight -------------------------------

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$build = [int]$os.BuildNumber
$isWorkstation = ([int]$os.ProductType -eq 1)
$osLine = ("{0} build {1} ({2})" -f $os.Caption.Trim(), $build, $(if ($isWorkstation) { 'workstation' } else { 'server' }))
Write-Line ("OS: {0}" -f $osLine)

if (-not $isWorkstation -or $build -lt 22000) {
    if (-not $AllowUnsupported) {
        Finish -Status 'PREFLIGHT_FAILED' -Detail ("Not a Windows 11 workstation: {0}. Set usrAllowUnsupportedOs=true to run anyway (testing only). Nothing was changed." -f $osLine) -Code 2
    }
    Write-Line "WARNING: unsupported OS; continuing because usrAllowUnsupportedOs=true. Windows 11-only values are written but ignored here."
}

#endregion

#region ----------------------------- Settings table --------------------------

# Every entry is a preference the Settings app itself writes. Paths are
# relative to the user hive (NTUSER.DAT). 'Classes' entries go to UsrClass.dat.
# Type: DWord | String | Binary.
$Adv = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$CDM = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

$UserSettings = @(
    # Taskbar
    @{ Hive='User'; Path="$Adv"; Name='ShowTaskViewButton';         Type='DWord'; Value=0 }
    @{ Hive='User'; Path="$Adv"; Name='TaskbarDa';                  Type='DWord'; Value=0 }   # Widgets
    @{ Hive='User'; Path="$Adv"; Name='TaskbarAl';                  Type='DWord'; Value=0 }   # Align left
    @{ Hive='User'; Path="$Adv"; Name='ShowCopilotButton';          Type='DWord'; Value=0 }
    @{ Hive='User'; Path='Software\Microsoft\Windows\CurrentVersion\Search'; Name='SearchboxTaskbarMode'; Type='DWord'; Value=0 }  # Hide
    @{ Hive='User'; Path='Software\Microsoft\Windows\CurrentVersion\PenWorkspace'; Name='PenWorkspaceButtonDesiredVisibility'; Type='DWord'; Value=0 }
    # Start
    @{ Hive='User'; Path="$Adv"; Name='Start_IrisRecommendations';  Type='DWord'; Value=0 }   # tips/new apps
    @{ Hive='User'; Path="$Adv"; Name='Start_AccountNotifications'; Type='DWord'; Value=0 }
    @{ Hive='User'; Path="$Adv"; Name='Start_Layout';               Type='DWord'; Value=1 }   # More pins
    # Privacy / suggestions
    @{ Hive='User'; Path="$CDM"; Name='SubscribedContent-338388Enabled'; Type='DWord'; Value=0 }  # Start suggestions
    @{ Hive='User'; Path="$CDM"; Name='SubscribedContent-338389Enabled'; Type='DWord'; Value=0 }  # tips & tricks
    @{ Hive='User'; Path="$CDM"; Name='SubscribedContent-310093Enabled'; Type='DWord'; Value=0 }  # welcome experience
    @{ Hive='User'; Path="$CDM"; Name='SubscribedContent-338387Enabled'; Type='DWord'; Value=0 }  # lock screen tips
    @{ Hive='User'; Path="$CDM"; Name='SubscribedContent-338393Enabled'; Type='DWord'; Value=0 }  # Settings suggestions
    @{ Hive='User'; Path="$CDM"; Name='SubscribedContent-353694Enabled'; Type='DWord'; Value=0 }  # Settings suggestions
    @{ Hive='User'; Path="$CDM"; Name='SubscribedContent-353696Enabled'; Type='DWord'; Value=0 }  # Settings suggestions
    @{ Hive='User'; Path="$CDM"; Name='SilentInstalledAppsEnabled';      Type='DWord'; Value=0 }
    @{ Hive='User'; Path="$CDM"; Name='SystemPaneSuggestionsEnabled';    Type='DWord'; Value=0 }
    @{ Hive='User'; Path="$CDM"; Name='SoftLandingEnabled';              Type='DWord'; Value=0 }
    @{ Hive='User'; Path="$CDM"; Name='RotatingLockScreenOverlayEnabled'; Type='DWord'; Value=0 }
    @{ Hive='User'; Path='Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled'; Type='DWord'; Value=0 }
    @{ Hive='User'; Path='Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name='ScoobeSystemSettingEnabled'; Type='DWord'; Value=0 }
    # Explorer
    @{ Hive='User'; Path="$Adv"; Name='HideFileExt'; Type='DWord'; Value=0 }
    @{ Hive='Classes'; Path='CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; Name='(Default)'; Type='String'; Value='' }  # classic context menu
    # Visual effects = the Accessibility > "Animation effects" switch, off.
    @{ Hive='User'; Path='Control Panel\Desktop'; Name='UserPreferencesMask'; Type='Binary'; Value=([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) }
    @{ Hive='User'; Path='Control Panel\Desktop\WindowMetrics'; Name='MinAnimate'; Type='String'; Value='0' }
    @{ Hive='User'; Path="$Adv"; Name='TaskbarAnimations'; Type='DWord'; Value=0 }
    @{ Hive='User'; Path='Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name='VisualFXSetting'; Type='DWord'; Value=3 }  # "Custom", so the dialog matches
)

#endregion

#region ----------------------------- Registry helpers ------------------------

function Set-RegValue {
    # Returns $true if the value was changed, $false if it was already correct.
    param([string]$KeyPath, [string]$Name, [string]$Type, $Value)
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        New-Item -Path $KeyPath -Force | Out-Null
    }
    $key = Get-Item -LiteralPath $KeyPath
    $propName = if ($Name -eq '(Default)') { '' } else { $Name }
    $current = $key.GetValue($propName, $null)
    $same = $false
    if ($null -ne $current) {
        switch ($Type) {
            'Binary' { $same = ($current -is [byte[]]) -and ([Convert]::ToBase64String($current) -eq [Convert]::ToBase64String($Value)) }
            default  { $same = ([string]$current -eq [string]$Value) }
        }
    }
    $key.Close()
    if ($same) { return $false }
    if ($Name -eq '(Default)') {
        Set-Item -LiteralPath $KeyPath -Value $Value | Out-Null
    } else {
        New-ItemProperty -LiteralPath $KeyPath -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
    }
    return $true
}

function Invoke-RegLoad {
    param([string]$MountName, [string]$HiveFile)
    if (-not (Test-Path -LiteralPath $HiveFile)) { throw ("hive file missing: {0}" -f $HiveFile) }
    $out = & reg.exe load "HKU\$MountName" $HiveFile 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("reg load {0} failed: {1}" -f $MountName, ($out -join ' ').Trim()) }
}

function Invoke-RegUnload {
    param([string]$MountName)
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    for ($i = 1; $i -le 5; $i++) {
        $out = & reg.exe unload "HKU\$MountName" 2>&1
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Milliseconds 500
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    }
    throw ("reg unload {0} failed: {1}" -f $MountName, ($out -join ' ').Trim())
}

function Set-HiveSettings {
    # $UserRoot / $ClassesRoot are Registry:: provider paths to the two hives.
    param([string]$UserRoot, [string]$ClassesRoot)
    $changed = 0; $kept = 0
    foreach ($s in $UserSettings) {
        $root = if ($s.Hive -eq 'Classes') { $ClassesRoot } else { $UserRoot }
        $key = '{0}\{1}' -f $root, $s.Path
        if (Set-RegValue -KeyPath $key -Name $s.Name -Type $s.Type -Value $s.Value) { $changed++ } else { $kept++ }
    }
    return @{ Changed = $changed; Kept = $kept }
}

#endregion

#region ----------------------------- Build the profile list ------------------

$ProfileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$plist = Get-ItemProperty -LiteralPath $ProfileListKey
$DefaultProfilePath = [Environment]::ExpandEnvironmentVariables($plist.Default)

$targets = @()
$targets += @{ Label = 'Default profile'; Sid = $null; Path = $DefaultProfilePath }

if ($Scope -eq 'All') {
    Get-ChildItem -LiteralPath $ProfileListKey | ForEach-Object {
        $sid = $_.PSChildName
        if ($sid -notlike 'S-1-5-21-*') { return }           # local/domain users only; skips SYSTEM, service and special SIDs
        $p = Get-ItemProperty -LiteralPath $_.PSPath
        $path = [Environment]::ExpandEnvironmentVariables([string]$p.ProfileImagePath)
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return }
        $targets += @{ Label = ("Profile {0}" -f (Split-Path $path -Leaf)); Sid = $sid; Path = $path }
    }
}

#endregion

#region ----------------------------- Apply per profile -----------------------

$failures = 0
$profilesDone = 0

foreach ($t in $targets) {
    $mountUser = $null; $mountClasses = $null
    try {
        if ($t.Sid -and (Test-Path -LiteralPath ("Registry::HKEY_USERS\{0}" -f $t.Sid))) {
            # Logged on: hives are already loaded by Windows. Write to them directly.
            $userRoot    = "Registry::HKEY_USERS\{0}" -f $t.Sid
            $classesRoot = "Registry::HKEY_USERS\{0}_Classes" -f $t.Sid
            $how = 'loaded'
        } else {
            $tag = if ($t.Sid) { $t.Sid } else { 'Default' }
            $mountUser    = "TCUI_{0}" -f $tag
            $mountClasses = "TCUI_{0}_Classes" -f $tag
            Invoke-RegLoad -MountName $mountUser    -HiveFile (Join-Path $t.Path 'NTUSER.DAT')
            Invoke-RegLoad -MountName $mountClasses -HiveFile (Join-Path $t.Path 'AppData\Local\Microsoft\Windows\UsrClass.dat')
            $userRoot    = "Registry::HKEY_USERS\{0}" -f $mountUser
            $classesRoot = "Registry::HKEY_USERS\{0}" -f $mountClasses
            $how = 'from disk'
        }
        $r = Set-HiveSettings -UserRoot $userRoot -ClassesRoot $classesRoot
        Write-Line ("{0}: changed {1}, already correct {2} ({3})" -f $t.Label, $r.Changed, $r.Kept, $how)
        $profilesDone++
    } catch {
        $failures++
        Write-Line ("ERROR: {0}: {1}" -f $t.Label, $_.Exception.Message)
    } finally {
        foreach ($m in @($mountClasses, $mountUser)) {
            if ($m) {
                try { Invoke-RegUnload -MountName $m } catch { $failures++; Write-Line ("ERROR: {0}" -f $_.Exception.Message) }
            }
        }
    }
}

#endregion

#region ----------------------------- Machine-wide ----------------------------

try {
    $edgeChanged = Set-RegValue -KeyPath 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'HideFirstRunExperience' -Type 'DWord' -Value 1
    Write-Line ("Edge first-run experience hidden (policy): {0}" -f $(if ($edgeChanged) { 'changed' } else { 'already set' }))
} catch {
    $failures++
    Write-Line ("ERROR: Edge policy: {0}" -f $_.Exception.Message)
}

if ($NeverSleepOnAC) {
    foreach ($setting in @('standby-timeout-ac', 'hibernate-timeout-ac')) {
        $out = & powercfg.exe /change $setting 0 2>&1
        if ($LASTEXITCODE -ne 0) {
            $failures++
            Write-Line ("ERROR: powercfg /change {0} 0: {1}" -f $setting, ($out -join ' ').Trim())
        }
    }
    Write-Line "Power: active plan sleep and hibernate on AC set to Never (display and battery settings untouched)."
} else {
    Write-Line "Power: skipped (usrNeverSleepOnAC=false)."
}

#endregion

#region ----------------------------- Explorer restart ------------------------

function Restart-ShellForLoggedOnUsers {
    # Killing explorer.exe from SYSTEM does not reliably bring the shell back, so
    # record who owns each shell, kill them, then relaunch explorer.exe inside any
    # session left without one via a one-shot interactive scheduled task running
    # as that user (no password needed; runs in the user's own session).
    $shells = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'")
    if ($shells.Count -eq 0) {
        Write-Line "Explorer restart: no interactive session; changes apply at next logon."
        return
    }
    $owners = @{}
    foreach ($sh in $shells) {
        $o = Invoke-CimMethod -InputObject $sh -MethodName GetOwner
        if ($o.ReturnValue -eq 0 -and $o.User) { $owners[[int]$sh.SessionId] = ('{0}\{1}' -f $o.Domain, $o.User) }
    }
    $shells | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 4
    $alive = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" | ForEach-Object { [int]$_.SessionId })
    $relaunched = 0
    foreach ($sess in $owners.Keys) {
        if ($alive -contains $sess) { continue }     # Windows brought it back on its own
        $taskName = 'TC-RestartExplorer-{0}' -f $sess
        try {
            $action    = New-ScheduledTaskAction -Execute 'explorer.exe'
            $principal = New-ScheduledTaskPrincipal -UserId $owners[$sess] -LogonType Interactive
            Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            Start-Sleep -Seconds 2
            $relaunched++
        } catch {
            Write-Line ("WARNING: could not relaunch Explorer for {0}: {1}. The user can sign out and back in." -f $owners[$sess], $_.Exception.Message)
        } finally {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    Write-Line ("Explorer restarted in {0} session(s) ({1} relaunched by task) so the context menu and visual changes take effect." -f $owners.Count, $relaunched)
}

if ($RestartExplorer) {
    try { Restart-ShellForLoggedOnUsers } catch { Write-Line ("WARNING: Explorer restart failed: {0}. Changes apply at next logon." -f $_.Exception.Message) }
} else {
    Write-Line "Explorer restart skipped (usrRestartExplorer=false); context menu and visual changes apply at next logon."
}

#endregion

$summary = ("{0} of {1} profile target(s) written, {2} setting(s) per profile" -f $profilesDone, $targets.Count, $UserSettings.Count)
if ($failures -gt 0) {
    Finish -Status 'PARTIAL' -Detail ("{0}; {1} error(s) above" -f $summary, $failures) -Code 3
}
Finish -Status 'APPLIED' -Detail $summary -Code 0
