<#
.SYNOPSIS
    Datto RMM Monitor - Connection Health - Ping Targets Not Responding [Win]

.DESCRIPTION
    Pings one or more hosts (typically the far side of a site-to-site tunnel)
    and alerts when the connection looks down:

      usrRequire = any   alert only when no target replies (default)
      usrRequire = all   alert when any target does not reply

    This version is a generic reachability check and knows nothing about the
    tunnel technology. WireGuard-specific checks are planned for this same
    component, not a new one.

    Uses System.Net.NetworkInformation.Ping rather than ping.exe: ping.exe output
    is localised, and it exits 0 when a router answers "Destination host
    unreachable", which would report a dead tunnel as healthy.

    Not knowing is treated as a fault: bad input, ping failing outright on every
    target, or the script dying all exit 1 with "Check could not run".

    Exit 0 = healthy, Exit 1 = alert. Read-only; changes nothing. Sends ICMP
    echo requests to the configured targets only.

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

# ---- Inputs ---------------------------------------------------------------
$MaxTargets = 8

$TargetsRaw = Get-Input 'usrTargets' ''
$Require    = (Get-Input 'usrRequire' 'any').ToLower()
$CountRaw   = Get-Input 'usrPingCount' '3'
$WaitRaw    = Get-Input 'usrReplyTimeoutSec' '2'

if ($TargetsRaw -eq '') { Write-MonitorResult 'Check could not run: usrTargets is empty; set the address(es) to ping' 1 }
$Targets = @($TargetsRaw -split '[\s,]+' | Where-Object { $_ -ne '' })
if ($Targets.Count -lt 1) { Write-MonitorResult 'Check could not run: usrTargets is empty; set the address(es) to ping' 1 }
if ($Targets.Count -gt $MaxTargets) { Write-MonitorResult "Check could not run: usrTargets has $($Targets.Count) entries; the most allowed is $MaxTargets" 1 }
foreach ($t in $Targets) {
    if ($t -notmatch '^[A-Za-z0-9:][A-Za-z0-9.:-]*$' -or $t.Length -gt 253) {
        Write-MonitorResult "Check could not run: usrTargets entry '$(Short $t 60)' is not an IP address or hostname" 1
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
# Pings are sequential: a reply is followed by a 1 s pause, a miss waits the full
# timeout. Worst case per target is therefore count x max(wait, 1) seconds.
$Worst = $Targets.Count * $Count * $Wait
if ($Worst -gt 120) {
    Write-MonitorResult "Check could not run: $($Targets.Count) targets x $Count pings x ${Wait}s could take ${Worst}s; keep it to 120s or less" 1
}
$TimeoutMs = $Wait * 1000

# ---- Ping each target -------------------------------------------------------
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
            # a missing or unreachable route is the tunnel being down; anything
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

$Total  = $Targets.Count
$Noun   = 'targets'; if ($Total -eq 1) { $Noun = 'target' }
$Detail = [string]::Join('; ', $Summary.ToArray())
Add-Diag "== settings: targets=$Total require=$Require count=$Count wait=${Wait}s"

# ---- Decide -----------------------------------------------------------------
if ($Errors -eq $Total) {
    Write-MonitorResult "Check could not run: ping failed on every target ($FirstError)" 1
}

if ($Require -eq 'any') {
    if ($Up -ge 1) { Write-MonitorResult "Connection up: $Up of $Total $Noun replied ($Detail)" 0 }
    Write-MonitorResult "Connection down: 0 of $Total $Noun replied ($Detail)" 1
}

if ($Up -eq $Total) { Write-MonitorResult "Connection up: all $Total $Noun replied ($Detail)" 0 }
if ($Up -eq 0)      { Write-MonitorResult "Connection down: 0 of $Total $Noun replied ($Detail)" 1 }
Write-MonitorResult "Connection degraded: $($Total - $Up) of $Total targets did not reply and all are required ($Detail)" 1
