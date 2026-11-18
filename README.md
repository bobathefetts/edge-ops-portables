# Edge-Ops Portables (`BYOB` + `Yap`)

Zero-install, self-contained Windows packages converted to follow the [FleetHacker Edge-Ops](https://github.com/fleethacker-data-crucible/edge-ops) layout and conventions.

## Option 1: Download Pre-Built Zip Packages (GitHub Releases)
Pre-built `.zip` archives are attached to **Releases** (not stored inside the Git folder tree because `Yap-v0.2.1.zip` exceeds GitHub's 100 MB Git file limit):

- **Release page:** https://github.com/bobathefetts/edge-ops-portables/releases/tag/v1.0.0
  - `BYOB-v0.3.9.zip` (`69.1 MB`) — Native BYOB desktop window (`--serve`), loopback Edge-Ops host (`8830-8832`), and **Outlook Classic** COM plugin (`plugins\outlook-classic\`, adapted from `PacketRat`).
  - `Yap-v0.2.1.zip` (`112.7 MB`) — Bundled Python 3.12 runtime, portable `.\data\` state, and local Edge-Ops dashboard (`8835-8837`).

Verify `.sha256`, right-click the `.zip` -> **Properties -> Unblock**, extract the whole folder, and double-click `BYOB.lnk` or `Yap.lnk`.

## Option 2: Run Directly From This Source Repo (Self-Bootstrapping)
Even if you clone this repo or use **Code -> Download ZIP**, you do **not** need `uv`, Python, or Rust installed:
- Running `BYOB.lnk` / `BYOB-Dev.bat` automatically runs `byob-portable\scripts\Build-Portable.ps1` if `bin\byob.exe` is missing.
- Running `Yap.lnk` / `Yap-Dev.bat` automatically runs `yap-portable\scripts\Build-Portable.ps1` if `runtime\python\python.exe` is missing (fetching standalone `uv.exe` into `temp\uv\` only if `uv` is not already installed).

See [byob-portable/README.md](byob-portable/README.md) and [yap-portable/README.md](yap-portable/README.md) for full details.
