<#
.SYNOPSIS
    Parses and lints every component script under Applications/, Scripts/ and
    Monitors/ - test scripts in a component's folder included - whether or not
    the component has a test.json.

.DESCRIPTION
    Shell (.sh): bash -n, then shellcheck. Anything at warning level or above
    fails; notes and style hints are left out.

    PowerShell (.ps1): the PowerShell parser, then PSScriptAnalyzer. A parse
    error or an Error-severity rule fails, and so does any warning not already
    in tools/lint-baseline.txt. The baseline holds the warnings that predate
    it, keyed on file, rule and message (not line, so an edit elsewhere in the
    file does not shift it); fixing one and rerunning with -UpdateBaseline
    shrinks it.

    Conventions, per component folder: the name ends with its OS tags in
    order, the folder is the name's slug, a test.json runs on exactly the
    platforms the tags name, and the README has the sections every component
    needs. The name is component.json's, or the README title without one;
    with both, they must match.

    A deliberate exception is suppressed in the script itself, with the reason
    beside it - "# shellcheck disable=SCxxxx  # why", or a
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute] - so the reviewer sees
    it in the diff.

    Needs shellcheck and the PSScriptAnalyzer module. CI installs the versions
    pinned in .github/workflows/lint-components.yml.

.EXAMPLE
    pwsh tools/lint-components.ps1

.EXAMPLE
    pwsh tools/lint-components.ps1 -UpdateBaseline
    Rewrites tools/lint-baseline.txt to today's warnings. Use it after fixing
    warnings, never to wave a new one through: suppress that in the script
    with its reason instead.
#>
param([switch]$UpdateBaseline)
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

# Warnings as "file<TAB>rule<TAB>message", one per occurrence, so a second
# copy of a known warning in the same file still counts as new.
$baselineFile = 'tools/lint-baseline.txt'
$known = @{}
if (Test-Path $baselineFile) {
    foreach ($k in Get-Content $baselineFile) { if ($k) { $known[$k] = 1 + $(if ($known.ContainsKey($k)) { $known[$k] } else { 0 }) } }
}
$found = [System.Collections.Generic.List[string]]::new()
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
            $key = "$f`t$($d.RuleName)`t$("$($d.Message)" -replace '\s+', ' ')"
            $found.Add($key)
            if (-not $UpdateBaseline -and $known.ContainsKey($key) -and $known[$key] -gt 0) { $known[$key]--; $warnings++ }
            elseif (-not $UpdateBaseline) { Write-Failure $f $d.Line "new warning $($d.RuleName): $($d.Message) (fix it, or suppress it in the script with the reason)" }
        }
    }
}

# ---- Conventions (CONTRIBUTING.md "Naming", COMPONENT-README-TEMPLATE.md) ----
# The display name is component.json's general.name, or the README title when
# there is no manifest; where both exist they must agree. The folder is its
# slug, its OS tags match test.json's platforms, and the README has the
# sections every component needs.
$tagPlatform = [ordered]@{ Win = 'windows'; Mac = 'macos'; Lin = 'linux' }
$requiredSections = @('What it does', 'How to tell it worked')
$components = @($files | ForEach-Object { ($_ -split '/')[0..1] -join '/' } | Sort-Object -Unique |
    Where-Object { $_ -match '^[^/]+/[^/]+$' -and (Test-Path -LiteralPath $_ -PathType Container) })
foreach ($dir in $components) {
    $readme = "$dir/README.md"
    if (-not (Test-Path -LiteralPath $readme)) { Write-Failure $dir 1 "$dir has no README.md"; continue }
    $lines = @(Get-Content -LiteralPath $readme)
    $title = @($lines | Where-Object { $_ -match '^# \S' } | Select-Object -First 1) -replace '^# ', ''
    $name = "$title".Trim()
    $manifestFile = "$dir/component.json"
    if (Test-Path -LiteralPath $manifestFile) {
        $general = (Get-Content -Raw -LiteralPath $manifestFile | ConvertFrom-Json).PSObject.Properties['general']
        $named = if ($general) { $general.Value.PSObject.Properties['name'] } else { $null }
        if ($named -and "$($named.Value)" -cne $name) {
            Write-Failure $manifestFile 1 "$dir`: component.json names it '$($named.Value)' but the README title is '$name'; they must match"
        }
        if ($named) { $name = "$($named.Value)" }
    }
    if (-not $name) { Write-Failure $readme 1 "$dir`: README has no '# Component name' title"; continue }

    # Tags: one or more of [Win] [Mac] [Lin], space-separated, in that order, at the end.
    $tags = @()
    if ($name -cmatch '^\S.*?((?: \[(?:Win|Mac|Lin)\])+)$') { $tags = @([regex]::Matches($Matches[1], '\[(\w+)\]') | ForEach-Object { $_.Groups[1].Value }) }
    $inOrder = @($tagPlatform.Keys | Where-Object { $tags -contains $_ })
    if ($tags.Count -eq 0 -or ($tags -join ' ') -cne ($inOrder -join ' ')) {
        Write-Failure $readme 1 "$dir`: '$name' must end with its OS tags, each once, space-separated, in the order [Win] [Mac] [Lin]"
    }

    $slug = ($name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if ((Split-Path $dir -Leaf) -cne $slug) {
        Write-Failure $readme 1 "$dir`: the folder must be named '$slug', the slug of '$name'"
    }

    $specFile = "$dir/test.json"
    if ($tags.Count -and (Test-Path -LiteralPath $specFile)) {
        $spec = Get-Content -Raw -LiteralPath $specFile | ConvertFrom-Json
        $p = $spec.PSObject.Properties['platforms']; if (-not $p) { $p = $spec.PSObject.Properties['platform'] }
        $have = @(if ($p) { $p.Value }) | Sort-Object
        $want = @($inOrder | ForEach-Object { $tagPlatform[$_] }) | Sort-Object
        if (($have -join ',') -cne ($want -join ',')) {
            Write-Failure $specFile 1 "$dir`: test.json runs on [$($have -join ', ')] but the OS tags say [$($want -join ', ')]"
        }
    }

    foreach ($s in $requiredSections) {
        if (-not ($lines -cmatch "^## $([regex]::Escape($s))\s*$")) { Write-Failure $readme 1 "$dir`: README is missing the '## $s' section" }
    }
}

if ($UpdateBaseline) {
    $found | Sort-Object | Set-Content -Encoding utf8NoBOM $baselineFile
    Write-Host "Wrote $($found.Count) warning(s) to $baselineFile."
    $warnings = $found.Count
} else {
    $gone = @($known.Keys | Where-Object { $known[$_] -gt 0 })
    if ($gone.Count) { Write-Host "$($gone.Count) baseline warning(s) no longer occur; run with -UpdateBaseline to drop them from $baselineFile." }
}

Write-Host ''
Write-Host "Linted $($sh.Count) shell and $($ps.Count) PowerShell scripts, and the conventions of $($components.Count) components: $script:failures failure(s), $warnings known PowerShell warning(s) in $baselineFile."
if ($script:failures) { exit 1 }
exit 0
