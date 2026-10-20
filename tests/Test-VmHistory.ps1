$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\VmHistory.ps1') -ValidateOnly
$testRoot=Join-Path $env:TEMP ('vm-history-test-'+[guid]::NewGuid().ToString('N'))
$Root=$testRoot
try {
    $job=Join-Path $testRoot 'AutoBuilds\20261021-test'
    New-Item -ItemType Directory -Path $job -Force | Out-Null
    @{AppDirectory=$testRoot} | ConvertTo-Json | Set-Content (Join-Path $job 'environment.json')
    $rows=@(Entries -SearchRoots @((Join-Path $testRoot 'AutoBuilds')) | Where-Object Path -eq $job)
    if($rows.Count -ne 1){throw 'Owned build was not discovered'}
    @{AppDirectory='C:\UnrelatedApp'} | ConvertTo-Json | Set-Content (Join-Path $job 'environment.json')
    if(@(Entries -SearchRoots @((Join-Path $testRoot 'AutoBuilds')) | Where-Object Path -eq $job).Count -ne 0){throw 'Foreign app build was accepted'}
    @{AppDirectory=$testRoot} | ConvertTo-Json | Set-Content (Join-Path $job 'environment.json')
    @{Id=[guid]::NewGuid().ToString();Name='Test';Vhd='C:\outside\Windows.vhdx'} | ConvertTo-Json | Set-Content (Join-Path $job 'project.json')
    $blocked=$false;try{Entries -SearchRoots @((Join-Path $testRoot 'AutoBuilds')) | Out-Null}catch{$blocked=$true}
    if(-not $blocked){throw 'Disk outside owned folder was accepted'}
    Remove-Item -LiteralPath (Join-Path $job 'project.json')
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'outside') | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $job 'linked') -Target (Join-Path $testRoot 'outside') | Out-Null
    $blocked=$false;try{CheckTree $job}catch{$blocked=$true}
    if(-not $blocked){throw 'Junction was accepted for recursive deletion'}
    Remove-Item -LiteralPath (Join-Path $job 'linked') -Force
    # Exercise the real deletion entry point with a fake Hyper-V module and disposable files.
    $vmId=[guid]::NewGuid().ToString()
    @{Id=$vmId;Name='TestVM';Vhd=(Join-Path $job 'Windows.vhdx')} | ConvertTo-Json | Set-Content (Join-Path $job 'project.json')
    Set-Content (Join-Path $job 'Windows.vhdx') 'test disk placeholder'
    $keptImage=Join-Path $testRoot 'keep.gho'; Set-Content $keptImage 'image'
    $modulePath=Join-Path $testRoot 'Modules\Hyper-V'
    New-Item -ItemType Directory -Path $modulePath -Force | Out-Null
    @'
function Get-VM { [pscustomobject]@{Id=[guid]$env:VMH_TEST_ID;State=$env:VMH_TEST_STATE} }
function Get-VMHardDiskDrive { param($VM) [pscustomobject]@{Path=(Join-Path $env:VMH_TEST_JOB 'Windows.vhdx')} }
function Get-VHD { param($Path) [pscustomobject]@{Attached=$false} }
function Remove-VM { param($VM,[switch]$Force) Set-Content (Join-Path $env:VMH_TEST_ROOT 'vm-removed.txt') 'removed' }
Export-ModuleMember -Function Get-VM,Get-VMHardDiskDrive,Get-VHD,Remove-VM
'@ | Set-Content (Join-Path $modulePath 'Hyper-V.psm1')
    $originalModulePath=$env:PSModulePath
    try {
        $env:PSModulePath=(Join-Path $testRoot 'Modules')+';'+$originalModulePath
        $env:VMH_TEST_ROOT=$testRoot; $env:VMH_TEST_JOB=$job; $env:VMH_TEST_ID=$vmId; $env:VMH_TEST_STATE='Running'
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($job))
        $backend=Join-Path $testRoot 'VmHistory.ps1'
        $backendText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\VmHistory.ps1')).Replace('Local\GhostImageAppVmWizard',('Local\VmHistoryTest-'+[guid]::NewGuid().ToString('N')))
        [IO.File]::WriteAllText($backend,$backendText,(New-Object Text.UTF8Encoding($true)))
        $ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $prior=$ErrorActionPreference; $ErrorActionPreference='Continue'
        $blockedOutput=& $ps -NoProfile -ExecutionPolicy Bypass -File $backend -Action Delete -Root $testRoot -HistoryRoots (Join-Path $testRoot 'AutoBuilds') -EntryBase64 $encoded 2>&1
        $blockedCode=$LASTEXITCODE; $ErrorActionPreference=$prior
        if($blockedCode -ne 1 -or -not(Test-Path $job) -or (Test-Path (Join-Path $testRoot 'vm-removed.txt'))){throw 'Running VM deletion was not blocked'}
        $env:VMH_TEST_STATE='Off'
        & $ps -NoProfile -ExecutionPolicy Bypass -File $backend -Action Delete -Root $testRoot -HistoryRoots (Join-Path $testRoot 'AutoBuilds') -EntryBase64 $encoded
        if($LASTEXITCODE -ne 0 -or (Test-Path $job) -or -not(Test-Path (Join-Path $testRoot 'vm-removed.txt')) -or -not(Test-Path $keptImage)){throw 'Owned deletion or GHO preservation failed'}
    } finally {
        $env:PSModulePath=$originalModulePath
        foreach($name in @('VMH_TEST_ROOT','VMH_TEST_JOB','VMH_TEST_ID','VMH_TEST_STATE')){Remove-Item -LiteralPath ('Env:\'+$name) -ErrorAction SilentlyContinue}
    }
    'PASS: owned history discovery, foreign app exclusion, disk path boundary, junction deletion guard, running VM block, VM unregister + file deletion, external GHO preserved.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $tempPrefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid cleanup target'}
    # Remove a fixture junction itself before recursive cleanup, even on failed assertions.
    $link=Join-Path $testRoot 'AutoBuilds\20261021-test\linked'
    if(Test-Path -LiteralPath $link){Remove-Item -LiteralPath $link -Force}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
