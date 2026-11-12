<#
.SYNOPSIS
    Datto RMM Monitor - Connection Health - Ping Targets Not Responding [Win]

.DESCRIPTION
    Checks a connection (typically a site-to-site tunnel) in one or both of two
    ways, depending on which inputs are set:

      usrTargets    ping 1-8 hosts on the far side
      usrWgTunnel   WireGuard for Windows: the tunnel service is running, and
                    its peers have completed a handshake within
                    usrHandshakeMaxAgeSec

      usrRequire = any   alert only when no target replies / no peer is current (default)
      usrRequire = all   alert when any target does not reply / any peer is stale

    Pings run first. Traffic through the tunnel makes WireGuard re-handshake
    with a live peer, so the handshake age read afterwards reflects the peer
    rather than an idle tunnel.

    Uses System.Net.NetworkInformation.Ping rather than ping.exe: ping.exe output
    is localised, and it exits 0 when a router answers "Destination host
    unreachable", which would report a dead tunnel as healthy.

    WireGuard state is read only with `wg.exe show <tunnel> latest-handshakes`,
    `transfer` and `allowed-ips`. Never `dump`, `private-key` or `showconf`,
    which print the tunnel's private key.

    Not knowing is treated as a fault: bad input, no wg.exe, ping failing
    outright on every target, or the script dying all exit 1 with
    "Check could not run".

    Exit 0 = healthy, Exit 1 = alert. Read-only; changes nothing.

.NOTES
    Category: Monitors (permanent) | Script type: PowerShell | Runs as: SYSTEM
    PowerShell 2.0-compatible. No attachments (monitors cannot have them).
    Source: https://github.com/TechCollective/DattoRMM_Components
#>

$ErrorActionPreference = 'Stop'
$script:Emitted   = $false
$script:DiagLines = New-Object System.Collections.Generic.List[string]
function Add-Diag { param([string]$Line) $script:DiagLines.Add($Line) }

function Write-MonitorResult {
    param([string]$Status, [int]$Code)
    # One line, 'STATUS=' with no space after the '='.
    $Status = ($Status -replace '[\r\n]+', ' ').Trim()
    if ($Status.Length -gt 400) { $Status = $Status.Substring(0, 397) + '...' }
    Write-Output '<-Start Result->'
    Write-Output "STATUS=$Status"
    Write-Output '<-End Result->'
    $script:Emitted = $true
    if ($Code -ne 0 -and $script:DiagLines.Count -gt 0) {
        Write-Output '<-Start Diagnostic->'
        foreach ($l in $script:DiagLines) { Write-Output $l }
        Write-Output '<-End Diagnostic->'
    }
    exit $Code
}

# Anything unhandled still produces a result block and never reports healthy.
trap {
    if (-not $script:Emitted) {
        Write-Output '<-Start Result->'
        Write-Output ("STATUS=Check could not run: the monitor stopped unexpectedly (" + ($_.Exception.Message -replace '[\r\n]+', ' ') + ")")
        Write-Output '<-End Result->'
        exit 1
    }
}

function Get-Input {
    param([string]$Name, [string]$Default)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($v -eq $null) { $v = '' }
    $v = $v.Trim()
    if ($v -eq '') { return $Default }
    return $v
}
function Short { param([string]$s, [int]$n) if ($s.Length -gt $n) { return $s.Substring(0, $n) } return $s }

function Format-Age {
    param([long]$s)
    if ($s -lt 120)    { return "${s}s" }
    if ($s -lt 7200)   { return "$([math]::Floor($s / 60))m" }
    if ($s -lt 172800) { return "$([math]::Floor($s / 3600))h" }
    return "$([math]::Floor($s / 86400))d"
}

