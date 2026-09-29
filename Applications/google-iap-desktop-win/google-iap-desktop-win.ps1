# Google IAP Desktop [Win]
# Stages Google IAP Desktop for a PER-USER install via Active Setup.
#
# IAP Desktop's MSI is per-user by design (Google deploys it through user-scoped GPO or Intune).
# A Datto component runs as SYSTEM, so this script does not install anything itself: it downloads
# the MSI to a machine-wide folder and registers an Active Setup component. Windows then runs a
# silent "msiexec /i IapDesktop.msi /qn" as each user, once per profile, at their next logon.
# No admin rights are needed for that per-user install on Windows 10/11.
#
# Input variables (arrive as strings):
#   msiUrl            Where to download IapDesktop.msi from. Default: Google's GitHub "latest" release.
#   reinstallExisting "true" forces every user to re-run the install at next logon even if the
#                     staged version is unchanged. Default "false".
#
# Exit codes: 0 staged; 1 download failed; 2 could not write the stub or registry; 3 bad input.
# Source of truth: https://github.com/TechCollective/DattoRMM_Components

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$msiUrl = $env:msiUrl
if ([string]::IsNullOrWhiteSpace($msiUrl)) {
    $msiUrl = 'https://github.com/GoogleCloudPlatform/iap-desktop/releases/latest/download/IapDesktop.msi'
}
if ($msiUrl -notmatch '^https://') {
    Write-Output "ERROR: msiUrl must be an https:// URL. Got: $msiUrl"
    exit 3
}
$reinstall = ("$env:reinstallExisting").Trim().ToLower() -eq 'true'

$stage = Join-Path $env:ProgramData 'TechCollective\IapDesktop'
$msi   = Join-Path $stage 'IapDesktop.msi'
$stub  = Join-Path $stage 'Install-IapDesktop-User.cmd'
$asKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{6f1c2b8e-4a4d-4b0e-9c2a-5d1e7f3a9b01}'

# --- 1. Download ---
try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Write-Output "Downloading IapDesktop.msi from $msiUrl"
    Invoke-WebRequest -Uri $msiUrl -OutFile $msi -UseBasicParsing
    $size = (Get-Item $msi).Length
    if ($size -lt 1MB) { throw "Downloaded file is only $size bytes; not a valid installer" }
    Write-Output ("Downloaded {0:N1} MB" -f ($size / 1MB))
} catch {
    Write-Output "ERROR: download failed - $($_.Exception.Message)"
    exit 1
}

# --- 2. Work out the Active Setup version stamp ---
# Prefer the MSI's ProductVersion so an unchanged release does not re-run for every user.
# Fall back to a date stamp if the Windows Installer COM object is unavailable.
$productVersion = $null
try {
    $wi   = New-Object -ComObject WindowsInstaller.Installer
    $db   = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($msi, 0))
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='ProductVersion'"))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $rec  = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    $productVersion = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1)
    $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
} catch {
    Write-Output "Could not read ProductVersion from the MSI ($($_.Exception.Message)); using a date stamp instead"
}
if ($productVersion) {
    $asVersion = ($productVersion -replace '[^0-9.]', '') -replace '\.', ','
} else {
    $asVersion = (Get-Date).ToString('yyyy,MM,dd,HHmm')
}
if ($reinstall) {
    # Append a timestamp segment so the stamp is strictly newer than whatever is recorded per user.
    $asVersion = $asVersion + ',' + (Get-Date).ToString('yyMMddHHmm')
}

# --- 3. Write the per-user stub and register Active Setup ---
try {
    $lines = @(
        '@echo off',
        'rem Staged by TechCollective via Datto RMM. Runs once per user at logon.',
        ('msiexec /i "' + $msi + '" /qn /norestart /l*v "' + '%LOCALAPPDATA%' + '\IapDesktop-install.log"')
    )
    Set-Content -Path $stub -Value $lines -Encoding ASCII

    New-Item -Path $asKey -Force | Out-Null
    Set-ItemProperty -Path $asKey -Name '(Default)'   -Value 'Google IAP Desktop (per-user)'
    Set-ItemProperty -Path $asKey -Name 'StubPath'    -Value ('cmd.exe /c "' + $stub + '"')
    Set-ItemProperty -Path $asKey -Name 'Version'     -Value $asVersion
    Set-ItemProperty -Path $asKey -Name 'IsInstalled' -Value 1 -Type DWord
} catch {
    Write-Output "ERROR: could not register Active Setup - $($_.Exception.Message)"
    exit 2
}

# --- 4. Report ---
$label = if ($productVersion) { $productVersion } else { 'unknown version' }
Write-Output "IAP Desktop staged: $label (Active Setup version $asVersion). Each user installs it at their next sign-in."
Write-Output "Existing profiles on this device:"
$skip = @('Public', 'Default', 'Default User', 'All Users')
Get-ChildItem 'C:\Users' -Directory | Where-Object { $skip -notcontains $_.Name } | ForEach-Object {
    # The per-user MSI installs under Roaming AppData, not Local (found by the Tier 1 test).
    $exe = Join-Path $_.FullName 'AppData\Roaming\Google\IAP Desktop\IapDesktop.exe'
    if (Test-Path $exe) { $have = (Get-Item $exe).VersionInfo.ProductVersion } else { $have = 'not yet - installs at next logon' }
    Write-Output ("  {0,-24} {1}" -f $_.Name, $have)
}
exit 0
