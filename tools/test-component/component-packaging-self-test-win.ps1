<#
================================================================================
 Datto RMM Component : Component Packaging Self-Test [Win]
================================================================================
 PURPOSE
   Proves that a .cpt built by tools/cpt.py in this repository imports into
   Datto RMM intact. It touches nothing on the endpoint: it reads its own input
   variables back out of the environment and prints what it found.

   Import this component, run it against one test device, and read the output.
   If every check below passes, the packaging format is correct and the build
   pipeline can be trusted with real components.

 WHAT IT CHECKS
   1. The component imported at all, so the ZIP layout and resource.xml are
      acceptable to Datto.
   2. Each declared input variable arrived, with the declared default, and with
      the value type Datto produces for that variable kind:
        TestString      string   -> arbitrary text
        TestEmpty       string   -> empty default, arrives as empty or unset
        TestBoolean     boolean  -> the literal text "true" or "false"
        TestChoice      map      -> the VALUE of the selected pair, not its name
   3. stdout, the Datto result block and the exit code all behave normally.

 EXIT CODES
   0  every check passed
   1  at least one input variable did not arrive as declared
================================================================================
#>

$ErrorActionPreference = 'Stop'

# Datto exposes each input variable to the script as an environment variable of
# the same name. Everything arrives as text, including booleans.
function Get-Input {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    return $value
}

$failures = New-Object System.Collections.Generic.List[string]

function Assert-Input {
    param(
        [string]$Name,
        [string]$Expected,
        [string]$Kind
    )
    $actual = Get-Input $Name
    $shown  = if ($actual -eq '') { '<empty>' } else { $actual }
    if ($actual -eq $Expected) {
        Write-Output ("  PASS  {0,-12} {1,-8} = {2}" -f $Name, $Kind, $shown)
    } else {
        Write-Output ("  FAIL  {0,-12} {1,-8} = {2}   (expected '{3}')" -f $Name, $Kind, $shown, $Expected)
        $failures.Add($Name)
    }
}

Write-Output '================================================================'
Write-Output ' Datto RMM component packaging self-test'
Write-Output '================================================================'
Write-Output ''
Write-Output 'Environment'
Write-Output ("  Device      : {0}" -f $env:COMPUTERNAME)
Write-Output ("  Running as  : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Write-Output ("  PowerShell  : {0}" -f $PSVersionTable.PSVersion)
Write-Output ("  Timestamp   : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'))
Write-Output ''

# The expected values below are the defaults declared in component.json. Run the
# component without touching anything in the Datto UI and they should all pass.
Write-Output 'Input variables (compared against the declared defaults)'
Assert-Input -Name 'TestString'  -Expected 'hello from the manifest' -Kind 'string'
Assert-Input -Name 'TestEmpty'   -Expected ''                        -Kind 'string'
Assert-Input -Name 'TestBoolean' -Expected 'true'                    -Kind 'boolean'
Assert-Input -Name 'TestChoice'  -Expected 'beta'                    -Kind 'map'
Write-Output ''

# A map variable is the one worth spelling out: the Datto UI shows the pair's
# NAME ("Second choice") while the script receives its VALUE ("beta"). Getting
# these the wrong way round is the classic packaging mistake, so say so plainly.
$choice = Get-Input 'TestChoice'
Write-Output ("Map variable detail: the UI offers Name='Second choice', and the")
Write-Output ("script received Value='{0}'. Value is what the script must switch on." -f $choice)
Write-Output ''

Write-Output '================================================================'
if ($failures.Count -eq 0) {
    $summary = 'PASS - component imported and all 4 input variables arrived as declared'
    Write-Output $summary
    Write-Output '================================================================'
    Write-Output "<-Start Result->"
    Write-Output "PackagingSelfTest=Pass"
    Write-Output "<-End Result->"
    exit 0
}

$summary = "FAIL - {0} input variable(s) did not arrive as declared: {1}" -f $failures.Count, ($failures -join ', ')
Write-Output $summary
Write-Output 'If you changed a value in the Datto UI before running, that is expected.'
Write-Output 'Otherwise the manifest and the packaged resource.xml disagree.'
Write-Output '================================================================'
Write-Output "<-Start Result->"
Write-Output "PackagingSelfTest=Fail"
Write-Output "<-End Result->"
exit 1
