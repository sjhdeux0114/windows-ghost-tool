param([switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'

function Require-HyperV {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw 'Hyper-V 관리 도구가 없습니다. Hyper-V 확인/활성화 버튼을 먼저 사용하세요. Home 에디션에서는 Hyper-V를 지원하지 않습니다.'
    }
    Import-Module Hyper-V -ErrorAction Stop
}
function Get-Project {
    Require-HyperV
    if (-not (Test-Path -LiteralPath $script:statePath)) { throw '먼저 기준 VM을 생성하세요.' }
    $p = Get-Content -LiteralPath $script:statePath -Raw | ConvertFrom-Json
    $vm = Get-VM -Id ([guid]$p.Id) -ErrorAction Stop
    $hdds = @(Get-VMHardDiskDrive -VM $vm)
    if ($hdds.Count -ne 1 -or $hdds[0].Path -ne $p.Vhd) { throw 'VM 디스크 구성이 변경되었습니다. 자동 작업을 중단합니다.' }
    if (@(Get-VMSnapshot -VM $vm).Count -gt 0) { throw '체크포인트가 있습니다. Hyper-V에서 병합을 완료한 뒤 다시 시도하세요.' }
    return @{ Project=$p; VM=$vm }
}
function Add-Note([string]$message) {
    $script:log.AppendText("$(Get-Date -Format HH:mm:ss)  $message`r`n")
}
function Run-Step([scriptblock]$action) {
    $script:form.UseWaitCursor = $true
    try { & $action } catch {
        Add-Note $_.Exception.Message
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, '작업 확인')
    } finally { $script:form.UseWaitCursor = $false }
}
function Add-Button([string]$text,[int]$x,[int]$y,[int]$width,[scriptblock]$action) {
    $b = New-Object Windows.Forms.Button
    $b.Text=$text; $b.SetBounds($x,$y,$width,38)
    $b.Add_Click($action); $script:form.Controls.Add($b)
}

