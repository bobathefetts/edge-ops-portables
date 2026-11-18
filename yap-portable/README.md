# Yap (Edge-Ops Pure PowerShell + C# + Whisper WASM Edition)

> Pure Windows PowerShell 5.1 + C# (`Add-Type`) + Edge Whisper WASM conversion of [bobathefetts/yap](https://github.com/bobathefetts/yap). **Zero Python, zero third-party EXEs/DLLs, zero installers.**

![PS 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE) ![Chrome engine](https://img.shields.io/badge/browser-Chrome%2FEdge-4285F4) ![No admin](https://img.shields.io/badge/admin-not%20required-3a7d44) ![License MIT](https://img.shields.io/badge/license-MIT-blue)

Converted to follow the [FleetHacker Edge-Ops](https://github.com/fleethacker-data-crucible/edge-ops) stack, using the SHA-256-pinned local Whisper WASM speech-input pattern from [PacketRat](https://github.com/fleethacker-data-crucible/PacketRat).

## Run (app-whitelisted Windows, zero install)
1. Download `Yap-v0.3.0.zip` from Releases, verify `.sha256`, right-click -> **Properties -> Unblock**, and extract the folder.
2. Double-click **`Yap.lnk`** (or **`Yap-Dev.bat`**).
3. Edge opens the local Yap app window (`http://localhost:8835/`), loading `whisper-tiny.en` locally in a Web Worker.
4. Hold **Ctrl+Win**, speak, and release: Yap captures 16 kHz audio via built-in Windows `winmm.dll`, transcribes locally in Whisper WASM (or falls back to built-in `.NET` `System.Speech` if the Edge window is closed), cleans up fillers/stutters/spoken formatting, and pastes at your cursor.

*(If strict WDAC blocks runtime C# `Add-Type` compilation on your workstation, Yap falls back automatically to the in-browser **Hold to Dictate** button using Edge `AudioWorklet` + Whisper WASM.)*

## Requirements
| Needs | Yes/No |
|---|---|
| Windows PowerShell 5.1 | Yes (built-in) |
| Chrome/Edge | Yes (runs local Whisper WASM) |
| Python / Node / third-party EXEs | **No** |
| Admin rights | No |
| Network access | No (62.5 MB Whisper WASM bundle included offline in `src\ui\vendor\voice\`) |
| Runtime C# compile (`Add-Type`) | Optional (enables global `Ctrl+Win` hook, WinMM mic, pill overlay, `SendInput`; degrades gracefully to Edge UI if blocked) |
| Default port | `8835-8837` (`reuse` policy) |

## Building from source checkout
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Portable.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Package-Yap.ps1
```

## License
MIT. Third-party code and notices: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
