# Changelog

## 0.3.9-edgeops.2 (2026-11-18)
- Switched default launch mode to `"desktop"` (`--serve`), so double-clicking `BYOB.lnk` opens BYOB in its own dedicated native window while keeping the Edge-Ops loopback endpoint (`8830-8832`) active.
- Integrated `plugins\outlook-classic\` (PowerShell 5.1 STA backend adapted from `fleethacker-data-crucible/PacketRat`): Classic Outlook COM profile check, folder listing, search with Sent-Items reply detection, full email/thread reading, sensitivity/PII heuristic guard, signature-preserving reply/new drafting, mark/move/archive, human-confirmed sending, and an Outlook side-pane + status chip.

## 0.3.9-edgeops.1 (2026-11-18)
- Initial portable Edge-Ops conversion of `Scronkfinkle/byob` v0.3.9.
- Added Windows PowerShell 5.1 host (`src\Start-BYOB.ps1`), C# 5 loopback proxy (`src\ProxyServer.cs`), headless `.lnk` launcher (`BYOB.lnk`), and dev `.bat` launchers.
- Isolated all runtime state (`BYOB_HOME` -> `data\`), `TEMP`/`TMP` (`temp\sys\`), logs (`logs\`), and default workspace (`workspace\`) inside the extracted folder.
- Added `/__fleethacker/id` and `/__fleethacker/shutdown` self-detection on port block `8830-8832` (`reuse` policy).
- Added Pester 5 smoke tests and zip + SHA-256 packager (`scripts\Package-BYOB.ps1`).
