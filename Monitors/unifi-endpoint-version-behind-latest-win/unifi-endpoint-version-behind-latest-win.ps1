<#
.SYNOPSIS
    Datto RMM Monitor - UniFi Endpoint - Version Behind Latest [Win]

.DESCRIPTION
    Alerts when the installed UniFi Endpoint is older than Ubiquiti's latest
    Windows release. Pair it with the "UniFi Endpoint [Win]" component as the
    monitor's auto-response to keep the app current without the app's own
    updater (which needs admin rights end users do not have).

    How "latest" is found - WITHOUT downloading the installer:
      * Sends HEAD requests to Ubiquiti's latest-MSI link and follows the
        redirect chain by hand (no body is read), reading the version from the
        .msi file name in a Location or Content-Disposition header.
      * Caches the answer in C:\ProgramData\_automation\UniFiEndpoint\latest.json
        for cacheHours, so the vendor is asked at most once per cacheHours per
        device however often the monitor runs.
      * Records when each new version was first seen, so graceDays can hold
        off alerting on a release that is only hours old.

    "I could not tell" (the latest version is unknown) is treated as ROUTINE for
    staleDays - a site with a flaky link does not raise alerts - and then as a
    FAULT: if no successful lookup has happened for staleDays, it alerts, because
    by then the vendor link has probably changed and the monitor is blind.

    Exit 0 = healthy (current, within grace, not installed, or temporarily unknown)
    Exit 1 = alert  (behind latest, blind for > staleDays, or the check crashed)

    Read-only on the product. Writes only its own cache file. Makes HEAD
    requests to download.uid.ui.com and any HTTPS host it redirects to.

.NOTES
    Category: Monitors (permanent) | Script type: PowerShell | Runs as: SYSTEM
    No attachments (monitors cannot have them).
    Source: https://github.com/TechCollective/DattoRMM_Components
#>

$ErrorActionPreference = 'Stop'

$VendorMsiUrl = 'https://download.uid.ui.com/?app=DESKTOP-IDENTITY-STANDARD-WINDOWS-MSI'
$CacheDir     = Join-Path $env:ProgramData '_automation\UniFiEndpoint'
$CacheFile    = Join-Path $CacheDir 'latest.json'

$script:DiagLines = New-Object System.Collections.Generic.List[string]
function Add-Diag { param([string]$Line) $script:DiagLines.Add($Line) }

function Write-MonitorResult {
    param([string]$Status, [int]$Code)
    # STATUS must be one line, and 'STATUS=' with no space after the '='.
    $Status = ($Status -replace '[\r\n]+', ' ').Trim()
    Write-Output '<-Start Result->'
    Write-Output "STATUS=$Status"
    Write-Output '<-End Result->'
    if ($Code -ne 0 -and $script:DiagLines.Count -gt 0) {
        Write-Output '<-Start Diagnostic->'
        $script:DiagLines | ForEach-Object { Write-Output $_ }
        Write-Output '<-End Diagnostic->'
    }
    exit $Code
}

