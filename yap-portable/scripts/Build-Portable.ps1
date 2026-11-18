# Populate and verify local Whisper WASM assets for Yap (Windows PowerShell 5.1). ASCII only.
# Zero Python, zero third-party EXEs/DLLs: downloads the 12 SHA-256-pinned WASM/ONNX files into src\ui\vendor\voice\ and builds Yap.lnk.
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$voiceDir = Join-Path $root 'src\ui\vendor\voice'
$manifestPath = Join-Path $root 'config\voice-assets.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

$cdnBase = 'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.8.1/dist'
$hfBase = 'https://huggingface.co/Xenova/whisper-tiny.en/resolve/79fb389fc764e7c395bd330e9531d9d32ada7049'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

foreach ($entry in @($manifest.files)) {
    $rel = [string]$entry.name
    $expected = ([string]$entry.sha256).ToLowerInvariant()
    $dest = Join-Path $voiceDir ($rel -replace '/', '\')
    New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null

    $needDownload = $Force -or -not (Test-Path -LiteralPath $dest)
    if (-not $needDownload) {
        $existingHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingHash -ne $expected) { $needDownload = $true }
    }

    if ($needDownload) {
        $url = if ($rel.StartsWith('models/whisper-tiny.en/')) {
            "$hfBase/" + $rel.Substring('models/whisper-tiny.en/'.Length)
        } else {
            "$cdnBase/$rel"
        }
        Write-Host "Downloading $rel ..."
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    }

    $actual = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch for ${rel}: expected $expected, got $actual"
    }
}

$lnkScript = Join-Path $PSScriptRoot 'New-ToolShortcut.ps1'
& $lnkScript -Root $root -Name 'Yap' -Script 'src\Start-Yap.ps1' -Icon 'assets\yap.ico,0' -Description 'Yap (Edge-Ops Pure PowerShell + Whisper WASM)'

Write-Host 'Build-Portable complete (zero Python, all 12 Whisper WASM assets verified).'
