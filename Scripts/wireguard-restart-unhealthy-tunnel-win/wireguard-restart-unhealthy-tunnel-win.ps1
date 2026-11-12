<#
.SYNOPSIS
    Datto RMM Script - WireGuard - Restart Unhealthy Tunnel [Win]

.DESCRIPTION
    Restarts a WireGuard for Windows tunnel, but only when that is warranted:

      1. It is unhealthy: its tunnel service is not running, or no peer has
         completed a handshake within usrHandshakeMaxAgeSec (the same test as
         the Connection Health monitor). usrMode=always skips this gate.
      2. It is meant to be running: its WireGuardTunnel$<name> service exists
         and is not Disabled. Deactivating a tunnel in the WireGuard app removes
         the service, so a missing service means a person turned it off; it
         stays off.
      3. It has not been restarted by this component within usrCooldownMin, so
         a monitor response cannot restart it in a loop. usrMode=always skips
         this gate.

    The restart stops and starts the tunnel service, which re-reads the
    tunnel's stored configuration. Afterwards it waits up to usrVerifySec for a
    peer to handshake, sending a ping into the tunnel to prompt one, and
    reports whether it did.

    Exit codes, each with a STATUS= line as the last line of output:
      0  HEALTHY          healthy; nothing done
      0  RESTARTED        restarted, and a peer handshaked afterwards
      1  STILL_UNHEALTHY  restarted, but no peer handshaked within usrVerifySec
      1  FAILED           a restart step failed, or wg.exe failed
      2  REFUSED          an input is invalid
      3  NOT_ACTIVE       no tunnel service, or it is Disabled: off on purpose; not started
      3  NO_PEERS         no peers configured; a restart cannot help
      3  COOLDOWN         restarted less than usrCooldownMin ago; not again
      3  NOT_INSTALLED    WireGuard for Windows is not installed

    Reads WireGuard state only with `wg.exe show <tunnel> latest-handshakes`
    and `allowed-ips`; never prints keys. Writes one file:
    %ProgramData%\TechCollective\WireGuard\restart-<tunnel>.last, the time of
    its last restart.

.NOTES
    Category: Scripts | Script type: PowerShell | Runs as: SYSTEM
    PowerShell 2.0-compatible.
    Source: https://github.com/TechCollective/DattoRMM_Components
#>

$ErrorActionPreference = 'Stop'
$script:Finished = $false

function Finish {
    param([int]$Code, [string]$Status, [string]$Message)
    Write-Output $Message
    Write-Output "STATUS=$Status"
    $script:Finished = $true
    exit $Code
}

