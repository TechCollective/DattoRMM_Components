<#
.SYNOPSIS
    Tier 1 test for a Windows Datto RMM component: run it the way Datto would,
    then check that it did what its test.json says it should.

.DESCRIPTION
    Reads <component>/component.json (the body, the timeout and the input
    variables' defaults) and <component>/test.json (the steps to run), and
    works through the steps in order. Exits 1 if any step fails.

    The component runs as SYSTEM through a scheduled task, with its input
    variables as environment variables and its attachments (files/) in the
    working directory - the same shape Datto gives it.

    Steps that need a user run as a local standard user the harness creates,
    also through a scheduled task. That is how a per-user install (Active
    Setup, a logon script) is exercised without an interactive logon, which a
    CI runner cannot do.

    This is built for DISPOSABLE machines - GitHub-hosted runners. It creates a
    local account, registers scheduled tasks and leaves behind whatever the
    component installed. It refuses to run outside GitHub Actions unless given
    -AllowLocal, and even then only use it on a VM you are about to throw away.

    The test.json format is documented in tools/test-harness/README.md.

.EXAMPLE
    ./tools/test-harness/Invoke-ComponentTest.ps1 -ComponentPath Applications/google-iap-desktop-win
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ComponentPath,
    [string]$WorkRoot,
    [switch]$AllowLocal
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# ---------------------------------------------------------------- guard rails

if ($env:GITHUB_ACTIONS -ne 'true' -and -not $AllowLocal) {
    throw 'This harness creates a local user and changes the machine. It only runs in GitHub Actions unless -AllowLocal is given - and then only on a throwaway VM.'
}
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run elevated: the harness registers scheduled tasks and creates a local user.'
}

$InCI         = $env:GITHUB_ACTIONS -eq 'true'
$HarnessDir   = $PSScriptRoot
$JobRunner    = Join-Path $HarnessDir 'Invoke-Job.ps1'
$ComponentPath = (Resolve-Path -LiteralPath $ComponentPath).Path

if (-not $WorkRoot) {
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
    $WorkRoot = Join-Path $base 'component-test'
}
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
# SYSTEM and the test user both write their output here. *S-1-1-0 is Everyone.
& icacls.exe $WorkRoot /grant '*S-1-1-0:(OI)(CI)M' | Out-Null

# ---------------------------------------------------------------- helpers

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

$script:Results  = New-Object System.Collections.ArrayList
$script:StepNo   = 0
$script:TestUser = $null

function Add-Result {
    param([string]$Step, [bool]$Pass, [string]$Detail, [switch]$Skip)
    [void]$script:Results.Add([pscustomobject]@{ Step = $Step; Pass = $Pass; Skip = [bool]$Skip; Detail = $Detail })
    $mark = if ($Skip) { 'SKIP' } elseif ($Pass) { 'PASS' } else { 'FAIL' }
    Write-Host "[$mark] $Step - $Detail"
    if (-not $Pass -and $InCI) {
        $clean = ($Detail -replace '[\r\n]+', ' ')
        Write-Host "::error title=${Step}::${clean}"
    }
}

# Output blocks fold away in the Actions log. Diagnostics use -Open so they
# show without clicking, and survive a copy-paste of the log.
function Write-Block {
    param([string]$Title, [string]$Text, [switch]$Open)
    $fold = $InCI -and -not $Open
    if ($fold) { Write-Host "::group::$Title" } else { Write-Host "----- $Title" }
    if ($Text) { Write-Host $Text.TrimEnd() } else { Write-Host '(empty)' }
    if ($fold) { Write-Host '::endgroup::' } else { Write-Host "----- end $Title" }
}

# The useful part of a verbose msiexec log: its error lines and its tail.
function Show-MsiLog {
    param([string]$Path)
    $text = Read-Text $Path
    if (-not $text) { Write-Host "No install log at $Path"; return }
    $lines = $text -split "`r?`n"
    $hits  = $lines | Select-String -Pattern 'Return value 3', 'error', '1601', 'Note: 1: ' | Select-Object -First 40 | ForEach-Object { $_.Line }
    Write-Block "Install log, error lines: $Path" (($hits | Out-String)) -Open
    Write-Block "Install log, last 25 lines: $Path" (($lines | Select-Object -Last 25) -join "`n") -Open
}

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [IO.File]::ReadAllText($Path) }
    return ''
}

