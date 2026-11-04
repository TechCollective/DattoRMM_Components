<#
.SYNOPSIS
    Datto RMM Component - Hardware - Estimate Model Year to UDF [Win]
    Estimates the year a Windows machine's model came out and writes it to a UDF.

.DESCRIPTION
    Reads the manufacturer, model, Lenovo product name and CPU from WMI, works out
    the year that model (or failing that, that CPU) was current, and writes one
    line to a Datto UDF, year first so it sorts and filters:

        2021 | high | Latitude 5420
        2023 | high | ThinkPad T14 Gen 4
        2020-2021 | medium | XPS 13 9310 | by CPU
        Unknown | Contoso Widget 9000
        VM | virtual machine

    It is an estimate of when the model was current, not a ship date. A unit can
    ship up to about a year later. Dell and Lenovo warranty lookups give the real
    ship date.

    Read-only apart from the one UDF value under HKLM\SOFTWARE\CentraStage. No
    network calls. It will not overwrite a UDF value that this component did not
    write unless usrOverwriteForeign is Yes, so a UDF already used by something
    else is not silently clobbered. The existing value is never printed (it could
    be anything, including a recovery key); only its length is.

    The rules mirror the Machine Year Estimator page. Change both together.

    Exit codes:
      0 = STATUS=WRITTEN, STATUS=UNCHANGED (same value already there) or
          STATUS=NO_ESTIMATE (wrote "Unknown | ..."; no rule matched)
      1 = STATUS=REFUSED        (invalid input variable)
      2 = STATUS=WRITE_FAILED   (the registry write did not stick)
      3 = STATUS=FOREIGN_VALUE  (the UDF holds a value this component did not write)

    Test hook: if the environment variable TC_TEST_HARDWARE is set, it is used
    instead of WMI, as "Manufacturer|Model|ProductVersion|CPU". Only the repo's
    Tier 1 test sets it. It changes nothing but the text written.

.NOTES
    Category: Scripts | Script type: PowerShell | Runs as: SYSTEM
    PowerShell 5.1. Safe to re-run; a second run with the same result changes nothing.
    Source: https://github.com/TechCollective/DattoRMM_Components
#>

#region ----------------------------- Setup -----------------------------------

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$ScriptName = 'Hardware - Estimate Model Year to UDF [Win]'
$Now        = (Get-Date).Year
$UdfKey     = 'HKLM:\SOFTWARE\CentraStage'
# A value this component wrote starts with one of these.
$OwnPattern = '^(\d{4}(-\d{4})?|Unknown|VM) \| '

