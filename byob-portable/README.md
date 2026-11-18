# BYOB (Edge-Ops Pure PowerShell 5.1 + Edge App Window + Outlook Classic)

> Zero-install, zero-EXE Edge-Ops implementation of [Scronkfinkle/byob](https://github.com/Scronkfinkle/byob) with Classic Outlook COM integration adapted from [fleethacker-data-crucible/PacketRat](https://github.com/fleethacker-data-crucible/PacketRat). Runs in its own standalone Edge `--app` window with **zero third-party executables or DLLs**.

![PS 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE) ![Chrome engine](https://img.shields.io/badge/browser-Chrome%2FEdge-4285F4) ![No admin](https://img.shields.io/badge/admin-not%20required-3a7d44) ![License MIT](https://img.shields.io/badge/license-MIT-blue)

## Run (app-whitelisted Windows, zero install)
1. Download `BYOB-v0.4.0.zip`, verify `.sha256`, right-click -> **Properties -> Unblock**, and extract the folder.
2. Double-click **`BYOB.lnk`** (or **`BYOB-Dev.bat`**).
3. BYOB opens in its own standalone Edge `--app` window (`http://localhost:8830/`), with the **Outlook Classic** pane alongside your chat.

## Capabilities
- **100% Application-Control friendly:** Pure Windows PowerShell 5.1 (`-STA`) + signed .NET Framework 4.x + Edge/Chrome `--app` UI (`0` `.exe`/`.dll` files, no runtime C# compile required).
- **Model support:** Auto-detects local servers (`Fairlead 8776`, `Phoenix LAI 1234`, `Windlass 8777`, `llama-server 8080`, `Ollama 11434`, `vLLM 8000`) and supports OpenAI `/v1/chat/completions`, Anthropic `/v1/messages`, prompt-based tool fallback, and image attachments.
- **Workspace & Office tools:** `list_files`, `read_file` (with built-in `.docx`/`.pptx`/`.xlsx` XML extraction), `search_files`, `write_file` / `edit_file` (with per-turn undo backups in `.\data\undo\`), `run_command`, `remember` (`memory.md`), `update_plan`, `delegate` subagents, and side-pane `create_artifact` (Markdown, CSV tables, sandboxed HTML apps).
- **Classic Outlook COM tools:** `outlook_status`, `outlook_folders`, `outlook_search` (with Sent-Items reply detection and PacketRat sensitivity redaction), `outlook_read`, `outlook_thread`, `outlook_open`, `outlook_draft_reply` (preserves Outlook signature), `outlook_draft_new`, `outlook_mark`, and `outlook_send` (always requires user confirmation).

## License
MIT (Edge-Ops host, tools, UI, and Outlook plugin) and MIT OR Apache-2.0 references. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
