# Runs one command described by a JSON job file, and records its exit code.
#
# Invoke-ComponentTest.ps1 hands this to a scheduled task so the command runs as
# another account (SYSTEM, or the local test user) without any quoting games.
# The job file carries: exe, args (one string, pre-quoted), workDir, env
# (name -> value), out, err, done. The exit code is written to `done` on every
# path, so the caller never waits on a job that died without saying so.

param([Parameter(Mandatory = $true)][string]$JobFile)

$job  = Get-Content -Raw -LiteralPath $JobFile | ConvertFrom-Json
$code = 999
try {
    if ($job.PSObject.Properties['env'] -and $job.env) {
        foreach ($p in $job.env.PSObject.Properties) {
            [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value, 'Process')
        }
    }
    $sp = @{
        FilePath               = $job.exe
        Wait                   = $true
        PassThru               = $true
        NoNewWindow            = $true
        RedirectStandardOutput = $job.out
        RedirectStandardError  = $job.err
        WorkingDirectory       = $job.workDir
    }
    if ($job.args) { $sp.ArgumentList = [string]$job.args }
    $p    = Start-Process @sp
    $code = $p.ExitCode
} catch {
    Add-Content -LiteralPath $job.err -Value ("harness: " + $_.Exception.Message)
    $code = 998
} finally {
    Set-Content -LiteralPath $job.done -Value $code
}
