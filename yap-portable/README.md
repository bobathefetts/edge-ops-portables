# Yap Portable

> Self-contained, zero-install Edge-Ops package of [bobathefetts/yap](https://github.com/bobathefetts/yap) — free, private push-to-talk dictation for Windows (Whisper + local llama.cpp cleanup).

![PS 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE) ![Chrome engine](https://img.shields.io/badge/browser-Chrome%2FEdge-4285F4) ![No admin](https://img.shields.io/badge/admin-not%20required-3a7d44) ![License MIT](https://img.shields.io/badge/license-MIT-blue)

Converted to follow the [FleetHacker Edge-Ops](https://github.com/fleethacker-data-crucible/edge-ops) portable packaging pattern.

**Status:** prototype. Get local authorization and a security review before using it with sensitive data.

## Run (portable Windows, zero install)
1. Download `Yap-v0.2.1.zip` (or copy the extracted `Yap-v0.2.1\` folder), verify the `.sha256` (`Get-FileHash .\Yap-v0.2.1.zip -Algorithm SHA256`), then right-click the zip -> Properties -> **Unblock** and extract the whole folder.
2. Double-click **`Yap.lnk`** (hidden console) or **`Yap-Dev.bat`** (visible console).
3. Hold **Ctrl+Win**, speak, and release to transcribe and paste at your cursor. Your browser also opens the local dashboard at `http://localhost:8835/` (walks `8835-8837`).

Options: `Yap-Dev.bat -Port <n>`, `-NoBrowser` (tray + hotkey only), `-CheckOnly`.

## Requirements
| Needs | Yes/No |
|---|---|
| Windows PowerShell 5.1 | Yes (built-in) |
| Chrome/Edge | Optional (for local dashboard UI; `-NoBrowser` skips) |
| Admin rights | No |
| Installs / third-party runtimes | No (portable Python runtime bundled in `runtime\python\`) |
| Network access | First-run only (to download Whisper + Qwen + llama.cpp if not pre-bundled with `-IncludeEngine -IncludeModels`) |
| Runtime C# compile (Add-Type) | No (tray/hotkeys run in portable Python; PS host uses `HttpListener`) |
| GPU | Optional (NVIDIA CUDA for Whisper or Vulkan GPU for llama.cpp; CPU fallback included) |
| Default port | `8835-8837` (`reuse` policy) |

## How it works
- `Yap.lnk` launches `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass` via `conhost.exe --headless` to run `src\Start-Yap.ps1`.
- `src\Start-Yap.ps1` sets `YAP_PORTABLE=1`, `YAP_HOME=<root>\data`, `YAP_ASSETS=<root>`, `TEMP=<root>\temp\sys`, `TMP=<root>\temp\sys`, and `HF_HOME=<root>\temp\hf`.
- Unlike upstream Yap, portable mode **never writes to `%USERPROFILE%\.yap`, Start Menu, or `HKCU\...\Run`**. Settings, history, logs, engine, CUDA DLLs, and models stay inside the extracted folder.
- `src\Start-Yap.ps1` serves a loopback-only dashboard (`src\ui\index.html`) and `/__fleethacker/id` & `/__fleethacker/shutdown` endpoints on `http://localhost:8835/`.

## Building and packaging
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Portable.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Package-Yap.ps1
```
Pass `-IncludeEngine` and `-IncludeModels` to `Build-Portable.ps1` (and `-IncludeDownloadedAssets` to `Package-Yap.ps1`) to bake the Vulkan `llama-server.exe` and models into an offline-ready archive.

## License
MIT. Third-party code and its notices: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
