# Edge-Ops Portables (`BYOB` + `Yap`)

Zero-install, self-contained Windows packages converted to follow the [FleetHacker Edge-Ops](https://github.com/fleethacker-data-crucible/edge-ops) layout and conventions.

## Ready-to-Run Releases
Download the packaged archives and `.sha256` checksums from **Releases -> latest**:
- `BYOB-v0.3.9.zip` — Self-contained BYOB desktop window (`--serve`), loopback Edge-Ops host (`8830-8832`), and **Outlook Classic** COM plugin (`plugins\outlook-classic\`, adapted from `PacketRat`).
- `Yap-v0.2.1.zip` — Self-contained push-to-talk Windows dictation (`Ctrl+Win`) with bundled Python 3.12 runtime, portable `.\data\` state, and local Edge-Ops dashboard (`8835-8837`).

Verify checksum, right-click the `.zip` -> **Properties -> Unblock**, extract the whole folder, and double-click `BYOB.lnk` or `Yap.lnk`.

## Building Packages From This Repo
```powershell
# BYOB Portable
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\byob-portable\scripts\Build-Portable.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\byob-portable\scripts\Package-BYOB.ps1

# Yap Portable
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\yap-portable\scripts\Build-Portable.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\yap-portable\scripts\Package-Yap.ps1
```

See [byob-portable/README.md](byob-portable/README.md) and [yap-portable/README.md](yap-portable/README.md) for full details.
