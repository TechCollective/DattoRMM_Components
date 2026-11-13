<#
.SYNOPSIS
    Datto RMM Component - ScreenConnect - Find and Remove Rogue Clients [Win]
    Hunts for ScreenConnect clients that are not ours and for the persistence left
    by the November 2026 "RelayTrap" campaign; optionally removes them.

.DESCRIPTION
    Context: from 2026-11-11 an attacker with access to MSPs' cloud ScreenConnect
    panels used Run Command to push a second ScreenConnect client, pointing at the
    attacker's own instance, to every endpoint. It persists with a SYSTEM scheduled
    task (TrapWatch, every 10 seconds), a Run value (RelayTrapLiteAlert), a
    payload folder (ProgramData\RelayTrap) and sckit-* files in TEMP. Huntress
    published the indicators below; the Run value and payload file names were added
    by Blackpoint. Do NOT investigate a suspect machine with an interactive
    ScreenConnect session: the kit can ride that session back to the technician.

    usrMode = Detect (the default) is READ-ONLY apart from the optional UDF. It checks:
      - every installed ScreenConnect client (by service, by service executable,
        and by "ScreenConnect Client (...)" folders under Program Files): the
        published rogue thumbprints, the c=Exploited property, attacker relays,
        and any instance whose thumbprint is not in usrKnownThumbprints
      - ScreenConnect processes running from outside an installed client
      - TrapWatch scheduled task, and any task whose action mentions RelayTrap
      - RelayTrapLiteAlert / RelayTrap Run values (HKLM in both the 64-bit and
        32-bit registry views, and every loaded user hive)
      - ProgramData\RelayTrap and sckit-* in the Windows, SYSTEM-profile and every
        user profile's TEMP
      - the named payload files, and sqlite3.exe, in TEMP, ProgramData, Public,
        Downloads and the Startup folders (the kit drops sqlite3.exe to scrape
        browser sessions). A sqlite3.exe is only flagged if it is in TEMP or
        was created on this disk since November 2026; older copies are listed
      - live TCP connections to the attacker IPs, DNS cache entries for their domains
      - Microsoft Defender exclusions that look like evasion (report only)

    usrMode = Remove does everything Detect does, then removes: every
    ScreenConnect client whose thumbprint can be read and is not in
    usrKnownThumbprints (whoever it belongs to), any client or process carrying a
    published indicator, the TrapWatch task, the Run values, ProgramData\RelayTrap,
    the sckit-* items and the named payload files. It never removes a client whose
    thumbprint is in usrKnownThumbprints or a client on a relay in
    usrKnownRelayHosts. A support-session client has no thumbprint in its name, so
    it is judged by its relay alone: ours if it is on our relay, not ours if it is
    on another one, and left for review if its relay cannot be read. It never
    removes sqlite3.exe and never changes Defender.
    Before deleting anything it saves the tasks, client command lines and payload
    under ProgramData\TechCollective\SCHunt. Remove refuses to run without both
    usrKnownThumbprints and usrKnownRelayHosts: two things have to be wrong
    before it could touch our own client.

    It does not relaunch itself or change the execution policy. Where the 64-bit
    and 32-bit views of Windows differ (HKLM Run and Uninstall keys, Program
    Files) it reads both explicitly, so it gives the same answer in either
    PowerShell host. The UDF is written the way every other component writes it.

    Indicators are stored defanged ([.] for .) and refanged at run time.

    Exit codes (any non-zero code shows the job as failed in Datto, on purpose):
      0 = STATUS=CLEAN (nothing found) or STATUS=REMOVED (Remove mode; the re-check
          after removal found nothing left)
      1 = STATUS=REFUSED            (invalid input variable)
      2 = STATUS=REVIEW             (no published indicator, but something for a
                                     person to look at)
      3 = STATUS=IOC_HIT            (Detect mode: a published indicator was found)
      4 = STATUS=REMOVE_INCOMPLETE  (Remove mode: something is still there)
      5 = STATUS=ERROR              (the script failed, or PowerShell is older than 3)

.NOTES
    Category: Scripts | Script type: PowerShell | Runs as: SYSTEM
    Windows PowerShell 3.0 or later (written for and tested on 5.1). Safe to re-run.
    Source: https://github.com/TechCollective/DattoRMM_Components
#>

#region ----------------------------- Setup -----------------------------------

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$ScriptName = 'ScreenConnect - Find and Remove Rogue Clients [Win]'
$UdfKey     = 'HKLM:\SOFTWARE\CentraStage'
$OwnPattern = '^SCHunt: '

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