trap {
    if (-not $script:Finished) {
        Write-Output ("The script stopped unexpectedly (" + ($_.Exception.Message -replace '[\r\n]+', ' ') + "). The tunnel may be mid-restart: check it.")
        Write-Output 'STATUS=FAILED'
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
function Refuse { param([string]$Why) Finish 2 'REFUSED' "Refused: $Why" }

function Format-Age {
    param([long]$s)
    if ($s -lt 120)    { return "${s}s" }
    if ($s -lt 7200)   { return "$([math]::Floor($s / 60))m" }
    if ($s -lt 172800) { return "$([math]::Floor($s / 3600))h" }
    return "$([math]::Floor($s / 86400))d"
}

function Get-UnixNow {
    $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [long][math]::Floor(([DateTime]::UtcNow - $epoch).TotalSeconds)
}

# Decides peer health from `wg show <tunnel> latest-handshakes` lines. A peer is
# current when it handshaked within MaxAge seconds, or, when Since is above 0,
# at or after Since. Returns @{ State = healthy|unhealthy|nopeers|error; Reason }.
function Measure-Handshakes {
    param([string[]]$Lines, [long]$Now, [int]$MaxAge, [long]$Since)
    $n = 0; $ok = 0; $parts = @()
    foreach ($line in $Lines) {
        if ($line -eq $null -or "$line".Trim() -eq '') { continue }
        $f = "$line".Split("`t"); $ts = 0L
        if ($f.Count -ne 2 -or $f[1] -notmatch '^[0-9]+$' -or -not [long]::TryParse($f[1], [ref]$ts)) {
            return @{ State = 'error'; Reason = 'unexpected output from wg show latest-handshakes' }
        }
        $n++
        if ($ts -eq 0) { $parts += "peer $n never"; continue }
        $age = $Now - $ts; if ($age -lt 0) { $age = 0 }
        $parts += "peer $n $(Format-Age $age) ago"
        if ($Since -gt 0) { if ($ts -ge $Since) { $ok++ } }
        elseif ($age -le $MaxAge) { $ok++ }
    }
    if ($n -eq 0) { return @{ State = 'nopeers'; Reason = 'the tunnel has no peers configured' } }
    $detail = [string]::Join(', ', $parts)
    if ($Since -gt 0) {
        if ($ok -ge 1) { return @{ State = 'healthy';   Reason = "$ok of $n peer(s) handshaked since the restart ($detail)" } }
        return              @{ State = 'unhealthy'; Reason = "no peer has handshaked since the restart ($detail)" }
    }
    if ($ok -ge 1) { return @{ State = 'healthy';   Reason = "$ok of $n peer(s) handshaked within ${MaxAge}s ($detail)" } }
    return              @{ State = 'unhealthy'; Reason = "no peer has handshaked within ${MaxAge}s ($detail)" }
}

# Addresses to ping after a restart: the first address of each peer's first
# IPv4 allowed-ips range, skipping a 0.0.0.0/0 default route. Any packet routed
# into the tunnel makes WireGuard start a handshake, answered or not.
function Get-NudgeTargets {
    param([string[]]$AllowedIps)
    $out = @()
    foreach ($line in $AllowedIps) {
        $f = "$line".Split("`t"); if ($f.Count -lt 2) { continue }
        foreach ($r in $f[1].Split(' ')) {
            if ($r -notmatch '^(\d+)\.(\d+)\.(\d+)\.(\d+)/(\d+)$' -or $Matches[5] -eq '0') { continue }
            if ($Matches[5] -eq '32') { $out += "$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])" }
            else { $out += "$($Matches[1]).$($Matches[2]).$($Matches[3]).$([int]$Matches[4] + 1)" }
            break
        }
    }
    return $out
}

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
    param([string]$Exe, [string]$Tunnel, [string]$Field)
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe show $Tunnel $Field 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $eap }
    return @{ Code = $code; Lines = $out }
}

function Get-StartMode {
    param([string]$Name)
    $filter = "Name='" + $Name + "'"
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $s = Get-CimInstance -ClassName Win32_Service -Filter $filter -ErrorAction SilentlyContinue
    } else {
        $s = Get-WmiObject -Class Win32_Service -Filter $filter -ErrorAction SilentlyContinue
    }
    if ($s) { return "$($s.StartMode)" }
    return ''
}

# ---- Inputs ---------------------------------------------------------------
$Tunnel    = Get-Input 'usrWgTunnel' ''
# A drop-down passes its value (ifunhealthy); accept the display name too (If unhealthy).
$Mode      = (Get-Input 'usrMode' 'ifunhealthy').ToLower() -replace ' ', ''
$MaxAgeRaw = Get-Input 'usrHandshakeMaxAgeSec' '300'
$VerifyRaw = Get-Input 'usrVerifySec' '30'
$CoolRaw   = Get-Input 'usrCooldownMin' '15'
$PingT     = Get-Input 'usrPingTarget' ''