# Decides the WireGuard verdict from `wg show <tunnel> latest-handshakes` lines
# (public key, TAB, unix time of the last handshake or 0 for never). Returns
# @{ V = up|down|degraded|error; Txt = ...; Diag = lines for the diagnostic }.
function Measure-WgPeers {
    param([string[]]$Handshakes, [string[]]$Transfer, [string[]]$AllowedIps,
          [long]$Now, [int]$MaxAge, [string]$Require)
    $diag = New-Object System.Collections.Generic.List[string]
    $parts = @(); $n = 0; $ok = 0
    foreach ($line in $Handshakes) {
        if ($line -eq $null -or $line.Trim() -eq '') { continue }
        $f = $line.Split("`t")
        $ts = 0L
        if ($f.Count -ne 2 -or $f[1] -notmatch '^[0-9]+$' -or -not [long]::TryParse($f[1], [ref]$ts)) {
            return @{ V = 'error'; Txt = 'unexpected output from wg show latest-handshakes'; Diag = $diag }
        }
        $key = $f[0]; $n++
        if ($ts -eq 0) {
            $state = 'never handshaked'; $parts += "peer $n never"
        } else {
            $age = $Now - $ts; if ($age -lt 0) { $age = 0 }
            $state = "last handshake $(Format-Age $age) ago"
            if ($age -le $MaxAge) { $ok++; $parts += "peer $n $(Format-Age $age) ago" }
            else                  { $parts += "peer $n $(Format-Age $age) ago (stale)" }
        }
        # Key prefix and allowed IPs identify the peer; endpoints are left out.
        $allowed = ''; foreach ($a in $AllowedIps) { $g = "$a".Split("`t"); if ($g[0] -eq $key -and $g.Count -ge 2) { $allowed = $g[1] } }
        $xfer = '';    foreach ($x in $Transfer)   { $g = "$x".Split("`t"); if ($g[0] -eq $key -and $g.Count -ge 3) { $xfer = "$($g[1])/$($g[2])" } }
        $diag.Add("   peer $n (key $(Short $key 8)...): $state; allowed-ips $allowed; rx/tx bytes $xfer")
    }
    if ($n -eq 0) { return @{ V = 'down'; Txt = 'no peers configured'; Diag = $diag } }
    $pn = 'peers'; if ($n -eq 1) { $pn = 'peer' }
    $detail = [string]::Join('; ', $parts)
    $within = "handshaked within ${MaxAge}s"
    if ($Require -eq 'any') {
        if ($ok -ge 1) { return @{ V = 'up';   Txt = "$ok of $n $pn $within ($detail)"; Diag = $diag } }
        return              @{ V = 'down'; Txt = "0 of $n $pn $within ($detail)"; Diag = $diag }
    }
    if ($ok -eq $n) { return @{ V = 'up';       Txt = "all $n $pn $within ($detail)"; Diag = $diag } }
    if ($ok -eq 0)  { return @{ V = 'down';     Txt = "0 of $n $pn $within ($detail)"; Diag = $diag } }
    return               @{ V = 'degraded'; Txt = "$($n - $ok) of $n peers stale and all are required ($detail)"; Diag = $diag }
}

# Combines the two checks. Worst verdict wins: down, degraded, error, up.
function Get-Verdict {
    param([string]$PingV, [string]$PingTxt, [string]$WgV, [string]$WgTxt, [string]$WgName)
    $parts = @()
    if ($PingV -ne 'none') { if ($WgV -ne 'none') { $parts += "ping: $PingTxt" } else { $parts += $PingTxt } }
    if ($WgV -ne 'none')   { $parts += "WireGuard ${WgName}: $WgTxt" }
    $msg = [string]::Join(' | ', $parts)
    if ($PingV -eq 'down'     -or $WgV -eq 'down')     { return @{ Code = 1; Status = "Connection down: $msg" } }
    if ($PingV -eq 'degraded' -or $WgV -eq 'degraded') { return @{ Code = 1; Status = "Connection degraded: $msg" } }
    if ($PingV -eq 'error'    -or $WgV -eq 'error')    { return @{ Code = 1; Status = "Check could not run: $msg" } }
    return @{ Code = 0; Status = "Connection up: $msg" }
}

# ---- Inputs ---------------------------------------------------------------
$MaxTargets = 8

