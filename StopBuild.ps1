param([Parameter(Mandatory=$true)][string]$JobDirectory,[int]$WorkerId=0)
$ErrorActionPreference='Stop'
try {
    $job=[IO.Path]::GetFullPath($JobDirectory).TrimEnd('\')
    if($job.StartsWith('\\') -or -not(Test-Path -LiteralPath (Join-Path $job 'environment.json'))){throw '빌드 작업 폴더를 확인할 수 없습니다.'}
    $environment=Get-Content -LiteralPath (Join-Path $job 'environment.json') -Raw | ConvertFrom-Json
    if([IO.Path]::GetFullPath($environment.AppDirectory).TrimEnd('\') -ne $PSScriptRoot.TrimEnd('\')){throw '이 앱이 생성한 작업만 중단할 수 있습니다.'}
    $all=@(Get-CimInstance Win32_Process)
    $worker=$all | Where-Object ProcessId -eq $WorkerId
    if($worker -and ($worker.Name -ne 'powershell.exe' -or $worker.CommandLine -notlike '*AutoBuild.ps1*' -or $worker.CommandLine.IndexOf($job,[StringComparison]::OrdinalIgnoreCase) -lt 0)){throw '빌드 프로세스가 일치하지 않습니다.'}
    $projectFile=Join-Path $job 'project.json'
    $vm=$null
    if(Test-Path -LiteralPath $projectFile){
        Import-Module Hyper-V
        $project=Get-Content -LiteralPath $projectFile -Raw | ConvertFrom-Json
        $expected=Join-Path $job 'Windows.vhdx'
        if($project.Vhd -ne $expected){throw 'VM 디스크 경로가 일치하지 않습니다.'}
        $vm=Get-VM -Id ([guid]$project.Id) -ErrorAction SilentlyContinue
        if($vm){$disks=@(Get-VMHardDiskDrive -VM $vm);if($disks.Count -ne 1 -or $disks[0].Path -ne $expected){throw 'VM 디스크 구성이 변경되었습니다.'}}
    }
    Set-Content -LiteralPath (Join-Path $job 'cancel-requested.txt') -Value (Get-Date -Format o)
    $children=@()
    $parents=@($WorkerId)
    while($parents.Count -gt 0 -and $WorkerId -gt 0){$next=@($all | Where-Object {$parents -contains $_.ParentProcessId -and $_.ProcessId -ne $PID});$children+=$next;$parents=@($next | Select-Object -ExpandProperty ProcessId)}
    if($worker){Stop-Process -Id $worker.ProcessId -Force}
    foreach($child in $children){$now=Get-CimInstance Win32_Process -Filter "ProcessId=$($child.ProcessId)";if($now -and $now.CreationDate -eq $child.CreationDate){Stop-Process -Id $now.ProcessId -Force -ErrorAction SilentlyContinue}}
    if($vm -and $vm.State -ne 'Off'){Stop-VM -VM $vm -TurnOff -Confirm:$false}
    # Do not detach or delete disks here: the history screen handles cleanup separately.
    Add-Content -LiteralPath (Join-Path $job 'build.log') -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'  사용자 요청으로 강제 중단. 미완성 결과는 사용하지 마세요.')
    Set-Content -LiteralPath (Join-Path $job 'exit-code.txt') -Value '1223'
    '작업과 해당 VM을 강제 중단했습니다. 작업 파일은 보존했습니다.'
} catch {[Console]::Error.WriteLine($_.Exception.Message);exit 1}
