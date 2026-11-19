# Verify the BYOB Explorer package and create Explorer.lnk (the no-console launcher). ASCII only.
# Pure Windows PowerShell 5.1 + Edge --app. Zero external binaries or downloads.
# Explorer.lnk can only be created on Windows (WScript.Shell COM); elsewhere this step is skipped.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

foreach ($req in @(
    'src\Start-Explorer.ps1',
    'src\LoopbackPort.ps1',
    'src\NetGate.ps1',
    'src\CredStore.ps1',
    'src\ExplorerTools.ps1',
    'src\ExplorerAgent.ps1',
    'src\PluginHost.ps1',
    'src\ByobLlm.ps1',
    'src\ByobTools.ps1',
    'src\ui\index.html',
    'plugins\README.md',
    'plugins\sample-portscan\byob-plugin.json',
    'plugins\sample-portscan\scan.ps1',
    'config\settings.json',
    'VERSION'
)) {
    $p = $root
    foreach ($part in $req.Split('\')) { $p = Join-Path $p $part }
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing required file: $req" }
}

$bins = @(Get-ChildItem -Path $root -Recurse -File -Include '*.exe', '*.dll', '*.pyd' -ErrorAction SilentlyContinue)
if ($bins.Count -gt 0) { throw "Native binaries found (the package must have none): $(@($bins | ForEach-Object { $_.FullName }) -join ', ')" }

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $lnkScript = Join-Path $PSScriptRoot 'New-ToolShortcut.ps1'
    & $lnkScript -Root $root -Name 'Explorer' -Script 'src\Start-Explorer.ps1' -Description 'BYOB Explorer (read-only network explorer)'
} else {
    Write-Host 'Not on Windows: Explorer.lnk was not created (run Explorer-Dev.bat or scripts\Build-Portable.ps1 once on Windows).'
}
Write-Host 'Build-Portable complete (zero EXEs/DLLs).'
