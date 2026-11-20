<#
.SYNOPSIS
    Tests the test harness: runs it on fixture components whose right answer is
    known, and fails when the harness passes something it should fail, or the
    other way round.

.DESCRIPTION
    Runs Invoke-ComponentTest.ps1 on Windows and invoke-component-test.sh on
    macOS and Linux, once per case below, each time against a temporary copy of
    this platform's fixture with a one-step test.json written for that case.

    Like the harness, it belongs on a disposable machine: GitHub Actions, or a
    throwaway VM or container.

.EXAMPLE
    pwsh tools/test-harness/self-test/Invoke-HarnessSelfTest.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$harnessDir = Split-Path $PSScriptRoot -Parent
$platform   = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
$fixture    = Join-Path $PSScriptRoot $(if ($platform -eq 'windows') { 'monitor-win' } else { 'monitor-lin' })
$work       = Join-Path ([IO.Path]::GetTempPath()) 'harness-self-test'

# Each case: what the fixture prints, the category it is saved as, and what the
# harness must conclude. Says is text a failing run must show, so a failure for
# some other reason does not count as the right answer.
$monitorRule = "exactly one result block"
$cases = @(
    @{ Name = 'Monitor, one result block';             Blocks = 'one';      Category = 'monitors'; Pass = $true }
    @{ Name = 'Monitor, diagnostic then one result';   Blocks = 'diag';     Category = 'monitors'; Pass = $true }
    @{ Name = 'Monitor, no result block';              Blocks = 'zero';     Category = 'monitors'; Pass = $false; Says = "$monitorRule, found 0 start and 0 end markers" }
    @{ Name = 'Monitor, two result blocks';            Blocks = 'two';      Category = 'monitors'; Pass = $false; Says = "$monitorRule, found 2 start and 2 end markers" }
    @{ Name = 'Monitor, result block never closed';    Blocks = 'unclosed'; Category = 'monitors'; Pass = $false; Says = "$monitorRule, found 1 start and 0 end markers" }
    @{ Name = 'Script, no result block is fine';       Blocks = 'zero';     Category = 'scripts';  Pass = $true }
)

# The harness's own CI behaviour (annotations, the step summary) is for real
# components. A case expected to fail must not paint the pull request red.
$saved = @{ GITHUB_ACTIONS = $env:GITHUB_ACTIONS; GITHUB_STEP_SUMMARY = $env:GITHUB_STEP_SUMMARY }
$env:GITHUB_ACTIONS = $null
$env:GITHUB_STEP_SUMMARY = $null
$env:ALLOW_LOCAL = '1'

$wrong = 0
try {
    foreach ($c in $cases) {
        $dir = Join-Path $work ($c.Blocks + '-' + $c.Category)
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        Copy-Item -Recurse $fixture $dir

        $manifestFile = Join-Path $dir 'component.json'
        $manifest = Get-Content -Raw $manifestFile | ConvertFrom-Json
        $manifest.general.category = $c.Category
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Encoding ASCII $manifestFile
        @{
            platforms = @($platform)
            steps     = @(@{ type = 'runComponent'; variables = @{ fixtureBlocks = $c.Blocks } })
        } | ConvertTo-Json -Depth 10 | Set-Content -Encoding ASCII (Join-Path $dir 'test.json')

        if ($platform -eq 'windows') {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $harnessDir 'Invoke-ComponentTest.ps1') -ComponentPath $dir -AllowLocal 2>&1 | Out-String
        } else {
            $out = & bash (Join-Path $harnessDir 'invoke-component-test.sh') $dir 2>&1 | Out-String
        }
        $passed = $LASTEXITCODE -eq 0

        $right = ($passed -eq $c.Pass) -and ($c.Pass -or $out.Contains($c.Says))
        if ($right) {
            Write-Host "[OK]    $($c.Name): harness $(if ($passed) { 'passed' } else { 'failed' }) it, as it should."
        } else {
            $wrong++
            $want = if ($c.Pass) { 'pass' } else { "fail saying: $($c.Says)" }
            Write-Host "[WRONG] $($c.Name): harness $(if ($passed) { 'passed' } else { 'failed' }) it; it should $want."
            Write-Host $out
        }
    }
} finally {
    $env:GITHUB_ACTIONS = $saved.GITHUB_ACTIONS
    $env:GITHUB_STEP_SUMMARY = $saved.GITHUB_STEP_SUMMARY
    $env:ALLOW_LOCAL = $null
}

Write-Host ''
Write-Host "Harness self-test on ${platform}: $($cases.Count - $wrong) right, $wrong wrong."
if ($wrong) { exit 1 }
exit 0