function Get-Var {
    param([string]$Name, [string]$Default = '')
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Write-Line { param([string]$Text) Write-Host $Text }

function Finish {
    param([string]$Status, [string]$Detail, [int]$Code)
    Write-Line ("DETAIL={0}" -f $Detail)
    Write-Line ("STATUS={0}" -f $Status)
    exit $Code
}

#endregion

#region ----------------------------- Inputs ----------------------------------

$UdfRaw    = Get-Var 'usrUdfNumber' '10'
$Overwrite = Get-Var 'usrOverwriteForeign' 'No'

Write-Line $ScriptName
Write-Line ("Device: {0}" -f $env:COMPUTERNAME)

if ($UdfRaw -notmatch '^\d{1,3}$' -or [int]$UdfRaw -lt 1 -or [int]$UdfRaw -gt 300) {
    Finish 'REFUSED' ("usrUdfNumber must be a whole number from 1 to 300, got '{0}'." -f $UdfRaw) 1
}
if ($Overwrite -notin @('No', 'Yes')) {
    Finish 'REFUSED' ("usrOverwriteForeign must be No or Yes, got '{0}'." -f $Overwrite) 1
}
$UdfName = 'Custom{0}' -f [int]$UdfRaw

#endregion

#region ----------------------------- Hardware --------------------------------

function Clean { param($s) if ($null -eq $s) { return '' } return ([string]$s).Trim() }

$Test = [Environment]::GetEnvironmentVariable('TC_TEST_HARDWARE')
if (-not [string]::IsNullOrWhiteSpace($Test)) {
    $p = @($Test.Split('|')) + @('', '', '', '')
    $Make = Clean $p[0]; $Model = Clean $p[1]; $Version = Clean $p[2]; $Cpu = Clean $p[3]
    Write-Line 'Hardware: simulated (TC_TEST_HARDWARE)'
} else {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $Make  = Clean $cs.Manufacturer
    $Model = Clean $cs.Model
    $Version = ''
    try { $Version = Clean (Get-CimInstance -ClassName Win32_ComputerSystemProduct).Version } catch { $Version = '' }
    $Cpu = ''
    try { $Cpu = Clean (@(Get-CimInstance -ClassName Win32_Processor)[0].Name) } catch { $Cpu = '' }
}
# Placeholder strings some boards report instead of a product name.
if ($Version -match '^(none|default string|to be filled.*|system version|not applicable|0+)$') { $Version = '' }
$Cpu = $Cpu -replace '\s+', ' '

Write-Line ("Manufacturer: {0}" -f $Make)
Write-Line ("Model:        {0}" -f $Model)
if ($Version) { Write-Line ("Product name: {0}" -f $Version) }
Write-Line ("CPU:          {0}" -f $Cpu)

#endregion

#region ----------------------------- Rules -----------------------------------

function Est {
    param([string]$Src, [string]$Label, [int]$Lo, [int]$Hi, [string]$Conf, [string]$Why)
    if ($Hi -lt $Lo) { $Hi = $Lo }
    return @{ Src = $Src; Label = $Label; Lo = $Lo; Hi = $Hi; Conf = $Conf; Why = $Why; Cands = $null; Defer = $false }
}
function Fmt { param($e) if ($e.Lo -eq $e.Hi) { return [string]$e.Lo } return ('{0}-{1}' -f $e.Lo, $e.Hi) }
function Digit { param([string]$s, [int]$i) return [int]$s.Substring($i, 1) }

function Get-DellEstimate {
    param([string]$t)
    if ($t -match 'latitude\s*d([5-8])([0-4])0\b') {
        return (Est 'model' ("Latitude D{0}{1}0" -f $Matches[1], $Matches[2]) (2004 + [int]$Matches[2]) 0 'medium' 'Old D-series Latitude.')
    }
    if ($t -match 'latitude\s*(e)?\s*(\d{4})(\s*rugged)?') {
        $d = $Matches[2]; $c = Digit $d 2; $e = [bool]$Matches[1]; $rug = [bool]$Matches[3]
        $y = 0
        if (-not $e -and $d.Substring(3,1) -eq '4' -and $c -le 2) { $y = @{0=2015;1=2016;2=2018}[$c] }
        elseif ($e) { $map = @{1=2010;2=2011;3=2012;4=2014;5=2015;7=2016}; if ($map.ContainsKey($c)) { $y = $map[$c] } }
        elseif ($c -le 5) { $y = 2019 + $c }
        else { $y = @{6=2015;7=2016;8=2017;9=2018}[$c] }
        if ($y) {
            $lbl = 'Latitude ' + $(if ($e) { 'E' } else { '' }) + $d + $(if ($rug) { ' Rugged' } else { '' })
            return (Est 'model' $lbl $y 0 'high' 'Latitude naming: the third digit tracks the model year.')
        }
    }
    if ($t -match 'optiplex\s*((?:micro|sff|tower|plus|ultra|all-in-one|aio)\s*)*(\d{4})') {
        $d = $Matches[2]; $newForm = [bool]$Matches[1]; $tail = $d.Substring(2, 2)
        $map = @{ '00'=@(,@(2022,2022)); '10'=@(@(2012,2012),@(2023,2023)); '11'=@(,@(2012,2012));
                  '20'=@(@(2013,2014),@(2024,2024)); '30'=@(,@(2014,2015)); '40'=@(,@(2016,2016));
                  '50'=@(,@(2017,2017)); '55'=@(,@(2017,2017)); '60'=@(,@(2018,2018)); '70'=@(,@(2019,2019));
                  '80'=@(,@(2020,2020)); '90'=@(,@(2021,2021)) }
        if ($map.ContainsKey($tail)) {
            $c = $map[$tail]
            if ($c.Count -gt 1 -and $d.Substring(0,1) -ne '7') { $c = @(,$c[0]) }
            if ($c.Count -gt 1 -and $newForm) { $c = @(,$c[1]) }
            if ($c.Count -eq 1) { return (Est 'model' "OptiPlex $d" $c[0][0] $c[0][1] 'high' 'OptiPlex naming: the last two digits track the model year.') }
            $x = Est 'model' "OptiPlex $d" 0 0 'medium' "Dell used the OptiPlex $d name twice."
            $x.Cands = $c
            return $x
        }
    }
    if ($t -match 'optiplex\s*(\d)(\d)0\b') {
        $map = @{9=2011;8=2010;7=2010;6=2009;5=2008;3=2007}; $k = [int]$Matches[2]
        if ($map.ContainsKey($k)) { return (Est 'model' ("OptiPlex {0}{1}0" -f $Matches[1], $Matches[2]) $map[$k] 0 'medium' 'Older three-digit OptiPlex.') }
    }
    # 2025+ naming carries the year in the product code: PC14250, QCM1250, PW716260 (25 = 2025).
    if ($t -cmatch '\b[A-Z]{1,4}\d*?(2[4-9])(\d)\b') {
        $y = 2000 + [int]$Matches[1]
        if ($y -le $Now + 1) { return (Est 'model' $Matches[0] $y 0 'high' "Dell's 2025+ product code carries the year.") }
    }
    if ($t -match '\bdell\s+pro\b|\bpro\s+max\b') { return (Est 'model' 'Dell Pro family' 2025 $Now 'high' 'Dell Pro names began in 2025.') }
    return $null
}

function Get-MtmEra {
    param([string]$code)
    $p2 = $code.Substring(0, 2); $c = $code.Substring(2, 1)
    $bands = @{
        '20' = @(@('AB',2014,2014),@('CDE',2015,2015),@('FG',2016,2016),@('HJ',2017,2017),@('KLM',2018,2018),@('NPQR',2019,2019),@('STUV',2020,2020),@('WXY',2021,2021))
        '21' = @(@('ABC',2022,2022),@('DEFGH',2023,2023),@('JKLM',2024,2024),@('NPQRST',2025,2025),@('UVWXYZ',2025,2026))
        '10' = @(@('ABCD',2013,2014),@('EFGH',2015,2016),@('JKLM',2016,2017),@('NPQRST',2018,2018),@('UVWXYZ',2019,2019))
        '11' = @(@('ABCD',2020,2020),@('EFGH',2021,2021),@('JKLMNPQRST',2022,2022),@('UVWXYZ',2022,2023))
        '12' = @(@('ABCDE',2023,2023),@('FGHJKLMNPQRSTUVWXYZ',2024,2024))
        '13' = @(,@('ABCDEFGHJKLMNPQRSTUVWXYZ0123456789',2025,2026))
        '30' = @(@('ABC',2015,2018),@('DE',2019,2021),@('F',2022,2023),@('GHJKL',2024,2025))
        '80' = @(@('ABCDEFGHJK',2015,2015),@('LMNPQRST',2016,2016),@('UVWXYZ',2017,2017))
        '81' = @(@('ABCDEFGH',2018,2018),@('JKLMNPQR',2019,2019),@('STUVWXYZ',2020,2020))
        '82' = @(@('ABCDEFG',2020,2020),@('HJKLM',2021,2021),@('NPQRSTU',2022,2022),@('VWXYZ',2023,2023))
        '83' = @(@('ABCDEF',2023,2024),@('GHJKL',2024,2024),@('MNPQRSTUVWXYZ',2025,2025))
    }
    if (-not $bands.ContainsKey($p2)) { return $null }
    foreach ($b in $bands[$p2]) { if ($b[0].Contains($c)) { return @($b[1], $b[2]) } }
    return $null
}

function Get-LenovoEstimate {
    param([string]$t, [bool]$IsLenovo)
    $gen = 0
    if ($t -match '\bgen(?:eration)?\s*(\d{1,2})[a-z]?\b') { $gen = [int]$Matches[1] }
    elseif ($t -match '\b(\d{1,2})(?:st|nd|rd|th)\s*gen\b(?!\s*intel)') { $gen = [int]$Matches[1] }
    elseif ($t -cmatch '\bG(\d{1,2})\b') { $gen = [int]$Matches[1] }

    $fams = @(
        @('x1\s*carbon', 2012, 'high'), @('x1\s*(yoga|2-in-1)', 2015, 'high'), @('x1\s*extreme', 2017, 'high'),
        @('x1\s*nano', 2019, 'high'), @('\bp1\b', 2017, 'high'), @('\b(t16|p16s?|p16v)\b', 2021, 'high'),
        @('\bl16\b', 2023, 'high'), @('\be16\b', 2022, 'high'), @('\b(e14|e15)\b', 2018, 'medium'),
        @('\b(t14s?|t15[gp]?|x13|l13|l14|l15|p14s|p15s|p15v?)\b', 2019, 'high'),
        @('thinkcentre|\bm\d{2}[qstn]\b|\bneo\b', 2019, 'medium'), @('thinkbook', 2019, 'low')
    )
    if ($gen) {
        foreach ($f in $fams) {
            if ($t -match $f[0]) {
                $y = $f[1] + $gen
                if ($y -ge 2013 -and $y -le $Now + 1) {
                    $lo = $(if ($f[2] -eq 'low') { $y - 1 } else { $y })
                    return (Est 'model' ("{0} Gen {1}" -f $Matches[0], $gen) $lo $y $f[2] ("Gen 1 of this line was {0}." -f ($f[1] + 1)))
                }
            }
        }
    }
    if ($t -match '\b([TXLEW])(\d)([3-9])([05])([sp]?)\b') {
        return (Est 'model' ('ThinkPad ' + $Matches[0].ToUpper()) (2010 + [int]$Matches[3]) 0 'high' 'Pre-2020 ThinkPad naming: the middle digit is the year.')
    }
    if ($t -match '\bP([57])([0-3])(s?)\b') { return (Est 'model' ('ThinkPad ' + $Matches[0].ToUpper()) (2016 + [int]$Matches[2]) 0 'high' 'P50 was 2016, counting up.') }
    if ($t -match '\bM([79])([0-3])0[a-z]?\b') {
        $y = 2016 + [int]$Matches[2]; $lo = $(if ($Matches[2] -eq '0') { $y - 1 } else { $y })
        return (Est 'model' ('ThinkCentre ' + $Matches[0]) $lo $y 'medium' 'ThinkCentre M7x0/M9x0 naming.')
    }
    if ($t -match '\bM[789]0[qsnt]\b') { return (Est 'model' ('ThinkCentre ' + $Matches[0]) 2019 2020 'medium' 'No Gen in the name usually means first generation.') }
    if ($t -cmatch '\bM([789])([1-3])[a-z]?\b') { return (Est 'model' ('ThinkCentre ' + $Matches[0]) (2010 + [int]$Matches[2]) 0 'medium' 'Older ThinkCentre: the last digit is the year.') }

    $code = ''
    if ($t -cmatch '\b((?:1[0-3]|2[01]|30|8[0-3])[0-9A-Z]{2})(?:[0-9A-Z]{4}(?:US|WW|00)|CT[O0]1WW)\b') { $code = $Matches[1] }
    elseif ($IsLenovo -and $t -cmatch '\b((?:1[0-3]|2[01]|30|8[0-3])(?=[0-9]?[A-Z])[0-9A-Z]{2})\b') { $code = $Matches[1] }
    if ($code) {
        $r = Get-MtmEra $code
        if ($r) { return (Est 'machine type' $code $r[0] $r[1] 'medium' 'Lenovo assigns machine-type codes roughly in sequence.') }
    }
    if ($IsLenovo -and $t -cmatch '\b\d{4}[A-Z0-9]{3}\b') { return (Est 'machine type' $Matches[0] 2008 2013 'low' 'Old 4-digit Lenovo machine type.') }
    return $null
}

$IntelGen = @{1=@(2009,2010);2=@(2011,2011);3=@(2012,2012);4=@(2013,2014);5=@(2015,2015);6=@(2015,2016);7=@(2016,2017);
              8=@(2017,2018);9=@(2018,2019);10=@(2019,2020);11=@(2020,2021);12=@(2022,2022);13=@(2023,2023);14=@(2023,2024)}

function Get-CpuEstimate {
    param([string]$t)
    if ($t -match 'core(?:\(tm\))?\s*ultra\s*[3579]\s*(\d)\d{2}[a-z]*') {
        $s = [int]$Matches[1]; $m = @{1=@(2023,2024);2=@(2024,2025);3=@(2026,2026)}
        if ($m.ContainsKey($s)) { return (Est 'CPU' ($Matches[0] -replace '\(tm\)','') $m[$s][0] $m[$s][1] 'medium' "Core Ultra series $s.") }
    }
    if ($t -match 'core(?:\(tm\))?\s+[3579]\s+([1-3])\d{2}[a-z]{0,2}\b') {
        $y = 2023 + [int]$Matches[1]
        return (Est 'CPU' ($Matches[0] -replace '\(tm\)','') $y 0 'medium' 'Intel Core (non-Ultra) series.')
    }
    if ($t -match '\bi[3579]-\s?(\d{3,5})') {
        $n = $Matches[1]
        $gen = $(if ($n.Length -eq 3) { 1 } elseif ($n.Length -eq 5) { [int]$n.Substring(0,2) } elseif ($n.Substring(0,1) -eq '1') { [int]$n.Substring(0,2) } else { [int]$n.Substring(0,1) })
        if ($IntelGen.ContainsKey($gen)) { return (Est 'CPU' $Matches[0] $IntelGen[$gen][0] $IntelGen[$gen][1] 'medium' "Intel generation $gen.") }
    }
    if ($t -match '\b[im][3579]?-?([5-8])Y\d{2}\b') { $g = [int]$Matches[1]; return (Est 'CPU' $Matches[0] $IntelGen[$g][0] $IntelGen[$g][1] 'medium' "Intel generation $g (Y-series).") }
    if ($t -match '\bi[357]\s+CPU\s+(?:M\s+)?\d{3}\b') { return (Est 'CPU' $Matches[0] 2009 2010 'medium' 'First-generation Intel Core.') }
    if ($t -match 'core(?:\(tm\))?2\s+(duo|quad)') { return (Est 'CPU' ('Core 2 ' + $Matches[1]) 2006 2009 'medium' 'Intel Core 2 era.') }
    if ($t -match 'ryzen\s+(?:ai\s+)?(?:[3579]\s+)?(?:pro\s+)?(\d{3,4})\s*([a-z]{0,3})') {
        $n = $Matches[1]; $suf = $Matches[2]; $lbl = $Matches[0]
        if ($n.Length -eq 3) {
            if ($n.Substring(0,1) -eq '2') { return (Est 'CPU' $lbl 2025 0 'medium' 'Ryzen 200 series.') }
            return (Est 'CPU' $lbl 2024 2025 'medium' 'Ryzen AI 300 series.')
        }
        $d = Digit $n 0
        if ($suf -match '[uh]') {
            $y = 2016 + $d
            if ($y -ge 2018 -and $y -le $Now) { return (Est 'CPU' $lbl $y ([Math]::Min($y + 1, $Now)) 'medium' 'Ryzen mobile series.') }
        } else {
            $m = @{1=@(2017,2017);2=@(2018,2018);3=@(2019,2019);4=@(2020,2020);5=@(2020,2021);7=@(2022,2023);8=@(2024,2024);9=@(2024,2025)}
            if ($m.ContainsKey($d)) { return (Est 'CPU' $lbl $m[$d][0] $m[$d][1] 'medium' 'Ryzen desktop series.') }
        }
    }
    if ($t -match '\bAMD\s+A(?:4|6|8|9|10|12)-(\d)\d{3}') {
        $m = @{3=@(2011,2011);4=@(2012,2012);5=@(2013,2013);6=@(2013,2014);7=@(2014,2015);9=@(2016,2018)}; $k = [int]$Matches[1]
        if ($m.ContainsKey($k)) { return (Est 'CPU' $Matches[0] $m[$k][0] $m[$k][1] 'low' 'AMD A-series APU.') }
    }
    if ($t -match 'snapdragon.*?\bX1[EP]\d{2}') { return (Est 'CPU' 'Snapdragon X' 2024 2025 'medium' 'Snapdragon X laptops shipped from mid-2024.') }
    if ($t -match '8cx\s*gen\s*(\d)') { $m = @{1=2019;2=2020;3=2022}; $k = [int]$Matches[1]; if ($m.ContainsKey($k)) { return (Est 'CPU' $Matches[0] $m[$k] 0 'medium' 'Snapdragon 8cx.') } }
    if ($t -match 'microsoft\s+sq(\d)') { $m = @{1=2019;2=2020;3=2022}; $k = [int]$Matches[1]; if ($m.ContainsKey($k)) { return (Est 'CPU' $Matches[0] $m[$k] 0 'medium' 'Microsoft SQ chip.') } }
    return $null
}

#endregion

#region ----------------------------- Estimate --------------------------------

$All = "$Make | $Model | $Version | $Cpu"
$Value = ''; $Outcome = 'WRITTEN'; $Why = ''

if ("$Make $Model" -match 'virtual machine|vmware|virtualbox|\bkvm\b|qemu|hvm domu|google compute|\bxen\b|amazon ec2|standard pc \(|parallels|droplet') {
    $Value = 'VM | virtual machine'
    $Why = 'Virtual machine; there is no build year to estimate.'
} else {
    $isDell   = $All -match '\b(dell|latitude|optiplex|precision|vostro|inspiron|xps|alienware|poweredge)\b'
    $isLenovo = $All -match '\b(lenovo|thinkpad|thinkcentre|thinkbook|ideapad|ideacentre|thinkstation)\b'
    $modelText = "$Model | $Version"

    $ests = New-Object System.Collections.ArrayList
    if ($isDell)   { $e = Get-DellEstimate $modelText; if ($e) { [void]$ests.Add($e) } }
    if ($isLenovo) { $e = Get-LenovoEstimate $modelText $true; if ($e) { [void]$ests.Add($e) } }
    if (-not $isDell -and -not $isLenovo) { $e = Get-LenovoEstimate $modelText $false; if ($e) { [void]$ests.Add($e) } }
    $c = Get-CpuEstimate $Cpu; if ($c) { [void]$ests.Add($c) }

    # A name Dell used twice is settled by the other clue (the CPU).
    $firm = @($ests | Where-Object { -not $_.Cands })
    foreach ($e in $ests) {
        if (-not $e.Cands) { continue }
        if ($firm.Count) {
            $ref = ($firm[0].Lo + $firm[0].Hi) / 2
            $best = $e.Cands[0]
            foreach ($cand in $e.Cands) { if ([Math]::Abs(($cand[0] + $cand[1]) / 2 - $ref) -lt [Math]::Abs(($best[0] + $best[1]) / 2 - $ref)) { $best = $cand } }
            $e.Lo = $best[0]; $e.Hi = $best[1]; $e.Cands = $null; $e.Why += ' The CPU settles which.'
        } else {
            $e.Lo = $e.Cands[0][0]; $e.Hi = $e.Cands[-1][1]; $e.Cands = $null; $e.Conf = 'low'; $e.Why += ' No CPU to tell them apart.'
        }
    }

    $rank = @{ high = 3; medium = 2; low = 1 }
    $pick = $null
    foreach ($e in $ests) {
        if ($null -eq $pick) { $pick = $e; continue }
        $a = $rank[$e.Conf]; $b = $rank[$pick.Conf]
        $better = ($a -gt $b) -or
                  ($a -eq $b -and $pick.Src -eq 'CPU' -and $e.Src -ne 'CPU') -or
                  ($a -eq $b -and (($pick.Src -eq 'CPU') -eq ($e.Src -eq 'CPU')) -and ($e.Hi - $e.Lo) -lt ($pick.Hi - $pick.Lo))
        if ($better) { $pick = $e }
    }

    foreach ($e in $ests) { Write-Line ("Clue: {0} {1} -> {2} ({3}). {4}" -f $e.Src, $e.Label, (Fmt $e), $e.Conf, $e.Why) }

    if ($pick) {
        # Name the machine the way a report reader knows it: Lenovo's product name when it has one.
        $name = $(if ($isLenovo -and $Version) { $Version } elseif ($Model) { $Model } else { $pick.Label })
        $Value = '{0} | {1} | {2}' -f (Fmt $pick), $pick.Conf, $name
        if ($pick.Src -ne 'model') { $Value += ' | by ' + $pick.Src }
        $Why = 'Based on the {0}.' -f $pick.Src
        $cp = @($ests | Where-Object { $_.Src -eq 'CPU' })
        if ($cp.Count -and $pick.Src -ne 'CPU' -and (($pick.Lo - $cp[0].Hi) -gt 1 -or ($cp[0].Lo - $pick.Hi) -gt 1)) {
            Write-Line ("WARNING: the model says {0} but the CPU says {1}; check the warranty lookup." -f (Fmt $pick), (Fmt $cp[0]))
        }
    } else {
        $Value = 'Unknown | {0}' -f $(if ($Model) { "$Make $Model".Trim() } else { $Make })
        $Outcome = 'NO_ESTIMATE'
        $Why = 'No rule matched the model or the CPU.'
    }
}

# UDF values are plain text, 255 characters at most.
$Value = (($Value -replace '[^\x20-\x7E]', '') -replace '\s+', ' ').Trim()
if ($Value.Length -gt 255) { $Value = $Value.Substring(0, 255) }
Write-Line ("Result: {0}" -f $Value)

#endregion

#region ----------------------------- Write -----------------------------------

$existing = ''
try { $existing = [string](Get-ItemProperty -LiteralPath $UdfKey -Name $UdfName -ErrorAction Stop).$UdfName } catch { $existing = '' }

if ($existing -eq $Value) {
    $s = $(if ($Outcome -eq 'NO_ESTIMATE') { 'NO_ESTIMATE' } else { 'UNCHANGED' })
    Finish $s ("{0} already holds this value. {1}" -f $UdfName, $Why) 0
}
if ($existing -and $existing -notmatch $OwnPattern -and $Overwrite -ne 'Yes') {
    Finish 'FOREIGN_VALUE' ("{0} already holds a value this component did not write ({1} characters). Nothing was changed. Clear it, choose another UDF, or set usrOverwriteForeign to Yes." -f $UdfName, $existing.Length) 3
}

try {
    if (-not (Test-Path -LiteralPath $UdfKey)) { New-Item -Path $UdfKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $UdfKey -Name $UdfName -Value $Value -PropertyType String -Force | Out-Null
    $check = [string](Get-ItemProperty -LiteralPath $UdfKey -Name $UdfName).$UdfName
} catch {
    Finish 'WRITE_FAILED' ("Could not write {0}: {1}" -f $UdfName, $_.Exception.Message) 2
}
if ($check -ne $Value) { Finish 'WRITE_FAILED' ("{0} did not hold the value after writing." -f $UdfName) 2 }

Finish $Outcome ("Wrote {0}; Datto shows it after the agent's next check-in. {1}" -f $UdfName, $Why) 0

#endregion
