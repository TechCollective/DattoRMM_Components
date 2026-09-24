<#
.SYNOPSIS
    Datto RMM Component - UniFi Endpoint [Win]
    Installs, updates, uninstalls or reinstalls Ubiquiti's UniFi Endpoint desktop agent.

.DESCRIPTION
    Install mode (default) is install-OR-update:
      * Gets the MSI from Ubiquiti's own download endpoint (latest release), or from
        the MSI attached to the component, depending on usrSource.
      * Refuses any MSI that is not Authenticode-signed by Ubiquiti.
      * Reads the MSI's ProductVersion and compares it with what is installed:
          - not installed          -> install
          - installed, older       -> upgrade in place
          - installed, same/newer  -> no action (never downgrades)
      * Applies Ubiquiti's documented MSI properties (ORG_DOMAIN, startup, VPN,
        Wi-Fi) and optional ENFORCE_CONFIG_* locks.
      * On an UPDATE (usrKeepExistingSettings=1, the default), re-applies the
        device's existing ORG_DOMAIN / startup / VPN / Wi-Fi settings from HKLM
        instead of the component defaults, so an unattended update (e.g. the
        version monitor's auto-response) cannot reset them. CHECK_UPDATE is
        always taken from usrCheckUpdate (default 0: users are not admins).
      * Verifies the result in the registry after msiexec returns.

    Never reboots. A reboot-required result (3010) is reported as a WARNING line
    and still exits 0.

    Exit codes:
      0 = success (installed, updated, already current, uninstalled)
      1 = failure (see the DETAIL line and the msiexec log)

.NOTES
    Category: Applications | Script type: PowerShell | Runs as: SYSTEM
    Requires 64-bit Windows 10/11 and PowerShell 5.1.
    Logs: C:\ProgramData\_automation\UniFiEndpoint\
    Source: https://github.com/TechCollective/DattoRMM_Components
#>

#region ----------------------------- Setup -----------------------------------

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is ~10x slower with the progress bar

$ScriptName    = 'UniFi Endpoint [Win]'
$LogDir        = Join-Path $env:ProgramData '_automation\UniFiEndpoint'
$DownloadDir   = Join-Path $LogDir 'download'
$TranscriptLog = Join-Path $LogDir 'component.log'
$MsiLog        = Join-Path $LogDir ("msi-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

# Ubiquiti's "latest Windows MSI" endpoint. Deliberately NOT an input variable:
# a free-text URL executed as SYSTEM is a remote-execution grant. Change it here,
# in the repo, under review.
$VendorMsiUrl       = 'https://download.uid.ui.com/?app=DESKTOP-IDENTITY-STANDARD-WINDOWS-MSI'
$ExpectedSignerOrg  = 'Ubiquiti'          # matched against the O= field of the signing certificate

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# Keep the transcript from growing forever.
if ((Test-Path $TranscriptLog) -and ((Get-Item $TranscriptLog).Length -gt 5MB)) {
    Move-Item -Path $TranscriptLog -Destination "$TranscriptLog.old" -Force
}
# Keep the ten newest msiexec logs.
Get-ChildItem -Path $LogDir -Filter 'msi-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 |
    Remove-Item -Force -ErrorAction SilentlyContinue

# Datto RMM component variables arrive as environment variables (always strings).
function Get-Var {
    param([string]$Name, [string]$Default = '')
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

# Normalise a boolean-ish input to '1' or '0'; anything else is a hard failure,
# because it is about to become an msiexec property.
function Get-BoolVar {
    param([string]$Name, [string]$Default)
    $v = Get-Var $Name $Default
    if ($v -match '^(1|true|yes|y)$')  { return '1' }
    if ($v -match '^(0|false|no|n)$') { return '0' }
    throw "Input variable '$Name' has invalid value '$v' (expected 1/0 or true/false)."
}

$script:Diag = New-Object System.Collections.Generic.List[string]
function Write-Diag {
    param([string]$Message)
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message
    $script:Diag.Add($line)
    Write-Host $line
}
function Write-DattoResult {
    param([string]$Status, [string]$Message, [string]$Version = 'N/A')
    Write-Host '<-Start Diagnostic->'
    $script:Diag | ForEach-Object { Write-Host $_ }
    Write-Host '<-End Diagnostic->'
    Write-Host '<-Start Result->'
    Write-Host ("STATUS={0}"  -f $Status)
    Write-Host ("VERSION={0}" -f $Version)
    Write-Host ("DETAIL={0}"  -f $Message)
    Write-Host '<-End Result->'
}

#endregion

#region ------------------------- Input validation -----------------------------

$exitCode = 0
try { Start-Transcript -Path $TranscriptLog -Append -Force | Out-Null } catch { }

try {
    $Mode   = Get-Var 'usrMode'   'Install'     # Install | Uninstall | Reinstall
    $Source = Get-Var 'usrSource' 'Auto'        # Auto | Download | Attached

    if ($Mode   -notmatch '^(?i)(install|uninstall|reinstall)$') { throw "usrMode '$Mode' is not one of Install, Uninstall, Reinstall." }
    if ($Source -notmatch '^(?i)(auto|download|attached)$')      { throw "usrSource '$Source' is not one of Auto, Download, Attached." }

    $OrgDomain       = Get-Var     'uiEndpointDomain'     ''
    $LaunchAtStartup = Get-BoolVar 'usrLaunchAtStartup'   '1'
    # Default 0: the app's own updater needs admin rights the users do not have.
    # Updates are delivered by this component (and the version monitor) instead.
    $CheckUpdate     = Get-BoolVar 'usrCheckUpdate'       '0'
    $ConnectWiFi     = Get-BoolVar 'usrConnectWiFi'       '0'
    $ConnectVpn      = Get-BoolVar 'usrConnectVpn'        '0'
    $AutoReconnect   = Get-BoolVar 'usrAutoReconnectWiFi' '0'
    $DesktopShortcut = Get-BoolVar 'usrDesktopShortcut'   '1'
    $EnforceConfig   = Get-BoolVar 'usrEnforceConfig'     '0'
    $InstallerName   = Get-Var     'usrInstallerName'     'UniFi Endpoint.msi'
    $ExtraArgs       = Get-Var     'usrExtraMsiArgs'      ''
    $KeepExisting    = Get-BoolVar 'usrKeepExistingSettings' '1'

    # These values reach a SYSTEM msiexec command line - constrain them.
    if ($OrgDomain -and $OrgDomain -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-]{0,252}$') {
        throw "uiEndpointDomain '$OrgDomain' contains characters that are not valid in a domain."
    }
    if ($InstallerName -notmatch '^[\w .\-]+\.msi$') {
        throw "usrInstallerName '$InstallerName' must be a bare .msi file name with no path."
    }
    # Only PROPERTY=value pairs, space separated; values may be double-quoted.
    # -cnotmatch: PowerShell's -match is case-insensitive, and [A-Z] must mean uppercase.
    if ($ExtraArgs -and $ExtraArgs -cnotmatch '^([A-Z][A-Z0-9_]*=("[^"]*"|[^\s"]+))(\s+[A-Z][A-Z0-9_]*=("[^"]*"|[^\s"]+))*$') {
        throw "usrExtraMsiArgs must be space-separated UPPERCASE_PROPERTY=value pairs only."
    }

#endregion

#region --------------------------- Detection ---------------------------------

    # Read both registry views explicitly via .NET so a 32-bit PowerShell host
    # still sees 64-bit installs (HKLM:\SOFTWARE is redirected under WOW64).
    # Match on name AND publisher, and never on UniFi Identity *Enterprise*,
    # which is a different product that must not be touched.
    $NamePatterns = @('UniFi Endpoint*', 'UniFi Identity Endpoint*', 'UniFi Identity Standard*')

    function Get-UniFiEndpoint {
        $found = @{}
        foreach ($viewName in @('Registry64', 'Registry32')) {
            $view = [Microsoft.Win32.RegistryView]::$viewName
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $uk   = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $uk) { continue }
            foreach ($sub in $uk.GetSubKeyNames()) {
                $k = $uk.OpenSubKey($sub)
                if (-not $k) { continue }
                $name      = [string]$k.GetValue('DisplayName')
                $publisher = [string]$k.GetValue('Publisher')
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                if ($name -like '*Enterprise*')          { continue }
                if ($publisher -notlike '*Ubiquiti*')    { continue }
                $hit = $false
                foreach ($p in $NamePatterns) { if ($name -like $p) { $hit = $true; break } }
                if (-not $hit -or $found.ContainsKey($sub)) { continue }
                $found[$sub] = [pscustomobject]@{
                    DisplayName     = $name
                    DisplayVersion  = [string]$k.GetValue('DisplayVersion')
                    ProductCode     = $sub
                    InstallLocation = [string]$k.GetValue('InstallLocation')
                }
            }
        }
        return @($found.Values | Sort-Object DisplayName)
    }

    # [version]'3.7.4' is LESS than [version]'3.7.4.0' - pad to four parts first.
    function ConvertTo-Version {
        param([string]$Text)
        if ($Text -notmatch '^\s*(\d+(\.\d+){0,3})') { return $null }
        $parts = @($Matches[1].Split('.'))
        while ($parts.Count -lt 4) { $parts += '0' }
        return [version]($parts -join '.')
    }

#endregion

#region -------------------------- Getting the MSI -----------------------------

    function Get-AttachedMsi {
        foreach ($dir in @($PSScriptRoot, (Get-Location).Path)) {
            if ([string]::IsNullOrWhiteSpace($dir)) { continue }
            $p = Join-Path $dir $InstallerName
            if (Test-Path -LiteralPath $p) { return $p }
        }
        return $null
    }

    function Get-VendorMsi {
        if (-not (Test-Path $DownloadDir)) { New-Item -Path $DownloadDir -ItemType Directory -Force | Out-Null }
        $dest = Join-Path $DownloadDir 'UniFiEndpoint-latest.msi'
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }

        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Diag "Downloading latest MSI from Ubiquiti ($(([uri]$VendorMsiUrl).Host))"
        Invoke-WebRequest -Uri $VendorMsiUrl -OutFile $dest -UseBasicParsing -TimeoutSec 900

        # Sanity: an MSI is an OLE compound file (D0 CF 11 E0) and is not tiny.
        # Catches an HTML error page saved as .msi before anything tries to run it.
        $fs = [IO.File]::OpenRead($dest)
        try { $hdr = New-Object byte[] 4; [void]$fs.Read($hdr, 0, 4); $len = $fs.Length } finally { $fs.Dispose() }
        if (($hdr[0] -ne 0xD0) -or ($hdr[1] -ne 0xCF) -or ($hdr[2] -ne 0x11) -or ($hdr[3] -ne 0xE0) -or ($len -lt 1MB)) {
            throw "Downloaded file is not an MSI ($len bytes). The vendor URL may have changed."
        }
        Write-Diag ("Downloaded {0:N1} MB" -f ($len / 1MB))
        return $dest
    }

    function Assert-UbiquitiSignature {
        param([string]$Path)
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        if ($sig.Status -ne 'Valid') {
            throw "MSI signature status is '$($sig.Status)', not Valid. Refusing to install."
        }
        $subject = $sig.SignerCertificate.Subject
        if ($subject -notmatch ('O="?' + [regex]::Escape($ExpectedSignerOrg))) {
            throw "MSI is validly signed, but not by $ExpectedSignerOrg (signer: $subject). Refusing to install."
        }
        Write-Diag "Signature valid: $subject"
    }

    function Get-MsiProductVersion {
        param([string]$Path)
        $wi = $db = $view = $rec = $null
        try {
            $wi   = New-Object -ComObject WindowsInstaller.Installer
            $db   = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($Path, 0))
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = 'ProductVersion'"))
            [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $rec  = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if (-not $rec) { return $null }
            return [string]$rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1)
        }
        finally {
            if ($view) { try { [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) } catch { } }
            foreach ($o in @($rec, $view, $db, $wi)) { if ($o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } }
            # Release the database handle so msiexec can open the file.
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        }
    }

    # Returns @{ Path; Version; Origin } for a signed, readable MSI, or throws.
    function Resolve-Msi {
        $candidates = @()
        switch -Regex ($Source) {
            '^(?i)download$' { $candidates = @('Download') }
            '^(?i)attached$' { $candidates = @('Attached') }
            default          { $candidates = @('Download', 'Attached') }   # Auto
        }
        $errors = @()
        foreach ($c in $candidates) {
            try {
                if ($c -eq 'Download') { $path = Get-VendorMsi }
                else {
                    $path = Get-AttachedMsi
                    if (-not $path) { throw "No attached '$InstallerName' in the component package." }
                    Write-Diag "Using attached installer: $InstallerName"
                }
                Assert-UbiquitiSignature -Path $path
                $ver = Get-MsiProductVersion -Path $path
                if (-not (ConvertTo-Version $ver)) { throw "Could not read ProductVersion from the MSI." }
                Write-Diag "MSI version: $ver ($c)"
                return @{ Path = $path; Version = $ver; Origin = $c }
            }
            catch {
                $errors += "$c : $($_.Exception.Message)"
                Write-Diag "WARNING: MSI source '$c' unusable - $($_.Exception.Message)"
            }
        }
        throw ("No usable MSI. " + ($errors -join ' | '))
    }

