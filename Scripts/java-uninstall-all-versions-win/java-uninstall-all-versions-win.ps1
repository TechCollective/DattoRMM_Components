<#
.SYNOPSIS
    Datto RMM Component - Java - Uninstall All Versions [Win]
    Uninstalls every standalone Java runtime and JDK, from any vendor, and cleans
    up what the uninstallers leave behind.

.DESCRIPTION
    "Standalone" means Java installed as a product of its own: an entry in
    Programs and Features, or a JDK/JRE folder in a vendor's own folder under
    Program Files. Covered: Oracle (Java 5 to current, JRE and JDK, and the Java
    Auto Updater), Eclipse Temurin / Adoptium / AdoptOpenJDK, Amazon Corretto,
    Azul Zulu, Microsoft Build of OpenJDK, BellSoft Liberica, IBM Semeru,
    SapMachine, Red Hat OpenJDK and ojdkbuild.

    It never touches a Java runtime bundled inside another application's folder
    (C:\Program Files\SomeApp\jre), a JDK unpacked somewhere else (C:\jdk, a
    developer's tool cache) or anything in a user profile. Those belong to the
    application or person that put them there.

    usrMode = Remove (the default):
      1. Stops processes running from the Java folders it is about to remove,
         and the Oracle updater (jusched, jucheck). Names and PIDs are printed.
      2. Uninstalls each registered Java with its own uninstaller: msiexec /x
         for MSI products, the vendor's registered quiet uninstall string
         otherwise. A product with neither is reported, never guessed at.
         It never reboots; a pending reboot is reported.
      3. Deletes leftover JDK/JRE folders under the vendor folders listed above,
         unless they belong to a version still registered (kept or failed).
      4. Only if no Java at all is still registered: deletes HKLM\SOFTWARE\JavaSoft,
         the Oracle javapath and Java Update folders, the SunJavaUpdateSched Run
         value, PATH entries and JAVA_HOME that pointed at what it deleted.
      5. Scans again; that re-check decides the result.

    usrMode = Report is READ-ONLY apart from the optional UDF: it lists what
    Remove would uninstall, keep and delete, and changes nothing.

    usrKeep: comma-separated text matched (case-insensitive, anywhere) against
    each product's name and folder name. A match is left installed. Use it for a
    version a line-of-business application needs.

    Exit codes (any non-zero code shows the job as failed in Datto, on purpose):
      0 = STATUS=CLEAN (no removable Java), STATUS=FOUND (Report mode: Java
          found) or STATUS=REMOVED (the re-check found nothing left to remove)
      1 = STATUS=REFUSED            (invalid input variable)
      3 = STATUS=REMOVE_INCOMPLETE  (something removable is still there)
      5 = STATUS=ERROR              (the script failed, or PowerShell older than 3)

.NOTES
    Category: Scripts | Script type: PowerShell | Runs as: SYSTEM
    Windows PowerShell 3.0 or later. Safe to re-run. Makes no network calls.
    Uninstall logs for failed uninstalls: %ProgramData%\TechCollective\JavaRemoval
    Source: https://github.com/TechCollective/DattoRMM_Components
#>

#region ----------------------------- Setup -----------------------------------

$ErrorActionPreference = 'Stop'

$ScriptName          = 'Java - Uninstall All Versions [Win]'
$UdfKey              = 'HKLM:\SOFTWARE\CentraStage'
$OwnUdfPattern       = '^Java: '
$UninstallTimeoutSec = 600

function Write-Line { param([string]$Text) Write-Host $Text }

function Finish {
    param([string]$Status, [string]$Detail, [int]$Code)
    Write-Line ("DETAIL={0}" -f $Detail)
    Write-Line ("STATUS={0}" -f $Status)
    exit $Code
}

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

Set-StrictMode -Version 2

function Get-Var {
    param([string]$Name, [string]$Default = '')
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

#endregion

#region ----------------------------- Inputs ----------------------------------

$Mode = Get-Var 'usrMode' 'Remove'
if ($Mode -eq 'Remove') { $Mode = 'Remove' }
elseif ($Mode -eq 'Report') { $Mode = 'Report' }
else { Finish 'REFUSED' 'usrMode must be Remove or Report.' 1 }

$KeepTerms = @((Get-Var 'usrKeep' '') -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($t in $KeepTerms) {
    if ($t.Length -lt 3) {
        Finish 'REFUSED' ("usrKeep term '{0}' is shorter than 3 characters; that would match almost anything. Use more of the product name." -f $t) 1
    }
}

$UdfRaw    = Get-Var 'usrUdfNumber' ''
$UdfNumber = 0
if ($UdfRaw) {
    if ($UdfRaw -notmatch '^\d{1,3}$' -or [int]$UdfRaw -lt 1 -or [int]$UdfRaw -gt 300) {
        Finish 'REFUSED' 'usrUdfNumber must be blank (no UDF) or a number from 1 to 300.' 1
    }
    $UdfNumber = [int]$UdfRaw
}

Write-Line ("Mode: {0} | Keep terms: {1} | UDF: {2} | Host: {3}-bit PowerShell {4}" -f $Mode,
    $(if ($KeepTerms.Count) { $KeepTerms -join ', ' } else { 'none' }),
    $(if ($UdfNumber) { "Custom$UdfNumber" } else { 'none' }),
    $(if ([IntPtr]::Size -eq 8) { 64 } else { 32 }), $PSVersionTable.PSVersion)

#endregion

#region ----------------------------- What counts as Java ---------------------

# Programs and Features display names. Anchored, so "JavaScript Tools" or an IDE
# with Java in its description never matches.
$JavaNamePatterns = @(
    '^Java(\(TM\))?( SE)? (Runtime Environment|Development Kit)\b',
    '^Java(\(TM\))? \d+(\s|$)',
    '^Java\(TM\) SE\b',
    '^Java Auto Updater$',
    '^J2SE (Runtime Environment|Development Kit)\b',
    '^(Eclipse Temurin|Eclipse Adoptium|AdoptOpenJDK) (JDK|JRE)\b',
    '^Amazon Corretto\b',
    '^(Azul )?Zulu( JDK| JRE| \d)',
    '^Microsoft Build of OpenJDK\b',
    '^Liberica (JDK|JRE)\b',
    '^IBM Semeru Runtime\b',
    '^SapMachine (JDK|JRE)\b',
    '^(Red Hat (build of )?)?OpenJDK\b'
)

# Vendor folders under each Program Files folder, and which children of each
# are a JDK or JRE. Nothing outside these is ever deleted.
$VendorRoots = @(
    @{ Root = 'Java';               Child = '.' },
    @{ Root = 'Eclipse Adoptium';   Child = '^(jdk|jre)' },
    @{ Root = 'Eclipse Foundation'; Child = '^(jdk|jre)' },
    @{ Root = 'AdoptOpenJDK';       Child = '^(jdk|jre)' },
    @{ Root = 'Amazon Corretto';    Child = '^(jdk|jre)' },
    @{ Root = 'Zulu';               Child = '.' },
    @{ Root = 'BellSoft';           Child = '^Liberica' },
    @{ Root = 'Semeru';             Child = '^(jdk|jre)' },
    @{ Root = 'SapMachine';         Child = '^(jdk|jre)' },
    @{ Root = 'RedHat';             Child = '^(java-|jdk|jre)' },
    @{ Root = 'ojdkbuild';          Child = '.' },
    @{ Root = 'Microsoft';          Child = '^jdk-' }
)

# Read Program Files from the 64-bit variables when they exist, so a 32-bit
# PowerShell host looks in the same places as a 64-bit one.
$PF64 = $env:ProgramW6432;       if (-not $PF64) { $PF64 = $env:ProgramFiles }
$CF64 = $env:CommonProgramW6432; if (-not $CF64) { $CF64 = $env:CommonProgramFiles }
$ProgramFilesBases = @(@($PF64, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique)
$CommonFilesBases  = @(@($CF64, ${env:CommonProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique)

# Shared Oracle leftovers, removed only when no Java at all is still registered.
$SharedDirs = @()
foreach ($cf in $CommonFilesBases) { $SharedDirs += (Join-Path $cf 'Oracle\Java'); $SharedDirs += (Join-Path $cf 'Java') }
$SharedDirs += (Join-Path $env:ProgramData 'Oracle\Java')

# Every path this script is allowed to delete must be strictly inside one of these.
$AllowedDeleteRoots = @()
foreach ($b in $ProgramFilesBases) { foreach ($vr in $VendorRoots) { $AllowedDeleteRoots += (Join-Path $b $vr.Root) } }
$AllowedDeleteRoots += $SharedDirs

$Views = @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)
$LogDir = Join-Path $env:ProgramData 'TechCollective\JavaRemoval'

#endregion

#region ----------------------------- Helpers ---------------------------------

function Test-JavaName {
    param([string]$Name)
    foreach ($p in $JavaNamePatterns) { if ($Name -match $p) { return $true } }
    return $false
}

function Test-Kept {
    param([string]$Text)
    if (-not $Text) { return $false }
    foreach ($t in $KeepTerms) {
        if ($Text.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Get-NormPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    try { $p = [IO.Path]::GetFullPath($p) } catch { }
    return $p.TrimEnd('\')
}

function Test-Under {
    # True when Path is Dir itself or anything inside it.
    param([string]$Path, [string]$Dir)
    $p = Get-NormPath $Path; $d = Get-NormPath $Dir
    if (-not $p -or -not $d) { return $false }
    return ($p.Equals($d, [StringComparison]::OrdinalIgnoreCase) -or
            $p.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Test-UnderAny {
    param([string]$Path, [string[]]$Dirs)
    foreach ($d in $Dirs) { if (Test-Under $Path $d) { return $true } }
    return $false
}

function Get-Ver3 {
    # First three numeric parts of a version string: '8.0.4010.11' -> '8.0.4010'.
    param([string]$Version)
    if (-not $Version) { return '' }
    $parts = @([regex]::Matches($Version, '\d+') | ForEach-Object { $_.Value })
    if ($parts.Count -lt 3) { return '' }
    return ($parts[0..2] -join '.')
}

function Get-JavaEntries {
    $found = @(); $seen = @{}
    foreach ($view in $Views) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $un = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $un) { continue }
            try {
                foreach ($name in $un.GetSubKeyNames()) {
                    $k = $un.OpenSubKey($name)
                    if (-not $k) { continue }
                    try {
                        $dn = [string]$k.GetValue('DisplayName')
                        if (-not $dn -or -not (Test-JavaName $dn)) { continue }
                        $id = ($name + '|' + $dn).ToLowerInvariant()
                        if ($seen.ContainsKey($id)) { continue }   # 32-bit Windows shows one hive twice
                        $seen[$id] = $true
                        $us   = [string]$k.GetValue('UninstallString')
                        $quiet = [string]$k.GetValue('QuietUninstallString')
                        $guid = ''
                        if ($name -match '^\{[0-9A-Fa-f-]{36}\}$') { $guid = $name }
                        elseif ($us -match '\{[0-9A-Fa-f-]{36}\}') { $guid = $Matches[0] }
                        $isMsi = [bool]($guid -and (([string]$k.GetValue('WindowsInstaller') -eq '1') -or $us -match 'msiexec'))
                        $found += New-Object PSObject -Property @{
                            DisplayName     = $dn
                            DisplayVersion  = [string]$k.GetValue('DisplayVersion')
                            Publisher       = [string]$k.GetValue('Publisher')
                            InstallLocation = Get-NormPath ([string]$k.GetValue('InstallLocation'))
                            KeyName         = $name
                            Guid            = $guid
                            IsMsi           = $isMsi
                            Quiet           = $quiet
                            Kept            = (Test-Kept $dn)
                        }
                    } finally { $k.Close() }
                }
            } finally { $un.Close() }
        } finally { $base.Close() }
    }
    return $found
}

function Get-JavaFolders {
    $out = @()
    foreach ($b in $ProgramFilesBases) {
        foreach ($vr in $VendorRoots) {
            $root = Join-Path $b $vr.Root
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            $children = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.PSIsContainer -and $_.Name -match $vr.Child })
            foreach ($d in $children) {
                $javaExe = Join-Path $d.FullName 'bin\java.exe'
                $hasJava = Test-Path -LiteralPath $javaExe -PathType Leaf
                $ver = ''
                if ($hasJava) { try { $ver = [string](Get-Item -LiteralPath $javaExe).VersionInfo.FileVersion } catch { } }
                $out += New-Object PSObject -Property @{
                    Path    = $d.FullName
                    Name    = $d.Name
                    HasJava = $hasJava
                    Version = $ver
                }
            }
        }
    }
    return $out
}

function Get-FolderOwner {
    # Which registered entry a folder belongs to: by InstallLocation, then by
    # java.exe version against DisplayVersion (Oracle records no InstallLocation).
    param($Folder, $Entries)
    foreach ($e in $Entries) {
        if ($e.InstallLocation -and ((Test-Under $Folder.Path $e.InstallLocation) -or (Test-Under $e.InstallLocation $Folder.Path))) { return $e }
    }
    $v = Get-Ver3 $Folder.Version
    if ($v) { foreach ($e in $Entries) { if ($v -eq (Get-Ver3 $e.DisplayVersion)) { return $e } } }
    return $null
}

function Test-FolderProtected {
    param($Folder, $Entries)
    if (Test-Kept $Folder.Name) { return $true }
    $o = Get-FolderOwner $Folder $Entries
    return [bool]($o -and $o.Kept)
}

function Remove-JavaDir {
    # rd removes a junction as a link and never follows it into its target,
    # which Remove-Item -Recurse can on Windows PowerShell 5.1.
    param([string]$Path)
    $full = Get-NormPath $Path
    $allowed = $false
    foreach ($r in $AllowedDeleteRoots) {
        $rn = Get-NormPath $r
        if ($full.StartsWith($rn + '\', [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true }
    }
    if (-not $allowed) { Write-Line ("  [skip] not inside a Java vendor folder, not deleted: {0}" -f $full); return $false }
    if (-not (Test-Path -LiteralPath $full)) { return $true }
    $ErrorActionPreference = 'Continue'
    $null = & $env:ComSpec /c rd /s /q $full 2>&1
    if (Test-Path -LiteralPath $full) { Write-Line ("  [fail] could not delete (files in use?): {0}" -f $full); return $false }
    Write-Line ("  [ok] deleted {0}" -f $full)
    return $true
}

function Remove-EmptyDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) { return }
    try { [IO.Directory]::Delete($Path, $false); Write-Line ("  [ok] removed empty folder {0}" -f $Path) } catch { }
}

function Stop-JavaProcesses {
    param([string[]]$Dirs)
    $Dirs = @($Dirs | Where-Object { $_ })
    if (-not $Dirs.Count) { return }
    foreach ($p in @(Get-WmiObject -Class Win32_Process)) {
        $exe = [string]$p.ExecutablePath
        if (-not $exe -or -not (Test-UnderAny $exe $Dirs)) { continue }
        try {
            Stop-Process -Id $p.ProcessId -Force
            Write-Line ("  [ok] stopped {0} (PID {1})" -f $p.Name, $p.ProcessId)
        } catch {
            Write-Line ("  [fail] could not stop {0} (PID {1}): {2}" -f $p.Name, $p.ProcessId, $_.Exception.Message)
        }
    }
}

function Invoke-Uninstall {
    # Returns a result object: Ok, Reboot, Note.
    param($Entry, [int]$Index)
    $r = New-Object PSObject -Property @{ Ok = $false; Reboot = $false; Note = '' }
    $log = ''
    if ($Entry.IsMsi) {
        $exe = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $log = Join-Path $LogDir ("uninstall-{0}.log" -f $Index)
        $argList = '/x {0} /qn /norestart REBOOT=ReallySuppress /l*v "{1}"' -f $Entry.Guid, $log
    } elseif ($Entry.Quiet) {
        $exe = $env:ComSpec
        $argList = '/s /c "{0}"' -f $Entry.Quiet
    } else {
        $r.Note = 'no silent uninstaller is registered; remove it by hand'
        return $r
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $p = Start-Process -FilePath $exe -ArgumentList $argList -PassThru
        $null = $p.Handle   # keeps the exit code readable after the process ends
        if (-not $p.WaitForExit($UninstallTimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            $r.Note = "uninstaller did not finish within $UninstallTimeoutSec seconds and was stopped"
            break
        }
        $code = $p.ExitCode
        if ($code -eq 1618 -and $attempt -eq 1) {
            Write-Line '  another installation is running; waiting 60 seconds and trying once more'
            Start-Sleep -Seconds 60
            continue
        }
        switch ($code) {
            0       { $r.Ok = $true; $r.Note = 'exit 0' }
            1605    { $r.Ok = $true; $r.Note = 'exit 1605 (already gone)' }
            1641    { $r.Ok = $true; $r.Reboot = $true; $r.Note = 'exit 1641 (reboot needed to finish)' }
            3010    { $r.Ok = $true; $r.Reboot = $true; $r.Note = 'exit 3010 (reboot needed to finish)' }
            default { $r.Note = "exit $code" }
        }
        break
    }
    if ($log -and (Test-Path -LiteralPath $log)) {
        if ($r.Ok) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
        else { $r.Note += "; log: $log" }
    }
    return $r
}

function Remove-SharedLeftovers {
    param([string[]]$DeletedPaths)

    foreach ($d in $SharedDirs) { if (Test-Path -LiteralPath $d) { $null = Remove-JavaDir $d } }
    foreach ($cf in $CommonFilesBases) { Remove-EmptyDir (Join-Path $cf 'Oracle') }
    Remove-EmptyDir (Join-Path $env:ProgramData 'Oracle')

    foreach ($view in $Views) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $js = $base.OpenSubKey('SOFTWARE\JavaSoft')
            if ($js) {
                $js.Close()
                $base.DeleteSubKeyTree('SOFTWARE\JavaSoft')
                Write-Line ("  [ok] deleted HKLM\SOFTWARE\JavaSoft ({0})" -f $view)
            }
            $run = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Run', $true)
            if ($run) {
                try {
                    if ($null -ne $run.GetValue('SunJavaUpdateSched')) {
                        $run.DeleteValue('SunJavaUpdateSched')
                        Write-Line ("  [ok] deleted Run value SunJavaUpdateSched ({0})" -f $view)
                    }
                } finally { $run.Close() }
            }
        } finally { $base.Close() }
    }

    # Machine PATH and JAVA_HOME: drop only entries that pointed at what was
    # deleted (or Oracle's javapath) and no longer exist. The value kind is kept.
    $envKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    try {
        $noExpand = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        $raw = [string]$envKey.GetValue('Path', '', $noExpand)
        if ($raw) {
            $kind = $envKey.GetValueKind('Path')
            $keep = @(); $dropped = @()
            foreach ($part in ($raw -split ';')) {
                if (-not $part) { continue }
                $exp = Get-NormPath $part
                $isJava = ($exp -match '\\Oracle\\Java\\javapath$') -or (Test-UnderAny $exp $DeletedPaths)
                if ($isJava -and -not (Test-Path -LiteralPath $exp)) { $dropped += $part } else { $keep += $part }
            }
            if ($dropped.Count) {
                $envKey.SetValue('Path', ($keep -join ';'), $kind)
                foreach ($d in $dropped) { Write-Line ("  [ok] removed from machine PATH: {0}" -f $d) }
            }
        }
        $jh = [string]$envKey.GetValue('JAVA_HOME', '', $noExpand)
        if ($jh) {
            $jhn = Get-NormPath $jh
            if ((Test-UnderAny $jhn $DeletedPaths) -and -not (Test-Path -LiteralPath $jhn)) {
                $envKey.DeleteValue('JAVA_HOME')
                Write-Line ("  [ok] removed machine JAVA_HOME (was {0})" -f $jh)
            }
        }
    } finally { $envKey.Close() }

    foreach ($b in $ProgramFilesBases) {
        foreach ($vr in $VendorRoots) {
            if ($vr.Root -eq 'Microsoft') { continue }   # never remove Program Files\Microsoft
            Remove-EmptyDir (Join-Path $b $vr.Root)
        }
    }
}

function Write-Udf {
    param([string]$Value)
    if ($UdfNumber -le 0) { return }
    $UdfName = "Custom$UdfNumber"
    if ($Value.Length -gt 255) { $Value = $Value.Substring(0, 252) + '...' }
    try { $existing = [string](Get-ItemProperty -LiteralPath $UdfKey -Name $UdfName -ErrorAction Stop).$UdfName } catch { $existing = '' }
    if ($existing -and $existing -notmatch $OwnUdfPattern) {
        Write-Line ("UDF=NOT_WRITTEN {0} already holds a value this component did not write ({1} characters)." -f $UdfName, $existing.Length)
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $UdfKey)) { New-Item -Path $UdfKey -Force | Out-Null }
        New-ItemProperty -LiteralPath $UdfKey -Name $UdfName -Value $Value -PropertyType String -Force | Out-Null
        Write-Line ("UDF=WRITTEN {0}: {1}" -f $UdfName, $Value)
    } catch {
        Write-Line ("UDF=WRITE_FAILED {0}: {1}" -f $UdfName, $_.Exception.Message)
    }
}

function Write-Entry {
    param($Entry, [string]$Tag)
    $how = if ($Entry.IsMsi) { 'MSI' } elseif ($Entry.Quiet) { 'quiet uninstaller' } else { 'no silent uninstaller' }
    Write-Line ("  [{0}] {1} | {2} | {3} | {4}" -f $Tag, $Entry.DisplayName, $Entry.DisplayVersion, $Entry.Publisher, $how)
}

#endregion

#region ----------------------------- Scan ------------------------------------

$Stamp   = Get-Date -Format 'yyyy-MM-dd HH:mm'
$Entries = @(Get-JavaEntries)
$Folders = @(Get-JavaFolders)
$ToRemove = @($Entries | Where-Object { -not $_.Kept })
$Kept     = @($Entries | Where-Object { $_.Kept })

Write-Line ("Registered Java: {0} (remove {1}, keep {2})" -f $Entries.Count, $ToRemove.Count, $Kept.Count)
foreach ($e in $ToRemove) { Write-Entry $e 'remove' }
foreach ($e in $Kept)     { Write-Entry $e 'keep' }

$UnregisteredJava = @()
$Leftovers = @()
Write-Line ("Java folders under Program Files vendor folders: {0}" -f $Folders.Count)
foreach ($f in $Folders) {
    $owner = Get-FolderOwner $f $Entries
    $prot  = Test-FolderProtected $f $Entries
    $what  = if ($owner) { 'belongs to ' + $owner.DisplayName } elseif ($f.HasJava) { 'not registered' } else { 'leftover, no java.exe' }
    $tag   = if ($prot) { 'keep' } else { 'remove' }
    Write-Line ("  [{0}] {1} ({2})" -f $tag, $f.Path, $what)
    if (-not $owner -and -not $prot) {
        if ($f.HasJava) { $UnregisteredJava += $f } else { $Leftovers += $f }
    }
}

#endregion

#region ----------------------------- Report ----------------------------------

if ($Mode -eq 'Report') {
    $n = $ToRemove.Count + $UnregisteredJava.Count
    if ($n -gt 0) {
        $names = @($ToRemove | ForEach-Object { $_.DisplayName }) + @($UnregisteredJava | ForEach-Object { $_.Name })
        Write-Udf ("Java: FOUND {0} | {1} | {2}" -f $n, ($names -join '; '), $Stamp)
        Finish 'FOUND' ("Report only, nothing changed. Remove would uninstall {0}, delete {1} unregistered and {2} leftover folder(s), keep {3}." -f $ToRemove.Count, $UnregisteredJava.Count, $Leftovers.Count, $Kept.Count) 0
    }
    Write-Udf ("Java: NONE | Kept {0} | {1}" -f $Kept.Count, $Stamp)
    Finish 'CLEAN' ("Report only, nothing changed. No removable Java; {0} leftover folder(s), {1} kept." -f $Leftovers.Count, $Kept.Count) 0
}

if ($ToRemove.Count -eq 0 -and $UnregisteredJava.Count -eq 0 -and $Leftovers.Count -eq 0) {
    Write-Udf ("Java: NONE | Kept {0} | {1}" -f $Kept.Count, $Stamp)
    Finish 'CLEAN' ("No removable Java found; nothing changed. Kept: {0}." -f $Kept.Count) 0
}

#endregion

#region ----------------------------- Remove ----------------------------------

$Reboot = $false

# 1. Stop what runs from the folders being removed, and the Oracle updater.
$StopDirs = @($ToRemove | ForEach-Object { $_.InstallLocation }) +
            @($Folders | Where-Object { -not (Test-FolderProtected $_ $Entries) } | ForEach-Object { $_.Path }) +
            @($CommonFilesBases | ForEach-Object { Join-Path $_ 'Java' })
Write-Line 'Stopping Java processes:'
Stop-JavaProcesses $StopDirs

# 2. Uninstall.
if ($ToRemove.Count) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
    Write-Line 'Uninstalling:'
    $i = 0
    foreach ($e in $ToRemove) {
        $i++
        $res = Invoke-Uninstall $e $i
        if ($res.Reboot) { $Reboot = $true }
        $tag = if ($res.Ok) { 'ok' } else { 'fail' }
        Write-Line ("  [{0}] {1}: {2}" -f $tag, $e.DisplayName, $res.Note)
    }
    Remove-EmptyDir $LogDir
    Remove-EmptyDir (Join-Path $env:ProgramData 'TechCollective')
    Start-Sleep -Seconds 5
}

# 3. Leftover folders, judged against what is registered now.
$After = @(Get-JavaEntries)
$Deleted = @()
Write-Line 'Leftover folders:'
foreach ($f in @(Get-JavaFolders)) {
    if (Test-FolderProtected $f $After) { continue }
    $owner = Get-FolderOwner $f $After
    if ($owner) { Write-Line ("  [left] {0} still belongs to registered {1}" -f $f.Path, $owner.DisplayName); continue }
    if (Remove-JavaDir $f.Path) { $Deleted += $f.Path }
}

# 4. Shared settings, only when no Java at all is still registered.
if ($After.Count -eq 0) {
    Write-Line 'Shared Java leftovers:'
    Stop-JavaProcesses $SharedDirs
    Remove-SharedLeftovers ($Deleted + @($ToRemove | ForEach-Object { $_.InstallLocation } | Where-Object { $_ }))
} else {
    Write-Line ("Shared Java settings (JavaSoft key, javapath, PATH) left in place: {0} Java product(s) still registered." -f $After.Count)
}

#endregion

#region ----------------------------- Re-check --------------------------------

$Final        = @(Get-JavaEntries)
$StillThere   = @($Final | Where-Object { -not $_.Kept })
$StillFolders = @(Get-JavaFolders | Where-Object { $_.HasJava -and -not (Test-FolderProtected $_ $Final) -and -not (Get-FolderOwner $_ $Final) })
$KeptCount    = @($Final | Where-Object { $_.Kept }).Count
$RemovedCount = $ToRemove.Count - $StillThere.Count

Write-Line ("Reboot needed to finish: {0}" -f $(if ($Reboot) { 'yes' } else { 'no' }))

if ($StillThere.Count -eq 0 -and $StillFolders.Count -eq 0) {
    Write-Udf ("Java: REMOVED {0} | Kept {1}{2} | {3}" -f $RemovedCount, $KeptCount, $(if ($Reboot) { ' | reboot pending' } else { '' }), $Stamp)
    Finish 'REMOVED' ("Uninstalled {0}, deleted {1} folder(s), kept {2}. Re-check found nothing left to remove." -f $RemovedCount, $Deleted.Count, $KeptCount) 0
}

Write-Line 'Still present:'
foreach ($e in $StillThere)   { Write-Entry $e 'left' }
foreach ($f in $StillFolders) { Write-Line ("  [left] {0}" -f $f.Path) }
$names = @($StillThere | ForEach-Object { $_.DisplayName }) + @($StillFolders | ForEach-Object { $_.Name })
Write-Udf ("Java: INCOMPLETE {0} left | {1} | {2}" -f $names.Count, ($names -join '; '), $Stamp)
Finish 'REMOVE_INCOMPLETE' ("{0} item(s) still present; see the lines above. If a reboot is pending, reboot and run again." -f $names.Count) 3

#endregion
