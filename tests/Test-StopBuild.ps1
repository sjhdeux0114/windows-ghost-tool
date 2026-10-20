$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$testRoot=Join-Path $env:TEMP ('stop-build-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    @{AppDirectory=$root} | ConvertTo-Json | Set-Content (Join-Path $testRoot 'environment.json')
    $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
    $output=& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'StopBuild.ps1') -JobDirectory $testRoot -WorkerId $PID 2>&1
    $code=$LASTEXITCODE;$ErrorActionPreference=$previous
    if($code -ne 1 -or (Test-Path (Join-Path $testRoot 'cancel-requested.txt'))){throw 'Unrelated process cancellation was not blocked'}
    'PASS: unrelated process is rejected before cancellation or VM changes.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid test cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
