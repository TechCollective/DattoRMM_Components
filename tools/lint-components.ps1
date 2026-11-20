<#
.SYNOPSIS
    Parses and lints every component script under Applications/, Scripts/ and
    Monitors/ - test scripts in a component's folder included - whether or not
    the component has a test.json.

.DESCRIPTION
    Shell (.sh): bash -n, then shellcheck. Anything at warning level or above
    fails; notes and style hints are left out.

    PowerShell (.ps1): the PowerShell parser, then PSScriptAnalyzer. A parse
    error or an Error-severity rule fails; warnings are listed but do not fail.

    A deliberate exception is suppressed in the script itself, with the reason
    beside it - "# shellcheck disable=SCxxxx  # why", or a
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute] - so the reviewer sees
    it in the diff.

    Needs shellcheck and the PSScriptAnalyzer module. CI installs the versions
    pinned in .github/workflows/lint-components.yml.

.EXAMPLE
    pwsh tools/lint-components.ps1
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

Set-Location (git rev-parse --show-toplevel)
$inCI = $env:GITHUB_ACTIONS -eq 'true'

if (-not (Get-Command shellcheck -ErrorAction SilentlyContinue)) { throw 'shellcheck is not installed.' }
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { throw 'PSScriptAnalyzer is not installed: Install-Module PSScriptAnalyzer -Scope CurrentUser' }

# Tracked files, and new ones not yet committed, so a local run sees a
# component before its first commit.
$files = @(git ls-files --cached --others --exclude-standard -- Applications Scripts Monitors | Sort-Object -Unique)
$sh = @($files | Where-Object { $_ -like '*.sh' })
$ps = @($files | Where-Object { $_ -like '*.ps1' })

$script:failures = 0
function Write-Failure([string]$File, [int]$Line, [string]$Message) {
    $script:failures++
    if ($inCI) { Write-Host "::error file=$File,line=$Line::$Message" } else { Write-Host "${File}:${Line}: $Message" }
}

foreach ($f in $sh) {
    $out = & bash -n $f 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Failure $f 1 ("does not parse: " + $out.Trim()) }
}
if ($sh.Count) {
    & shellcheck --severity=warning --format=gcc $sh 2>&1 | ForEach-Object {
        if ("$_" -match '^(.+?):(\d+):\d+: (.*)$') { Write-Failure $Matches[1] ([int]$Matches[2]) $Matches[3] } else { Write-Host $_ }
    }
    # 1 is "found something", reported above. 2 and up is shellcheck itself
    # failing (a file it could not read, bad options), which reports nothing
    # in that form and must not read as a clean run.
    if ($LASTEXITCODE -gt 1) { Write-Failure $sh[0] 1 "shellcheck could not run (exit $LASTEXITCODE); see its output above" }
}

$warnings = 0
foreach ($f in $ps) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f).Path, [ref]$null, [ref]$errors)
    foreach ($e in @($errors)) { Write-Failure $f $e.Extent.StartLineNumber ("does not parse: " + $e.Message) }
    if (@($errors).Count) { continue }

    foreach ($d in @(Invoke-ScriptAnalyzer -Path $f)) {
        if ("$($d.Severity)" -in 'Error', 'ParseError') {
            Write-Failure $f $d.Line "$($d.RuleName): $($d.Message)"
        } elseif ("$($d.Severity)" -eq 'Warning') {
            $warnings++
            Write-Host "${f}:$($d.Line): warning $($d.RuleName): $($d.Message)"
        }
    }
}

Write-Host ''
Write-Host "Linted $($sh.Count) shell and $($ps.Count) PowerShell scripts: $script:failures failure(s), $warnings PowerShell warning(s) listed above."
if ($script:failures) { exit 1 }
exit 0
