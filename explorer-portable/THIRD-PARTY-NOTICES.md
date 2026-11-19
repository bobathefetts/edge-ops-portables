# Third-Party Notices

BYOB Explorer adds **no third-party code**. It contains no compiled binaries and loads no external
modules (VMware PowerCLI is used only if you install it yourself).

## 1. byob-portable (this repository)
- **Location:** `..\byob-portable\`
- **License:** MIT
- **Use:** BYOB Explorer started as a copy of `byob-portable` 0.4.0: the loopback host, LLM client,
  base tools (files, run_command, artifacts, plan, memory, delegate), undo backups and the UI were
  carried over and then changed for network exploration. The Outlook integration was removed.

## 2. BYOB (idea, architecture and prompt design)
- **Upstream URL:** https://github.com/Scronkfinkle/byob
- **License:** MIT OR Apache-2.0
- **Use:** `byob-portable` reimplemented the BYOB idea in Windows PowerShell 5.1 and vanilla
  HTML/CSS/JS; BYOB Explorer inherits that design. No upstream code is included.

## 3. FleetHacker Edge-Ops patterns
- **Upstream URL:** https://github.com/fleethacker-data-crucible/edge-ops
- **License:** MIT
- **Location:** `src\LoopbackPort.ps1` (one fix: the IPv6 probe no longer fails on machines without
  IPv6), `scripts\New-ToolShortcut.ps1`, `tests\LoopbackPort.Tests.ps1`, `PSScriptAnalyzerSettings.psd1`.
