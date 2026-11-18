# Edge-Ops Portables (`BYOB` + `Yap`)

Zero-install, zero-EXE Windows packages converted to follow the [FleetHacker Edge-Ops](https://github.com/fleethacker-data-crucible/edge-ops) stack for app-whitelisted (AppLocker/WDAC) workstations.

## Download Pre-Built Zip Packages (GitHub Releases)
- **Latest Release:** https://github.com/bobathefetts/edge-ops-portables/releases/latest
  - `BYOB-v0.4.0.zip` — **Pure Windows PowerShell 5.1 (`-STA`) + Edge `--app` window + Classic Outlook COM** (`0` `.exe`/`.dll` files). Workspace files, Office `.docx`/`.xlsx`/`.pptx` reading, artifacts, undo, approvals, and full Outlook inbox assistant.
  - `Yap-v0.3.0.zip` (`29.4 MB`) — **Pure Windows PowerShell 5.1 + C# (`Add-Type`) + local Edge Whisper WASM** (`whisper-tiny.en` ONNX pre-bundled offline, `0` `.exe`/`.dll`/`.pyd` files, zero Python).

Verify `.sha256`, right-click each `.zip` -> **Properties -> Unblock**, extract the whole folder, and double-click `BYOB.lnk` or `Yap.lnk`.

See [byob-portable/README.md](byob-portable/README.md) and [yap-portable/README.md](yap-portable/README.md) for full details.
