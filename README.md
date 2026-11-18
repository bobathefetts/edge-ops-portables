# Edge-Ops Portables (`BYOB` + `Yap`)

Zero-install Windows packages converted to follow the [FleetHacker Edge-Ops](https://github.com/fleethacker-data-crucible/edge-ops) conventions.

## Download Pre-Built Zip Packages (GitHub Releases)
- **Latest Release:** https://github.com/bobathefetts/edge-ops-portables/releases/latest
  - `Yap-v0.3.0.zip` (`29.4 MB`) — **Pure Windows PowerShell 5.1 + C# (`Add-Type`) + local Edge Whisper WASM** (`whisper-tiny.en` ONNX pre-bundled offline, `0` `.exe`/`.dll`/`.pyd` files, zero Python).
  - `BYOB-v0.3.9.zip` (`69.1 MB`) — Native BYOB desktop window (`--serve`), loopback Edge-Ops host (`8830-8832`), and **Outlook Classic** COM plugin (`plugins\outlook-classic\`, adapted from `PacketRat`).

Verify `.sha256`, right-click each `.zip` -> **Properties -> Unblock**, extract the whole folder, and double-click `Yap.lnk` or `BYOB.lnk`.

## Building From Source
```powershell
# Yap (PowerShell 5.1 + C# + Whisper WASM; zero Python)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\yap-portable\scripts\Build-Portable.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\yap-portable\scripts\Package-Yap.ps1

# BYOB Portable (downloads BYOB Windows release binary + packages Outlook Classic plugin)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\byob-portable\scripts\Build-Portable.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\byob-portable\scripts\Package-BYOB.ps1
```

See [yap-portable/README.md](yap-portable/README.md) and [byob-portable/README.md](byob-portable/README.md) for full details.
