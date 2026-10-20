param([switch]$ValidateOnly)
# Runs only inside the brand-new reference VM, via an independent SYSTEM task.
# Compatible with Windows 7's PowerShell 2.0.
$ErrorActionPreference='Stop'
function Note($s) { Add-Content -LiteralPath 'C:\GhostBuild\seal.log' -Value ((Get-Date -Format s)+' '+$s) }
function Test-AuditReady($setupInProgress,$oobeInProgress,[bool]$desktop,[string]$imageState) {
    return ($setupInProgress -eq 0 -and $desktop -and ($oobeInProgress -eq 0 -or $imageState -eq 'IMAGE_STATE_SPECIALIZE_RESEAL_TO_AUDIT'))
}
if ($ValidateOnly) { return }
$sealMutex=New-Object Threading.Mutex($false,'Local\GhostAutoSealWorker')
if (-not $sealMutex.WaitOne(0)) { $sealMutex.Dispose(); exit 0 }
try {
    if (-not (Test-Path -LiteralPath 'C:\GhostBuild\Architecture.txt')) { throw 'Missing reference VM marker.' }
    Note 'Waiting for audit setup to finish.'
    $deadline=(Get-Date).AddMinutes(90)
    $stable=0
    $ticks=0
    while ($stable -lt 6) {
        if ((Get-Date) -gt $deadline) { throw 'Audit setup timed out.' }
        $s=Get-ItemProperty 'HKLM:\SYSTEM\Setup'
        $imageState=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
        if (Test-AuditReady $s.SystemSetupInProgress $s.OOBEInProgress ([bool](Get-Process explorer -ErrorAction SilentlyContinue)) $imageState) { $stable++ } else { $stable=0 }
        if (($ticks % 6) -eq 0) { Note ('Setup wait: SystemSetupInProgress='+$s.SystemSetupInProgress+'; OOBEInProgress='+$s.OOBEInProgress+'; stable='+$stable) }
        $ticks++
        Start-Sleep -Seconds 10
    }
    Note 'Audit setup complete. Preparing Sysprep.'
    Get-Process sysprep -ErrorAction SilentlyContinue | Stop-Process -Force
    foreach ($p in @('C:\Windows\Panther\unattend.xml','C:\Windows\Panther\Unattend\unattend.xml')) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
    $architecture=(Get-Content -LiteralPath 'C:\GhostBuild\Architecture.txt' -TotalCount 1).Trim()
    if ($architecture -ne 'amd64' -and $architecture -ne 'x86') { throw 'Invalid architecture.' }
    $xml='<unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="oobeSystem"><component name="Microsoft-Windows-Deployment" processorArchitecture="'+$architecture+'" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><Reseal><Mode>OOBE</Mode></Reseal></component></settings></unattend>'
    $xml | Set-Content -LiteralPath 'C:\Windows\Temp\GhostFinalize.xml' -Encoding UTF8
    $previousPreference=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    $taskQuery=@(& schtasks.exe /Query /TN GhostAutoSeal 2>&1)
    $taskCode=$LASTEXITCODE
    $ErrorActionPreference=$previousPreference
    if ($taskCode -eq 0) {
        & schtasks.exe /Delete /TN GhostAutoSeal /F | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cannot remove build task.' }
    } else { Note 'Scheduled task is absent; continuing the independent sealing worker.' }
    Note 'Starting Sysprep generalize / OOBE / shutdown.'
    $p=Start-Process -FilePath 'C:\Windows\System32\Sysprep\Sysprep.exe' -ArgumentList '/generalize /oobe /shutdown /quiet /unattend:C:\Windows\Temp\GhostFinalize.xml' -PassThru
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw ('Sysprep failed: '+$p.ExitCode) }
} catch {
    Note ('FAILED: '+$_.Exception.Message)
    ($_ | Format-List * -Force | Out-String) | Set-Content -LiteralPath 'C:\GhostBuild\error-details.txt'
    exit 1
} finally { $sealMutex.ReleaseMutex(); $sealMutex.Dispose() }