# Run a command as SYSTEM or as the test user through a scheduled task.
# Returns @{ Code; Out; Err; TimedOut }. With -NoWait, returns the task name
# and the path of its done-file instead, and leaves the command running.
function Invoke-As {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Arguments = '',
        [string]$WorkDir = $WorkRoot,
        [hashtable]$Environment = @{},
        [ValidateSet('system', 'testuser')][string]$As = 'system',
        [int]$TimeoutSeconds = 600,
        [switch]$NoWait
    )
    $script:StepNo++
    $id   = '{0:D2}-{1}' -f $script:StepNo, ($Label -replace '[^A-Za-z0-9]+', '-')
    $jobF = Join-Path $WorkRoot "$id.job.json"
    $out  = Join-Path $WorkRoot "$id.out.txt"
    $err  = Join-Path $WorkRoot "$id.err.txt"
    $done = Join-Path $WorkRoot "$id.done.txt"

    @{ exe = $Exe; args = $Arguments; workDir = $WorkDir; env = $Environment; out = $out; err = $err; done = $done } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jobF -Encoding UTF8

    $taskName = "ComponentTest-$id"
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                  -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -JobFile "{1}"' -f $JobRunner, $jobF)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSeconds + 120))
    if ($As -eq 'system') {
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    } else {
        Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -Force `
            -User $script:TestUser.Name -Password $script:TestUser.Password -RunLevel Limited | Out-Null
    }
    Start-ScheduledTask -TaskName $taskName

    if ($NoWait) { return @{ Task = $taskName; Done = $done; Out = $out; Err = $err } }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath $done) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    $timedOut = -not (Test-Path -LiteralPath $done)
    if ($timedOut) { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $code = if ($timedOut) { $null } else { [int]((Get-Content -LiteralPath $done -Raw).Trim()) }
    return @{ Code = $code; Out = (Read-Text $out); Err = (Read-Text $err); TimedOut = $timedOut }
}

function New-TestUser {
    if ($script:TestUser) { return }
    $name = 'tctest'
    $pw   = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    $pw   = $pw + 'a1B'
    New-LocalUser -Name $name -Password (ConvertTo-SecureString $pw -AsPlainText -Force) `
        -PasswordNeverExpires -AccountNeverExpires -Description 'Component test user' | Out-Null
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $name -ErrorAction SilentlyContinue   # Users
    # Performance Log Users holds "Log on as a batch job" by default, which a
    # scheduled task running under a stored password needs. It grants no admin.
    Add-LocalGroupMember -SID 'S-1-5-32-559' -Member $name -ErrorAction SilentlyContinue
    $script:TestUser = @{ Name = $name; Password = $pw; Profile = $null }

    # First run as the user creates their profile, and proves the logon works
    # before any real step depends on it.
    # whoami /groups shows which logon type the task got (BATCH vs INTERACTIVE),
    # which is the first thing to know when a user step behaves differently here
    # than at a real logon.
    $r = Invoke-As -Label 'create-profile' -Exe 'cmd.exe' -Arguments '/c whoami /groups' -As testuser -TimeoutSeconds 180
    Write-Block "Test user token (whoami /groups)" $r.Out
    $script:TestUser.Groups = $r.Out
    if ($r.TimedOut -or $r.Code -ne 0) {
        throw "Could not run anything as the test user (exit $($r.Code)). $($r.Err)"
    }
    $sid  = (Get-LocalUser -Name $name).SID.Value
    $prof = Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $sid } | Select-Object -First 1
    if (-not $prof) { throw 'The test user ran a command but has no profile.' }
    $script:TestUser.Profile = $prof.LocalPath
    Write-Host "Test user '$name' ready, profile $($prof.LocalPath)"
}

function Get-MsiServiceState {
    $svc = Get-CimInstance Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
    if (-not $svc) { return 'msiserver: not found' }
    return ('msiserver: {0}, start mode {1}' -f $svc.State, $svc.StartMode)
}

