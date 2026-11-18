# Third-Party Notices

This portable Edge-Ops package ships or wraps the following open-source software:

## 1. BYOB (Bring Your Own Brain)
- **Version:** 0.3.9
- **Upstream URL:** https://github.com/Scronkfinkle/byob
- **License:** MIT OR Apache-2.0
- **Location:** `bin\byob.exe` (and upstream source in `patches\`)
- **Changes:** Wrapped with a Windows PowerShell 5.1 Edge-Ops launcher (`src\Start-BYOB.ps1`) that forces `BYOB_HOME` into `.\data\`, redirects `TEMP`/`TMP` into `.\temp\sys\`, and exposes Edge-Ops loopback port management and `/__fleethacker/id` & `/__fleethacker/shutdown` endpoints.

## 2. byob-artifact-host (Servo + SpiderMonkey + ANGLE)
- **Version:** Bundled with BYOB 0.3.9
- **Upstream URL:** https://github.com/Scronkfinkle/byob
- **License:** MPL-2.0 (Servo/SpiderMonkey) and BSD-3-Clause (ANGLE)
- **Location:** `bin\byob-artifact-host.exe`, `bin\libEGL.dll`, `bin\libGLESv2.dll`, `bin\NOTICE`, `bin\LICENSE-ANGLE`
- **Changes:** Unmodified upstream Windows release binaries.

## 3. FleetHacker Edge-Ops & PacketRat Outlook COM Patterns
- **Upstream URLs:** https://github.com/fleethacker-data-crucible/edge-ops , https://github.com/fleethacker-data-crucible/PacketRat
- **License:** MIT
- **Location:** `src\LoopbackPort.ps1`, `scripts\New-ToolShortcut.ps1`, `tests\LoopbackPort.Tests.ps1`, `PSScriptAnalyzerSettings.psd1`, `plugins\outlook-classic\outlook_com.ps1`
- **Changes:** Adapted test path in `tests\LoopbackPort.Tests.ps1`, and adapted PacketRat's Classic Outlook COM mailbox reader, sensitivity heuristic, Sent Items reply detector, and signature-preserving reply drafter into a BYOB plugin backend.
