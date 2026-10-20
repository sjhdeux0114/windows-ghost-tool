param([ValidateSet('List','Delete','OpenVm','Detach')][string]$Action='List',[string]$Root=$PSScriptRoot,[string]$EntryBase64='',[string[]]$HistoryRoots=@(),[switch]$ValidateOnly)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
function Full([string]$p) { [IO.Path]::GetFullPath($p).TrimEnd('\') }
function NoLinks([string]$p) {
    $cursor=$p
    while($cursor) {
        if((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "연결 경로는 삭제할 수 없습니다: $cursor" }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}
function CheckTree([string]$p) {
    foreach($item in Get-ChildItem -LiteralPath $p -Force) {
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "연결 파일 또는 폴더가 있습니다: $($item.FullName)" }
        if($item.PSIsContainer) { CheckTree $item.FullName }
    }
}
function ReadJson([string]$p) { if(Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } }
function Entries([string[]]$SearchRoots=@()) {
    $roots=@((Join-Path $Root 'AutoBuilds'),'C:\GhostAutoBuilds')
    $registry=Join-Path $Root 'vm-history-roots.txt'
    if(Test-Path -LiteralPath $registry) { $roots+=@(Get-Content -LiteralPath $registry) }
    $pointer=Join-Path $Root 'retry-job.txt'
    if(Test-Path -LiteralPath $pointer) { $roots+=[IO.Path]::GetDirectoryName((Get-Content -LiteralPath $pointer -Raw).Trim()) }
    if($SearchRoots.Count -gt 0){$roots=$SearchRoots} elseif($HistoryRoots.Count -gt 0){$roots=$HistoryRoots}
    $paths=@()
    foreach($r in ($roots | Select-Object -Unique)) {
        if(-not $r -or $r.StartsWith('\\')){continue}
        $r=Full $r
        if((Split-Path $r -Leaf) -notin @('AutoBuilds','GhostAutoBuilds')){continue}
        if(Test-Path -LiteralPath $r) { NoLinks $r; $paths+=@(Get-ChildItem -LiteralPath $r -Directory | Select-Object -ExpandProperty FullName) }
    }
    $manual=ReadJson (Join-Path $Root 'vm-project.json')
    if($manual -and $manual.Vhd) { $paths+=[IO.Path]::GetDirectoryName($manual.Vhd) }
    foreach($p in ($paths | Select-Object -Unique)) {
        $p=Full $p
        NoLinks $p
        $project=ReadJson (Join-Path $p 'project.json')
        $environment=ReadJson (Join-Path $p 'environment.json')
        $isManual=$manual -and ((Full ([IO.Path]::GetDirectoryName($manual.Vhd))) -eq $p)
        if($isManual) {
            $manualRoot=Full (Join-Path $Root 'VirtualMachines')
            if([IO.Path]::GetDirectoryName($p) -ne $manualRoot){continue}
            $project=$manual
        } elseif(-not $environment -or (Full $environment.AppDirectory) -ne (Full $Root)) { continue }
        $vhd=Join-Path $p 'Windows.vhdx'
        if($project -and (Full $project.Vhd) -ne (Full $vhd)){throw "VM 디스크 경로가 내역과 다릅니다: $p"}
        $result=ReadJson (Join-Path $p 'result.json')
        $exitFile=Join-Path $p 'exit-code.txt'
        $status=if($result.Verified){'이미지 생성 완료'}elseif(Test-Path $exitFile){'중단 / 실패'}else{'진행 중 / 미완료'}
        $id=if($project){[string]$project.Id}else{''}
        $name=if($project){[string]$project.Name}else{Split-Path $p -Leaf}
        [pscustomobject]@{Path=$p;Name=$name;Id=$id;Status=$status;Created=(Get-Item -LiteralPath $p).CreationTime.ToString('yyyy-MM-dd HH:mm:ss');Manual=[bool]$isManual}
    }
}
if($ValidateOnly){return}
try {
    $Root=Full $Root
    if($Action -eq 'List') {
        $rows=@(Entries | Sort-Object Created -Descending)
        try {
            Import-Module Hyper-V
            foreach($row in $rows) { if($row.Id){$vm=Get-VM -Id ([guid]$row.Id) -ErrorAction SilentlyContinue;if($vm){$row.Status+=' / '+$vm.State}} }
        } catch { }
        ConvertTo-Json -InputObject $rows -Depth 4 -Compress
        exit 0
    }
    $target=Full ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EntryBase64)))
    if($Action -eq 'OpenVm'){
        $matches=@(Entries | Where-Object Path -eq $target)
        if($matches.Count -ne 1 -or -not $matches[0].Id){throw '등록된 VM이 없습니다. 디스크 위치 열기로 작업 파일을 확인하세요.'}
        Import-Module Hyper-V
        $vm=Get-VM -Id ([guid]$matches[0].Id)
        Start-Process -FilePath "$env:WINDIR\System32\vmconnect.exe" -ArgumentList @('localhost','-G',$vm.Id.ToString()) -WindowStyle Normal
        'VM 연결 창을 열었습니다. VM 전원 상태는 변경하지 않았습니다.'
        exit 0
    }
    $mutex=New-Object Threading.Mutex($false,'Local\GhostImageAppVmWizard')
    $locked=$mutex.WaitOne(0)
    if(-not $locked){throw '가상 Windows 생성 작업이 진행 중입니다. 완료 후 삭제하세요.'}
    try {
        if(Get-Process Ghost64 -ErrorAction SilentlyContinue){throw 'Ghost 작업이 진행 중입니다. 완료 후 삭제하세요.'}
        $matches=@(Entries | Where-Object Path -eq $target)
        if($matches.Count -ne 1){throw '삭제할 생성 내역을 다시 확인할 수 없습니다.'}
        $entry=$matches[0]
        NoLinks $target
        CheckTree $target
        if($Action -eq 'Delete' -and @(Get-ChildItem -LiteralPath $target -Recurse -File | Where-Object Extension -in @('.gho','.ghs')).Count -gt 0){throw '작업 폴더 안에 GHO 이미지가 있습니다. 이미지를 다른 폴더로 옮긴 뒤 삭제하세요.'}
        Import-Module Hyper-V
        $vms=@(Get-VM)
        $owners=@()
        foreach($vm in $vms) {
            $hdds=@(Get-VMHardDiskDrive -VM $vm)
            $inside=@($hdds | Where-Object { $_.Path -and (Full $_.Path).StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase) })
            if(($entry.Id -and $vm.Id.ToString() -eq $entry.Id) -or $inside.Count -gt 0) {
                if($vm.Id.ToString() -ne $entry.Id){throw '다른 VM이 이 디스크를 사용 중이므로 삭제할 수 없습니다.'}
                if($vm.State -ne 'Off'){throw 'VM을 정상 종료한 뒤 삭제하세요. 실행 중인 VM은 삭제하지 않습니다.'}
                if($inside.Count -ne $hdds.Count){throw 'VM에 내역 폴더 밖의 디스크가 연결되어 있습니다.'}
                $owners+=$vm
            }
        }
        $diskFiles=@(Get-ChildItem -LiteralPath $target -Recurse -File | Where-Object Extension -in @('.vhd','.vhdx','.avhd','.avhdx'))
        if($Action -eq 'Detach'){
            $attached=@()
            foreach($file in $diskFiles){
                $v=Get-VHD -Path $file.FullName
                if($v.Attached){
                    $physical=@($v | Get-Disk)
                    if($physical.Count -ne 1 -or $physical[0].IsBoot -or $physical[0].IsSystem){throw '시스템 또는 확인할 수 없는 디스크는 연결 해제할 수 없습니다.'}
                    $attached+=$file.FullName
                }
            }
            foreach($path in $attached){Dismount-VHD -Path $path -ErrorAction Stop}
            '가상 디스크 연결 해제를 완료했습니다. 이제 삭제하기를 사용할 수 있습니다.'
            exit 0
        }
        foreach($file in $diskFiles){$v=Get-VHD -Path $file.FullName;if($v.Attached){throw '가상 디스크가 연결되어 있습니다. 연결 해제 후 삭제하세요.'}}
        foreach($vm in $owners){Remove-VM -VM $vm -Force}
        # Exact, revalidated generated directory only. No output GHO outside this folder is removed.
        Remove-Item -LiteralPath $target -Recurse -Force
        $launcher=$target+'.launcher.log'
        if(Test-Path -LiteralPath $launcher){Remove-Item -LiteralPath $launcher -Force}
        if($entry.Manual){Remove-Item -LiteralPath (Join-Path $Root 'vm-project.json') -Force}
        $pointer=Join-Path $Root 'retry-job.txt'
        if((Test-Path $pointer) -and ((Get-Content $pointer -Raw).Trim() -eq $target)){Remove-Item -LiteralPath $pointer -Force}
        '가상 Windows와 디스크 파일, 생성 내역을 삭제했습니다.'
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
