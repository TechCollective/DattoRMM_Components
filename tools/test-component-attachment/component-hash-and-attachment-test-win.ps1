<#
================================================================================
 Datto RMM Component : Component Hash and Attachment Test [Win]
================================================================================
 PURPOSE
   Probes two things this repository has not been able to establish by reading
   exports alone:

     1. What Datto does with an empty <hash/> when the component carries an
        attachment. Two of three real exports have <hash/> empty; the only one
        with a value was the only one with an attachment, so hash looks related
        to the payload. It is not a plain MD5 of it - that was tested and did
        not match - so what it actually is remains unknown.

     2. Whether a payload file packed into a .cpt is laid down next to the
        script at run time, and arrives byte-intact.

   This component changes nothing on the endpoint. It reads its own working
   directory and reports what it finds.

 THE EXPERIMENT
   This component is built with <hash/> deliberately EMPTY and one attachment,
   payload.txt, of known content.

     Step 1  Import the .cpt. If Datto rejects it, hash is required whenever
             there is an attachment - that alone is the answer.
     Step 2  Run it on one device and read the output below.
     Step 3  Export the component back out of Datto and open its resource.xml:

                 unzip -p "export.cpt" resource.xml | grep -i hash

             If <hash> now carries a value, Datto computes it server side on
             import and it never needs to be authored. Compare that value
             against the digests this script prints - if it matches one, the
             field is finally explained.

 EXPECTED PAYLOAD
   payload.txt, 161 bytes
   MD5     b03e7d94cbb193a4857d71a34e82e77d
   SHA256  f800327e1910108df235e7e79b2d6a804eaff1fbaf841c15d1fd1aaa9739a61d

 EXIT CODES
   0  the attachment was found and its content matched
   1  the attachment was missing, or its content did not match
================================================================================
#>

$ErrorActionPreference = 'Stop'

$ExpectedName   = 'payload.txt'
$ExpectedSize   = 161
$ExpectedMd5    = 'b03e7d94cbb193a4857d71a34e82e77d'
$ExpectedSha256 = 'f800327e1910108df235e7e79b2d6a804eaff1fbaf841c15d1fd1aaa9739a61d'

function Get-Digest {
    param([string]$Path, [string]$Algorithm)
    (Get-FileHash -Path $Path -Algorithm $Algorithm).Hash.ToLower()
}

Write-Output '================================================================'
Write-Output ' Datto RMM hash and attachment probe'
Write-Output '================================================================'
Write-Output ''
Write-Output ("  Device      : {0}" -f $env:COMPUTERNAME)
Write-Output ("  Working dir : {0}" -f (Get-Location).Path)
Write-Output ("  Timestamp   : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'))
Write-Output ''

# Everything Datto laid down beside the script. Worth printing in full: it shows
# whether the payload keeps its name, and what else the agent adds.
Write-Output 'Files in the working directory'
Get-ChildItem -File | ForEach-Object {
    Write-Output ("  {0,-40} {1,10} bytes" -f $_.Name, $_.Length)
}
Write-Output ''

$payload = Get-ChildItem -File -Filter $ExpectedName | Select-Object -First 1

if (-not $payload) {
    Write-Output "FAIL - $ExpectedName is not in the working directory."
    Write-Output 'The attachment did not survive packaging or import.'
    Write-Output '================================================================'
    Write-Output "<-Start Result->"
    Write-Output "AttachmentTest=Missing"
    Write-Output "<-End Result->"
    exit 1
}

$md5    = Get-Digest -Path $payload.FullName -Algorithm MD5
$sha256 = Get-Digest -Path $payload.FullName -Algorithm SHA256

Write-Output 'Attachment as delivered'
Write-Output ("  Name        : {0}" -f $payload.Name)
Write-Output ("  Size        : {0} bytes (expected {1})" -f $payload.Length, $ExpectedSize)
Write-Output ("  MD5         : {0}" -f $md5)
Write-Output ("  SHA256      : {0}" -f $sha256)
Write-Output ''

# Printed so they can be compared by eye against whatever <hash> holds in an
# export taken after this import. That comparison is the whole point.
Write-Output 'Compare these against <hash> in a fresh export of this component:'
Write-Output ("  payload MD5     {0}" -f $md5)
Write-Output ("  payload SHA256  {0}" -f $sha256)
Write-Output ''

$intact = ($payload.Length -eq $ExpectedSize) -and ($md5 -eq $ExpectedMd5) -and ($sha256 -eq $ExpectedSha256)

Write-Output '================================================================'
if ($intact) {
    Write-Output 'PASS - the attachment arrived byte-intact.'
    Write-Output 'The component also imported with <hash/> empty, so hash is not'
    Write-Output 'required at import time even when a payload is present.'
    Write-Output '================================================================'
    Write-Output "<-Start Result->"
    Write-Output "AttachmentTest=Pass"
    Write-Output "<-End Result->"
    exit 0
}

Write-Output 'FAIL - the attachment arrived, but its content does not match.'
Write-Output ("  expected MD5 {0}" -f $ExpectedMd5)
Write-Output ("  actual   MD5 {0}" -f $md5)
Write-Output 'Something re-encoded the payload in transit.'
Write-Output '================================================================'
Write-Output "<-Start Result->"
Write-Output "AttachmentTest=Corrupt"
Write-Output "<-End Result->"
exit 1
