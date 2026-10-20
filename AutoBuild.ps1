param(
    [string]$IsoPath,
    [string]$JobDirectory,
    [string]$OutputPath,
    [ValidateSet('Auto','7','10','11')][string]$WindowsFamily='Auto',
    [ValidateSet('Auto','UEFI','BIOS')][string]$BootMode='Auto',
    [int]$ImageIndex=0,
    [ValidateRange(2,1048576)][int]$MemoryGB=8,
    [ValidateRange(1,2048)][int]$ProcessorCount=4,
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
$script:started=Get-Date
$script:sequence=0

function Write-Stage([string]$message) {
    $line="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $message"
    [IO.File]::AppendAllText($script:logPath,$line+[Environment]::NewLine,[Text.Encoding]::UTF8)
    $script:sequence++
    $event=@{ Sequence=$script:sequence; Timestamp=(Get-Date).ToString('o'); ElapsedSeconds=[math]::Round(((Get-Date)-$script:started).TotalSeconds,2); Message=$message } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText((Join-Path $JobDirectory 'events.jsonl'),$event+[Environment]::NewLine,[Text.Encoding]::UTF8)
}
function Invoke-Native([string]$exe,[string[]]$arguments) {
    Write-Stage ('실행: '+$exe+' '+($arguments -join ' '))
    # Windows PowerShell treats redirected native stderr as an ErrorRecord.
    # Capture the entire output before checking the actual process exit code.
    $previousPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $nativeOutput=@(& $exe @arguments 2>&1)
        $nativeExitCode=$LASTEXITCODE
    } finally { $ErrorActionPreference=$previousPreference }
    foreach ($line in $nativeOutput) { Write-Stage "$line" }
    Write-Stage ("종료 코드: $nativeExitCode")
    if ($nativeExitCode -ne 0) { throw "$([IO.Path]::GetFileName($exe)) 실패: 종료 코드 $nativeExitCode" }
}
function Assert-JobPath([string]$path) {
    $root=[IO.Path]::GetFullPath($JobDirectory).TrimEnd('\')+'\'
    $full=[IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { throw '작업 폴더 밖의 파일 작업을 차단했습니다.' }
}
function Get-OwnedDisk([string]$path) {
    Assert-JobPath $path
    $v=Get-VHD -Path $path
    if (-not $v.Attached) { throw '작업용 VHDX가 연결되어 있지 않습니다.' }
    $disk=@($v | Get-Disk)
    if ($disk.Count -ne 1 -or $disk[0].IsBoot -or $disk[0].IsSystem) { throw '안전한 가상 디스크를 식별할 수 없습니다.' }
    if ($disk[0].Size -ne $script:diskSize) { throw '가상 디스크 크기가 변경되었습니다.' }
    return $disk[0]
}
function Get-WindowsFamily([string]$name,[string]$version) {
    if ($name -match '(?i)server') { throw 'Windows Server ISO는 지원하지 않습니다.' }
    $v=$null
    if ([version]::TryParse($version,[ref]$v)) {
        if ($v.Major -eq 6 -and $v.Minor -eq 1) { return '7' }
        if ($v.Major -eq 10 -and $v.Minor -eq 0) { if ($v.Build -ge 22000) { return '11' }; return '10' }
        throw "지원 대상이 아닌 Windows 버전입니다: $version"
    }
    if ($name -match '(?i)Windows\s*(7|10|11)\b') { return $Matches[1] }
    return 'Unknown'
}
function New-OwnedUefiBootStore([string]$vhd,[string]$windowsRoot,[string]$efiRoot) {
    $owned=Get-OwnedDisk $vhd
    foreach ($root in @($windowsRoot,$efiRoot)) {
        if ($root -notmatch '^[A-Z]:\\$') { throw '드라이브 문자 루트가 필요합니다.' }
        $part=Get-Partition -DriveLetter $root.Substring(0,1)
        if ($part.DiskNumber -ne $owned.Number) { throw '작업 VM 밖의 부팅 구성 변경을 차단했습니다.' }
    }
    # Build a separate, non-system BCD file. Never unload the host BCD hive.
    $store=Join-Path $JobDirectory ('boot-'+[guid]::NewGuid().ToString('N')+'.bcd')
    Assert-JobPath $store
    $editor=Join-Path $env:WINDIR 'System32\bcdedit.exe'
    $loader='{'+[guid]::NewGuid().ToString()+'}'
    Invoke-Native $editor @('/createstore',$store)
    Invoke-Native $editor @('/store',$store,'/create','{bootmgr}','/d','Windows Boot Manager')
    Invoke-Native $editor @('/store',$store,'/set','{bootmgr}','device',('partition='+$efiRoot.TrimEnd('\')))
    Invoke-Native $editor @('/store',$store,'/set','{bootmgr}','path','\EFI\Microsoft\Boot\bootmgfw.efi')
    Invoke-Native $editor @('/store',$store,'/create',$loader,'/d','Windows','/application','osloader')
    foreach ($element in @('device','osdevice')) {
        Invoke-Native $editor @('/store',$store,'/set',$loader,$element,('partition='+$windowsRoot.TrimEnd('\')))
    }
    Invoke-Native $editor @('/store',$store,'/set',$loader,'path','\Windows\system32\winload.efi')
    Invoke-Native $editor @('/store',$store,'/set',$loader,'systemroot','\Windows')
    Invoke-Native $editor @('/store',$store,'/default',$loader)
    Invoke-Native $editor @('/store',$store,'/displayorder',$loader,'/addlast')
    Invoke-Native $editor @('/store',$store,'/timeout','0')
    Invoke-Native $editor @('/store',$store,'/enum','all')
    $bootDir=Join-Path $efiRoot 'EFI\Microsoft\Boot'
    foreach ($file in @('bootmgfw.efi','bootmgr.efi')) {
        if (-not (Test-Path -LiteralPath (Join-Path $bootDir $file))) { throw "UEFI 부팅 파일 누락: $file" }
    }
    $fallback=Join-Path $efiRoot 'EFI\Boot'
    [void][IO.Directory]::CreateDirectory($fallback)
    Copy-Item -LiteralPath (Join-Path $bootDir 'bootmgfw.efi') -Destination (Join-Path $fallback 'bootx64.efi') -Force
    Copy-Item -LiteralPath $store -Destination (Join-Path $bootDir 'BCD') -Force
    Write-Stage '작업 디스크 전용 BCD 파일 생성 및 배치 완료. VM 부팅으로 검증합니다.'
}
function New-AuditAnswer([string]$architecture) {
    if ($architecture -notin @('amd64','x86')) { throw '지원하지 않는 아키텍처입니다.' }
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
 <settings pass="specialize">
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><ComputerName>GhostReference</ComputerName></component>
 </settings>
 <settings pass="oobeSystem">
  <component name="Microsoft-Windows-Deployment" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><Reseal><Mode>Audit</Mode></Reseal></component>
 </settings>
 <settings pass="auditUser">
  <component name="Microsoft-Windows-Deployment" processorArchitecture="$architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Description>Start independent image sealing task</Description><Path>cmd.exe /c C:\GhostBuild\StartSeal.cmd</Path></RunSynchronousCommand></RunSynchronous>
  </component>
 </settings>
</unattend>
"@
}
function Assert-Sealed([string]$windowsPath) {
    $state=Join-Path $windowsPath 'Setup\State\State.ini'
    if (-not (Test-Path -LiteralPath $state)) { throw 'Windows 설치 상태 파일이 없습니다.' }
    $text=[IO.File]::ReadAllText($state)
    if ($text -notmatch '(?im)^\s*ImageState\s*=\s*"?IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE"?\s*$') {
        throw 'Sysprep 일반화 완료 상태가 아닙니다. Ghost 캡처를 중단합니다.'
    }
}
function New-SealTaskXml {
    return @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
 <Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers>
 <Principals><Principal id="System"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
 <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><Enabled>true</Enabled><ExecutionTimeLimit>PT2H</ExecutionTimeLimit></Settings>
 <Actions Context="System"><Exec><Command>C:\Windows\System32\cmd.exe</Command><Arguments>/d /c C:\GhostBuild\RunSeal.cmd</Arguments></Exec></Actions>
</Task>
'@
}
function Convert-FixedVhdToFlat([string]$path,[long]$expectedSize) {
    Assert-JobPath $path
    $f=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        if ($f.Length -ne $expectedSize+512) { throw '고정 VHD 길이가 예상과 다릅니다.' }
        [void]$f.Seek(-512,[IO.SeekOrigin]::End)
        $footer=New-Object byte[] 512
        if ($f.Read($footer,0,512) -ne 512 -or [Text.Encoding]::ASCII.GetString($footer,0,8) -ne 'conectix') { throw 'VHD footer가 올바르지 않습니다.' }
        $typeBytes=$footer[60..63]; [Array]::Reverse($typeBytes)
        if ([BitConverter]::ToUInt32([byte[]]$typeBytes,0) -ne 2) { throw '고정 VHD가 아닙니다.' }
        $sizeBytes=$footer[48..55]; [Array]::Reverse($sizeBytes)
        if ([BitConverter]::ToUInt64([byte[]]$sizeBytes,0) -ne $expectedSize) { throw 'VHD 내부 용량이 다릅니다.' }
        $checkBytes=$footer[64..67]; [Array]::Reverse($checkBytes)
        $checksum=[BitConverter]::ToUInt32([byte[]]$checkBytes,0)
        [uint32]$sum=0
        for ($i=0;$i -lt 512;$i++) { if ($i -lt 64 -or $i -gt 67) { $sum+=$footer[$i] } }
        if ($checksum -ne ([uint32]::MaxValue - $sum)) { throw 'VHD footer 체크섬이 일치하지 않습니다.' }
        $f.SetLength($expectedSize)
    } finally { $f.Dispose() }
}
function New-VmdkDescriptor([long]$size,[string]$flatName) {
    if ($size -le 0 -or $size%512 -ne 0 -or $flatName -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'VMDK 데이터 정보가 올바르지 않습니다.' }
    $sectors=[long]($size/512)
    $cylinders=[long][Math]::Floor($sectors/(255*63))
    return @"
# Disk DescriptorFile
version=1
encoding="UTF-8"
CID=12345678
parentCID=ffffffff
createType="monolithicFlat"

RW $sectors FLAT "$flatName" 0

ddb.adapterType = "ide"
ddb.geometry.cylinders = "$cylinders"
ddb.geometry.heads = "255"
ddb.geometry.sectors = "63"
ddb.virtualHWVersion = "6"
"@
}
function Invoke-GhostCapture([string]$ghost,[string]$descriptor,[string]$output) {
    Assert-JobPath $descriptor
    Assert-OutputPath $output
    if ([IO.Path]::GetExtension($descriptor) -ne '.vmdk' -or -not (Test-Path -LiteralPath $descriptor)) { throw '캡처용 VMDK가 없습니다.' }
    if (Test-Path -LiteralPath $output) { throw '기존 GHO 파일을 덮어쓰지 않습니다.' }
    # -ad loads exactly one virtual file at Ghost disk 50. Never infer a host physical disk number.
    $args='"-ad='+$descriptor+'" "-clone,mode=create,src=50,dst='+$output+'" -z1 -batch -sure -fx "-afile='+(Join-Path $JobDirectory 'ghost-create-error.txt')+'"'
    Write-Stage "Ghost 실행: $ghost $args"
    $p=Start-Process -FilePath $ghost -ArgumentList $args -WorkingDirectory $JobDirectory -PassThru
    $p.WaitForExit()
    Write-Stage "Ghost 생성 종료 코드: $($p.ExitCode)"
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $output) -or (Get-Item -LiteralPath $output).Length -eq 0) {
        throw "Ghost 이미지 생성 실패 (종료 코드 $($p.ExitCode)). 작업 폴더의 GHOSTERR.TXT를 확인하세요."
    }
    Write-Stage 'GHO 생성 완료. Ghost 무결성 검사를 실행합니다.'
    $checkArgs='"-chkimg,'+$output+'" -batch -fx "-afile='+(Join-Path $JobDirectory 'ghost-check-error.txt')+'"'
    Write-Stage "Ghost 검사 실행: $ghost $checkArgs"
    $p=Start-Process -FilePath $ghost -ArgumentList $checkArgs -WorkingDirectory $JobDirectory -PassThru
    $p.WaitForExit()
    Write-Stage "Ghost 무결성 검사 종료 코드: $($p.ExitCode)"
    if ($p.ExitCode -ne 0) { throw "Ghost 이미지 무결성 검사 실패: $($p.ExitCode)" }
}

function Assert-OutputPath([string]$path) {
    if ([IO.Path]::GetExtension($path) -ne '.gho' -or $path.IndexOfAny([char[]]",`"`r`n") -ge 0 -or $path.StartsWith('\\')) { throw '쉼표와 따옴표가 없는 로컬 .gho 경로를 지정하세요.' }
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($path)))) { throw 'GHO 저장 폴더가 없습니다.' }
    if (Test-Path -LiteralPath $path) { throw '기존 GHO 파일을 덮어쓰지 않습니다.' }
    if (@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($path)) -Filter ([IO.Path]::GetFileNameWithoutExtension($path)+'*.ghs')).Count -gt 0) { throw '같은 이름의 분할 이미지가 있습니다. 다른 이름을 사용하세요.' }
}

if ($ValidateOnly) { return }
$script:diskSize=40GB
$vm=$null; $mounted=$false; $isoOwned=$false; $isoImage=$null; $credential=$null
$exitCode=1; $mutex=$null; $hasMutex=$false
try {
    if ([string]::IsNullOrWhiteSpace($JobDirectory)) { throw '작업 폴더가 필요합니다.' }
    $JobDirectory=[IO.Path]::GetFullPath($JobDirectory)
    if ($JobDirectory.IndexOfAny([char[]]",`"`r`n") -ge 0 -or $JobDirectory.StartsWith('\\')) { throw '쉼표와 따옴표가 없는 로컬 작업 경로가 필요합니다.' }
    # Every run owns a brand-new directory. Existing projects are never reinitialized.
    if (Test-Path -LiteralPath $JobDirectory) { throw '이미 존재하는 작업 폴더입니다. 새 작업으로 시작하세요.' }
    [void][IO.Directory]::CreateDirectory($JobDirectory)
    $script:logPath=Join-Path $JobDirectory 'build.log'
    Write-Stage '자동 빌드 시작: Windows 판별 → ISO 적용 → VM 부팅 → Sysprep → GHO 생성 → 무결성 검사'
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '관리자 권한이 필요합니다.' }
    # Restrict temporary audit credentials and build files to this user and SYSTEM/Administrators.
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @($id.User.Value,'S-1-5-18','S-1-5-32-544')) {
        $rule=New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $JobDirectory -AclObject $acl
    Start-Transcript -LiteralPath (Join-Path $JobDirectory 'powershell-transcript.txt') -Force | Out-Null
    $script:transcriptStarted=$true
    $environment=@{ Started=$started.ToString('o'); PowerShell=$PSVersionTable.PSVersion.ToString(); HostOS=[Environment]::OSVersion.ToString(); Is64Bit=[Environment]::Is64BitProcess; ISO=$IsoPath; Output=$OutputPath; AppDirectory=$PSScriptRoot }
    $environment | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $JobDirectory 'environment.json') -Encoding UTF8
    $mutex=New-Object Threading.Mutex($false,'Local\GhostImageAppVmWizard')
    $hasMutex=$mutex.WaitOne(0)
    if (-not $hasMutex) { throw '다른 가상 Windows 작업 창이 열려 있습니다. 먼저 종료하세요.' }
    if (Get-Process Ghost64 -ErrorAction SilentlyContinue) { throw '이미 실행 중인 Ghost를 먼저 종료하세요.' }
    $feature=Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
    if ($feature.State -ne 'Enabled') {
        Write-Stage 'Hyper-V 활성화 중. Windows Home에서는 이 기능을 지원하지 않습니다.'
        $result=Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
        if ($result.RestartNeeded) { $exitCode=3010; throw 'Hyper-V 설치 완료. PC를 재부팅한 뒤 가상 Windows 만들기를 다시 누르세요.' }
    }
    Import-Module Hyper-V -ErrorAction Stop
    $hostInfo=Get-VMHost -ErrorAction Stop
    $hostMemory=(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    if ($MemoryGB*1GB -gt $hostMemory -or $ProcessorCount -gt [Environment]::ProcessorCount) { throw '선택한 VM 사양이 이 PC의 RAM 또는 논리 CPU 수를 초과합니다.' }
    Write-Stage "선택한 VM 사양: RAM ${MemoryGB}GB / CPU $ProcessorCount 개"
    $ghost=Join-Path $PSScriptRoot 'Ghost64.exe'
    if (-not (Test-Path -LiteralPath $ghost)) { throw 'Ghost64.exe가 없습니다.' }
    if ((Get-Item -LiteralPath $ghost).VersionInfo.FileMajorPart -lt 12) { throw '자동 가상 디스크 캡처는 Ghost 12 이상을 요구합니다.' }
    Write-Stage "Ghost 버전: $((Get-Item -LiteralPath $ghost).VersionInfo.FileVersion)"
    $IsoPath=(Resolve-Path -LiteralPath $IsoPath).ProviderPath
    Write-Stage "ISO: $IsoPath / $((Get-Item -LiteralPath $IsoPath).Length) bytes. SHA256 계산 중..."
    Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256 | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $JobDirectory 'iso-sha256.json') -Encoding UTF8
    if ([IO.Path]::GetExtension($IsoPath) -ne '.iso') { throw 'Windows ISO를 선택하세요.' }
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($JobDirectory))
    if ($drive.DriveFormat -notin @('NTFS','ReFS')) { throw '작업 디스크는 NTFS 또는 ReFS여야 합니다.' }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath=Join-Path $JobDirectory 'Windows.gho' }
    $OutputPath=[IO.Path]::GetFullPath($OutputPath); Assert-OutputPath $OutputPath
    $isoImage=Get-DiskImage -ImagePath $IsoPath
    if (-not $isoImage.Attached) { $isoImage=Mount-DiskImage -ImagePath $IsoPath -PassThru; $isoOwned=$true }
    $isoVolumes=@($isoImage | Get-Volume | Where-Object DriveLetter)
    if ($isoVolumes.Count -ne 1) { throw 'ISO 드라이브를 식별할 수 없습니다.' }
    $isoRoot="$($isoVolumes[0].DriveLetter):\"
    $image=Join-Path $isoRoot 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $image)) { $image=Join-Path $isoRoot 'sources\install.esd' }
    if (-not (Test-Path -LiteralPath $image)) { throw 'ISO에서 install.wim 또는 install.esd를 찾지 못했습니다. 분할 SWM ISO는 지원하지 않습니다.' }
    $images=@(Get-WindowsImage -ImagePath $image)
    if ($ImageIndex -gt 0) { $chosen=$images | Where-Object ImageIndex -eq $ImageIndex | Select-Object -First 1 }
    else {
        $chosen=$images | Where-Object ImageName -match '(?i)^Windows (7 Professional|10 Pro|11 Pro)$' | Select-Object -First 1
        if (-not $chosen) { $chosen=$images | Select-Object -First 1 }
    }
    if (-not $chosen) { throw '선택한 Windows 이미지 인덱스가 없습니다.' }
    $detail=Get-WindowsImage -ImagePath $image -Index $chosen.ImageIndex
    $images | Select-Object ImageIndex,ImageName,ImageDescription | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $JobDirectory 'iso-images.json') -Encoding UTF8
    $detail | Select-Object * | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $JobDirectory 'selected-image.json') -Encoding UTF8
    $detected=Get-WindowsFamily ([string]$chosen.ImageName) ([string]$detail.Version)
    if ($detected -eq 'Unknown') {
        if ($WindowsFamily -eq 'Auto') { $exitCode=20; throw 'Windows 버전을 자동 판별하지 못했습니다. 앱에서 Windows 7/10/11 중 선택하세요.' }
        $detected=$WindowsFamily
    } elseif ($WindowsFamily -ne 'Auto' -and $detected -ne $WindowsFamily) { throw '사용자가 선택한 Windows 버전과 ISO 내부 버전이 다릅니다.' }
    $architecture=if ([string]$detail.Architecture -in @('9','amd64','x64')) { 'amd64' } elseif ([string]$detail.Architecture -in @('0','x86')) { 'x86' } else { throw 'ARM 또는 판별할 수 없는 아키텍처는 지원하지 않습니다.' }
    if ($detected -eq '11' -and $architecture -ne 'amd64') { throw 'Windows 11은 x64 ISO만 지원합니다.' }
    if ($BootMode -eq 'Auto') { $BootMode=if ($detected -eq '7' -or $architecture -eq 'x86') { 'BIOS' } else { 'UEFI' } }
    if (($detected -eq '7' -or $architecture -eq 'x86') -and $BootMode -ne 'BIOS') { throw 'Windows 7 또는 x86은 이 도구에서 BIOS VM을 사용해야 합니다.' }
    if ($detected -eq '11' -and $BootMode -ne 'UEFI') { throw 'Windows 11은 UEFI VM이 필요합니다.' }
    $script:diskSize=if ($detected -eq '11') { 64GB } else { 40GB }
    $need=3*$diskSize+8GB
    if ($drive.AvailableFreeSpace -lt $need) { throw "작업 드라이브에 $([math]::Ceiling($need/1GB))GiB 이상의 여유 공간이 필요합니다. 다른 드라이브를 저장 위치로 선택하세요." }
    Write-Stage "자동 판별: Windows $detected / $architecture / $($detail.Version)."
    if ((New-Object IO.DriveInfo([IO.Path]::GetPathRoot($OutputPath))).AvailableFreeSpace -lt $diskSize+2GB) {
        throw 'GHO 저장 드라이브 공간이 부족합니다.'
    }
    Write-Stage "선택 이미지: $($chosen.ImageName), 인덱스 $($chosen.ImageIndex), $BootMode. 네트워크 없는 새 VM에 설치합니다."
    $vhdPath=Join-Path $JobDirectory 'Windows.vhdx'
    New-VHD -Path $vhdPath -SizeBytes $diskSize -Dynamic -LogicalSectorSizeBytes 512 | Out-Null
    Mount-VHD -Path $vhdPath -NoDriveLetter | Out-Null; $mounted=$true
    $disk=Get-OwnedDisk $vhdPath
    if ($disk.PartitionStyle -ne 'RAW') { throw '새 가상 디스크가 RAW 상태가 아닙니다.' }
    $style=if ($BootMode -eq 'UEFI') { 'GPT' } else { 'MBR' }
    $disk | Initialize-Disk -PartitionStyle $style | Out-Null
    $disk=Get-OwnedDisk $vhdPath
    if ($BootMode -eq 'UEFI') {
        $system=New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter
        $system | Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
        New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
    } else {
        $system=New-Partition -DiskNumber $disk.Number -Size 550MB -IsActive -AssignDriveLetter
        $system | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    }
    $os=New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    $os | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $osRoot="$($os.DriveLetter):\"; $systemRoot="$($system.DriveLetter):\"
    Write-Stage 'Windows 이미지 적용 중. 이 단계는 수 분 이상 걸릴 수 있습니다.'
    Expand-WindowsImage -ImagePath $image -Index $chosen.ImageIndex -ApplyPath $osRoot -CheckIntegrity -LogPath (Join-Path $JobDirectory 'dism.log') | Out-Null
    $bootArgs=@((Join-Path $osRoot 'Windows'),'/s',$systemRoot,'/f',$BootMode,'/v')
    if ($detected -ne '7') { $bootArgs+='/c' }
    try { Invoke-Native "$env:WINDIR\System32\bcdboot.exe" $bootArgs }
    catch {
        if ($BootMode -ne 'UEFI' -or $architecture -ne 'amd64' -or $_.Exception.Message -notmatch '183$') { throw }
        Write-Stage 'BCD 하이브 이름 충돌(183). 작업 폴더에 별도 BCD를 생성한 뒤 작업 EFI 파티션에 배치합니다.'
        New-OwnedUefiBootStore $vhdPath $osRoot $systemRoot
    }
    # Fresh offline image only: never touch the host's Windows/Panther.
    $answer=New-AuditAnswer $architecture
    $panther=Join-Path $osRoot 'Windows\Panther'; [void][IO.Directory]::CreateDirectory($panther)
    [IO.File]::WriteAllText((Join-Path $panther 'unattend.xml'),$answer,[Text.Encoding]::UTF8)
    $guestFolder=Join-Path $osRoot 'GhostBuild'; [void][IO.Directory]::CreateDirectory($guestFolder)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'GuestSeal.ps1') -Destination (Join-Path $guestFolder 'Seal.ps1')
    [IO.File]::WriteAllText((Join-Path $guestFolder 'Architecture.txt'),$architecture)
    [IO.File]::WriteAllText((Join-Path $guestFolder 'SealTask.xml'),(New-SealTaskXml),[Text.Encoding]::Unicode)
    $runSeal='@echo off'+"`r`n"+'echo %date% %time% Launching seal script >> C:\GhostBuild\launcher.log'+"`r`n"+'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\GhostBuild\Seal.ps1 >> C:\GhostBuild\launcher.log 2>&1'+"`r`n"+'exit /b %errorlevel%'+"`r`n"
    [IO.File]::WriteAllText((Join-Path $guestFolder 'RunSeal.cmd'),$runSeal,[Text.Encoding]::ASCII)
    $startSeal='@echo off'+"`r`n"+'schtasks.exe /Create /TN GhostAutoSeal /XML C:\GhostBuild\SealTask.xml /F >> C:\GhostBuild\task-start.log 2>&1'+"`r`n"+'if errorlevel 1 exit /b 1'+"`r`n"+'schtasks.exe /Run /TN GhostAutoSeal >> C:\GhostBuild\task-start.log 2>&1'+"`r`n"+'exit /b %errorlevel%'+"`r`n"
    [IO.File]::WriteAllText((Join-Path $guestFolder 'StartSeal.cmd'),$startSeal,[Text.Encoding]::ASCII)
    $answer=$null
    Dismount-VHD -Path $vhdPath; $mounted=$false
    if ($isoOwned) { Dismount-DiskImage -ImagePath $IsoPath; $isoOwned=$false }
    $gen=if ($BootMode -eq 'UEFI') { 2 } else { 1 }
    $name='GhostAuto-'+[guid]::NewGuid().ToString('N').Substring(0,12)
    $vm=New-VM -Name $name -Generation $gen -MemoryStartupBytes ($MemoryGB*1GB) -VHDPath $vhdPath -Path $JobDirectory
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Set-VMProcessor -VM $vm -Count $ProcessorCount
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes ($MemoryGB*1GB)
    if ($detected -eq '11') { Set-VMKeyProtector -VMName $name -NewLocalKeyProtector; Enable-VMTPM -VMName $name }
    @{ Id=$vm.Id.ToString(); Name=$name; Vhd=$vhdPath; ImageName=$chosen.ImageName; BootMode=$BootMode } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $JobDirectory 'project.json') -Encoding UTF8
    Write-Stage "VM 시작: $name. 자동 초기 설정과 VM 내부 Sysprep 완료를 기다립니다 (최대 120분)."
    Start-VM -VM $vm
    Write-Stage "가상 Windows 화면 확인: 연결 창에서 초기 설정 진행 상태를 확인하세요. VM: $name"
    try {
        $vmConnect=Join-Path $env:WINDIR 'System32\vmconnect.exe'
        # This window is intentionally visible so the user can inspect guest setup.
        Start-Process -FilePath $vmConnect -ArgumentList @('localhost',$name) -WindowStyle Normal -ErrorAction Stop | Out-Null
        Write-Stage '가상 컴퓨터 연결 창을 열었습니다. Windows 초기 설정과 자동 재부팅을 확인하세요. Sysprep 완료 후 VM은 자동 종료됩니다.'
    } catch {
        Write-Stage "가상 컴퓨터 연결 창을 열지 못했습니다: $($_.Exception.Message). Hyper-V 관리자에서 $name 연결을 여세요. 자동 작업은 계속 진행합니다."
    }
    $deadline=(Get-Date).AddMinutes(120)
    while ((Get-VM -Id $vm.Id).State -ne 'Off') {
        if ((Get-Date) -gt $deadline) { throw '설치/Sysprep 시간 초과. Hyper-V에서 VM과 C:\GhostBuild\seal.log를 확인하세요. 강제 종료하거나 캡처하지 않습니다.' }
        Write-Stage 'Windows 자동 설치 / Sysprep / VM 정상 종료 대기 중...'; Start-Sleep -Seconds 15
    }
    if (@(Get-VMSnapshot -VM $vm).Count -ne 0) { throw '예상하지 못한 체크포인트가 있습니다.' }
    $drives=@(Get-VMHardDiskDrive -VM $vm)
    if ($drives.Count -ne 1 -or $drives[0].Path -ne $vhdPath) { throw 'VM 디스크 구성이 변경되었습니다.' }
    Write-Stage 'VM 종료 확인. Windows 내부의 일반화 완료 상태를 검사합니다.'
    Mount-VHD -Path $vhdPath -ReadOnly -NoDriveLetter | Out-Null; $mounted=$true
    $disk=Get-OwnedDisk $vhdPath
    $osPart=@($disk | Get-Partition | Where-Object { $_.Size -gt 10GB })
    if ($osPart.Count -ne 1) { throw '검증할 Windows 파티션을 식별하지 못했습니다.' }
    $mountPoint=Join-Path $JobDirectory 'verify'; [void][IO.Directory]::CreateDirectory($mountPoint)
    $accessPath=$mountPoint.TrimEnd('\')+'\'
    $osPart[0] | Add-PartitionAccessPath -AccessPath $accessPath
    try {
        $guestLogs=Join-Path $JobDirectory 'GuestLogs'; [void][IO.Directory]::CreateDirectory($guestLogs)
        foreach ($entry in @('GhostBuild','Windows\Panther','Windows\Setup\State')) {
            $guestSource=Join-Path $mountPoint $entry
            if (Test-Path -LiteralPath $guestSource) { Copy-Item -LiteralPath $guestSource -Destination (Join-Path $guestLogs ($entry.Replace('\','-'))) -Recurse }
        }
        $panther=Join-Path $mountPoint 'Windows\System32\Sysprep\Panther'
        if (Test-Path -LiteralPath $panther) { Copy-Item -LiteralPath $panther -Destination (Join-Path $JobDirectory 'SysprepLogs') -Recurse }
        Assert-Sealed (Join-Path $mountPoint 'Windows')
    } finally { $osPart[0] | Remove-PartitionAccessPath -AccessPath $accessPath -ErrorAction SilentlyContinue }
    Dismount-VHD -Path $vhdPath; $mounted=$false
    Write-Stage "일반화 성공 확인. Ghost용 가상 디스크 변환 중 ($($diskSize/1GB)GiB 임시 파일)..."
    $fixed=Join-Path $JobDirectory 'capture.vhd'
    Convert-VHD -Path $vhdPath -DestinationPath $fixed -VHDType Fixed | Out-Null
    Convert-FixedVhdToFlat $fixed $diskSize
    $flat=Join-Path $JobDirectory 'capture-flat.vmdk'; Move-Item -LiteralPath $fixed -Destination $flat
    $descriptor=Join-Path $JobDirectory 'capture.vmdk'
    [IO.File]::WriteAllText($descriptor,(New-VmdkDescriptor $diskSize 'capture-flat.vmdk'),[Text.Encoding]::ASCII)
    $output=$OutputPath
    Write-Stage 'Ghost 이미지 생성 중. 원본은 작업용 VMDK 파일이며 호스트 물리 디스크 번호는 사용하지 않습니다.'
    Invoke-GhostCapture $ghost $descriptor $output
    # Only disposable generated conversion files are removed, and only after successful verification.
    Assert-JobPath $flat; Remove-Item -LiteralPath $flat
    Assert-JobPath $descriptor; Remove-Item -LiteralPath $descriptor
    Write-Stage "완료: $output (Ghost 무결성 검사 통과). 실제 대상 PC에서 복원·부팅 검증은 별도로 필요합니다."
    $metadata=@{ Output=$output; VM=$name; Verified=$true; BootMode=$BootMode; WindowsFamily=$detected; Architecture=$architecture; DiskSize=$diskSize }
    $metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $JobDirectory 'result.json') -Encoding UTF8
    $metadata | ConvertTo-Json | Set-Content -LiteralPath ($output+'.json') -Encoding UTF8
    $exitCode=0
} catch {
    if ($script:logPath) {
        ($_ | Format-List * -Force | Out-String) + [Environment]::NewLine + $_.ScriptStackTrace | Set-Content -LiteralPath (Join-Path $JobDirectory 'error-details.txt') -Encoding UTF8
        if ($vm) { try { Get-VM -Id $vm.Id | Select-Object Name,Id,State,Status,CPUUsage,MemoryAssigned,Uptime | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $JobDirectory 'vm-at-error.json') -Encoding UTF8 } catch { } }
    }
    if ($script:logPath) { Write-Stage "중단: $($_.Exception.Message)" }
    else { Write-Error $_ }
} finally {
    $credential=$null; $password=$null; $answer=$null
    if ($mounted) { try { Dismount-VHD -Path $vhdPath -ErrorAction Stop } catch { if ($script:logPath) { Write-Stage "가상 디스크 연결 해제 실패: $($_.Exception.Message)" } } }
    if ($isoOwned) { try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop } catch { if ($script:logPath) { Write-Stage "ISO 연결 해제 실패: $($_.Exception.Message)" } } }
    if ($hasMutex) { $mutex.ReleaseMutex() }; if ($mutex) { $mutex.Dispose() }
    if ($script:logPath) { [IO.File]::WriteAllText((Join-Path $JobDirectory 'exit-code.txt'),[string]$exitCode) }
    if ($script:transcriptStarted) { Stop-Transcript | Out-Null }
}
exit $exitCode
