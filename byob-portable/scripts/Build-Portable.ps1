# Verify and prepare the pure PowerShell 5.1 + Edge --app BYOB package. ASCII only.
# Zero external binaries or downloads required.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

foreach ($req in @(
    'src\Start-BYOB.ps1',
    'src\LoopbackPort.ps1',
    'src\ByobLlm.ps1',
    'src\ByobTools.ps1',
    'src\ui\index.html',
    'plugins\outlook-classic\outlook_com.ps1',
    'plugins\outlook-classic\prompt.md'
)) {
    if (-not (Test-Path (Join-Path $root $req))) {
        throw "Missing required file: $req"
    }
}

$lnkScript = Join-Path $PSScriptRoot 'New-ToolShortcut.ps1'
& $lnkScript -Root $root -Name 'BYOB' -Script 'src\Start-BYOB.ps1' -Description 'BYOB (Edge-Ops Pure PowerShell + Outlook Classic)'
Write-Host 'Build-Portable complete (zero EXEs/DLLs).'