$TargetsRaw = Get-Input 'usrTargets' ''
$Require    = (Get-Input 'usrRequire' 'any').ToLower()
$CountRaw   = Get-Input 'usrPingCount' '3'
$WaitRaw    = Get-Input 'usrReplyTimeoutSec' '2'
$WgTunnel   = Get-Input 'usrWgTunnel' ''
$MaxAgeRaw  = Get-Input 'usrHandshakeMaxAgeSec' '300'

if ($TargetsRaw -eq '' -and $WgTunnel -eq '') {
    Write-MonitorResult 'Check could not run: nothing to check; set usrTargets (addresses to ping), usrWgTunnel (WireGuard tunnel name), or both' 1
}
$Targets = @()
if ($TargetsRaw -ne '') {
    $Targets = @($TargetsRaw -split '[\s,]+' | Where-Object { $_ -ne '' })
    if ($Targets.Count -lt 1) { Write-MonitorResult 'Check could not run: usrTargets has no addresses in it' 1 }
    if ($Targets.Count -gt $MaxTargets) { Write-MonitorResult "Check could not run: usrTargets has $($Targets.Count) entries; the most allowed is $MaxTargets" 1 }
    foreach ($t in $Targets) {
        if ($t -notmatch '^[A-Za-z0-9:][A-Za-z0-9.:-]*$' -or $t.Length -gt 253) {
            Write-MonitorResult "Check could not run: usrTargets entry '$(Short $t 60)' is not an IP address or hostname" 1
        }
    }
}

if ($Require -ne 'any' -and $Require -ne 'all') { Write-MonitorResult "Check could not run: usrRequire must be any or all (got '$(Short $Require 40)')" 1 }
$Count = 0
if (-not [int]::TryParse($CountRaw, [ref]$Count) -or $CountRaw -notmatch '^[0-9]+$' -or $Count -lt 1 -or $Count -gt 10) {
    Write-MonitorResult "Check could not run: usrPingCount must be 1-10 (got '$(Short $CountRaw 40)')" 1
}
$Wait = 0
if (-not [int]::TryParse($WaitRaw, [ref]$Wait) -or $WaitRaw -notmatch '^[0-9]+$' -or $Wait -lt 1 -or $Wait -gt 5) {
    Write-MonitorResult "Check could not run: usrReplyTimeoutSec must be 1-5 (got '$(Short $WaitRaw 40)')" 1
}
# WireGuard for Windows tunnel names: 1-32 of letters, digits and _ = + . -
if ($WgTunnel -ne '' -and $WgTunnel -cnotmatch '^[A-Za-z0-9_=+.-]{1,32}$') {
    Write-MonitorResult "Check could not run: usrWgTunnel '$(Short $WgTunnel 40)' is not a valid WireGuard tunnel name" 1
}
if ($WgTunnel.StartsWith('-')) {
    Write-MonitorResult "Check could not run: usrWgTunnel '$(Short $WgTunnel 40)' is not a valid WireGuard tunnel name" 1
}
$MaxAge = 0
if (-not [int]::TryParse($MaxAgeRaw, [ref]$MaxAge) -or $MaxAgeRaw -notmatch '^[0-9]+$' -or $MaxAge -lt 150 -or $MaxAge -gt 3600) {
    Write-MonitorResult "Check could not run: usrHandshakeMaxAgeSec must be 150-3600 (got '$(Short $MaxAgeRaw 40)')" 1
}
# Pings are sequential: a reply is followed by a 1 s pause, a miss waits the full
# timeout. Worst case per target is therefore count x max(wait, 1) seconds.
$Worst = $Targets.Count * $Count * $Wait
if ($Worst -gt 120) {
    Write-MonitorResult "Check could not run: $($Targets.Count) targets x $Count pings x ${Wait}s could take ${Worst}s; keep it to 120s or less" 1
}
$TimeoutMs = $Wait * 1000

# ---- Ping each target -------------------------------------------------------
# Result: $PingV is none, up, down, degraded or error; $PingTxt says why.
$PingV = 'none'; $PingTxt = ''
$Total = $Targets.Count

