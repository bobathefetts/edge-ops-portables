# Changelog

## 0.1.0 (2026-11-19)
First release of **BYOB Explorer**, a read-only network explorer and investigator for isolated lab
enclaves, derived from `byob-portable` 0.4.0 in this repository.

- **New product identity:** tool id `byob-explorer`, port block `8833-8835` (runs beside BYOB on
  `8830-8832`), host `src\Start-Explorer.ps1`, launchers `Explorer-Dev.bat` / `Explorer.lnk`,
  packager output `Explorer-v<VERSION>.zip`, log files `logs\Explorer_*.log`.
- **Removed Outlook completely** (tools, routes, settings, UI pane, prompt text, plugin folder).
- **Read-only network tools:** `net_query` (local / WinRM / PowerCLI) and `ssh_query`, checked by
  the read-only command gate (`src\NetGate.ps1`) and the per-workspace scope
  (`<workspace>\.byob\scope.json`); full outputs saved to `workspace\raw\`.
- **Knowledge base as memory:** `kb_read`, `kb_write`, `frontier` (to-explore list),
  `baseline_diff`; the system prompt carries the kb index and frontier count.
- **Credential store** (`data\credentials.json`, DPAPI per user) with `GET/POST /api/credentials`;
  the model only sees credential names.
- **Autonomous agent loop** (`src\ExplorerAgent.ps1`): `chat` and `explore` modes with step budgets
  (40 / 300), explore kick-off instruction and auto-continue while the frontier has open items,
  context management (trim old tool outputs, then summarise), loop guard and bad-streak nudge,
  model-call retries (5 s / 15 s), prompt Stop in every waiting state (model call, approval,
  running child process), progress events.
- **Plugins** (`src\PluginHost.ps1`): `byob-plugin.json` folders in `plugins\` and
  `<workspace>\.byob\plugins\`, exposed as `plg_<plugin>_<tool>`; SHA-256 trust in
  `data\plugin-trust.json`; untrusted or changed plugins always ask. Sample `plugins\sample-portscan`.
- **HTTP API:** `/api/credentials`, `/api/scope`, `/api/kb`, `/api/kb/file`, `/api/plugins`;
  `/api/state` adds `credentialCount`, per-workspace `scopeExists`, `runningChats`.
- **UI:** Knowledge / Artifacts / Plan pane, Explore button, scope / credentials / progress chips,
  readable `net_query`/`ssh_query` steps with a BLOCKED badge, settings sections for model, run
  limits, approvals (YOLO warning), credentials, scope and plugins.
- **Hardening:** `run_command` no longer passes `-ExecutionPolicy Bypass`; file tools refuse the
  app data folder; the gate denies `Get-Variable` in every mode; HTML artifacts are served with a
  CSP sandbox; request bodies are never logged or echoed in errors; approvals are matched by id.
- **LLM client:** asynchronous HTTP with a configurable timeout (`request_timeout_sec`), error
  messages include the server's response body, OpenAI-style conversation converted for the
  Anthropic API, tool calls always normalised so tool-call/tool-result pairing stays valid.
- **Tests:** `tests\Run-CoreTests.ps1` (gate, scope, credentials, tools, plugins, agent helpers) and
  `tests\Run-HostSmoke.ps1` + `tests\mock_llm.py` (end-to-end over the HTTP API with a scripted
  model); dev override `BYOB_EXPLORER_ALLOW_PS7=1` runs the host under PowerShell 7 for testing.
- **Not yet tested on Windows:** see the README section of the same name.
