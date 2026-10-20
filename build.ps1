param([string]$OutputName='GhostImageApp.exe')
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
Push-Location $PSScriptRoot
try {
    # Windows PowerShell 5.1 requires a BOM for scripts with Korean text.
    foreach ($scriptName in @('VmWizard.ps1','AutoBuild.ps1','GuestSeal.ps1','VmHistory.ps1')) {
        $wizard = Join-Path $PSScriptRoot $scriptName
        $wizardText = [IO.File]::ReadAllText($wizard)
        [IO.File]::WriteAllText($wizard, $wizardText, (New-Object Text.UTF8Encoding($true)))
    }
    & $compiler /nologo /target:winexe /platform:x64 "/out:$OutputName" /win32manifest:app.manifest /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Management.dll /reference:System.Web.Extensions.dll GhostImageApp.cs AutoBuildForm.cs RestoreForm.cs VmHistoryForm.cs
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
} finally { Pop-Location }
