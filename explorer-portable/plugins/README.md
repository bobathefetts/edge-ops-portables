# BYOB Explorer plugins

A plugin adds tools that the AI can call. The AI can write its own plugins; you decide whether
they run without asking.

> **Plugins are NOT checked by the read-only gate.** A plugin script is ordinary PowerShell and
> can do anything your Windows account can do, including using the lab credentials it can reach.
> Trusting a plugin means trusting its code. Read the `.ps1` files before you press **Trust**.

## Where plugins live

| Location | Plugin id | Who puts it there |
|---|---|---|
| `<app folder>\plugins\<folder>\` | `app:<folder>` | You (shipped with the app) |
| `<workspace>\.byob\plugins\<folder>\` | `workspace:<folder>` | You, or the AI with `write_file` (which asks you first) |

The host looks for plugins again before every model call, so a plugin written during a turn shows
up on the next step.

## Folder layout

```
my-plugin\
  byob-plugin.json     the manifest (required)
  check.ps1            one script per tool (any name ending in .ps1)
```

## Manifest (`byob-plugin.json`)

```json
{
  "name": "portcheck",
  "description": "What the plugin is for.",
  "tools": [
    {
      "name": "check",
      "description": "What this tool does and when to use it. The AI reads this.",
      "access": "read",
      "params": {
        "type": "object",
        "properties": {
          "target": { "type": "string", "description": "Host to check." }
        },
        "required": ["target"]
      },
      "script": "check.ps1",
      "timeout_sec": 60
    }
  ]
}
```

| Field | Rules |
|---|---|
| `name` | 1-40 characters: letters, digits, `_`, `-`. |
| `tools` | 1-20 tools. |
| `tools[].name` | 1-40 characters: letters, digits, `_`, `-`. Unique in the plugin. |
| `tools[].access` | `read`, `write` or `execute` (default `execute`). Only used once the plugin is trusted. |
| `tools[].params` | A JSON schema object (`"type": "object"`). Optional. |
| `tools[].script` | A relative `.ps1` path inside the plugin folder (no `..`). |
| `tools[].timeout_sec` | 1-600 (default 60). The process is killed when it runs out of time. |

The AI sees each tool as `plg_<plugin name>_<tool name>` (lower case, only `a-z 0-9 _`, at most
60 characters). Two plugins that produce the same tool name: the second one is reported as invalid.

A plugin with a missing or broken manifest is skipped and listed with its error in
**Settings > Plugins**.

## How a tool runs

* A separate `powershell.exe -NoProfile -NonInteractive -EncodedCommand ...` process.
* The current directory is the workspace.
* The script file is read as text and run as a script block (so the machine's execution policy
  does not block it), with **one argument**: the tool arguments as an object.
* Two variables are set before the script runs: `$PluginRoot` (the plugin folder) and
  `$WorkspaceRoot` (the workspace folder).
* Everything the script writes to its output (and errors) is captured. The full output is saved to
  `workspace\raw\`; the AI gets the first 4000 and last 2000 characters if it is long.
* Use `return` to stop early, **not** `exit` (`exit` ends the process before the output is
  collected).

```powershell
param($ToolArgs)
$target = [string]$ToolArgs.target
"checking $target"
```

## Trust

`data\plugin-trust.json` records, for each trusted plugin id, a SHA-256 hash over every file in
the plugin folder.

* **Untrusted** (new, or any file changed since you trusted it): the AI can still call its tools,
  but **every call asks you**, whatever the approval mode (even YOLO). The approval card says the
  plugin is new or changed.
* **Trusted**: the tools use the `access` declared in the manifest. A trusted `read` tool runs
  without asking (in the recommended approval mode).

Trust and untrust plugins in **Settings > Plugins**. If you edit a trusted plugin, it becomes
untrusted until you trust it again.

## Sample

`sample-portscan\` provides `plg_portscan_scan`: a TCP connect test of up to 30 ports on one host.
It loads the app's `src\NetGate.ps1` and refuses any host outside the workspace scope
(`.byob\scope.json`). It ships untrusted: read `scan.ps1`, then trust it if you want it to run
without asking.
