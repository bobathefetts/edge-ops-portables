# Build / populate the portable Yap runtime (Windows PowerShell 5.1). ASCII only.
# Uses uv to stage a self-contained standalone Python 3.12 + pip packages inside runtime\python\,
# optionally pre-downloads the llama.cpp Vulkan engine / models, and creates Yap.lnk.
param(
    [switch]$Force,
    [switch]$IncludeEngine,
    [switch]$IncludeModels
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pyDir = Join-Path $root 'runtime\python'
$pyExe = Join-Path $pyDir 'python.exe'
$reqFile = Join-Path $root 'src\app\requirements-portable.txt'

function Find-Uv {
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:USERPROFILE '.local\bin\uv.exe'
    if (Test-Path $fallback) { return $fallback }
    throw 'uv is required to build the portable Python runtime (https://docs.astral.sh/uv/).'
}

$uv = Find-Uv

if ($Force -or -not (Test-Path $pyExe)) {
    Write-Host 'Ensuring standalone Python 3.12 via uv...'
    & $uv python install 3.12
    if ($LASTEXITCODE -ne 0) { throw 'uv python install 3.12 failed.' }

    $srcPyExe = (& $uv python find 3.12 --managed-python 2>$null | Select-Object -First 1)
    if (-not $srcPyExe -or -not (Test-Path $srcPyExe)) {
        $srcPyExe = (& $uv python find 3.12 | Select-Object -First 1)
    }
    if (-not $srcPyExe -or -not (Test-Path $srcPyExe)) {
        throw 'Could not locate managed Python 3.12 installation.'
    }
    $srcPyDir = Split-Path -Parent $srcPyExe

    if (Test-Path $pyDir) { Remove-Item $pyDir -Recurse -Force }
    New-Item -ItemType Directory -Force $pyDir | Out-Null
    Write-Host "Copying standalone Python from $srcPyDir -> $pyDir ..."
    Copy-Item -Path (Join-Path $srcPyDir '*') -Destination $pyDir -Recurse -Force

    # Allow uv pip install directly into our isolated portable Python copy.
    $extMarker = Join-Path $pyDir 'Lib\EXTERNALLY-MANAGED'
    if (Test-Path $extMarker) { Remove-Item $extMarker -Force }
} else {
    Write-Host 'runtime\python\python.exe already present (use -Force to rebuild).'
}

Write-Host 'Installing Yap dependencies into portable runtime\python\ ...'
& $uv pip install --python $pyExe --system --no-cache -r $reqFile
if ($LASTEXITCODE -ne 0) {
    throw 'uv pip install failed.'
}

# Remove unneeded test/cache directories inside site-packages to keep zip lean.
Get-ChildItem -Path $pyDir -Filter '__pycache__' -Directory -Recurse -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$libTest = Join-Path $pyDir 'Lib\test'
if (Test-Path $libTest) { Remove-Item $libTest -Recurse -Force -ErrorAction SilentlyContinue }

# Ensure msvcp140.dll is bundled beside vcruntime140.dll for llama-server.exe on bare Windows systems.
$msvcpTarget = Join-Path $pyDir 'msvcp140.dll'
if (-not (Test-Path $msvcpTarget)) {
    $sysMsvcp = Join-Path $env:SystemRoot 'System32\msvcp140.dll'
    if (Test-Path $sysMsvcp) {
        Copy-Item -Path $sysMsvcp -Destination $msvcpTarget -Force
    } else {
        $wheelMsvcp = Get-ChildItem -Path $pyDir -Filter 'msvcp140*.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wheelMsvcp) {
            Copy-Item -Path $wheelMsvcp.FullName -Destination $msvcpTarget -Force
        }
    }
}

if ($IncludeEngine) {
    Write-Host 'Pre-downloading Vulkan llama.cpp engine into engine\ ...'
    $env:YAP_PORTABLE = '1'
    $env:YAP_ASSETS = $root
    $env:YAP_HOME = Join-Path $root 'data'
    $appDir = Join-Path $root 'src\app'
    & $pyExe -c "import sys; sys.path.insert(0, r'$appDir'); from yap import assets; p = assets.ensure_engine('vulkan'); print('Engine:', p)"
    if ($LASTEXITCODE -ne 0) { throw 'Failed to download Vulkan engine.' }
}

if ($IncludeModels) {
    Write-Host 'Pre-downloading default speech (small.en) and cleanup (qwen3.5-2b) models into models\ ...'
    $env:YAP_PORTABLE = '1'
    $env:YAP_ASSETS = $root
    $env:YAP_HOME = Join-Path $root 'data'
    $appDir = Join-Path $root 'src\app'
    & $pyExe -c "import sys; sys.path.insert(0, r'$appDir'); from yap import assets; print(assets.ensure_whisper('small.en')); print(assets.ensure_llm('qwen3.5-2b'))"
    if ($LASTEXITCODE -ne 0) { throw 'Failed to download models.' }
}

# Create Edge-Ops headless .lnk launcher using Yap's own icon.
$lnkScript = Join-Path $PSScriptRoot 'New-ToolShortcut.ps1'
& $lnkScript -Root $root -Name 'Yap' -Script 'src\Start-Yap.ps1' -Icon 'assets\yap.ico,0' -Description 'Yap Portable (Push-to-Talk Dictation)'

Write-Host 'Build-Portable complete.'