#endregion

#region ------------------------- Install / Remove -----------------------------

    function Invoke-Msi {
        param([string[]]$Arguments, [string]$Action, [switch]$NotInstalledIsOk)

        Write-Diag "msiexec $($Arguments -join ' ')"
        $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" `
                           -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
        $code = $p.ExitCode
        Write-Diag "$Action exit code: $code"

        switch ($code) {
            0       { return @{ Success = $true;  Reboot = $false; Code = 0 } }
            3010    { return @{ Success = $true;  Reboot = $true;  Code = 3010 } }
            1641    { return @{ Success = $true;  Reboot = $true;  Code = 1641 } }
            1605    { return @{ Success = [bool]$NotInstalledIsOk; Reboot = $false; Code = 1605 } }
            default { return @{ Success = $false; Reboot = $false; Code = $code } }
        }
    }

    # ---- Preserving a device's existing settings on update --------------------
    # An update started by the version monitor's auto-response runs with the
    # component's DEFAULT variables, not the values a site was installed with.
    # Passing defaults on upgrade would reset ORG_DOMAIN, VPN and startup options.
    # So on an update, read what Ubiquiti persisted in HKLM and pass it back.
    # Ubiquiti documents the value names but not the key path, so search the
    # vendor keys (bounded depth) for a key holding them.
    $PersistedMap = [ordered]@{
        OrgDomain            = 'ORG_DOMAIN'
        LaunchAtStartup      = 'LAUNCH_AT_STARTUP'
        ConnectWiFiOnStartup = 'CONNECT_WIFI_ON_STARTUP'
        ConnectVpnOnStartup  = 'CONNECT_VPN_ON_STARTUP'
        AutoReconnectWiFi    = 'AUTO_RECONNECT_WIFI'
        # CheckUpdate is deliberately NOT preserved: it is always set from
        # usrCheckUpdate so existing installs are switched off the self-updater.
    }

    function Find-SettingsKey {
        param($Key, [string]$Path, [int]$Depth)
        if (-not $Key) { return $null }
        $names = @($Key.GetValueNames())
        if (($names -contains 'OrgDomain') -or ($names -contains 'LaunchAtStartup')) {
            return @{ Key = $Key; Path = $Path }
        }
        if ($Depth -le 0) { return $null }
        foreach ($sub in $Key.GetSubKeyNames()) {
            $hit = Find-SettingsKey -Key $Key.OpenSubKey($sub) -Path "$Path\$sub" -Depth ($Depth - 1)
            if ($hit) { return $hit }
        }
        return $null
    }

    function Get-ExistingSettings {
        foreach ($viewName in @('Registry64', 'Registry32')) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,
                                                               [Microsoft.Win32.RegistryView]::$viewName)
            foreach ($rootPath in @('SOFTWARE', 'SOFTWARE\Policies')) {
                $root = $base.OpenSubKey($rootPath)
                if (-not $root) { continue }
                foreach ($vendor in @($root.GetSubKeyNames() | Where-Object { $_ -like 'Ubiquiti*' -or $_ -like 'UniFi*' })) {
                    $hit = Find-SettingsKey -Key $root.OpenSubKey($vendor) -Path "$rootPath\$vendor" -Depth 3
                    if (-not $hit) { continue }
                    $vals = @{}
                    foreach ($name in $PersistedMap.Keys) {
                        $v = $hit.Key.GetValue($name)
                        if ($null -eq $v) { continue }
                        $s = ([string]$v).Trim()
                        if ($name -eq 'OrgDomain') {
                            if ($s -match '^[A-Za-z0-9][A-Za-z0-9.\-]{0,252}$') { $vals[$PersistedMap[$name]] = $s }
                        } elseif ($s -match '^[01]$') {
                            $vals[$PersistedMap[$name]] = $s
                        }
                    }
                    $enforce = $false
                    foreach ($n in @($hit.Key.GetValueNames() | Where-Object { $_ -like 'Enforce*' })) {
                        if (([string]$hit.Key.GetValue($n)).Trim() -eq '1') { $enforce = $true }
                    }
                    return @{ Path = "HKLM\$($hit.Path) ($viewName)"; Values = $vals; Enforce = $enforce }
                }
            }
        }
        return $null
    }

    $script:Existing = $null

    function Get-InstallProperties {
        $cfg = [ordered]@{
            ORG_DOMAIN              = $OrgDomain
            LAUNCH_AT_STARTUP       = $LaunchAtStartup
            CONNECT_WIFI_ON_STARTUP = $ConnectWiFi
            CONNECT_VPN_ON_STARTUP  = $ConnectVpn
            AUTO_RECONNECT_WIFI     = $AutoReconnect
        }
        $enforce = $EnforceConfig
        if ($script:Existing) {
            foreach ($k in @($script:Existing.Values.Keys)) { $cfg[$k] = $script:Existing.Values[$k] }
            if ($script:Existing.Enforce) { $enforce = '1' }
            Write-Diag ("Keeping existing settings from {0}: {1}" -f $script:Existing.Path,
                        (($script:Existing.Values.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '))
        }

        $props = @()
        if ($cfg['ORG_DOMAIN']) { $props += "ORG_DOMAIN=`"$($cfg['ORG_DOMAIN'])`"" }
        foreach ($k in @('LAUNCH_AT_STARTUP', 'CONNECT_WIFI_ON_STARTUP', 'CONNECT_VPN_ON_STARTUP', 'AUTO_RECONNECT_WIFI')) {
            $props += "$k=$($cfg[$k])"
        }
        $props += @(
            "CHECK_UPDATE=$CheckUpdate"
            "ADD_DESKTOP_SHORTCUT=$DesktopShortcut"
            'LAUNCH_AFTER_INSTALL=0'
        )
        if ($enforce -eq '1') {
            Write-Diag 'Enforcement locks enabled - users cannot change these settings locally.'
            $props += @(
                'ENFORCE_CONFIG_ORG_DOMAIN=1'
                'ENFORCE_CONFIG_CHECK_UPDATE=1'
                'ENFORCE_CONFIG_LAUNCH_AT_STARTUP=1'
                'ENFORCE_CONFIG_CONNECT_WIFI_ON_STARTUP=1'
                'ENFORCE_CONFIG_CONNECT_VPN_ON_STARTUP=1'
            )
        }
        if ($ExtraArgs) { $props += $ExtraArgs }
        return $props
    }

    function Install-FromMsi {
        param([string]$MsiPath)
        $msiArgs = @('/i', "`"$MsiPath`"", '/qn', '/norestart', '/l*v', "`"$MsiLog`"") + (Get-InstallProperties)
        return (Invoke-Msi -Arguments $msiArgs -Action 'Install')
    }

    function Uninstall-UniFiEndpoint {
        $installed = @(Get-UniFiEndpoint)
        if ($installed.Count -eq 0) {
            Write-Diag 'Nothing to uninstall - product not present.'
            return @{ Success = $true; Reboot = $false; Code = 0 }
        }
        $overall = @{ Success = $true; Reboot = $false; Code = 0 }
        foreach ($app in $installed) {
            Write-Diag "Removing '$($app.DisplayName)' v$($app.DisplayVersion) ($($app.ProductCode))"
            if ($app.ProductCode -match '^\{[0-9A-Fa-f\-]{36}\}$') {
                $r = Invoke-Msi -Arguments @('/x', $app.ProductCode, '/qn', '/norestart', '/l*v', "`"$MsiLog`"") `
                                -Action 'Uninstall' -NotInstalledIsOk
            } else {
                Write-Diag "'$($app.DisplayName)' is not an MSI registration; not removing it automatically."
                $r = @{ Success = $false; Reboot = $false; Code = -1 }
            }
            if (-not $r.Success) { $overall.Success = $false; $overall.Code = $r.Code }
            if ($r.Reboot)       { $overall.Reboot  = $true }
        }
        return $overall
    }

#endregion

#region ---------------------------- Main -------------------------------------

    Write-Diag "$ScriptName starting. Mode = $Mode | Source = $Source"
    Write-Diag "Host: $env:COMPUTERNAME | OS: $((Get-CimInstance Win32_OperatingSystem).Caption)"

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'UniFi Endpoint requires a 64-bit version of Windows.'
    }

    $before = @(Get-UniFiEndpoint)
    if ($before.Count -gt 0) {
        Write-Diag ("Detected: {0}" -f (($before | ForEach-Object { "$($_.DisplayName) v$($_.DisplayVersion)" }) -join '; '))
    } else {
        Write-Diag 'UniFi Endpoint not currently installed.'
    }

    # ---------------- Uninstall ----------------
    if ($Mode -match '^(?i)uninstall$') {
        $r = Uninstall-UniFiEndpoint
        if (-not $r.Success) { throw "Uninstall failed (exit $($r.Code)). See $MsiLog" }
        Start-Sleep -Seconds 5
        if (@(Get-UniFiEndpoint).Count -gt 0) { throw 'Uninstall reported success but the product is still registered.' }
        if ($r.Reboot) { Write-Diag 'WARNING: Windows reports a reboot is required to finish removal. No reboot was forced.' }
        Write-DattoResult -Status 'REMOVED' -Message 'UniFi Endpoint uninstalled and verified absent.'
    }
    else {
        # ------------- Install / Reinstall -------------
        $msi       = Resolve-Msi
        $targetVer = ConvertTo-Version $msi.Version
        $newest    = $null
        foreach ($app in $before) {
            $v = ConvertTo-Version $app.DisplayVersion
            if ($v -and ((-not $newest) -or ($v -gt $newest))) { $newest = $v }
        }

        if (($Mode -match '^(?i)install$') -and $newest -and ($newest -ge $targetVer)) {
            Write-Diag "Installed version $newest is current (available: $targetVer). No action."
            Write-DattoResult -Status 'UP_TO_DATE' -Message "UniFi Endpoint $newest already current; no action taken." -Version "$newest"
        }
        else {
            $action = 'INSTALLED'
            if ($Mode -match '^(?i)reinstall$') {
                $action = 'REINSTALLED'
                if ($before.Count -gt 0) {
                    $u = Uninstall-UniFiEndpoint
                    if (-not $u.Success) { throw "Reinstall: removal failed (exit $($u.Code)); not installing over it. See $MsiLog" }
                    Start-Sleep -Seconds 5
                }
            }
            elseif ($newest) {
                $action = 'UPDATED'
                Write-Diag "Updating $newest -> $targetVer"
                if ($KeepExisting -eq '1') {
                    $script:Existing = Get-ExistingSettings
                    if (-not $script:Existing) {
                        Write-Diag 'WARNING: Could not find the existing UniFi Endpoint settings in HKLM; applying component variables instead.'
                    }
                }
            }

            $result = Install-FromMsi -MsiPath $msi.Path

            # 1638 = "another version of this product is already installed": the
            # MSI would not upgrade in place. Remove the old one, then install.
            if ((-not $result.Success) -and ($result.Code -eq 1638)) {
                Write-Diag 'WARNING: MSI would not upgrade in place (1638). Removing old version, then installing.'
                $u = Uninstall-UniFiEndpoint
                if (-not $u.Success) { throw "Could not remove old version (exit $($u.Code)). See $MsiLog" }
                Start-Sleep -Seconds 5
                $result = Install-FromMsi -MsiPath $msi.Path
            }
            if ((-not $result.Success) -and ($result.Code -eq 1618)) {
                throw 'Another installation is in progress on this device (1618). Re-run the job later.'
            }
            if (-not $result.Success) {
                throw "msiexec failed with exit code $($result.Code). See $MsiLog"
            }

            Start-Sleep -Seconds 5
            $after = @(Get-UniFiEndpoint)
            if ($after.Count -eq 0) {
                throw "msiexec returned $($result.Code) but no UniFi Endpoint registration was found. See $MsiLog"
            }
            $current = $after | Where-Object { (ConvertTo-Version $_.DisplayVersion) -ge $targetVer } | Select-Object -First 1
            if (-not $current) {
                throw ("msiexec returned $($result.Code) but installed version is still " +
                       (($after | ForEach-Object { $_.DisplayVersion }) -join ', ') + " (expected $targetVer).")
            }
            Write-Diag "Verified: $($current.DisplayName) v$($current.DisplayVersion)"

            if ($after.Count -gt 1) {
                Write-Diag ("WARNING: more than one UniFi Endpoint registration remains: " +
                            (($after | ForEach-Object { "$($_.DisplayName) v$($_.DisplayVersion)" }) -join '; ') +
                            ". Run with usrMode=Reinstall to clean up.")
            }
            if ($result.Reboot) {
                Write-Diag 'WARNING: Windows reports a reboot is required to finish. No reboot was forced.'
                $action = "${action}_REBOOT_REQUIRED"
            }
            if ($OrgDomain -and -not $script:Existing) { Write-Diag "Organization domain applied: $OrgDomain" }

            Write-DattoResult -Status $action `
                              -Message "UniFi Endpoint $($current.DisplayVersion) $($action.ToLower().Replace('_',' ')) and verified." `
                              -Version $current.DisplayVersion
        }

        if ($msi.Origin -eq 'Download') { Remove-Item -LiteralPath $msi.Path -Force -ErrorAction SilentlyContinue }
    }

    $exitCode = 0
}
catch {
    Write-Diag "ERROR: $($_.Exception.Message)"
    Write-DattoResult -Status 'FAILED' -Message $_.Exception.Message
    $exitCode = 1
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}

exit $exitCode

#endregion
