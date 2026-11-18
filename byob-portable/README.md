# BYOB Portable (Bring Your Own Brain + Outlook Classic)

> Self-contained, zero-install Edge-Ops package of [Scronkfinkle/byob](https://github.com/Scronkfinkle/byob) with Classic Outlook COM integration adapted from [fleethacker-data-crucible/PacketRat](https://github.com/fleethacker-data-crucible/PacketRat). Runs in its own desktop window and lets your local AI assistant search, read, thread, triage, and draft/send replies across your Outlook emails.

![PS 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE) ![Chrome engine](https://img.shields.io/badge/browser-Chrome%2FEdge-4285F4) ![No admin](https://img.shields.io/badge/admin-not%20required-3a7d44) ![License MIT](https://img.shields.io/badge/license-MIT-blue)

Converted to follow the [FleetHacker Edge-Ops](https://github.com/fleethacker-data-crucible/edge-ops) portable packaging pattern.

**Status:** prototype. Get local authorization and a security review before using it with sensitive data.

## Run (portable Windows, zero install)
1. Download `BYOB-v0.3.9.zip` (or copy the extracted `BYOB-v0.3.9\` folder), verify the `.sha256` (`Get-FileHash .\BYOB-v0.3.9.zip -Algorithm SHA256`), then right-click the zip -> Properties -> **Unblock** and extract the whole folder.
2. Double-click **`BYOB.lnk`** (hidden host console) or **`BYOB-Dev.bat`** (visible console).
3. BYOB opens in **its own desktop window** with the **Outlook Classic** plugin pre-loaded (click **Outlook** in the header/side pane or ask the assistant about your emails). A loopback browser UI + Edge-Ops control endpoint also runs at `http://127.0.0.1:8830/` (walks `8830-8832`). Close the BYOB window or send `POST /__fleethacker/shutdown` with `X-FleetHacker-Shutdown: 1` to stop.

Options: `BYOB-Dev.bat -Headless` (browser-only mode), `-OpenBrowser` (also open browser tab alongside desktop window), `-Port <n>`, `-NoBrowser`, `-Direct` (skip C# proxy), `-CheckOnly`, `-Yolo`, `-Workspace <dir>`, `-Model <name>`, `-InferenceUrl <url>`.

## Classic Outlook Integration (`plugins\outlook-classic\`)
Adapted from PacketRat's Windows PowerShell 5.1 COM provider (no OAuth, no cloud sync, Classic Outlook desktop app required):
- `outlook_status` & `outlook_folders`: checks MAPI profile health (never hangs on a Choose Profile modal) and lists Inbox/Sent/Drafts/Archive/subfolders with unread counts.
- `outlook_search`: searches folders by sender, recipient, subject, body text, unread status, and days back, including Sent-Items reply detection (`appearsReplied`) and PacketRat's sensitivity/PII body redaction heuristic.
- `outlook_read` & `outlook_thread`: reads paginated email bodies/attachments and full conversation threads across Inbox and Sent Items.
- `outlook_draft_reply` & `outlook_draft_new`: saves drafts in Outlook while preserving your Outlook HTML/WordEditor signature (never auto-sends).
- `outlook_mark`, `outlook_open`, & `outlook_send`: marks read/unread, tags categories, moves/archives, opens emails in Outlook, and sends only after BYOB's mandatory confirmation prompt.

## Requirements
| Needs | Yes/No |
|---|---|
| Windows PowerShell 5.1 | Yes (built-in; also runs the Outlook Classic COM backend) |
| Chrome/Edge | Optional (only needed in `-Headless` / `-OpenBrowser` mode; default runs in BYOB's own window) |
| Classic Outlook | Optional (required for `outlook_*` email tools; New Outlook Store app does not expose COM) |
| Admin rights | No |
| Installs / third-party runtimes | No (portable `bin\byob.exe` bundled) |
| Network access | Optional (connects to local LLM on `127.0.0.1` or user-configured API) |
| Runtime C# compile (Add-Type) | Yes (for loopback `/__fleethacker/id` proxy; `-Direct` skips it) |
| Default port | `8830-8832` (`reuse` policy) |

## Building and packaging
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Portable.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Package-BYOB.ps1
```

## License
MIT (Edge-Ops host wrapper and Outlook plugin) and MIT OR Apache-2.0 (BYOB). Third-party notices: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
