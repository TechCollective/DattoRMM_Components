<#
.SYNOPSIS
    Tests the test harness: runs it on fixture components whose right answer is
    known, and fails when the harness passes something it should fail, or the
    other way round.

.DESCRIPTION
    Runs Invoke-ComponentTest.ps1 on Windows and invoke-component-test.sh on
    macOS and Linux, once per case below, each time against a temporary copy of
    this platform's fixture with the case's steps written as its test.json.

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

# Each case: the category the fixture is saved as, the test.json steps, and
# what the harness must conclude. Says is text a failing run must show, so a
# failure for some other reason does not count as the right answer. After, if
# given, runs once the harness is done and returns what is wrong, or ''.
# Platform limits a case to one platform.
function Get-RunCase([string]$Name, [string]$Blocks, [string]$Category, [bool]$Pass, [string]$Says = '') {
    @{ Name = $Name; Category = $Category; Pass = $Pass; Says = $Says
       Steps = @(@{ type = 'runComponent'; variables = @{ fixtureBlocks = $Blocks } }) }
}
function Get-CommandCase([string]$Name, [hashtable]$Step, [string]$Says, [scriptblock]$After = $null) {
    @{ Name = $Name; Category = 'scripts'; Pass = $false; Says = $Says; Platform = 'windows'; After = $After
       Steps = @(@{ type = 'command' } + $Step) }
}

$monitorRule = "exactly one result block"
$planted = 'C:\ProgramData\tc-harness-selftest'
$cases = @(
    Get-RunCase 'Monitor, one result block'           'one'      'monitors' $true
    Get-RunCase 'Monitor, diagnostic then one result' 'diag'     'monitors' $true
    Get-RunCase 'Monitor, no result block'            'zero'     'monitors' $false "$monitorRule, found 0 start and 0 end markers"
    Get-RunCase 'Monitor, two result blocks'          'two'      'monitors' $false "$monitorRule, found 2 start and 2 end markers"
    Get-RunCase 'Monitor, result block never closed'  'unclosed' 'monitors' $false "$monitorRule, found 1 start and 0 end markers"
    Get-RunCase 'Script, no result block is fine'     'zero'     'scripts'  $true

    # Windows command step: plant state as each identity, and check it.
    @{ Name = 'Windows command: plant and check, as SYSTEM, the test user and the runner'; Category = 'scripts'; Pass = $true; Platform = 'windows'
       Steps = @(
        @{ type = 'command'; label = 'Plant a key and a file as SYSTEM'; outputContains = @('nt authority\system')
           run = "New-Item -Force -Path 'HKLM:\SOFTWARE\TCHarnessSelfTest' | Out-Null; Set-ItemProperty -Path 'HKLM:\SOFTWARE\TCHarnessSelfTest' -Name Planted -Value yes; New-Item -ItemType Directory -Force '$planted' | Out-Null; Set-Content '$planted\planted.txt' x; whoami" }
        @{ type = 'registry'; path = 'HKLM:\SOFTWARE\TCHarnessSelfTest'; name = 'Planted'; equals = 'yes' }
        @{ type = 'file'; path = '%ProgramData%\tc-harness-selftest\planted.txt' }
        @{ type = 'command'; as = 'testuser'; label = 'Plant a file as the test user'; outputContains = @('tctest')
           run = 'Set-Content "$env:LOCALAPPDATA\tc-planted.txt" x; whoami' }
        @{ type = 'file'; as = 'testuser'; path = '%LOCALAPPDATA%\tc-planted.txt' }
        @{ type = 'command'; as = 'runner'; outputContains = @($env:USERNAME); run = 'whoami' }
        @{ type = 'command'; label = 'A non-zero exit and stderr, as expected'; expectExitCode = 3
           outputContains = @('to stderr'); outputNotContains = @('never printed'); run = "Write-Error 'to stderr'; exit 3" }
    ) }
    Get-CommandCase 'Windows command: wrong exit code'      @{ run = 'exit 3' } 'Exit code 3, expected 0'
    Get-CommandCase 'Windows command: missing output'      @{ run = "'hello'"; outputContains = @('goodbye') } 'output is missing: goodbye'
    Get-CommandCase 'Windows command: unwanted output'     @{ run = "'hello'"; outputNotContains = @('HELLO') } 'output should not contain: HELLO'
    Get-CommandCase 'Windows command: timeout stops it'    @{ timeoutSeconds = 15
        run = "New-Item -ItemType Directory -Force '$planted' | Out-Null; `$PID | Set-Content '$planted\sleeper.pid'; Start-Sleep -Seconds 300" } `
        'Timed out after 15s' {
            $id = [int](Get-Content -Raw "$planted\sleeper.pid")
            if (Get-Process -Id $id -ErrorAction SilentlyContinue) { "the timed-out command (process $id) is still running" } else { '' }
        }
)
$cases = @($cases | Where-Object { -not $_.ContainsKey('Platform') -or $_.Platform -eq $platform })

# The harness's own CI behaviour (annotations, the step summary) is for real
# components. A case expected to fail must not paint the pull request red.
$saved = @{ GITHUB_ACTIONS = $env:GITHUB_ACTIONS; GITHUB_STEP_SUMMARY = $env:GITHUB_STEP_SUMMARY }
$env:GITHUB_ACTIONS = $null
$env:GITHUB_STEP_SUMMARY = $null
$env:ALLOW_LOCAL = '1'

$wrong = 0
try {
    foreach ($c in $cases) {
        $dir = Join-Path $work ($c.Name -replace '[^A-Za-z0-9]+', '-')
        if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        Copy-Item -Recurse $fixture $dir

        $manifestFile = Join-Path $dir 'component.json'
        $manifest = Get-Content -Raw $manifestFile | ConvertFrom-Json
        $manifest.general.category = $c.Category
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Encoding ASCII $manifestFile
        @{ platforms = @($platform); steps = $c.Steps } | ConvertTo-Json -Depth 10 | Set-Content -Encoding ASCII (Join-Path $dir 'test.json')

        if ($platform -eq 'windows') {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $harnessDir 'Invoke-ComponentTest.ps1') -ComponentPath $dir -AllowLocal 2>&1 | Out-String
        } else {
            $out = & bash (Join-Path $harnessDir 'invoke-component-test.sh') $dir 2>&1 | Out-String
        }
        $passed = $LASTEXITCODE -eq 0

        $right = ($passed -eq $c.Pass) -and ($c.Pass -or $out.Contains($c.Says))
        if ($right -and $c.ContainsKey('After') -and $c.After) {
            $afterProblem = & $c.After
            if ($afterProblem) { $right = $false; $out += "`nAfter the run: $afterProblem" }
        }
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