# Run a command directly in the harness's own process - as the runner's own
# account, in its own logon session, rather than through a scheduled task.
# Returns @{ Code; Out; Err; TimedOut }.
function Invoke-Direct {
    param([string]$Exe, [string]$Arguments, [string]$WorkDir, [int]$TimeoutSeconds = 600)
    $script:StepNo++
    $id  = '{0:D2}-direct' -f $script:StepNo
    $out = Join-Path $WorkRoot "$id.out.txt"
    $err = Join-Path $WorkRoot "$id.err.txt"
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -WorkingDirectory $WorkDir -NoNewWindow -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle   # without this, Windows PowerShell may not report ExitCode
    $done = $p.WaitForExit($TimeoutSeconds * 1000)
    if (-not $done) { $p.Kill() }
    $code = if ($done) { $p.ExitCode } else { $null }
    return @{ Code = $code; Out = (Read-Text $out); Err = (Read-Text $err); TimedOut = (-not $done) }
}

# When a file check misses, look for the same file name where installers
# usually put things, so a wrong expected path shows the right one.
function Find-Candidates {
    param([string]$Path, [string]$As)
    $leaf  = Split-Path $Path -Leaf
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)})
    if ($As -eq 'testuser' -and $script:TestUser) { $roots += (Join-Path $script:TestUser.Profile 'AppData') }
    else { $roots += (Join-Path $env:USERPROFILE 'AppData') }
    $hits = @()
    foreach ($r in $roots) {
        if ($r -and (Test-Path -LiteralPath $r)) {
            $hits += @(Get-ChildItem -LiteralPath $r -Filter $leaf -File -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                       Select-Object -First 5 -ExpandProperty FullName)
        }
    }
    return $hits
}

