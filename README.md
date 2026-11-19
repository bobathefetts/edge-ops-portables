# Edge-Ops Portables (`BYOB` + `Yap`)

Zero-install, zero-EXE Windows packages converted to follow the [FleetHacker Edge-Ops](https://github.com/fleethacker-data-crucible/edge-ops) stack for app-whitelisted (AppLocker/WDAC) workstations.

## Download Pre-Built Zip Packages (GitHub Releases)
- **Latest Release:** https://github.com/bobathefetts/edge-ops-portables/releases/latest
  - `BYOB-v0.4.0.zip` — **Pure Windows PowerShell 5.1 (`-STA`) + Edge `--app` window + Classic Outlook COM** (`0` `.exe`/`.dll` files). Workspace files, Office `.docx`/`.xlsx`/`.pptx` reading, artifacts, undo, approvals, and full Outlook inbox assistant.
  - `Yap-v0.3.0.zip` (`29.4 MB`) — **Pure Windows PowerShell 5.1 + C# (`Add-Type`) + local Edge Whisper WASM** (`whisper-tiny.en` ONNX pre-bundled offline, `0` `.exe`/`.dll`/`.pyd` files, zero Python).

Verify `.sha256`, right-click each `.zip` -> **Properties -> Unblock**, extract the whole folder, and double-click `BYOB.lnk` or `Yap.lnk`.

See [byob-portable/README.md](byob-portable/README.md) and [yap-portable/README.md](yap-portable/README.md) for full details.

## BYOB Explorer (`explorer-portable`)
A third package, built from `byob-portable`: a **read-only network explorer and investigator** for isolated lab enclaves (VMware ESXi hosts with Windows/Linux VMs), run from a Windows management laptop against an OpenAI-compatible model on another box. It explores the allowed scope on its own and writes a markdown knowledge base, investigates problems you describe in chat, keeps lab credentials in one DPAPI-encrypted store (the AI only sees names), and can write its own PowerShell plugins that you review and trust. Every network query passes a read-only command gate and a per-workspace scope list. Same zero-EXE stack (Windows PowerShell 5.1 + Edge `--app`), port block `8833-8835` so it runs beside BYOB. Version 0.1.0, not yet tested on Windows: see [explorer-portable/README.md](explorer-portable/README.md).