if ($Tunnel -eq '') { Refuse 'usrWgTunnel is empty; set the WireGuard tunnel name as the WireGuard app shows it' }
if ($Tunnel -cnotmatch '^[A-Za-z0-9_=+.-]{1,32}$' -or $Tunnel.StartsWith('-')) { Refuse "usrWgTunnel '$(Short $Tunnel 40)' is not a valid WireGuard tunnel name" }
if ($Mode -ne 'ifunhealthy' -and $Mode -ne 'always') { Refuse "usrMode must be ifunhealthy or always (got '$(Short $Mode 40)')" }
$MaxAge = 0
if ($MaxAgeRaw -notmatch '^[0-9]+$' -or -not [int]::TryParse($MaxAgeRaw, [ref]$MaxAge) -or $MaxAge -lt 150 -or $MaxAge -gt 3600) { Refuse "usrHandshakeMaxAgeSec must be 150-3600 (got '$(Short $MaxAgeRaw 40)')" }
$Verify = 0
if ($VerifyRaw -notmatch '^[0-9]+$' -or -not [int]::TryParse($VerifyRaw, [ref]$Verify) -or $Verify -lt 10 -or $Verify -gt 120) { Refuse "usrVerifySec must be 10-120 (got '$(Short $VerifyRaw 40)')" }
$Cooldown = 0
if ($CoolRaw -notmatch '^[0-9]+$' -or -not [int]::TryParse($CoolRaw, [ref]$Cooldown) -or $Cooldown -gt 1440) { Refuse "usrCooldownMin must be 0-1440 (got '$(Short $CoolRaw 40)')" }
if ($PingT -ne '' -and ($PingT -notmatch '^[A-Za-z0-9:][A-Za-z0-9.:-]*$' -or $PingT.Length -gt 253)) { Refuse "usrPingTarget '$(Short $PingT 60)' is not an IP address or hostname" }

# ---- Is it installed, and meant to be running? --------------------------------
$SvcName = 'WireGuardTunnel$' + $Tunnel
$Svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
$WgExe = Find-WgExe
if (-not $Svc -and $WgExe -eq '') {
    Finish 3 'NOT_INSTALLED' 'WireGuard for Windows is not installed on this machine; there is no tunnel to restart.'
}
if (-not $Svc) {
    Finish 3 'NOT_ACTIVE' "Tunnel '$Tunnel' is not active: there is no $SvcName service, so it was deactivated in the WireGuard app or the name is wrong. Not activated. To bring it up, activate it in the WireGuard app."
}
if ($WgExe -eq '') {
    Finish 1 'FAILED' "The $SvcName service exists but wg.exe was not found, so the tunnel's health cannot be read. Not touched."
}

# ---- Health -------------------------------------------------------------------
function Get-TunnelHealth {
    param([long]$Since)
    $Svc.Refresh()
    if ($Svc.Status -ne 'Running') { return @{ State = 'unhealthy'; Reason = "the $SvcName service is $($Svc.Status)"; Running = $false } }
    $hs = Invoke-WgShow $WgExe $Tunnel 'latest-handshakes'
    if ($hs.Code -ne 0) {
        $why = ''; foreach ($l in $hs.Lines) { if ("$l".Trim() -ne '') { $why = "$l".Trim() } }
        return @{ State = 'error'; Reason = "wg show failed (exit $($hs.Code)): $(Short $why 200)"; Running = $true }
    }
    $m = Measure-Handshakes -Lines $hs.Lines -Now (Get-UnixNow) -MaxAge $MaxAge -Since $Since
    return @{ State = $m.State; Reason = $m.Reason; Running = $true }
}

$h = Get-TunnelHealth 0
Write-Output "Before: $($h.Reason)."
if ($h.State -eq 'error')   { Finish 1 'FAILED' "Could not read the tunnel's state: $($h.Reason). Not touched." }
if ($h.State -eq 'nopeers') { Finish 3 'NO_PEERS' "Tunnel '$Tunnel' has no peers configured, so a restart cannot bring it up. Fix its configuration." }
if ($h.State -eq 'healthy' -and $Mode -eq 'ifunhealthy') { Finish 0 'HEALTHY' "Tunnel '$Tunnel' is healthy; nothing to do." }

