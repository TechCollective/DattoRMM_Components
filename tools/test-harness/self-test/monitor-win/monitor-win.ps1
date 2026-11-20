# Harness self-test fixture: prints the result blocks fixtureBlocks asks for.
function Write-Result([string]$Status) { Write-Output '<-Start Result->'; Write-Output "STATUS=$Status"; Write-Output '<-End Result->' }
switch ($env:fixtureBlocks) {
    'one'      { Write-Result 'ok' }
    'diag'     { Write-Output '<-Start Diagnostic->'; Write-Output 'note'; Write-Output '<-End Diagnostic->'; Write-Result 'ok' }
    'zero'     { Write-Output 'no result block' }
    'two'      { Write-Result 'first'; Write-Result 'second' }
    'unclosed' { Write-Output '<-Start Result->'; Write-Output 'STATUS=unclosed' }
}
exit 0