if ($ValidateOnly) { return }
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$mutex=New-Object Threading.Mutex($false,'Local\GhostImageAppVmWizard')
if (-not $mutex.WaitOne(0)) {
    [void][Windows.Forms.MessageBox]::Show('가상 머신 준비 창이 이미 열려 있습니다.'); $mutex.Dispose(); exit
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [void][Windows.Forms.MessageBox]::Show('GhostImageApp.exe를 관리자 권한으로 실행하세요.'); exit 1
}
$script:statePath=Join-Path $PSScriptRoot 'vm-project.json'
$script:form=New-Object Windows.Forms.Form
$form.Text='기준 Windows 가상 머신 만들기 · Hyper-V'
$form.ClientSize=New-Object Drawing.Size(900,650)
$form.Font=New-Object Drawing.Font('Malgun Gothic',10)
$form.StartPosition='CenterScreen'
$label=New-Object Windows.Forms.Label
$label.Text="Windows ISO → VM 설치 → 프로그램 설정 → Sysprep → Ghost 캡처`r`nWindows 10/11 Pro·Enterprise 계열의 Hyper-V와 BIOS 가상화가 필요합니다."
$label.SetBounds(20,15,860,65); $form.Controls.Add($label)
$iso=New-Object Windows.Forms.TextBox
$iso.SetBounds(20,90,730,30); $iso.Text=Join-Path $PSScriptRoot 'Windows_10.iso'; $form.Controls.Add($iso)
Add-Button 'ISO 선택' 760 85 120 {
    $d=New-Object Windows.Forms.OpenFileDialog; $d.Filter='Windows ISO|*.iso'
    if ($d.ShowDialog() -eq 'OK') { $iso.Text=$d.FileName }; $d.Dispose()
}
$generation=New-Object Windows.Forms.ComboBox
$generation.DropDownStyle='DropDownList'; $generation.SetBounds(20,140,300,30)
[void]$generation.Items.Add('UEFI / GPT · 64비트 Windows (2세대)')
[void]$generation.Items.Add('Legacy BIOS / MBR (1세대)')
$generation.SelectedIndex=0; $form.Controls.Add($generation)
$label2=New-Object Windows.Forms.Label
$label2.Text='동적 디스크 80GB · 네트워크 기본 미연결'
$label2.SetBounds(340,144,540,30); $form.Controls.Add($label2)
$hostOS=Get-CimInstance Win32_OperatingSystem
$totalGB=[int][math]::Floor($hostOS.TotalVisibleMemorySize/1MB)
$freeGB=[int][math]::Floor($hostOS.FreePhysicalMemory/1MB)
$cpuTotal=[Environment]::ProcessorCount
$resourceLabel=New-Object Windows.Forms.Label
$resourceLabel.Text="PC: RAM ${totalGB}GB (사용 가능 약 ${freeGB}GB), 논리 CPU ${cpuTotal}개. VM RAM(GB):"
$resourceLabel.SetBounds(20,178,570,30); $form.Controls.Add($resourceLabel)
$ramChoice=New-Object Windows.Forms.NumericUpDown
$ramChoice.Minimum=2; $ramChoice.Maximum=[math]::Max(2,$totalGB)
$ramChoice.Value=[math]::Max(2,[math]::Min(8,[math]::Min([math]::Floor($totalGB/2),$freeGB-2)))
$ramChoice.SetBounds(590,175,80,30); $form.Controls.Add($ramChoice)
$cpuLabel=New-Object Windows.Forms.Label
$cpuLabel.Text='CPU 개수:'; $cpuLabel.SetBounds(690,178,85,30); $form.Controls.Add($cpuLabel)
$cpuChoice=New-Object Windows.Forms.NumericUpDown
$cpuChoice.Minimum=1; $cpuChoice.Maximum=$cpuTotal; $cpuChoice.Value=[math]::Max(1,[math]::Min(4,[math]::Floor($cpuTotal/2)))
$cpuChoice.SetBounds(790,175,80,30); $form.Controls.Add($cpuChoice)
Add-Button '1. Hyper-V 확인 / 활성화' 20 215 265 {
    Run-Step {
        $f=Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
        if ($f.State -eq 'Enabled') { Require-HyperV; Add-Note 'Hyper-V 활성화됨. VM 생성이 가능합니다.'; return }
        $answer=[Windows.Forms.MessageBox]::Show('Hyper-V를 활성화할까요? 완료 후 Windows를 직접 재부팅해야 합니다.', 'Windows 기능 변경','OKCancel','Question')
        if ($answer -ne 'OK') { return }
        $result=Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
        Add-Note "Hyper-V 기능 설정 완료. 재부팅 필요: $($result.RestartNeeded). 재부팅 후 앱을 다시 실행하세요."
    }
}
Add-Button '2. 새 기준 VM 생성' 305 215 265 {
    Run-Step {
        Require-HyperV
        if (Test-Path -LiteralPath $statePath) { throw '이미 기준 VM 프로젝트가 있습니다. 기존 VM을 사용하세요. 새 프로젝트는 별도 앱 폴더에서 만드세요.' }
        $isoPath=(Resolve-Path -LiteralPath $iso.Text).ProviderPath
        if ([IO.Path]::GetExtension($isoPath) -ne '.iso') { throw 'ISO 파일을 선택하세요.' }
        $name='GhostReference-'+(Get-Date -Format 'yyyyMMdd-HHmmss')
        $root=Join-Path $PSScriptRoot "VirtualMachines\$name"
        if (Test-Path -LiteralPath $root) { throw 'VM 폴더가 이미 존재합니다.' }
        $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($root))
        if ($drive.AvailableFreeSpace -lt 90GB) { throw '앱이 있는 디스크에 90GiB 이상의 여유 공간을 확보하세요.' }
        $gen=if ($generation.SelectedIndex -eq 0) { 2 } else { 1 }
        $vhd=Join-Path $root 'Windows.vhdx'
        if ($ramChoice.Value*1GB -gt (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory) { throw '선택한 RAM이 PC 메모리를 초과합니다.' }
        $vm=New-VM -Name $name -Generation $gen -MemoryStartupBytes ([long]$ramChoice.Value*1GB) -NewVHDPath $vhd -NewVHDSizeBytes 80GB -Path $root
        # Persist immediately so partial setup remains recoverable without deleting user data.
        @{ Id=$vm.Id.ToString(); Name=$name; Vhd=$vhd; ISO=$isoPath } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
        Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
        Set-VMProcessor -VM $vm -Count ([int]$cpuChoice.Value)
        Add-Note "선택한 VM 사양: RAM $($ramChoice.Value)GB / CPU $($cpuChoice.Value)개"
        if ($gen -eq 2) {
            $dvd=Add-VMDvdDrive -VMName $name -Path $isoPath -Passthru
            Set-VMFirmware -VMName $name -FirstBootDevice $dvd
        } else {
            Set-VMDvdDrive -VMName $name -Path $isoPath
            Set-VMBios -VMName $name -StartupOrder CD,IDE,LegacyNetworkAdapter,Floppy
        }
        Add-Note "생성 완료: $name / $vhd. 다음 버튼으로 VM을 시작하세요."
    }
}
Add-Button '3. 설치 / VM 화면 열기' 590 215 290 {
    Run-Step {
        $s=Get-Project; $vm=$s.VM
        if ((Get-VHD -Path $s.Project.Vhd).Attached -and $vm.State -eq 'Off') { throw '캡처용 가상 디스크 연결을 먼저 해제하세요.' }
        if ($vm.State -eq 'Off') {
            $answer=[Windows.Forms.MessageBox]::Show('VM을 부팅합니다. Sysprep 후 봉인한 Windows를 부팅하면 캡처 전에 Sysprep을 다시 해야 합니다. 계속할까요?','VM 부팅','OKCancel','Question')
            if ($answer -ne 'OK') { return }; Start-VM -VM $vm
        }
        Start-Process -FilePath "$env:WINDIR\System32\vmconnect.exe" -ArgumentList @('localhost',$vm.Name)
        Add-Note 'VM 화면에서 ISO 부팅 키를 누르고 Windows를 설치하세요. 로컬 관리자 계정과 암호를 설정하세요.'
    }
}
Add-Button '4. VM 내부 Sysprep 실행' 20 250 265 {
    Run-Step {
        $s=Get-Project
        if ($s.VM.State -ne 'Running') { throw '설치가 완료된 Windows VM을 실행하고 로그인하세요.' }
        $answer=[Windows.Forms.MessageBox]::Show('VM의 프로그램 설치와 업데이트를 완료했나요? 이 작업은 VM Windows에서 일반화 후 종료를 요청합니다. 호스트 Windows에는 Sysprep을 실행하지 않습니다.','VM Sysprep','OKCancel','Question')
        if ($answer -ne 'OK') { return }
        $cred=Get-Credential -Message '가상 머신 내부의 로컬 관리자 계정과 암호 (호스트 계정 아님)'
        if ($null -eq $cred) { return }
        try {
            Invoke-Command -VMId $s.VM.Id -Credential $cred -ScriptBlock {
                $ErrorActionPreference='Stop'
                $id=[Security.Principal.WindowsIdentity]::GetCurrent()
                if (-not ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'VM 관리자 계정이 필요합니다.' }
                if (Get-Process sysprep -ErrorAction SilentlyContinue) { throw 'Sysprep이 이미 실행 중입니다.' }
                Start-Process -FilePath "$env:WINDIR\System32\Sysprep\Sysprep.exe" -ArgumentList '/generalize /oobe /shutdown' -ErrorAction Stop
                'VM 내부 Sysprep 프로세스 시작을 요청했습니다.'
            } | ForEach-Object { Add-Note "$_" }
        } finally { $cred=$null }
        Add-Note '시작 요청은 성공 판정이 아닙니다. VM 화면에서 오류가 없는지 확인하고 정상 종료까지 기다리세요. 실패 로그: VM의 C:\Windows\System32\Sysprep\Panther.'
    }
}
Add-Button '5. 캡처용 디스크 연결' 305 250 265 {
    Run-Step {
        $s=Get-Project
        if ($s.VM.State -ne 'Off') { throw 'VM이 완전히 종료되어야 연결할 수 있습니다. 강제 종료하지 마세요.' }
        $answer=[Windows.Forms.MessageBox]::Show('VM에서 Sysprep이 오류 없이 완료되어 자동 종료되었나요? 단순 종료는 일반화 완료를 의미하지 않습니다. 확인 후에만 진행하세요.','일반화 완료 확인','OKCancel','Question')
        if ($answer -ne 'OK') { return }
        $v=Get-VHD -Path $s.Project.Vhd
        if ($v.Attached) { throw '이미 연결된 가상 디스크입니다. 기존 연결 상태를 먼저 확인하세요.' }
        $disk=Mount-VHD -Path $s.Project.Vhd -ReadOnly -NoDriveLetter -Passthru | Get-Disk
        Add-Note "읽기 전용 연결 완료: Windows 디스크 $($disk.Number), $([math]::Round($disk.Size/1GB)) GiB. 메인 앱에서 새로 고침 후 이 디스크를 선택하세요. Ghost 번호는 별도 대조하세요."
    }
}
Add-Button '6. 캡처 후 연결 해제' 590 250 290 {
    Run-Step {
        $s=Get-Project
        if ($s.VM.State -ne 'Off') { throw 'VM이 실행 중입니다. 연결 해제를 중단합니다.' }
        if (Get-Process Ghost64 -ErrorAction SilentlyContinue) { throw 'Ghost가 실행 중입니다. 캡처와 검사를 완료하고 Ghost를 종료하세요.' }
        if (-not (Get-VHD -Path $s.Project.Vhd).Attached) { Add-Note '연결된 가상 디스크가 없습니다.'; return }
        Dismount-VHD -Path $s.Project.Vhd
        Add-Note '캡처용 디스크 연결 해제 완료. 봉인한 VM은 다음 이미지 수정 전까지 부팅하지 마세요.'
    }
}
$help=New-Object Windows.Forms.Label
$help.Text="설치는 VM 화면에서 직접 진행합니다. 업데이트와 원하는 앱을 설치한 뒤 4번을 누르세요.`r`n네트워크가 필요하면 Hyper-V 관리자에서 이 VM에 기존 가상 스위치를 연결하세요.`r`n5번 후 메인 앱에서 VHDX 디스크를 선택해 .gho를 만듭니다. 캡처 중 VM을 시작하지 마세요.`r`nUEFI용 이미지와 Legacy BIOS용 이미지는 구분해서 준비해야 합니다."
$help.SetBounds(20,315,860,105); $form.Controls.Add($help)
$script:log=New-Object Windows.Forms.TextBox
$log.SetBounds(20,430,860,195); $log.Multiline=$true; $log.ReadOnly=$true; $log.ScrollBars='Vertical'; $form.Controls.Add($log)
Add-Note '각 단계는 직접 선택할 때 실행됩니다. Hyper-V 활성화 후에는 PC 재부팅이 필요할 수 있습니다.'
[void]$form.ShowDialog()
$form.Dispose()
$mutex.ReleaseMutex()
$mutex.Dispose()