function Get-Prop {
    # Reads a property that may not exist, without tripping StrictMode.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Refang { param([string]$Text) return ($Text -replace '\[\.\]', '.') }

trap {
    Write-Line ("ERROR: {0}" -f $_.Exception.Message)
    Write-Line 'DETAIL=The script stopped unexpectedly. Nothing after the last line above ran.'
    Write-Line 'STATUS=ERROR'
    exit 5
}

Write-Line $ScriptName

if ($PSVersionTable.PSVersion.Major -lt 3) {
    Finish 'ERROR' ("PowerShell 3 or later is required; this machine has {0}. Check it by hand." -f $PSVersionTable.PSVersion) 5
}

#endregion

#region ----------------------------- Indicators ------------------------------
# Published 2026-11-11 (Huntress, with additions credited to Blackpoint). Update
# here, in this one place, as the advisories change.

$RogueThumbprints = @('2588ef5c15954b10', 'ed630cc2c873b091')
$IocIPs           = @('185[.]99[.]255[.]28', '155[.]94[.]150[.]39') | ForEach-Object { Refang $_ }
$IocDomains       = @('newnewnew[.]gotdns[.]org', 'soxnewwork[.]homedns[.]org', 'payproofkit[.]com',
                      'mo7sen[.]dev', 'cdn007-digitaldownloads[.]com') | ForEach-Object { Refang $_ }
$IocFileNames     = @('Panel-Lateral.ps1', 'runnew.cmd', 'ToolboxRelayUploader.exe', 'Run-Lateral-Full.bat')
$IocRunValues     = @('RelayTrapLiteAlert')
$IocTaskNames     = @('TrapWatch')
$IocFolderName    = 'RelayTrap'
$IocTempPrefix    = 'sckit-'
# sqlite3.exe ships with plenty of legitimate tools. Outside TEMP, only a copy that
# landed on this disk since this campaign began is worth a person's time; an
# older one is listed but not flagged.
$SqliteSince      = [datetime]'2026-11-01'
# The file search gives up after this many seconds, so one enormous folder
# cannot run the job into its timeout.
$FileSearchSeconds = 180

#endregion

#region ----------------------------- Inputs ----------------------------------

$Mode      = Get-Var 'usrMode' 'Detect'
$ThumbRaw  = Get-Var 'usrKnownThumbprints' ''
$RelayRaw  = Get-Var 'usrKnownRelayHosts' ''
$UdfRaw    = Get-Var 'usrUdfNumber' ''
$Overwrite = Get-Var 'usrOverwriteForeign' 'No'
$CheckDef  = Get-Var 'usrCheckDefenderExclusions' 'Yes'

if (@('Detect', 'Remove') -notcontains $Mode) {
    Finish 'REFUSED' 'usrMode must be Detect or Remove.' 1
}
if (@('Yes', 'No') -notcontains $Overwrite) {
    Finish 'REFUSED' 'usrOverwriteForeign must be Yes or No.' 1
}
if (@('Yes', 'No') -notcontains $CheckDef) {
    Finish 'REFUSED' 'usrCheckDefenderExclusions must be Yes or No.' 1
}

$KnownThumbs = @()
foreach ($t in ($ThumbRaw -split '[,;\s]+' | Where-Object { $_ })) {
    $t = $t.ToLower()
    if ($t -notmatch '^[0-9a-f]{16}$') {
        Finish 'REFUSED' ("usrKnownThumbprints: '{0}' is not a 16-character hex thumbprint." -f $t) 1
    }
    if ($RogueThumbprints -contains $t) {
        Finish 'REFUSED' ("usrKnownThumbprints: {0} is a published attacker thumbprint, not ours." -f $t) 1
    }
    $KnownThumbs += $t
}

$KnownRelays = @()
foreach ($r in ($RelayRaw -split '[,;\s]+' | Where-Object { $_ })) {
    $r = $r.ToLower()
    if ($r -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$') {
        Finish 'REFUSED' ("usrKnownRelayHosts: '{0}' is not a host name." -f $r) 1
    }
    $KnownRelays += $r
}

$UdfNumber = 0
if ($UdfRaw) {
    if ($UdfRaw -notmatch '^\d{1,3}$' -or [int]$UdfRaw -lt 1 -or [int]$UdfRaw -gt 300) {
        Finish 'REFUSED' 'usrUdfNumber must be blank (no UDF) or a number from 1 to 300.' 1
    }
    $UdfNumber = [int]$UdfRaw
}

if ($Mode -eq 'Remove' -and $KnownThumbs.Count -eq 0) {
    Finish 'REFUSED' 'Remove mode needs usrKnownThumbprints, so our own client is never removed.' 1
}
if ($Mode -eq 'Remove' -and $KnownRelays.Count -eq 0) {
    Finish 'REFUSED' 'Remove mode needs usrKnownRelayHosts as well (the relay= value a Detect run prints for our client), so a mistyped thumbprint cannot remove our own client.' 1
}

Write-Line ("Mode: {0} | Known thumbprints: {1} | Known relays: {2} | UDF: {3} | Host: {4}-bit PowerShell {5}" -f $Mode,
    $KnownThumbs.Count, $KnownRelays.Count, $(if ($UdfNumber) { "Custom$UdfNumber" } else { 'none' }),
    $(if ([Environment]::Is64BitProcess) { 64 } else { 32 }), $PSVersionTable.PSVersion)
if ($KnownThumbs.Count -eq 0) {
    Write-Line 'NOTE: No known thumbprints given, so every ScreenConnect client is flagged for review.'
}

#endregion

#region ----------------------------- Paths -----------------------------------

$ProgramData = [Environment]::GetFolderPath('CommonApplicationData')
if ([string]::IsNullOrWhiteSpace($ProgramData)) { $ProgramData = 'C:\ProgramData' }
$WinTemp = Join-Path $env:SystemRoot 'Temp'

$ProfilesDir = $null
try { $ProfilesDir = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name 'ProfilesDirectory').ProfilesDirectory } catch { $ProfilesDir = $null }
if ([string]::IsNullOrWhiteSpace($ProfilesDir)) { $ProfilesDir = Join-Path $env:SystemDrive 'Users' }
$Profiles = @(Get-ChildItem -LiteralPath $ProfilesDir -Directory -Force -ErrorAction SilentlyContinue)