if ($Total -gt 0) {
    $Up = 0; $Errors = 0
    $Summary = New-Object System.Collections.Generic.List[string]
    $FirstError = ''
    $Pinger = New-Object System.Net.NetworkInformation.Ping
    $HaveFindNetRoute = [bool](Get-Command Find-NetRoute -ErrorAction SilentlyContinue)

    foreach ($t in $Targets) {
        $ok = 0; $sent = 0; $rttSum = 0; $err = ''
        $fails = @{}
        for ($i = 1; $i -le $Count; $i++) {
            $sent++
            try {
                $reply = $Pinger.Send($t, $TimeoutMs)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $ok++; $rttSum += $reply.RoundtripTime
                    if ($i -lt $Count) { Start-Sleep -Milliseconds 1000 }
                } else {
                    $k = $reply.Status.ToString()
                    if ($fails.ContainsKey($k)) { $fails[$k]++ } else { $fails[$k] = 1 }
                }
            } catch {
                # PingException. Classify by SocketErrorCode, which is not localised:
                # a missing or unreachable route is the connection being down; anything
                # else (the name did not resolve, bad input) is the check failing.
                $e = $_.Exception
                while ($e.InnerException) { $e = $e.InnerException }
                $code = ''
                if ($e -is [System.Net.Sockets.SocketException]) { $code = $e.SocketErrorCode.ToString() }
                if (@('HostUnreachable', 'NetworkUnreachable', 'NetworkDown', 'ConnectionRefused', 'TimedOut') -contains $code) {
                    $k = 'DestinationNetworkUnreachable'
                    if ($code -eq 'TimedOut')          { $k = 'TimedOut' }
                    if ($code -eq 'ConnectionRefused') { $k = 'DestinationPortUnreachable' }
                    if ($fails.ContainsKey($k)) { $fails[$k]++ } else { $fails[$k] = 1 }
                    continue
                }
                $err = ($e.Message -replace '[\r\n]+', ' ').Trim()
                if ($code -ne '') { $err = "$err [$code]" }
                break
            }
        }

        $failText = ''
        if ($fails.Count -gt 0) {
            $parts = @(); foreach ($k in $fails.Keys) { $parts += "$k x$($fails[$k])" }
            $failText = [string]::Join(', ', $parts)
        }

        if ($ok -gt 0) {
            $Up++
            $avg = [math]::Round($rttSum / $ok)
            if ($avg -lt 1) { $avgText = '<1' } else { $avgText = "$avg" }
            $Summary.Add("$t $ok/$sent $avgText ms")
        } elseif ($err -ne '' -and $sent -eq 1) {
            $Errors++
            $err = Short $err 120
            if ($FirstError -eq '') { $FirstError = $err }
            $Summary.Add("$t error: $err")
        } elseif ($fails.ContainsKey('DestinationHostUnreachable') -or $fails.ContainsKey('DestinationNetworkUnreachable')) {
            $Summary.Add("$t no route")
        } else {
            $Summary.Add("$t no reply")
        }

        Add-Diag "== $t : $ok/$sent replies"
        if ($failText -ne '') { Add-Diag "   failures: $failText" }
        if ($err -ne '')      { Add-Diag "   error: $err" }
        if ($HaveFindNetRoute -and $t -match '^[0-9.]+$|:') {
            try {
                $r = @(Find-NetRoute -RemoteIPAddress $t -ErrorAction Stop)
                $ifc = ($r | Where-Object { $_.InterfaceAlias } | Select-Object -First 1).InterfaceAlias
                $hop = ($r | Where-Object { $_.NextHop } | Select-Object -First 1).NextHop
                Add-Diag "   route: interface '$ifc', next hop $hop"
            } catch { Add-Diag "   route: none found" }
        }
    }

    $Noun   = 'targets'; if ($Total -eq 1) { $Noun = 'target' }
    $Detail = [string]::Join('; ', $Summary.ToArray())

    if ($Errors -eq $Total) {
        $PingV = 'error';    $PingTxt = "ping failed on every target ($FirstError)"
    } elseif ($Require -eq 'any') {
        if ($Up -ge 1) { $PingV = 'up';   $PingTxt = "$Up of $Total $Noun replied ($Detail)" }
        else           { $PingV = 'down'; $PingTxt = "0 of $Total $Noun replied ($Detail)" }
    } elseif ($Up -eq $Total) {
        $PingV = 'up';       $PingTxt = "all $Total $Noun replied ($Detail)"
    } elseif ($Up -eq 0) {
        $PingV = 'down';     $PingTxt = "0 of $Total $Noun replied ($Detail)"
    } else {
        $PingV = 'degraded'; $PingTxt = "$($Total - $Up) of $Total targets did not reply and all are required ($Detail)"
    }
}

