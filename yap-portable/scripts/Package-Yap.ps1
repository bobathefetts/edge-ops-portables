# Package Yap into dist\Yap-v<VERSION>.zip + .sha256 (edge-ops release layout). ASCII only.
param(
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()

# Ensure Whisper WASM assets and Yap.lnk are present and verified
& (Join-Path $PSScriptRoot 'Build-Portable.ps1')

$distDir = if ($OutDir) { $OutDir } else { Join-Path $root 'dist' }
New-Item -ItemType Directory -Force $distDir | Out-Null

$pkgName = "Yap-v$version"
$stageParent = Join-Path $root 'temp\pkg-stage'
$stageDir = Join-Path $stageParent $pkgName
if (Test-Path $stageParent) { Remove-Item $stageParent -Recurse -Force }
New-Item -ItemType Directory -Force $stageDir | Out-Null

$includeItems = @(
    'Yap.lnk',
    'Yap-Dev.bat',
    'Package.bat',
    'README.md',
    'LICENSE',
    'THIRD-PARTY-NOTICES.md',
    'CHANGELOG.md',
    'VERSION',
    'PSScriptAnalyzerSettings.psd1',
    'assets',
    'config',
    'src',
    'scripts',
    'tests'
)

foreach ($item in $includeItems) {
    $srcPath = Join-Path $root $item
    if (Test-Path $srcPath) {
        Copy-Item -Path $srcPath -Destination (Join-Path $stageDir $item) -Recurse -Force
    }
}

foreach ($clean in @('src\.pid', 'data', 'logs', 'temp')) {
    $p = Join-Path $stageDir $clean
    if (Test-Path $p) { Remove-Item $p -Recurse -Force }
}

$zipOut = Join-Path $distDir "$pkgName.zip"
$shaOut = "$zipOut.sha256"
if (Test-Path $zipOut) { Remove-Item $zipOut -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stageParent, $zipOut, [System.IO.Compression.CompressionLevel]::Optimal, $false)

$hash = (Get-FileHash -Path $zipOut -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($shaOut, "$hash  $pkgName.zip`r`n", [Text.Encoding]::ASCII)

Remove-Item $stageParent -Recurse -Force
Write-Host "Packaged: $zipOut ($('{0:N1}' -f ((Get-Item $zipOut).Length / 1MB)) MB)"
Write-Host "SHA-256:  $hash"
