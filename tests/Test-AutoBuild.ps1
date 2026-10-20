$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\AutoBuild.ps1') -ValidateOnly
$testRoot=Join-Path $env:TEMP ('ghost-validation-'+[guid]::NewGuid().ToString('N'))
$JobDirectory=$testRoot
[void][IO.Directory]::CreateDirectory($testRoot)
function Assert($condition,$message) { if (-not $condition) { throw $message } }
try {
    $script:logPath=Join-Path $testRoot 'native.log'
    $nativeTest=Join-Path $testRoot 'native-test.cmd'
    Set-Content -LiteralPath $nativeTest -Value "@echo off`r`necho diagnostic-on-stderr 1>&2`r`necho final-output`r`nexit /b 7" -Encoding ASCII
    $blocked=$false
    try { Invoke-Native $env:ComSpec @('/d','/c',$nativeTest) } catch { $blocked=($_.Exception.Message -match '7') }
    Assert $blocked 'Native nonzero exit code was not preserved'
    $nativeLog=Get-Content -LiteralPath $script:logPath -Raw
    Assert (($nativeLog -match 'diagnostic-on-stderr') -and ($nativeLog -match 'final-output')) 'Native output was lost after stderr'
    [xml]$taskXml=New-SealTaskXml
    $ns=New-Object Xml.XmlNamespaceManager($taskXml.NameTable)
    $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    Assert ($taskXml.SelectSingleNode('//t:DisallowStartIfOnBatteries',$ns).InnerText -eq 'false') 'Seal task must allow battery power'
    Assert ($taskXml.SelectSingleNode('//t:UserId',$ns).InnerText -eq 'S-1-5-18') 'Seal task must use SYSTEM'
    Assert ($taskXml.SelectSingleNode('//t:Command',$ns).InnerText -eq 'C:\Windows\System32\cmd.exe') 'Seal task launcher missing'
    Assert ((Get-WindowsFamily 'custom image' '10.0.19045.1') -eq '10') 'Windows 10 metadata detection failed'
    Assert ((Get-WindowsFamily 'custom image' '10.0.22621.1') -eq '11') 'Windows 11 metadata detection failed'
    Assert ((Get-WindowsFamily 'custom image' '6.1.7601.1') -eq '7') 'Windows 7 metadata detection failed'
    Assert ((Get-WindowsFamily 'Windows 10 Pro' '') -eq '10') 'Image-name fallback failed'
    Assert ((Get-WindowsFamily 'unknown custom' '') -eq 'Unknown') 'Unknown version must ask user'
    $blocked=$false; try { Get-WindowsFamily 'Windows Server 2022' '10.0.20348.1' } catch { $blocked=$true }; Assert $blocked 'Server image accepted'
    foreach ($architecture in @('amd64','x86')) {
        [xml]$xml=New-AuditAnswer $architecture
        Assert ($xml.unattend.settings.Count -eq 3) 'Unattend configuration missing'
        Assert (($xml.OuterXml -match 'StartSeal.cmd') -and ($xml.OuterXml -notmatch 'Sysprep.exe')) 'Setup must only start independent task'
    }
    $windows=Join-Path $testRoot 'Windows'; [void][IO.Directory]::CreateDirectory((Join-Path $windows 'Setup\State'))
    $state=Join-Path $windows 'Setup\State\State.ini'
    Set-Content -LiteralPath $state -Value "[State]`r`nImageState=IMAGE_STATE_COMPLETE"
    $blocked=$false; try { Assert-Sealed $windows } catch { $blocked=$true }; Assert $blocked 'Unsealed Windows accepted'
    Set-Content -LiteralPath $state -Value "[State]`r`nImageState=`"IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`""
    Assert-Sealed $windows
    $blocked=$false; try { Assert-JobPath (Join-Path $env:TEMP 'outside.vhd') } catch { $blocked=$true }; Assert $blocked 'Outside conversion accepted'
    $file=Join-Path $testRoot 'tiny.vhd'
    $size=4096
    $bytes=New-Object byte[] ($size+512)
    $footer=New-Object byte[] 512
    [Text.Encoding]::ASCII.GetBytes('conectix').CopyTo($footer,0)
    $sizeBytes=[BitConverter]::GetBytes([uint64]$size); [Array]::Reverse($sizeBytes); $sizeBytes.CopyTo($footer,48)
    $type=[BitConverter]::GetBytes([uint32]2); [Array]::Reverse($type); $type.CopyTo($footer,60)
    [uint32]$sum=0; foreach ($b in $footer) { $sum+=$b }
    $checksum=[BitConverter]::GetBytes([uint32]([uint32]::MaxValue-$sum)); [Array]::Reverse($checksum); $checksum.CopyTo($footer,64)
    $footer.CopyTo($bytes,$size); [IO.File]::WriteAllBytes($file,$bytes)
    Convert-FixedVhdToFlat $file $size
    Assert ((Get-Item -LiteralPath $file).Length -eq $size) 'VHD conversion length mismatch'
    $bad=Join-Path $testRoot 'bad.vhd'; $bytes[$size+20]=1; [IO.File]::WriteAllBytes($bad,$bytes)
    $blocked=$false; try { Convert-FixedVhdToFlat $bad $size } catch { $blocked=$true }; Assert $blocked 'Invalid footer checksum accepted'
    Assert ((Get-Item -LiteralPath $bad).Length -eq $size+512) 'Invalid VHD was truncated'
    Assert ((New-VmdkDescriptor 40GB 'capture-flat.vmdk') -match 'RW 83886080 FLAT') 'VMDK sector count incorrect'
    $blocked=$false; try { New-VmdkDescriptor 512 '../physicaldrive' } catch { $blocked=$true }; Assert $blocked 'Unsafe VMDK extent accepted'
    'PASS: version detection, fallback, XML, seal validation, path boundary, VHD checksum/conversion, VMDK extent.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