# ---- WireGuard ----------------------------------------------------------------
# WireGuard for Windows runs each active tunnel as the service
# WireGuardTunnel$<name>. Deactivating the tunnel in the app removes the
# service, so a missing service means the tunnel is not active.
$WgV = 'none'; $WgTxt = ''

function Find-WgExe {
    # 64-bit Program Files even when the agent runs 32-bit PowerShell.
    foreach ($root in @($env:ProgramW6432, $env:ProgramFiles)) {
        if ($root) { $p = Join-Path $root 'WireGuard\wg.exe'; if (Test-Path -LiteralPath $p) { return $p } }
    }
    $c = Get-Command 'wg.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Definition }
    return ''
}

function Invoke-WgShow {
    # Returns @{ Code = exit code; Lines = output lines (stdout and stderr) }.
    param([string]$Exe, [string]$Field)
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe show $WgTunnel $Field 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $eap }
    return @{ Code = $code; Lines = $out }
}

if ($WgTunnel -ne '') {
    Add-Diag "== WireGuard $WgTunnel"
    $svcName = 'WireGuardTunnel$' + $WgTunnel
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        $WgV = 'down'; $WgTxt = 'tunnel is not active (no tunnel service)'
        Add-Diag "   service: $svcName not found"
    } elseif ($svc.Status -ne 'Running') {
        $WgV = 'down'; $WgTxt = "tunnel service is $($svc.Status)"
        Add-Diag "   service: $svcName $($svc.Status)"
    } else {
        Add-Diag "   service: $svcName Running"
        $wgExe = Find-WgExe
        if ($wgExe -eq '') {
            $WgV = 'error'; $WgTxt = 'wg.exe not found (WireGuard for Windows not installed in the usual place)'
        } else {
            $hs = Invoke-WgShow $wgExe 'latest-handshakes'
            if ($hs.Code -ne 0) {
                $why = ''; foreach ($l in $hs.Lines) { if ("$l".Trim() -ne '') { $why = "$l".Trim() } }
                $WgV = 'error'; $WgTxt = "wg show failed: $(Short $why 120)"
                Add-Diag "   wg show (exit $($hs.Code)): $(Short $why 200)"
            } else {
                $xf = Invoke-WgShow $wgExe 'transfer'
                $al = Invoke-WgShow $wgExe 'allowed-ips'
                $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
                $now = [long][math]::Floor(([DateTime]::UtcNow - $epoch).TotalSeconds)
                $m = Measure-WgPeers -Handshakes $hs.Lines -Transfer $xf.Lines -AllowedIps $al.Lines -Now $now -MaxAge $MaxAge -Require $Require
                $WgV = $m.V; $WgTxt = $m.Txt
                foreach ($l in $m.Diag) { Add-Diag $l }
            }
        }
    }
}

Add-Diag "== settings: targets=$Total require=$Require count=$Count wait=${Wait}s wg=$(if ($WgTunnel) { $WgTunnel } else { 'none' }) max-handshake-age=${MaxAge}s"

# ---- Decide -----------------------------------------------------------------
$verdict = Get-Verdict -PingV $PingV -PingTxt $PingTxt -WgV $WgV -WgTxt $WgTxt -WgName $WgTunnel
Write-MonitorResult $verdict.Status $verdict.Code