$StartMode = Get-StartMode $SvcName
if ($StartMode -eq 'Disabled') {
    Finish 3 'NOT_ACTIVE' "The $SvcName service is Disabled, so the tunnel was turned off on purpose. Not started."
}

# ---- Cooldown -----------------------------------------------------------------
$StateDir = Join-Path $env:ProgramData 'TechCollective\WireGuard'
$Stamp = Join-Path $StateDir "restart-$Tunnel.last"
$Now = Get-UnixNow
if ($Mode -eq 'ifunhealthy' -and $Cooldown -gt 0 -and (Test-Path -LiteralPath $Stamp)) {
    $last = 0L
    $raw = "$(Get-Content -LiteralPath $Stamp -TotalCount 1 -ErrorAction SilentlyContinue)".Trim()
    if ([long]::TryParse($raw, [ref]$last)) {
        $since = $Now - $last
        if ($since -ge 0 -and $since -lt ($Cooldown * 60)) {
            Finish 3 'COOLDOWN' "Tunnel '$Tunnel' was restarted by this component $(Format-Age $since) ago; the cooldown is $Cooldown minutes. Not restarted again. If restarts are not fixing it, the cause is elsewhere (far side, ISP, config)."
        }
    }
}

# ---- Restart ------------------------------------------------------------------
try {
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    Set-Content -LiteralPath $Stamp -Value "$Now" -Encoding ASCII
} catch {
    Write-Output "Warning: could not write $Stamp; the cooldown will not apply to the next run."
}

$wait = [TimeSpan]::FromSeconds(30)
Write-Output "Restarting the $SvcName service..."
$Svc.Refresh()
if ($Svc.Status -ne 'Stopped') {
    try {
        if ($Svc.Status -ne 'StopPending') { $Svc.Stop() }
        $Svc.WaitForStatus('Stopped', $wait)
    } catch {
        Finish 1 'FAILED' "Stopping $SvcName failed: $(($_.Exception.Message -replace '[\r\n]+', ' ')). Its state is now $(try { $Svc.Refresh(); $Svc.Status } catch { 'unknown' })."
    }
}
try {
    $Svc.Start()
    $Svc.WaitForStatus('Running', $wait)
} catch {
    Finish 1 'FAILED' "Starting $SvcName failed: $(($_.Exception.Message -replace '[\r\n]+', ' ')). THE TUNNEL IS DOWN. Check the WireGuard app's log."
}

# ---- Verify -------------------------------------------------------------------
if ($PingT -ne '') { $Nudge = @($PingT) }
else { $Nudge = @(Get-NudgeTargets (Invoke-WgShow $WgExe $Tunnel 'allowed-ips').Lines) }
if ($Nudge.Count -gt 0) { Write-Output "Waiting up to ${Verify}s for a handshake (prompting with ping to $([string]::Join(' ', $Nudge)))..." }
else { Write-Output "Waiting up to ${Verify}s for a handshake..." }

$Pinger = New-Object System.Net.NetworkInformation.Ping
$deadline = (Get-UnixNow) + $Verify
while ($true) {
    foreach ($t in $Nudge) { try { [void]$Pinger.Send($t, 1000) } catch { } }
    $h = Get-TunnelHealth $Now
    if ($h.State -eq 'healthy' -or (Get-UnixNow) -ge $deadline) { break }
    Start-Sleep -Seconds 2
}

Write-Output "After: $($h.Reason)."
if ($h.State -eq 'healthy') { Finish 0 'RESTARTED' "Tunnel '$Tunnel' restarted and a peer handshaked $((Get-UnixNow) - $Now)s later." }
if (-not $h.Running)        { Finish 1 'FAILED' "Tunnel '$Tunnel' was restarted but its service is not running." }
Finish 1 'STILL_UNHEALTHY' "Tunnel '$Tunnel' restarted, but no peer handshaked within ${Verify}s. The far side may be down or unreachable, or nothing sent traffic: set usrPingTarget to a far-side address, or PersistentKeepalive on the peer."
