# Proves what a stopped PowerShell monitor prints: nothing after the kill. Starts
# this monitor the way the harness does, pinging an address that never answers
# so it is mid-run, and stops the process after 5 seconds. Stop-Process is
# TerminateProcess: the monitor's trap never runs, so no result block appears.
# See "Killed monitors" in tools/test-harness/README.md.
#
# The harness runs this from a copy in its work root (the working directory).
# The monitor body is there too, in the run-NN folder an earlier runComponent
# step left, so this step must come after one.
$body = Get-ChildItem -Path (Join-Path $PWD 'run-*\connection-health-ping-targets-not-responding-win.ps1') |
    Select-Object -First 1
if (-not $body) { 'cannot find the monitor body under a run-* folder of ' + $PWD; exit 1 }

$out = Join-Path $PWD 'kill.out'
$env:usrTargets = '192.0.2.1'
$env:usrPingCount = '10'
$env:usrReplyTimeoutSec = '5'
$p = Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow `
    -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $body.FullName) `
    -RedirectStandardOutput $out -RedirectStandardError "$out.err"
Start-Sleep -Seconds 5
if ($p.HasExited) { 'the monitor finished before it could be stopped, so this proves nothing'; exit 1 }
Stop-Process -Id $p.Id -Force
$p.WaitForExit()

'process stopped, exit code ' + $p.ExitCode
$lines = @(Get-Content -LiteralPath $out, "$out.err")
$lines
'start markers: {0}, STATUS lines: {1}' -f @($lines | Where-Object { $_ -eq '<-Start Result->' }).Count,
    @($lines | Where-Object { $_ -like 'STATUS=*' }).Count