# TEMP for SYSTEM is normally Windows\Temp; the SYSTEM profile's own TEMP folders
# are covered too. A 32-bit host on 64-bit Windows sees the 32-bit one as
# System32, so it reaches the 64-bit one through Sysnative instead.
$SysDirs = @('System32')
if ([Environment]::Is64BitOperatingSystem) {
    if ([Environment]::Is64BitProcess) { $SysDirs = @('System32', 'SysWOW64') } else { $SysDirs = @('Sysnative', 'SysWOW64') }
}
$TempRoots = @($WinTemp)
foreach ($sys in $SysDirs) {
    $TempRoots += Join-Path $env:SystemRoot ("{0}\config\systemprofile\AppData\Local\Temp" -f $sys)
}
$TempRoots += @($Profiles | ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' })

$StartupRoots = @(Join-Path $ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp')
$StartupRoots += @($Profiles | ForEach-Object { Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' })

$ProgramFilesRoots = @(@(${env:ProgramW6432}, ${env:ProgramFiles}, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique)
$RelayTrapPath = Join-Path $ProgramData $IocFolderName
$EvidenceRoot  = Join-Path $ProgramData 'TechCollective\SCHunt'

#endregion

#region ----------------------------- Registry views --------------------------
# HKLM\SOFTWARE has a 64-bit and a 32-bit view. The PowerShell registry provider
# only shows the view that matches the host, so these read both through .NET.

function Get-RegViews {
    if ([Environment]::Is64BitOperatingSystem) {
        return @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
    }
    return @([Microsoft.Win32.RegistryView]::Default)
}

function Get-RunValues {
    $out  = New-Object System.Collections.Generic.List[object]
    $subs = @('SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')
    $raw  = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    $viewsRead = 0
    $hivesRead = 0

    foreach ($view in @(Get-RegViews)) {
        $base = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            foreach ($sub in $subs) {
                $key = $base.OpenSubKey($sub)
                if (-not $key) { continue }
                foreach ($n in $key.GetValueNames()) {
                    $out.Add([pscustomobject]@{ Hive = 'HKLM'; View = $view; SubKey = $sub; Name = $n
                        Value = [string]$key.GetValue($n, '', $raw); Shown = ("HKLM ({0})\{1}" -f $view, $sub) })
                }
                $key.Close()
            }
            $viewsRead++
        } catch {
            Write-Line ("WARNING: HKLM Run keys ({0}) could not be read: {1}" -f $view, $_.Exception.Message)
        } finally {
            if ($base) { $base.Close() }
        }
    }

    $users = $null
    try {
        $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Default)
        foreach ($sid in $users.GetSubKeyNames()) {
            if ($sid -like '*_Classes') { continue }
            $hivesRead++
            foreach ($leaf in @('Run', 'RunOnce')) {
                $sub = "{0}\Software\Microsoft\Windows\CurrentVersion\{1}" -f $sid, $leaf
                $key = $null
                try { $key = $users.OpenSubKey($sub) } catch { $key = $null }
                if (-not $key) { continue }
                foreach ($n in $key.GetValueNames()) {
                    $out.Add([pscustomobject]@{ Hive = 'HKU'; View = [Microsoft.Win32.RegistryView]::Default; SubKey = $sub; Name = $n
                        Value = [string]$key.GetValue($n, '', $raw); Shown = ("HKU\{0}" -f $sub) })
                }
                $key.Close()
            }
        }
    } catch {
        Write-Line ("WARNING: User Run keys could not be read: {0}" -f $_.Exception.Message)
    } finally {
        if ($users) { $users.Close() }
    }
    Write-Line ("[ok] Run values checked: HKLM {0} view(s), {1} loaded user hive(s), {2} value(s)." -f $viewsRead, $hivesRead, $out.Count)
    return $out
}

function Remove-RunValue {
    param($Target)
    $hive = [Microsoft.Win32.RegistryHive]::Users
    if ($Target.Hive -eq 'HKLM') { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $Target.View)
    try {
        $key = $base.OpenSubKey($Target.SubKey, $true)
        if ($key) { $key.DeleteValue($Target.Name, $false); $key.Close() }
    } finally {
        $base.Close()
    }
}

function Get-UninstallCodes {
    # MSI product codes whose DisplayName is "ScreenConnect Client (<thumb>)", from both views.
    param([string]$Thumb)
    $codes = @()
    foreach ($view in @(Get-RegViews)) {
        $base = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($root) {
                foreach ($name in $root.GetSubKeyNames()) {
                    if ($name -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { continue }
                    $k = $root.OpenSubKey($name)
                    if (-not $k) { continue }
                    $dn = [string]$k.GetValue('DisplayName', '')
                    $k.Close()
                    if ($dn -like ("ScreenConnect Client ({0})*" -f $Thumb)) { $codes += $name }
                }
                $root.Close()
            }
        } catch {
            Write-Line ("  could not read Uninstall keys ({0}): {1}" -f $view, $_.Exception.Message)
        } finally {
            if ($base) { $base.Close() }
        }
    }
    return @($codes | Select-Object -Unique)
}

#endregion

#region ----------------------------- Detection -------------------------------

function Test-IocHost {
    param([string]$HostName)
    if (-not $HostName) { return $false }
    $h = $HostName.ToLower()
    if ($IocIPs -contains $h) { return $true }
    foreach ($d in $IocDomains) { if ($h -eq $d -or $h.EndsWith('.' + $d)) { return $true } }
    return $false
}

function Get-ActionText {
    param($Task)
    $parts = @()
    foreach ($a in @($Task.Actions)) {
        $exe     = Get-Prop $a 'Execute'
        $argText = Get-Prop $a 'Arguments'
        if ($exe) { $parts += ("{0} {1}" -f $exe, $argText).Trim() }
    }
    return ($parts -join ' | ')
}

function Get-FolderDate {
    param([string]$Folder)
    if (-not $Folder) { return 'unknown' }
    try { return (Get-Item -LiteralPath $Folder -Force -ErrorAction Stop).CreationTime.ToString('yyyy-MM-dd') } catch { return 'unknown' }
}

function Find-NamedFiles {
    # Looks for files with one of the given names under Root, MaxDepth folders down.
    # It walks folders only and tests for each name directly, skips junctions and
    # links, and stops when the clock passes the budget.
    param([string]$Root, [string[]]$Names, [int]$MaxDepth, $Clock, [int]$BudgetSeconds)
    $hits = New-Object System.Collections.Generic.List[object]
    $cutShort = $false
    $folders = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($Root, 0))
    while ($stack.Count -gt 0) {
        if ($Clock.Elapsed.TotalSeconds -gt $BudgetSeconds) { $cutShort = $true; break }
        $item = $stack.Pop()
        $dir = [string]$item[0]
        $depth = [int]$item[1]
        $folders++
        foreach ($n in $Names) {
            $candidate = [System.IO.Path]::Combine($dir, $n)
            try { if ([System.IO.File]::Exists($candidate)) { $hits.Add((New-Object System.IO.FileInfo $candidate)) } } catch { }
        }
        if ($depth -ge $MaxDepth) { continue }
        $subs = @()
        try { $subs = [System.IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($sd in $subs) {
            try {
                if ([System.IO.File]::GetAttributes($sd) -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            } catch { continue }
            $stack.Push(@($sd, ($depth + 1)))
        }
    }
    return [pscustomobject]@{ Hits = $hits.ToArray(); CutShort = $cutShort; Folders = $folders }
}

function Get-ScClients {
    $list = New-Object System.Collections.Generic.List[object]
    $svcs = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'ScreenConnect Client*' -or ([string]$_.PathName) -match 'ScreenConnect\.ClientService\.exe'
    })
    foreach ($s in $svcs) {
        $path  = [string]$s.PathName
        $thumb = ''
        if ($s.Name -match '\(([0-9a-fA-F]{16})\)') { $thumb = $Matches[1].ToLower() }
        elseif ($path -match 'ScreenConnect Client \(([0-9a-fA-F]{16})\)') { $thumb = $Matches[1].ToLower() }
        $relay = ''
        if ($path -match '[?&]h=([^&"\s]+)') { $relay = $Matches[1].ToLower() }
        $exe = ''
        if ($path -match '^\s*"([^"]+)"') { $exe = $Matches[1] } elseif ($path -match '^\s*(\S+)') { $exe = $Matches[1] }
        $folder = ''
        $cut = $exe.LastIndexOf('\')
        if ($cut -gt 0) { $folder = $exe.Substring(0, $cut) }
        # An uninstalled service stays listed, marked for deletion, until a restart.
        $pending = $false
        try {
            $df = Get-ItemProperty -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}" -f $s.Name) -Name 'DeleteFlag' -ErrorAction Stop
            $pending = ([int]$df.DeleteFlag -eq 1)
        } catch { $pending = $false }
        $list.Add([pscustomobject]@{
            Thumb = $thumb; Relay = $relay; Exploited = ($path -match '[?&]c=Exploited')
            Service = [string]$s.Name; State = [string]$s.State; Folder = $folder; PathName = $path; PendingDelete = $pending
        })
    }
    foreach ($root in $ProgramFilesRoots) {
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'ScreenConnect Client*' })) {
            $dir  = $d.FullName.TrimEnd('\')
            $seen = @($list | Where-Object { $_.Folder -and $_.Folder.TrimEnd('\') -ieq $dir })
            if ($seen.Count -gt 0) { continue }
            $thumb = ''
            if ($d.Name -match '\(([0-9a-fA-F]{16})\)') { $thumb = $Matches[1].ToLower() }
            $list.Add([pscustomobject]@{
                Thumb = $thumb; Relay = ''; Exploited = $false
                Service = ''; State = 'no service'; Folder = $dir; PathName = ''; PendingDelete = $false
            })
        }
    }
    return $list
}

function Invoke-Hunt {
    $found = New-Object System.Collections.Generic.List[object]
    function Add-F { param($Sev, $Kind, $Text, $Target = $null)
        $found.Add([pscustomobject]@{ Severity = $Sev; Kind = $Kind; Text = $Text; Target = $Target }) }

    $procs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)

    # 1. Installed ScreenConnect clients
    $clients = @(Get-ScClients)
    if ($clients.Count -eq 0) { Write-Line '[ok] No ScreenConnect clients on this machine.' }
    $oursPresent = $false
    foreach ($c in $clients) {
        $label = ("ScreenConnect client thumb={0} relay={1} service='{2}' state={3} installed={4}" -f
            $(if ($c.Thumb) { $c.Thumb } else { 'unreadable' }), $(if ($c.Relay) { $c.Relay } else { 'unknown' }),
            $c.Service, $c.State, (Get-FolderDate $c.Folder))
        $isKnown    = [bool]($c.Thumb -and ($KnownThumbs -contains $c.Thumb))
        $onOurRelay = [bool]($c.Relay -and ($KnownRelays -contains $c.Relay))
        $iocRelay   = Test-IocHost $c.Relay

        if ($isKnown) {
            # Ours. Reported if it looks tampered with, never removed.
            $oursPresent = $true
            if ($iocRelay)         { Add-F 'IOC'    'OwnClient' ("OUR thumbprint on an ATTACKER RELAY (not removed; investigate): {0}" -f $label) }
            elseif ($c.Exploited)  { Add-F 'REVIEW' 'OwnClient' ("c=Exploited property on OUR client; check who set it in the panel: {0}" -f $label) }
            elseif ($KnownRelays.Count -gt 0 -and $c.Relay -and -not $onOurRelay) {
                                     Add-F 'REVIEW' 'OwnClient' ("Our thumbprint, but a relay not in usrKnownRelayHosts: {0}" -f $label) }
            else                   { Write-Line ("[ok] Known: {0}" -f $label) }
            continue
        }
        if ($c.Thumb -and ($RogueThumbprints -contains $c.Thumb)) { Add-F 'IOC' 'Client' ("ROGUE CLIENT ID: {0}" -f $label) $c; continue }
        if ($c.Exploited)                                         { Add-F 'IOC' 'Client' ("c=Exploited PROPERTY: {0}" -f $label) $c; continue }
        if ($iocRelay)                                            { Add-F 'IOC' 'Client' ("ATTACKER RELAY: {0}" -f $label) $c; continue }
        if ($onOurRelay -and -not $c.Thumb) {
            # A support-session client: its service is named after the session, not the
            # instance, so there is no thumbprint to read. On our relay, it is ours.
            Write-Line ("[ok] Ours (support-session client left by our own instance): {0}" -f $label)
            continue
        }
        # Nothing left that can run: a folder with no service, or a service Windows has
        # already marked for deletion, and no process running from it. Remove tidies
        # it up; either way it is not a client anyone can connect through.
        $running = @($procs | Where-Object { $c.Folder -and $_.ExecutablePath -and
            ([string]$_.ExecutablePath).StartsWith($c.Folder.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($running.Count -eq 0 -and (-not $c.Service -or ($c.PendingDelete -and $c.State -ne 'Running'))) {
            $why = 'no service'
            if ($c.Service) { $why = 'service marked for deletion' }
            Add-F 'INFO' 'ClientFolder' ("Leftover of a removed ScreenConnect client ({0}, nothing running; goes at the next restart): {1} folder={2}" -f $why, $label, $c.Folder) $c
            continue
        }
        if ($onOurRelay) {
            # Our relay with a thumbprint we did not list: probably a typo in the input. Never removed.
            Add-F 'REVIEW' 'ClientKept' ("Our relay but a thumbprint not in usrKnownThumbprints (check the input; not removed): {0}" -f $label)
            continue
        }
        if (-not $c.Thumb) {
            if ($c.Relay -and $KnownRelays.Count -gt 0) {
                # No thumbprint, but it reports to a relay that is not ours: not our instance.
                Add-F 'REVIEW' 'Client' ("NOT OUR INSTANCE (support-session client on another relay): {0}" -f $label) $c
                continue
            }
            # Cannot tell whose it is, so it is never removed automatically.
            Add-F 'REVIEW' 'ClientKept' ("ScreenConnect client whose thumbprint cannot be read (not removed): {0} folder={1}" -f $label, $c.Folder)
            continue
        }
        Add-F 'REVIEW' 'Client' ("NOT OUR INSTANCE: {0}" -f $label) $c
    }
    if ($KnownThumbs.Count -gt 0 -and -not $oursPresent) {
        Write-Line '[i] Our own ScreenConnect client is not installed on this machine.'
    }

    # 1b. ScreenConnect processes running from outside an installed client
    $clientFolders = @($clients | Where-Object { $_.Folder } | ForEach-Object { $_.Folder.TrimEnd('\') + '\' })
    foreach ($p in @($procs | Where-Object { $_.Name -like 'ScreenConnect.*' -and $_.ExecutablePath })) {
        $exePath = [string]$p.ExecutablePath
        if (@($clientFolders | Where-Object { $exePath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
        $cmd   = [string]$p.CommandLine
        $relay = ''
        if ($cmd -match '[?&]h=([^&"\s]+)') { $relay = $Matches[1].ToLower() }
        $text = ("pid={0} path={1} relay={2}" -f $p.ProcessId, $exePath, $(if ($relay) { $relay } else { 'unknown' }))
        if ($cmd -match '[?&]c=Exploited' -or (Test-IocHost $relay)) {
            Add-F 'IOC' 'Process' ("ROGUE SCREENCONNECT PROCESS: {0}" -f $text) ([pscustomobject]@{ ProcessId = [int]$p.ProcessId; Path = $exePath })
        } elseif ($relay -and ($KnownRelays -contains $relay)) {
            Write-Line ("[ok] ScreenConnect session to our relay, not installed as a client: {0}" -f $text)
        } else {
            Add-F 'REVIEW' 'ProcessKept' ("ScreenConnect process outside an installed client (support session?): {0}" -f $text)
        }
    }

    # 2. Scheduled tasks
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
            $act     = Get-ActionText $t
            $nameHit = (@($IocTaskNames | Where-Object { $t.TaskName -like "*$_*" }).Count -gt 0)
            if ($nameHit -or $act -match $IocFolderName) {
                Add-F 'IOC' 'Task' ("SCHEDULED TASK: {0}{1} -> {2}" -f $t.TaskPath, $t.TaskName, $act) $t
            }
        }
    } catch { Write-Line ("WARNING: Scheduled tasks could not be read: {0}" -f $_.Exception.Message) }

    # 3. Run values: HKLM in both registry views, and every loaded user hive
    foreach ($rv in @(Get-RunValues)) {
        if ($IocRunValues -contains $rv.Name -or $rv.Value -match $IocFolderName) {
            Add-F 'IOC' 'RunValue' ("RUN VALUE: {0}\{1} = {2}" -f $rv.Shown, $rv.Name, $rv.Value) $rv
        }
    }

    # 4. Payload folder and sckit-* temp items
    if (Test-Path -LiteralPath $RelayTrapPath) { Add-F 'IOC' 'Folder' ("FOLDER: {0} exists" -f $RelayTrapPath) $RelayTrapPath }
    foreach ($tr in $TempRoots) {
        if (-not (Test-Path -LiteralPath $tr)) { continue }
        foreach ($i in @(Get-ChildItem -LiteralPath $tr -Filter ($IocTempPrefix + '*') -Force -ErrorAction SilentlyContinue)) {
            Add-F 'IOC' 'TempItem' ("TEMP ARTIFACT: {0}" -f $i.FullName) $i.FullName
        }
    }

    # 5. Named payload files, and sqlite3.exe where it should not be
    $roots = @($ProgramData, (Join-Path $ProfilesDir 'Public')) + $TempRoots + $StartupRoots +
             @($Profiles | ForEach-Object { Join-Path $_.FullName 'Downloads' })
    $names = @($IocFileNames) + @('sqlite3.exe')
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $seenFile = @{}
    $foldersSearched = 0
    $searchCut = $false
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $res = Find-NamedFiles -Root $root -Names $names -MaxDepth 4 -Clock $clock -BudgetSeconds $FileSearchSeconds
        $foldersSearched += $res.Folders
        foreach ($file in $res.Hits) {
            $key = $file.FullName.ToLower()
            if ($seenFile.ContainsKey($key)) { continue }
            $seenFile[$key] = $true
            if ($file.FullName.StartsWith($EvidenceRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($IocFileNames -contains $file.Name) {
                Add-F 'IOC' 'File' ("IOC FILE: {0} (modified {1:yyyy-MM-dd HH:mm})" -f $file.FullName, $file.LastWriteTime) $file.FullName
            } else {
                $full   = $file.FullName.Replace('/', '\')
                $inTemp = (@($TempRoots | Where-Object { $full.StartsWith($_.Replace('/', '\').TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
                $about  = ("{0} (created {1:yyyy-MM-dd}, modified {2:yyyy-MM-dd})" -f $file.FullName, $file.CreationTime, $file.LastWriteTime)
                if ($inTemp -or $file.CreationTime -ge $SqliteSince) {
                    Add-F 'REVIEW' 'Sqlite' ("sqlite3.exe in TEMP or new since {0:yyyy-MM-dd}: {1}" -f $SqliteSince, $about)
                } else {
                    Write-Line ("[ok] Older sqlite3.exe, not flagged: {0}" -f $about)
                }
            }
        }
        if ($res.CutShort) { $searchCut = $true; break }
    }
    if ($searchCut) {
        Write-Line ("WARNING: File search stopped at its {0}-second limit after {1} folders; the rest were not searched." -f $FileSearchSeconds, $foldersSearched)
    } else {
        Write-Line ("[ok] File search: {0} folders in {1:N0} seconds." -f $foldersSearched, $clock.Elapsed.TotalSeconds)
    }

    # 6. Live connections to attacker IPs
    try {
        foreach ($conn in @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $IocIPs -contains $_.RemoteAddress })) {
            $procPath = ("pid {0}" -f $conn.OwningProcess)
            $owner = @($procs | Where-Object { $_.ProcessId -eq $conn.OwningProcess })
            if ($owner.Count -gt 0 -and $owner[0].ExecutablePath) { $procPath = [string]$owner[0].ExecutablePath }
            Add-F 'IOC' 'Connection' ("CONNECTION: {0}:{1} state={2} process={3}" -f $conn.RemoteAddress, $conn.RemotePort, $conn.State, $procPath)
        }
    } catch { Write-Line ("WARNING: TCP connections could not be read: {0}" -f $_.Exception.Message) }

    # 7. DNS cache (history: an entry can outlive the thing that made it)
    try {
        $seenDns = @{}
        foreach ($e in @(Get-DnsClientCache -ErrorAction Stop | Where-Object { Test-IocHost $_.Entry })) {
            $id = ("{0}|{1}" -f $e.Entry, $e.Data)
            if ($seenDns.ContainsKey($id)) { continue }
            $seenDns[$id] = $true
            Add-F 'IOC' 'Dns' ("DNS CACHE: {0} -> {1}" -f $e.Entry, $e.Data)
        }
    } catch { Write-Line ("WARNING: DNS cache could not be read: {0}" -f $_.Exception.Message) }

    # 8. Defender exclusions that look like evasion (report only, never changed)
    if ($CheckDef -eq 'Yes') {
        try {
            $mp = Get-MpPreference -ErrorAction Stop
            foreach ($x in @(Get-Prop $mp 'ExclusionPath' | Where-Object { $_ })) {
                if ($x -match '^[A-Za-z]:\\?$' -or $x -match '(?i)screenconnect|relaytrap|\\temp\\?$|\\programdata\\?$|\\users\\?$|\\windows\\?$|\\downloads\\?$') {
                    Add-F 'REVIEW' 'Defender' ("DEFENDER PATH EXCLUSION: {0}" -f $x)
                }
            }
            foreach ($x in @(Get-Prop $mp 'ExclusionProcess' | Where-Object { $_ })) {
                if ($x -match '(?i)powershell|pwsh|cmd\.exe|wscript|cscript|mshta|rundll32|regsvr32|msiexec|screenconnect') {
                    Add-F 'REVIEW' 'Defender' ("DEFENDER PROCESS EXCLUSION: {0}" -f $x)
                }
            }
            foreach ($x in @(Get-Prop $mp 'ExclusionExtension' | Where-Object { $_ })) {
                if ($x -match '(?i)^\.?(exe|dll|ps1|bat|cmd|vbs|js|msi|hta|scr)$') {
                    Add-F 'REVIEW' 'Defender' ("DEFENDER EXTENSION EXCLUSION: {0}" -f $x)
                }
            }
        } catch { Write-Line ("NOTE: Defender exclusions not checked: {0}" -f $_.Exception.Message) }
    }

    return $found
}

function Write-Findings {
    param($Findings)
    foreach ($x in @($Findings)) {
        $mark = '?'
        if ($x.Severity -eq 'IOC')  { $mark = '!' }
        if ($x.Severity -eq 'INFO') { $mark = 'i' }
        Write-Line ("[{0}] {1}" -f $mark, $x.Text)
    }
}

#endregion

#region ----------------------------- Removal ---------------------------------

$RemovableKinds = @('Client', 'ClientFolder', 'Process', 'Task', 'RunValue', 'Folder', 'TempItem', 'File')

function Stop-ProcessList {
    param($List)
    foreach ($p in @($List)) {
        if ([int]$p.ProcessId -eq $PID) { continue }
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Line ("  stopped process {0} ({1})" -f $p.ProcessId, $p.Name) }
        catch { Write-Line ("  could not stop process {0}: {1}" -f $p.ProcessId, $_.Exception.Message) }
    }
}

function Stop-ProcessesUnder {
    param([string]$Folder)
    if (-not $Folder) { return }
    $prefix = $Folder.TrimEnd('\') + '\'
    Stop-ProcessList @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

function Stop-KitProcesses {
    # The task runs its payload through a script host, so the executable is not
    # under RelayTrap but the command line names it.
    $needles = @(('\' + $IocFolderName + '\'), ('\' + $IocTempPrefix))
    Stop-ProcessList @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $cl = [string]$_.CommandLine
        $cl -and (@($needles | Where-Object { $cl.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) })
}

function Reset-FolderAccess {
    # Some leftover client folders deny even SYSTEM. Take ownership for Administrators,
    # put the permissions back to inherited, and clear read-only/system/hidden.
    param([string]$Folder)
    $sys = Join-Path $env:SystemRoot 'System32'
    $ErrorActionPreference = 'Continue'   # local to this function: these tools write to stderr
    try { & (Join-Path $sys 'takeown.exe') /f $Folder /a /r /d Y 2>&1 | Out-Null } catch { }
    try { & (Join-Path $sys 'icacls.exe') $Folder /reset /t /c /q 2>&1 | Out-Null } catch { }
    try { & (Join-Path $sys 'icacls.exe') $Folder /grant '*S-1-5-18:(OI)(CI)F' /t /c /q 2>&1 | Out-Null } catch { }
    try { & (Join-Path $sys 'attrib.exe') -r -s -h (Join-Path $Folder '*') /s /d 2>&1 | Out-Null } catch { }
}

function Register-DeleteAtRestart {
    # Asks Windows to delete the folder's contents, then the folder, at the next
    # restart. Used when files are still held open (ScreenConnect's logon DLL is
    # loaded by Windows itself until then).
    param([string]$Folder)
    try {
        if (-not ('SCHunt.Native' -as [type])) {
            Add-Type -Namespace SCHunt -Name Native -MemberDefinition '[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);'
        }
        $items  = @(Get-ChildItem -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
        $items += @(Get-ChildItem -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($i in $items) { [void][SCHunt.Native]::MoveFileEx($i.FullName, [NullString]::Value, 4) }
        return [SCHunt.Native]::MoveFileEx($Folder, [NullString]::Value, 4)
    } catch {
        Write-Line ("  could not schedule deletion at restart: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Remove-ScClient {
    param($Client)
    Write-Line ("Removing ScreenConnect client thumb={0} service='{1}'" -f $Client.Thumb, $Client.Service)
    if ($Client.Service) {
        try { Set-Service -Name $Client.Service -StartupType Disabled -ErrorAction Stop } catch { }
        try { Stop-Service -Name $Client.Service -Force -ErrorAction Stop } catch { }
    }
    Stop-ProcessesUnder $Client.Folder

    if ($Client.Thumb -match '^[0-9a-f]{16}$') {
        foreach ($code in @(Get-UninstallCodes $Client.Thumb)) {
            try {
                $proc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/x', $code, '/qn', '/norestart') -PassThru -NoNewWindow
                $null = $proc.Handle   # keeps ExitCode readable after the process ends
                if ($proc.WaitForExit(120000)) {
                    Write-Line ("  msiexec /x {0} exited {1}" -f $code, $proc.ExitCode)
                } else {
                    try { $proc.Kill() } catch { }
                    Write-Line ("  msiexec /x {0} did not finish in 120 seconds and was stopped" -f $code)
                }
            } catch { Write-Line ("  msiexec /x {0} could not run: {1}" -f $code, $_.Exception.Message) }
        }
    }

    if ($Client.Service -and (Get-Service -Name $Client.Service -ErrorAction SilentlyContinue)) {
        try { Stop-Service -Name $Client.Service -Force -ErrorAction Stop } catch { }
        & (Join-Path $env:SystemRoot 'System32\sc.exe') delete $Client.Service | Out-Null
        Write-Line ("  sc delete '{0}' exited {1}" -f $Client.Service, $LASTEXITCODE)
    }
    Stop-ProcessesUnder $Client.Folder
    # Only ever delete a folder that is unmistakably a ScreenConnect client folder.
    if ($Client.Folder -and $Client.Folder -match '[\\/]ScreenConnect Client \([^)\\/]+\)[\\/]?$' -and (Test-Path -LiteralPath $Client.Folder)) {
        try { Remove-Item -LiteralPath $Client.Folder -Recurse -Force -ErrorAction Stop; Write-Line ("  deleted {0}" -f $Client.Folder) }
        catch {
            Write-Line ("  could not delete {0}: {1}" -f $Client.Folder, $_.Exception.Message)
            Write-Line '  resetting ownership and permissions on that folder, then trying again'
            Reset-FolderAccess $Client.Folder
            try { Remove-Item -LiteralPath $Client.Folder -Recurse -Force -ErrorAction Stop; Write-Line ("  deleted {0}" -f $Client.Folder) }
            catch {
                if (Register-DeleteAtRestart $Client.Folder) { Write-Line '  files are still held open; Windows will delete the folder at the next restart' }
                else { Write-Line ("  still could not delete {0}; it should clear after a restart" -f $Client.Folder) }
            }
        }
    } elseif ($Client.Folder -and (Test-Path -LiteralPath $Client.Folder)) {
        Write-Line ("  left in place (not a standard client folder name): {0}" -f $Client.Folder)
    }
}

function Save-Evidence {
    param($Findings)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    try {
        if (-not (Test-Path -LiteralPath $EvidenceRoot)) { New-Item -Path $EvidenceRoot -ItemType Directory -Force | Out-Null }
        $log   = Join-Path $EvidenceRoot ("findings-{0}.txt" -f $stamp)
        $lines = @("Host: $env:COMPUTERNAME", "Scan: $stamp", '') + @($Findings | ForEach-Object { "[{0}] {1}" -f $_.Severity, $_.Text })
        foreach ($t in @($Findings | Where-Object { $_.Kind -eq 'Task' })) {
            try {
                $xml = [string](Export-ScheduledTask -TaskName $t.Target.TaskName -TaskPath $t.Target.TaskPath -ErrorAction Stop)
                $lines += ''; $lines += ("--- Task XML: {0}{1}" -f $t.Target.TaskPath, $t.Target.TaskName); $lines += $xml
            } catch { }
        }
        foreach ($c in @($Findings | Where-Object { $_.Kind -eq 'Client' -and $_.Target -and $_.Target.PathName })) {
            $lines += ''; $lines += ("--- Service command line: {0}" -f $c.Target.Service); $lines += $c.Target.PathName
        }
        Set-Content -LiteralPath $log -Value $lines -Encoding UTF8
        Write-Line ("Evidence log: {0}" -f $log)

        $zip   = Join-Path $EvidenceRoot ("evidence-{0}.zip" -f $stamp)
        $items = @()
        $items += @($Findings | Where-Object { @('Folder', 'TempItem', 'File') -contains $_.Kind } | ForEach-Object { [string]$_.Target })
        $items += @($Findings | Where-Object { $_.Kind -eq 'Client' -and $_.Target -and $_.Target.Folder } | ForEach-Object { [string]$_.Target.Folder })
        foreach ($i in @($items | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)) {
            try {
                if (Test-Path -LiteralPath $zip) { Compress-Archive -LiteralPath $i -DestinationPath $zip -Update -ErrorAction Stop }
                else                             { Compress-Archive -LiteralPath $i -DestinationPath $zip -ErrorAction Stop }
            } catch { Write-Line ("  not archived {0}: {1}" -f $i, $_.Exception.Message) }
        }
        if (Test-Path -LiteralPath $zip) { Write-Line ("Evidence zip: {0} (antivirus may quarantine it)" -f $zip) }
    } catch {
        Write-Line ("WARNING: Evidence not fully saved: {0}" -f $_.Exception.Message)
    }
}

function Invoke-Removal {
    param($Findings)
    $removable = @($Findings | Where-Object { $_.Target -and ($RemovableKinds -contains $_.Kind) })
    if ($removable.Count -eq 0) { Write-Line 'Nothing to remove.'; return }

    # Disarm first: TrapWatch reinstalls the client every 10 seconds.
    foreach ($t in @($removable | Where-Object { $_.Kind -eq 'Task' })) {
        try { Disable-ScheduledTask -TaskName $t.Target.TaskName -TaskPath $t.Target.TaskPath -ErrorAction Stop | Out-Null } catch { }
        try { Stop-ScheduledTask    -TaskName $t.Target.TaskName -TaskPath $t.Target.TaskPath -ErrorAction Stop } catch { }
    }
    Stop-KitProcesses
    Stop-ProcessesUnder $RelayTrapPath
    foreach ($c in @($removable | Where-Object { $_.Kind -eq 'Client' })) {
        if ($c.Target.Service) {
            try { Set-Service  -Name $c.Target.Service -StartupType Disabled -ErrorAction Stop } catch { }
            try { Stop-Service -Name $c.Target.Service -Force -ErrorAction Stop } catch { }
        }
        Stop-ProcessesUnder $c.Target.Folder
    }
    foreach ($p in @($removable | Where-Object { $_.Kind -eq 'Process' })) {
        # Only if that process id is still the same executable.
        Stop-ProcessList @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessId -eq $p.Target.ProcessId -and ([string]$_.ExecutablePath) -ieq $p.Target.Path })
    }

    # Nothing worth keeping from a leftover folder, so evidence is only saved
    # when something real is being removed.
    if (@($removable | Where-Object { $_.Severity -ne 'INFO' }).Count -gt 0) { Save-Evidence $Findings }

    foreach ($t in @($removable | Where-Object { $_.Kind -eq 'Task' })) {
        try { Unregister-ScheduledTask -TaskName $t.Target.TaskName -TaskPath $t.Target.TaskPath -Confirm:$false -ErrorAction Stop
              Write-Line ("Deleted scheduled task {0}{1}" -f $t.Target.TaskPath, $t.Target.TaskName) }
        catch { Write-Line ("Could not delete task {0}: {1}" -f $t.Target.TaskName, $_.Exception.Message) }
    }
    foreach ($v in @($removable | Where-Object { $_.Kind -eq 'RunValue' })) {
        try { Remove-RunValue $v.Target
              Write-Line ("Deleted Run value {0}\{1}" -f $v.Target.Shown, $v.Target.Name) }
        catch { Write-Line ("Could not delete Run value {0}: {1}" -f $v.Target.Name, $_.Exception.Message) }
    }
    foreach ($c in @($removable | Where-Object { @('Client', 'ClientFolder') -contains $_.Kind })) { Remove-ScClient $c.Target }

    foreach ($p in @($removable | Where-Object { @('Folder', 'TempItem', 'File') -contains $_.Kind } | ForEach-Object { [string]$_.Target })) {
        # Guard: only the fixed RelayTrap folder, sckit-* items and the named payload files.
        $leaf = Split-Path -Path $p.TrimEnd('\') -Leaf
        $ok   = ($p -ieq $RelayTrapPath) -or ($leaf -like ($IocTempPrefix + '*')) -or ($IocFileNames -contains $leaf)
        if (-not $ok -or -not (Test-Path -LiteralPath $p)) { continue }
        try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop; Write-Line ("Deleted {0}" -f $p) }
        catch { Write-Line ("Could not delete {0}: {1}" -f $p, $_.Exception.Message) }
    }
}

#endregion

#region ----------------------------- Run -------------------------------------

$findings = @(Invoke-Hunt)
Write-Findings $findings

$priorEvidence = Test-Path -LiteralPath $EvidenceRoot
if ($priorEvidence) { Write-Line ("NOTE: An earlier Remove run saved evidence on this machine: {0}" -f $EvidenceRoot) }

$removed = $false
$removedClients = @()
if ($Mode -eq 'Remove' -and @($findings | Where-Object { $_.Target -and ($RemovableKinds -contains $_.Kind) }).Count -gt 0) {
    Write-Line '--- Removing ---'
    # Tidying a leftover folder is not a removal worth reporting on its own.
    $realWork = (@($findings | Where-Object { $_.Target -and $_.Severity -ne 'INFO' -and ($RemovableKinds -contains $_.Kind) }).Count -gt 0)
    # Remember which clients were there, so the UDF still names them afterwards.
    foreach ($x in @($findings | Where-Object { $_.Kind -eq 'Client' -and $_.Target })) {
        if ($x.Text -match 'thumb=(\S+) relay=(\S+)') { $removedClients += ("{0}@{1}" -f $Matches[1], $Matches[2]) }
    }
    Invoke-Removal $findings
    $removed = $realWork
    Start-Sleep -Seconds 15   # long enough for a TrapWatch-style task to fire if anything survived
    Write-Line '--- Re-check after removal ---'
    $findings = @(Invoke-Hunt)
    Write-Findings $findings
}

$hard     = @($findings | Where-Object { $_.Severity -eq 'IOC' })
$review   = @($findings | Where-Object { $_.Severity -eq 'REVIEW' })
# After a removal, a DNS cache entry is history, not something left behind.
$leftover = @($hard | Where-Object { $_.Kind -ne 'Dns' }) + @($review | Where-Object { $_.Target })
$dnsOnly  = @($hard | Where-Object { $_.Kind -eq 'Dns' })

if ($removed -and $leftover.Count -gt 0) {
    $status = 'REMOVE_INCOMPLETE'; $code = 4
    $detail = ("{0} item(s) are still present after removal. Investigate from EDR or Datto, not ScreenConnect." -f $leftover.Count)
    $back = @($leftover | Where-Object { $_.Kind -eq 'Client' -and $_.Text -match 'thumb=(\S+) relay=(\S+)' -and ($removedClients -contains ("{0}@{1}" -f $Matches[1], $Matches[2])) })
    if ($back.Count -gt 0) { $detail += ' A client that was uninstalled is running again, so something on this machine is putting it back (another management agent, a scheduled task or a policy).' }
} elseif ($removed -and $review.Count -gt 0) {
    $status = 'REVIEW'; $code = 2
    $detail = ("Removal finished; {0} item(s) it does not remove are left for a person to review." -f $review.Count)
} elseif ($removed) {
    $status = 'REMOVED'; $code = 0
    $detail = 'Everything found was removed and the re-check found nothing left. Evidence is under ProgramData\TechCollective\SCHunt.'
    if ($dnsOnly.Count -gt 0) { $detail += ' The DNS cache still holds attacker lookups from before the removal.' }
} elseif ($hard.Count -gt 0) {
    $status = 'IOC_HIT'; $code = 3
    $detail = ("{0} published indicator(s) found. Do not open a ScreenConnect session to this machine." -f $hard.Count)
} elseif ($review.Count -gt 0) {
    $status = 'REVIEW'; $code = 2
    $detail = ("{0} item(s) for a person to review; no published indicator found." -f $review.Count)
} else {
    $status = 'CLEAN'; $code = 0
    $detail = 'No indicators and no ScreenConnect client other than ours.'
}

# UDF: a short summary a filter can sort the fleet by.
if ($UdfNumber -gt 0) {
    $UdfName = "Custom$UdfNumber"
    $value = "SCHunt: {0} | IOC {1} | Review {2} | {3:yyyy-MM-dd HH:mm}" -f $status, $hard.Count, $review.Count, (Get-Date)
    if ($removed -or $priorEvidence) { $value += ' | Evidence saved' }
    # What was found, so an export of this UDF can group the fleet by cause:
    # each foreign client as thumbprint@relay, everything else by kind.
    $tags = @()
    foreach ($x in @($findings | Where-Object { $_.Severity -ne 'INFO' })) {
        if (@('Client', 'ClientKept') -contains $x.Kind -and $x.Text -match 'thumb=(\S+) relay=(\S+)') {
            $tags += ("SC {0}@{1}" -f $Matches[1], $Matches[2])
        } else {
            $tags += [string]$x.Kind
        }
    }
    foreach ($rc in @($removedClients | Select-Object -Unique)) {
        # Only claim "Removed" for a client the re-check no longer finds.
        if ($tags -notcontains ("SC {0}" -f $rc)) { $tags += ("Removed SC {0}" -f $rc) }
    }
    $tags = @($tags | Select-Object -Unique)
    if ($tags.Count -gt 0) { $value += ' | ' + ($tags -join '; ') }
    if ($value.Length -gt 255) { $value = $value.Substring(0, 252) + '...' }
    $existing = ''
    try { $existing = [string](Get-ItemProperty -LiteralPath $UdfKey -Name $UdfName -ErrorAction Stop).$UdfName } catch { $existing = '' }
    if ($existing -and $existing -notmatch $OwnPattern -and $Overwrite -ne 'Yes') {
        Write-Line ("UDF=NOT_WRITTEN {0} already holds a value this component did not write ({1} characters)." -f $UdfName, $existing.Length)
    } else {
        try {
            if (-not (Test-Path -LiteralPath $UdfKey)) { New-Item -Path $UdfKey -Force | Out-Null }
            New-ItemProperty -LiteralPath $UdfKey -Name $UdfName -Value $value -PropertyType String -Force | Out-Null
            Write-Line ("UDF=WRITTEN {0}: {1}" -f $UdfName, $value)
        } catch {
            Write-Line ("UDF=WRITE_FAILED {0}: {1}" -f $UdfName, $_.Exception.Message)
        }
    }
}

Finish $status $detail $code

#endregion
