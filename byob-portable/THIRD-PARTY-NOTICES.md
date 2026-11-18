# Third-Party Notices

## 1. BYOB (architecture, protocol concepts & prompt design)
- **Upstream URL:** https://github.com/Scronkfinkle/byob
- **License:** MIT OR Apache-2.0
- **Location:** `src\ByobLlm.ps1`, `src\ByobTools.ps1`, `src\ui\index.html`
- **Changes:** Reimplemented cleanly in Windows PowerShell 5.1 and vanilla HTML/CSS/JS with zero compiled binaries so it runs on AppLocker/WDAC workstations.

## 2. FleetHacker Edge-Ops & PacketRat Outlook COM Patterns
- **Upstream URLs:** https://github.com/fleethacker-data-crucible/edge-ops , https://github.com/fleethacker-data-crucible/PacketRat
- **License:** MIT
- **Location:** `src\LoopbackPort.ps1`, `scripts\New-ToolShortcut.ps1`, `tests\LoopbackPort.Tests.ps1`, `PSScriptAnalyzerSettings.psd1`, `plugins\outlook-classic\outlook_com.ps1`
- **Changes:** Adapted PacketRat's Classic Outlook COM mailbox reader, sensitivity heuristic, Sent Items reply detector, and signature-preserving reply drafter into BYOB's STA PowerShell host.
