# Build / populate the portable BYOB bundle (Windows PowerShell 5.1). ASCII only.
# Downloads the official Windows release archive, verifies SHA-256, extracts into bin\, and creates BYOB.lnk.
param(
    [switch]$Slim,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$binDir = Join-Path $root 'bin'
$tempDir = Join-Path $root 'temp\build'

New-Item -ItemType Directory -Force $binDir, $tempDir | Out-Null

$assetName = if ($Slim) {
    "byob-slim-$version-x86_64-pc-windows-msvc.zip"
} else {
    "byob-$version-x86_64-pc-windows-msvc.zip"
}
$baseUrl = "https://github.com/Scronkfinkle/byob/releases/download/v$version"
$zipPath = Join-Path $tempDir $assetName
$shaPath = Join-Path $tempDir "$assetName.sha256"

$targetExe = Join-Path $binDir 'byob.exe'
if ($Force -or -not (Test-Path $targetExe)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "Downloading $assetName..."
    Invoke-WebRequest -Uri "$baseUrl/$assetName" -OutFile $zipPath -UseBasicParsing
    Invoke-WebRequest -Uri "$baseUrl/$assetName.sha256" -OutFile $shaPath -UseBasicParsing

    $expectedLine = (Get-Content $shaPath -Raw).Trim()
    $expectedHash = ($expectedLine -split '\s+')[0].ToLowerInvariant()
    $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expectedHash -ne $actualHash) {
        throw "SHA-256 mismatch for ${assetName}: expected $expectedHash, got $actualHash"
    }
    Write-Host "Verified SHA-256: $actualHash"

    $extractDir = Join-Path $tempDir 'extract'
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $foundExe = Get-ChildItem -Path $extractDir -Filter 'byob.exe' -Recurse | Select-Object -First 1
    if (-not $foundExe) {
        throw "byob.exe not found inside $assetName"
    }
    $srcFolder = $foundExe.DirectoryName
    Get-ChildItem -Path $binDir -Force | Remove-Item -Recurse -Force
    Copy-Item -Path (Join-Path $srcFolder '*') -Destination $binDir -Recurse -Force
    Write-Host "Populated $binDir from $srcFolder"
} else {
    Write-Host "bin\byob.exe already present (use -Force to re-download)."
}

# Create Edge-Ops headless .lnk launcher
$lnkScript = Join-Path $PSScriptRoot 'New-ToolShortcut.ps1'
& $lnkScript -Root $root -Name 'BYOB' -Script 'src\Start-BYOB.ps1' -Description 'BYOB Portable (Desktop Window + Outlook Classic)'

Write-Host 'Build-Portable complete.'