try {
    # ------------------------------------------------------------ inputs ----
    function Get-IntVar {
        param([string]$Name, [int]$Default, [int]$Min, [int]$Max)
        $raw = [Environment]::GetEnvironmentVariable($Name)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $n = 0
        if (-not [int]::TryParse($raw.Trim(), [ref]$n) -or $n -lt $Min -or $n -gt $Max) {
            throw "Input variable '$Name' = '$raw' is not a whole number from $Min to $Max."
        }
        return $n
    }
    $CacheHours     = Get-IntVar 'cacheHours' 12 1 168
    $GraceDays      = Get-IntVar 'graceDays'  2  0 60
    $StaleDays      = Get-IntVar 'staleDays'  7  1 60
    $AlertIfMissing = ([string]$env:alertIfMissing).Trim() -match '^(1|true|yes|y)$'

    # --------------------------------------------------------- helpers ------
    # Compare only as many version fields as BOTH sides have, so '3.7.4' (file
    # name) equals '3.7.4.301' (registry) instead of looking older forever.
    function Split-Version {
        param([string]$Text)
        if ($Text -notmatch '^\s*(\d+(\.\d+){0,3})') { return $null }
        return @($Matches[1].Split('.') | ForEach-Object { [int]$_ })
    }
    function Compare-Version {
        param([int[]]$A, [int[]]$B)
        $n = [Math]::Min($A.Count, $B.Count)
        for ($i = 0; $i -lt $n; $i++) {
            if ($A[$i] -lt $B[$i]) { return -1 }
            if ($A[$i] -gt $B[$i]) { return 1 }
        }
        return 0
    }

    function Get-InstalledEndpoint {
        # Same rules as the install component: both registry views, publisher
        # must be Ubiquiti, never UniFi Identity *Enterprise*.
        $patterns = @('UniFi Endpoint*', 'UniFi Identity Endpoint*', 'UniFi Identity Standard*')
        $found = @{}
        foreach ($viewName in @('Registry64', 'Registry32')) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,
                                                               [Microsoft.Win32.RegistryView]::$viewName)
            $uk = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $uk) { continue }
            foreach ($sub in $uk.GetSubKeyNames()) {
                $k = $uk.OpenSubKey($sub)
                if (-not $k) { continue }
                $name = [string]$k.GetValue('DisplayName')
                if ([string]::IsNullOrWhiteSpace($name) -or $name -like '*Enterprise*') { continue }
                if (([string]$k.GetValue('Publisher')) -notlike '*Ubiquiti*') { continue }
                $hit = $false
                foreach ($p in $patterns) { if ($name -like $p) { $hit = $true; break } }
                if ($hit -and -not $found.ContainsKey($sub)) {
                    $found[$sub] = [pscustomobject]@{ Name = $name; Version = [string]$k.GetValue('DisplayVersion') }
                }
            }
        }
        return @($found.Values)
    }

    function Get-VersionFromFileName {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
        $t = [uri]::UnescapeDataString($Text)
        # Content-Disposition: filename="X.msi" / filename*=UTF-8''X.msi
        if ($t -match "filename\*?=(?:UTF-8'')?`"?([^`";]+)") { $t = $Matches[1] }
        else {
            try { $t = ([uri]$t).AbsolutePath } catch { }
            $t = ($t -split '/')[-1]
        }
        if ($t -match '(\d+\.\d+\.\d+(?:\.\d+)?)[^\\/]*\.msi$') { return $Matches[1] }
        return $null
    }

    function Resolve-LatestVersion {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $url = $VendorMsiUrl
        for ($hop = 0; $hop -lt 6; $hop++) {
            $resp = $null
            foreach ($method in @('HEAD', 'GET')) {
                $req = [Net.HttpWebRequest]::Create($url)
                $req.Method            = $method
                $req.AllowAutoRedirect = $false
                $req.Timeout           = 15000
                $req.ReadWriteTimeout  = 15000
                $req.UserAgent         = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) DattoRMM-UniFiEndpoint-VersionMonitor'
                try { $resp = $req.GetResponse() }
                catch [Net.WebException] {
                    $resp = $_.Exception.Response
                    if (-not $resp) { throw }
                }
                $code = [int]$resp.StatusCode
                # Some servers refuse HEAD; retry the same hop with GET, reading no body.
                if ($method -eq 'HEAD' -and ($code -eq 405 -or $code -eq 403 -or $code -eq 501)) { $resp.Close(); $resp = $null; continue }
                break
            }
            try {
                $code = [int]$resp.StatusCode
                $loc  = $resp.Headers['Location']
                $cd   = $resp.Headers['Content-Disposition']
            } finally { $resp.Close() }   # never read the body: no installer download

            Add-Diag "  hop ${hop}: $code $(([uri]$url).Host)$(if ($loc) { ' -> ' + ([uri]::new([uri]$url, $loc)).Host })"

            foreach ($candidate in @($cd, $loc, $url)) {
                $v = Get-VersionFromFileName $candidate
                if ($v) { return $v }
            }
            if ($code -ge 300 -and $code -lt 400 -and $loc) {
                $next = [uri]::new([uri]$url, $loc)
                if ($next.Scheme -ne 'https') { throw "Vendor link redirected to non-HTTPS ($($next.Host))." }
                $url = $next.AbsoluteUri
                continue
            }
            throw "No version in the vendor link's file name (last HTTP status $code)."
        }
        throw 'Vendor link redirected more than 6 times.'
    }

    function Read-Cache {
        if (-not (Test-Path -LiteralPath $CacheFile)) { return $null }
        try { return (Get-Content -LiteralPath $CacheFile -Raw | ConvertFrom-Json) } catch { return $null }
    }
    function Write-Cache {
        param($Obj)
        if (-not (Test-Path $CacheDir)) { New-Item -Path $CacheDir -ItemType Directory -Force | Out-Null }
        $Obj | ConvertTo-Json | Set-Content -LiteralPath $CacheFile -Encoding UTF8
    }
    # PS 5.1's ConvertFrom-Json leaves ISO dates as strings; PS 7 turns them into DateTime.
    function ConvertTo-Utc {
        param($s)
        if ($null -eq $s -or "$s" -eq '') { return $null }
        if ($s -is [datetime]) { return $s.ToUniversalTime() }
        return [datetime]::Parse([string]$s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }

    # ------------------------------------------------------- installed ------
    $installed = @(Get-InstalledEndpoint)
    if ($installed.Count -eq 0) {
        if ($AlertIfMissing) { Write-MonitorResult 'UniFi Endpoint is not installed on this device (alertIfMissing is on).' 1 }
        Write-MonitorResult 'UniFi Endpoint is not installed; nothing to check.' 0
    }
    $current = $null; $currentText = $null
    foreach ($i in $installed) {
        $v = Split-Version $i.Version
        if ($v -and ((-not $current) -or ((Compare-Version $v $current) -gt 0))) { $current = $v; $currentText = $i.Version }
    }
    Add-Diag ("Installed: " + (($installed | ForEach-Object { "$($_.Name) v$($_.Version)" }) -join '; '))
    if (-not $current) { throw "Installed version '$($installed[0].Version)' could not be read." }

    # ---------------------------------------------------------- latest ------
    $now   = [datetime]::UtcNow
    $cache = Read-Cache
    $latestText = $null; $firstSeen = $null; $lastSuccess = $null; $firstFailure = $null; $lookupError = $null
    if ($cache) {
        $latestText   = [string]$cache.Version
        $firstSeen    = ConvertTo-Utc $cache.FirstSeenUtc
        $lastSuccess  = ConvertTo-Utc $cache.LastSuccessUtc
        $firstFailure = ConvertTo-Utc $cache.FirstFailureUtc
    }

    $cacheFresh = $lastSuccess -and (($now - $lastSuccess).TotalHours -lt $CacheHours)
    if (-not $cacheFresh) {
        Add-Diag "Vendor lookup ($VendorMsiUrl):"
        try {
            $found = Resolve-LatestVersion
            # A change from a known version = a new release, first seen now. With no
            # previous answer (first run on this device) the release date is unknown,
            # so no grace period applies - a long-outdated device alerts straight away.
            if ($latestText -and ($found -ne $latestText)) { $firstSeen = $now }
            elseif (-not $latestText) { $firstSeen = $null }
            $latestText = $found; $lastSuccess = $now; $firstFailure = $null
        }
        catch {
            $lookupError = $_.Exception.Message
            if (-not $firstFailure) { $firstFailure = $now }
            Add-Diag "Lookup failed: $lookupError"
        }
        Write-Cache ([pscustomobject]@{
            Version         = $latestText
            FirstSeenUtc    = if ($firstSeen)    { $firstSeen.ToString('o') }    else { $null }
            LastSuccessUtc  = if ($lastSuccess)  { $lastSuccess.ToString('o') }  else { $null }
            FirstFailureUtc = if ($firstFailure) { $firstFailure.ToString('o') } else { $null }
        })
    }

    $latest = Split-Version $latestText
    $cachedAgeDays = if ($lastSuccess) { ($now - $lastSuccess).TotalDays } else { $null }

    # Unknown, or last good answer too old: routine until staleDays, then a fault.
    if ((-not $latest) -or ($cachedAgeDays -gt $StaleDays)) {
        $blindSince = if ($lastSuccess) { $lastSuccess } elseif ($firstFailure) { $firstFailure } else { $now }
        $blindDays  = [Math]::Floor(($now - $blindSince).TotalDays)
        $why        = if ($lookupError) { $lookupError } else { 'no successful lookup yet' }
        if (($now - $blindSince).TotalDays -gt $StaleDays) {
            Write-MonitorResult "Check could not run: latest UniFi Endpoint version unknown for $blindDays days ($why). Installed $currentText." 1
        }
        Write-MonitorResult "UniFi Endpoint $currentText installed; latest version temporarily unknown ($why). Alerts after $StaleDays days." 0
    }

    $src = if ($lookupError) { "cached, lookup failed: $lookupError" } elseif ($cacheFresh) { 'cached' } else { 'checked now' }
    Add-Diag "Latest: $latestText ($src). First seen: $(if ($firstSeen) { $firstSeen.ToString('yyyy-MM-dd HH:mm') + ' UTC' } else { 'unknown' })"

    if ((Compare-Version $current $latest) -ge 0) {
        Write-MonitorResult "UniFi Endpoint $currentText is current (latest $latestText, $src)." 0
    }

    $age = if ($firstSeen) { ($now - $firstSeen).TotalDays } else { [double]::MaxValue }
    if ($age -lt $GraceDays) {
        Write-MonitorResult ("UniFi Endpoint $currentText; $latestText released {0:yyyy-MM-dd}, within the $GraceDays-day grace period." -f $firstSeen) 0
    }

    Add-Diag 'Auto-response: run UniFi Endpoint [Win] (usrMode=Install). Logs on the device: C:\ProgramData\_automation\UniFiEndpoint\'
    $since = if ($firstSeen) { " (available since {0:yyyy-MM-dd})" -f $firstSeen } else { '' }
    Write-MonitorResult "UniFi Endpoint $currentText is behind the latest version $latestText$since." 1
}
catch {
    Add-Diag "Error at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    Write-MonitorResult "Check could not run: $($_.Exception.Message)" 1
}