# Expand %VARS% in a path from test.json. For as=testuser the per-user
# variables resolve against the test user's profile. For system and runner
# they resolve in the harness's own environment - the runner's account.
function Expand-SpecPath {
    param([string]$Path, [string]$As = 'system')
    if ($As -eq 'testuser') {
        New-TestUser
        $p = $script:TestUser.Profile
        $Path = $Path -ireplace '%LOCALAPPDATA%', (Join-Path $p 'AppData\Local')
        $Path = $Path -ireplace '%APPDATA%',      (Join-Path $p 'AppData\Roaming')
        $Path = $Path -ireplace '%USERPROFILE%',  $p
        $Path = $Path -ireplace '%TEMP%',         (Join-Path $p 'AppData\Local\Temp')
    }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

# ---------------------------------------------------------------- load

$manifestFile = Join-Path $ComponentPath 'component.json'
$specFile     = Join-Path $ComponentPath 'test.json'
foreach ($f in @($manifestFile, $specFile)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing $f" }
}
$manifest = Get-Content -Raw -LiteralPath $manifestFile | ConvertFrom-Json
$spec     = Get-Content -Raw -LiteralPath $specFile     | ConvertFrom-Json

$general     = Get-Prop $manifest 'general'
$name        = Get-Prop $general 'name' (Split-Path $ComponentPath -Leaf)
$installType = Get-Prop $general 'installType' 'powershell'
$timeout     = [int](Get-Prop $general 'timeout' 600)
$body        = Join-Path $ComponentPath (Get-Prop $manifest 'body')

# Input variables: defaults from component.json, then test.json's overrides.
$baseVars = @{}
foreach ($v in @(Get-Prop $manifest 'variables' @())) {
    if ($v) { $baseVars[[string]$v.name] = [string](Get-Prop $v 'defaultVal' '') }
}
$specVars = Get-Prop $spec 'variables'
if ($specVars) { foreach ($p in $specVars.PSObject.Properties) { $baseVars[$p.Name] = [string]$p.Value } }

$steps = @(Get-Prop $spec 'steps' @())
if ($steps.Count -eq 0) { throw "$specFile has no steps." }

Write-Host "Component: $name"
Write-Host "Body:      $body ($installType, timeout ${timeout}s)"
Write-Host "Steps:     $($steps.Count)"
Write-Host ''

# ---------------------------------------------------------------- steps

$stop = $false
$i = 0
foreach ($s in $steps) {
    $i++
    $type  = [string](Get-Prop $s 'type')
    $as    = [string](Get-Prop $s 'as' 'system')
    $label = [string](Get-Prop $s 'label' '')
    if (-not $label) { $label = "$i. $type" } else { $label = "$i. $label" }

    # "tier": 2 marks a step a CI runner cannot do honestly - one that needs a
    # real interactive logon. It is listed so the spec stays the whole story,
    # and reported as skipped rather than failed.
    $tier = [int](Get-Prop $s 'tier' 1)
    if ($tier -gt 1) { Add-Result $label $true "Tier $tier only - needs a real logon, which a CI runner cannot provide." -Skip; continue }

    if ($stop) { Add-Result $label $false 'Skipped: an earlier component run failed.'; continue }

    try {
        switch ($type) {

            'runComponent' {
                # A fresh working directory per run: the body plus its attachments
                # at the root, which is where Datto puts them.
                $runDir = Join-Path $WorkRoot ('run-{0:D2}' -f $i)
                New-Item -ItemType Directory -Force -Path $runDir | Out-Null
                Copy-Item -LiteralPath $body -Destination $runDir
                $files = Join-Path $ComponentPath 'files'
                if (Test-Path -LiteralPath $files) { Copy-Item -Path (Join-Path $files '*') -Destination $runDir -Recurse }
                $runBody = Join-Path $runDir (Split-Path $body -Leaf)

                $vars = @{} + $baseVars
                $stepVars = Get-Prop $s 'variables'
                if ($stepVars) { foreach ($p in $stepVars.PSObject.Properties) { $vars[$p.Name] = [string]$p.Value } }

                switch ($installType) {
                    'powershell' { $exe = 'powershell.exe'; $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $runBody }
                    'batch'      { $exe = 'cmd.exe';        $arg = '/c "{0}"' -f $runBody }
                    default      { throw "installType '$installType' is not supported by the Windows harness." }
                }

                $r = Invoke-As -Label 'component' -Exe $exe -Arguments $arg -WorkDir $runDir -Environment $vars -As system -TimeoutSeconds $timeout
                Write-Block "$label - stdout" $r.Out
                if ($r.Err.Trim()) { Write-Block "$label - stderr" $r.Err }

                $want = [int](Get-Prop $s 'expectExitCode' 0)
                if ($r.TimedOut) {
                    Add-Result $label $false "Timed out after ${timeout}s (component.json timeout)."
                    $stop = $true
                } elseif ($r.Code -ne $want) {
                    Add-Result $label $false "Exit code $($r.Code), expected $want."
                    $stop = $true
                } else {
                    $missing = @()
                    foreach ($t in @(Get-Prop $s 'outputContains' @())) {
                        if ($t -and $r.Out.IndexOf([string]$t, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $missing += $t }
                    }
                    if ($missing.Count) {
                        Add-Result $label $false ("Exit code $($r.Code) as expected, but output is missing: " + ($missing -join ' | '))
                    } else {
                        Add-Result $label $true "Exit code $($r.Code) as expected."
                    }
                }
            }

            'file' {
                $path   = Expand-SpecPath ([string](Get-Prop $s 'path')) $as
                $exists = [bool](Get-Prop $s 'exists' $true)
                $found  = Test-Path -LiteralPath $path
                if (-not $exists) {
                    Add-Result $label (-not $found) ($(if ($found) { 'Present but should not be: ' } else { 'Absent as expected: ' }) + $path)
                } elseif (-not $found) {
                    $cand = @(Find-Candidates $path $as)
                    $more = if ($cand.Count) { ' The same file name exists at: ' + ($cand -join '; ') } else { '' }
                    Add-Result $label $false ("Not found: $path." + $more)
                } else {
                    $min = Get-Prop $s 'minVersion'
                    if ($min) {
                        $raw = (Get-Item -LiteralPath $path).VersionInfo.FileVersion
                        $ver = $null
                        if ($raw -match '\d+(\.\d+){1,3}') { $ver = [version]$Matches[0] }
                        if ($ver -and $ver -ge [version]$min) {
                            Add-Result $label $true "Found, version $ver (>= $min): $path"
                        } else {
                            Add-Result $label $false "Found, but version '$raw' is not >= $min`: $path"
                        }
                    } else {
                        Add-Result $label $true "Found: $path"
                    }
                }
            }

            'registry' {
                # Machine-wide keys only (HKLM:). A per-user registry check would
                # need the test user's hive loaded; add it when a component needs it.
                $path = [string](Get-Prop $s 'path')
                $valueName = [string](Get-Prop $s 'name' '')
                if (-not (Test-Path -LiteralPath $path)) {
                    Add-Result $label $false "Key not found: $path"
                } elseif (-not $valueName) {
                    Add-Result $label $true "Key exists: $path"
                } else {
                    $key = Get-Item -LiteralPath $path
                    $n   = if ($valueName -eq '(Default)') { '' } else { $valueName }
                    if ($key.GetValueNames() -notcontains $n) {
                        Add-Result $label $false "Value '$valueName' not found under $path"
                    } else {
                        $val = [string]$key.GetValue($n)
                        $eq  = Get-Prop $s 'equals'
                        $rx  = Get-Prop $s 'matches'
                        if ($null -ne $eq) {
                            Add-Result $label ($val -eq [string]$eq) "$valueName = '$val' (expected '$eq')"
                        } elseif ($null -ne $rx) {
                            Add-Result $label ($val -match [string]$rx) "$valueName = '$val' (expected to match /$rx/)"
                        } else {
                            Add-Result $label $true "$valueName = '$val'"
                        }
                    }
                }
            }

            'uninstallEntry' {
                # Is the product registered in Programs and Features, and for
                # whom? "user" entries are read from the harness's own HKCU - the
                # runner's account - so this pairs with as: runner steps.
                $rx = [string](Get-Prop $s 'displayName')
                $roots = @(
                    @{ Scope = 'machine'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
                    @{ Scope = 'machine'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
                    @{ Scope = 'user';    Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
                )
                $hits = @()
                foreach ($root in $roots) {
                    if (-not (Test-Path -LiteralPath $root.Path)) { continue }
                    foreach ($k in @(Get-ChildItem -LiteralPath $root.Path -ErrorAction SilentlyContinue)) {
                        $dn = $k.GetValue('DisplayName')
                        if ($dn -and $dn -match $rx) {
                            $hits += [pscustomobject]@{ Scope = $root.Scope; Name = $dn; Version = $k.GetValue('DisplayVersion'); Location = $k.GetValue('InstallLocation') }
                        }
                    }
                }
                $want = Get-Prop $s 'scope'
                if ($hits.Count -eq 0) {
                    Add-Result $label $false "No uninstall entry matching /$rx/ (machine-wide, or for $env:USERNAME)."
                } else {
                    $desc = ($hits | ForEach-Object { "$($_.Scope): '$($_.Name)' $($_.Version) at '$($_.Location)'" }) -join '; '
                    if ($want -and -not ($hits | Where-Object { $_.Scope -eq $want })) {
                        Add-Result $label $false "Registered, but not $want-scoped: $desc"
                    } else {
                        Add-Result $label $true "Registered - $desc"
                    }
                }
            }

            'activeSetup' {
                # Stands in for the user's next logon: run the StubPath the
                # component registered, as a standard user, the way Windows would.
                # What this cannot prove is that Windows fires it at a real
                # logon - that needs an interactive session (Tier 2).
                $guid = [string](Get-Prop $s 'key')
                $akey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$guid"
                if (-not (Test-Path -LiteralPath $akey)) { throw "Active Setup key not found: $akey" }
                $stubPath = [string](Get-Item -LiteralPath $akey).GetValue('StubPath')
                if (-not $stubPath) { throw "No StubPath under $akey" }
                $stubTimeout = [int](Get-Prop $s 'timeoutSeconds' 600)

                if ((Get-Prop $s 'as' 'testuser') -eq 'runner') {
                    # The runner's own account, in its own session: the closest a
                    # CI runner gets to "the user logs on and Active Setup runs
                    # the stub". That account is an administrator, so this proves
                    # the stub, the MSI and a silent install work - not that a
                    # standard user could do it (Tier 2).
                    $r = Invoke-Direct -Exe 'cmd.exe' -Arguments ('/c ' + $stubPath) -WorkDir $env:USERPROFILE -TimeoutSeconds $stubTimeout
                    Write-Block "$label - stdout" $r.Out
                    if ($r.Err.Trim()) { Write-Block "$label - stderr" $r.Err }
                    $ok = (-not $r.TimedOut) -and $r.Code -eq 0
                    if (-not $ok) {
                        $log = Get-Prop $s 'log'
                        if ($log) { Show-MsiLog (Expand-SpecPath ([string]$log) 'runner') }
                    }
                    $detail = if ($r.TimedOut) { 'Timed out.' } else { "StubPath ran as $env:USERNAME (the runner's own account, an administrator), exit code $($r.Code)." }
                    Add-Result $label $ok $detail
                    break
                }

                New-TestUser
                # Started as admin so the user only has to reach it, not launch it.
                Start-Service -Name msiserver -ErrorAction SilentlyContinue
                $r = Invoke-As -Label 'active-setup' -Exe 'cmd.exe' -Arguments ('/c ' + $stubPath) -As testuser `
                        -WorkDir $script:TestUser.Profile -TimeoutSeconds $stubTimeout
                Write-Block "$label - stdout" $r.Out
                if ($r.Err.Trim()) { Write-Block "$label - stderr" $r.Err }
                $ok = (-not $r.TimedOut) -and $r.Code -eq 0
                if (-not $ok) {
                    Write-Host (Get-MsiServiceState)
                    Write-Block 'Test user token (whoami /groups)' $script:TestUser.Groups -Open
                    $log = Get-Prop $s 'log'
                    if ($log) { Show-MsiLog (Expand-SpecPath ([string]$log) 'testuser') }
                }
                $detail = if ($r.TimedOut) { 'Timed out.' } else { "StubPath ran as $($script:TestUser.Name), exit code $($r.Code)." }
                if (-not $r.TimedOut -and $r.Code -eq 1601) {
                    # Seen on GitHub's runners: a standard user's msiexec from a
                    # scheduled task (a BATCH logon) is refused by the Installer
                    # service with 0x80070005. Running it elevated instead
                    # changes what is tested - an elevated per-user MSI can
                    # install per-machine - so a spec that hits this should mark
                    # the step "tier": 2 rather than work around it.
                    $detail += ' msiexec as a standard user cannot reach the Installer service from a batch logon on this runner. Mark this step "tier": 2 - see tools/test-harness/README.md.'
                }
                Add-Result $label $ok $detail
            }

            'launch' {
                # Start the app as the user, and pass if it is still running after
                # aliveSeconds. There is no desktop in a CI session, so this proves
                # "starts and does not crash", not "shows a window".
                $path  = Expand-SpecPath ([string](Get-Prop $s 'path')) $as
                $alive = [int](Get-Prop $s 'aliveSeconds' 15)
                if (-not (Test-Path -LiteralPath $path)) { throw "Not found: $path" }
                if ($as -eq 'runner') {
                    $p = Start-Process -FilePath $path -PassThru
                    $null = $p.Handle
                    Start-Sleep -Seconds $alive
                    if ($p.HasExited) {
                        Add-Result $label $false "Exited within ${alive}s (exit code $($p.ExitCode)): $path"
                    } else {
                        Add-Result $label $true "Still running after ${alive}s as ${env:USERNAME}: $path"
                        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                    }
                    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $path } | Stop-Process -Force -ErrorAction SilentlyContinue
                    break
                }
                $h = Invoke-As -Label 'launch' -Exe $path -As $as -NoWait -TimeoutSeconds ($alive + 60)
                Start-Sleep -Seconds $alive
                if (Test-Path -LiteralPath $h.Done) {
                    $code = (Get-Content -LiteralPath $h.Done -Raw).Trim()
                    if ((Read-Text $h.Err).Trim()) { Write-Block "$label - stderr" (Read-Text $h.Err) }
                    Add-Result $label $false "Exited within ${alive}s (exit code $code): $path"
                } else {
                    Add-Result $label $true "Still running after ${alive}s: $path"
                }
                Stop-ScheduledTask -TaskName $h.Task -ErrorAction SilentlyContinue
                Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $path } | Stop-Process -Force -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $h.Task -Confirm:$false -ErrorAction SilentlyContinue
            }

            default { throw "Unknown step type '$type'. See tools/test-harness/README.md." }
        }
    } catch {
        Add-Result $label $false ("Harness error: " + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- report

$failed  = @($script:Results | Where-Object { -not $_.Pass })
$skipped = @($script:Results | Where-Object { $_.Skip })
$total   = $script:Results.Count
Write-Host ''
Write-Host ("{0}: {1} passed, {2} failed, {3} skipped (Tier 2)" -f $name, ($total - $failed.Count - $skipped.Count), $failed.Count, $skipped.Count)

if ($env:GITHUB_STEP_SUMMARY) {
    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("### $name")
    $md.Add('')
    $md.Add('| | Step | Detail |')
    $md.Add('|---|---|---|')
    foreach ($r in $script:Results) {
        $icon = if ($r.Skip) { 'SKIP' } elseif ($r.Pass) { 'PASS' } else { '**FAIL**' }
        $md.Add(('| {0} | {1} | {2} |' -f $icon, $r.Step, ($r.Detail -replace '\|', '\|' -replace '[\r\n]+', ' ')))
    }
    $md.Add('')
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $md -Encoding UTF8
}

if ($failed.Count) { exit 1 }
exit 0
