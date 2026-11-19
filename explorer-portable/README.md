# BYOB Explorer (read-only network explorer and investigator)

BYOB Explorer is a local AI assistant for **isolated lab networks** (VMware ESXi hosts running Windows
and Linux VMs). You run it on a Windows management laptop; the AI model runs on another computer
that the laptop reaches over a private link.

It does four things:

1. **Explores on its own, read-only.** Press **Explore** and it maps the network you allowed
   (hosts, VMs, subnets, services, dependencies), writing what it learns into a knowledge base of
   plain markdown files. That knowledge base is its memory for later chats.
2. **Investigates problems.** Describe a symptom in the chat; it checks the hosts involved with
   read-only queries, compares with what it knew was normal, and reports the likely cause and the
   fix it recommends. It does not make the fix.
3. **Keeps the lab logins in one place**, encrypted for your Windows account. The AI only sees
   their names.
4. **Can build its own tools** as small PowerShell plugins, which you review and trust.

It is pure Windows PowerShell 5.1 plus an Edge/Chrome app window: no installer, no `.exe` or
`.dll` files, no admin rights. Version 0.1.0. Derived from `byob-portable` in this repository.

---

## What you need

| Needed | Notes |
|---|---|
| Windows 10/11 with **Windows PowerShell 5.1** | Built in (`powershell.exe`). |
| **Microsoft Edge** or Google Chrome | Used as the app window. |
| A reachable **AI model server** | OpenAI-compatible (`/v1/chat/completions`), with **tool calling** (function calling) enabled, e.g. llama.cpp `llama-server --jinja`, vLLM with a tool parser, Ollama. A larger, tool-capable model works much better. |
| *Optional:* **VMware PowerCLI** module | Only for vCenter/ESXi queries (`net_query via=vsphere`). Install it for your user (`VMware.VimAutomation.Core`) or copy it into your PowerShell modules folder. |
| *Optional:* **WinRM** to the Windows VMs | For Windows queries (`net_query via=winrm`). The VMs must accept WinRM from the laptop with the credential you store. |
| *Optional:* **OpenSSH client** | For Linux queries (`ssh_query`). Windows ships it at `C:\Windows\System32\OpenSSH\ssh.exe` (an optional Windows feature). |

---

## First run, step by step

1. **Unpack.** Copy the `Explorer-v0.1.0` folder to the laptop (if you downloaded a zip:
   right-click it, **Properties > Unblock**, then extract the whole folder).
2. **Launch.** Double-click **`Explorer-Dev.bat`**. A console window opens (leave it open; it
   shows startup errors), then the BYOB Explorer window opens at `http://localhost:8833/`.
   The first time, `Explorer-Dev.bat` also creates **`Explorer.lnk`** in the same folder. After
   that you can start it with `Explorer.lnk` (no console window). `Explorer.lnk` cannot be
   created ahead of time; if it is missing, run `Explorer-Dev.bat` (or
   `scripts\Build-Portable.ps1`) once on Windows.
3. **Connect the model.** Click **Settings** (or the model chip at the top). Under **Model**,
   enter the server address, for example `http://10.50.0.2:8080/v1`, and an API key if the server
   needs one. Click **Detect** to list the server's models and pick one, then click **Test**. You
   should see `OK`. Click **Save settings**.
4. **Add credentials.** Under **Credentials**, add each lab login:
   * `windows` for WinRM to Windows hosts (user like `LAB\admin`),
   * `vsphere` for vCenter or ESXi (user like `administrator@vsphere.local`); put the vCenter/ESXi
     host name in the **Note** so the AI knows where to use it,
   * `linux` for ssh (user like `root`; a password, or the path to an SSH private key).
   Click **Save credential** for each one.
5. **Set the scope.** Under **Scope**, list what the AI may touch, one entry per line:
   IPv4 addresses (`10.20.30.5`), subnets (`10.20.30.0/24`, /8 or smaller) or host name patterns
   (`esx01`, `*.sw4.lab`). Put anything it must never touch under **Deny** (for example the
   default gateway). Click **Save scope**. **Until a scope is saved, nothing on the network is
   allowed.**
6. **Press Explore.** Close Settings and click the green **Explore** button (or the
   "Explore this network" card). The AI first looks at what the laptop itself can see, seeds a
   to-explore list (the *frontier*) from the scope, then works through it item by item. Watch the
   steps in the chat and the files appear in the **Knowledge** pane on the right. The top bar
   shows `step N/300`. Press **Stop** at any time; press **Explore** again later to continue from
   where it left off.

---

## Everyday use

* **Ask about the network:** "What do you know about this network so far?", "Which VMs run on
  esx02?", "What depends on the SQL server?". It answers from the knowledge base and checks live
  when needed.
* **Investigate a problem:** click the **Investigate a problem** card, fill in the symptom, where
  it is seen and since when, and press **Send**. It restates the symptom, reads what normal looks
  like in the knowledge base, runs read-only checks, compares with earlier outputs
  (`baseline_diff`) and reports: findings (with the raw files they came from), likely cause,
  recommended fix, and what is still unknown.
* **Baseline a server:** the **Baseline a server** card records a known-good snapshot of one host
  so later problems can be compared with it.
* **Guide an exploration:** type a hint in the box before pressing **Explore**, e.g. "focus on
  the storage network today".
* **Approvals:** some actions stop and ask you (an orange or red card). **Allow once** or **Deny**.
* **Several labs:** use the **+** next to the workspace list to add a folder per lab enclave. Each
  workspace has its own knowledge base, raw outputs and scope.
* **Run limits:** Settings > Run limits sets the step budgets (40 per chat turn, 300 per Explore
  run by default), the model timeout, and the context budget. When a long run fills the context,
  old outputs are shortened and the work so far is summarised automatically.

---

## Where things are stored

| Location | What |
|---|---|
| `data\settings.json` | Settings (model address, limits, approval mode). |
| `data\secrets.json` | The model API key (plain text, protected only by file permissions). |
| `data\credentials.json` | Lab credentials. Passwords are encrypted with Windows DPAPI for **this Windows user on this computer**; another user or another computer cannot decrypt them. |
| `data\plugin-trust.json` | Which plugins you trusted (a hash of their files). |
| `data\chats\` | Chat history. |
| `data\memory.md`, `<workspace>\.byob\memory.md` | Notes the AI saved with `remember`. |
| `workspace\kb\` | The knowledge base: `00-index.md`, `10-inventory.md`, `20-network.md`, ..., `hosts\<name>.md`, and `frontier.json` (the to-explore list). Plain markdown; you can read and edit it. |
| `workspace\raw\` | The full output of every query, one file each, with a header (time, target, command). Knowledge base facts cite these files. |
| `<workspace>\.byob\scope.json` | The scope for that workspace. |
| `<workspace>\.byob\plugins\` | Plugins the AI wrote for that workspace. |
| `logs\` | Host logs (no passwords or request bodies are logged). |

---

## Safety model, in plain words

**What runs without asking** (in the recommended *ask_writes* mode):

* `net_query` and `ssh_query`: one query each, checked first by the **read-only gate**.
* Reading and writing the knowledge base (`kb_read`, `kb_write`), the frontier list, listing
  credential names, comparing outputs, reading workspace files, the plan and the subagent.
* Plugins you have **trusted** whose tools are declared `read`.

**What asks first** (in *ask_writes* and *ask_all*; YOLO turns these prompts off):

* `run_command` (runs any PowerShell command on the laptop), `write_file`, `edit_file`,
  `create_artifact`, `remember`.

**What always asks, in every mode (even YOLO):**

* Every plugin that is **new or changed** since you trusted it.

**What the read-only gate does:** it reads each command before it runs and refuses anything it
does not positively recognise as read-only: it allows `Get-*`/`Test-*`-style PowerShell, a list of
read-only Windows tools (`ping`, `ipconfig`, `arp -a`, `route print`, `nslookup`, ...), read-only
Linux commands over ssh, `kubectl get/describe/logs`, and PowerCLI `Get-*`. It refuses file
writes, service changes, restarts, scripts, redirection, credential or secret access, and any
target outside the scope. Refused commands show a red **BLOCKED** badge and are not run.

**What the gate does NOT guarantee:**

* Read-only does not mean harmless to read. Queries can return **sensitive data** (user names,
  configuration, logs) and that data goes to the model server and into `workspace\raw\` and the
  knowledge base. Treat the workspace folder as sensitive.
* "Read-only" is decided by an allow-list written by hand. A command the authors believed
  read-only could still change something on an unusual system. Keep the scope tight.
* Queries run with **the credentials you stored**. If those are admin credentials, a gate mistake
  runs with admin rights. Prefer read-only lab accounts where you can.
* **Plugins and `run_command` are outside the gate.** Their code can do anything your Windows
  account can do. Read a plugin's `.ps1` files before you trust it; read every `run_command`
  before you allow it.
* **YOLO mode removes the prompts** for `run_command` and file writes. Do not use it with stored
  admin credentials on hand unless you are watching.
* Scope host-name patterns are matched as text; DNS is not consulted. An IP that is in scope can
  be reached under a name that is not, and vice versa, so list both if needed.

The app's own web server listens on `localhost` only and refuses requests from other computers
or other web pages. Credential passwords are never shown in the app, sent to the model, written
to chats or logs, or returned by the API.

---

## Plugins

See [plugins/README.md](plugins/README.md) for the format. In short: a folder with a
`byob-plugin.json` manifest and one `.ps1` script per tool, in the app's `plugins\` folder or in
`<workspace>\.byob\plugins\` (the AI can write the latter; that asks you first). New or changed
plugins always ask before running; trust them in **Settings > Plugins** once you have read the
code. The sample `plugins\sample-portscan` checks up to 30 TCP ports on one in-scope host.

---

## Known limits

* The AI is only as good as the model behind it. Small models loop, forget to cite raw files, or
  stop early; the app limits loops (a repeated identical call is refused the third time) and
  nudges Explore runs to keep going while the frontier has open items, but cannot make a weak
  model careful.
* One reply runs at a time per chat. The host serves one request at a time; a slow **Test** or
  **Detect** blocks the window for a few seconds.
* The context budget is measured in characters, not tokens (about 4 characters per token).
* Host names in the scope are matched literally (see the safety section).
* The approval mode **ask_all** asks before every tool call including read-only queries, which is
  slow for Explore runs.
* `secrets.json` (the model API key) is not encrypted.

## Not yet tested on Windows

This version was built and tested on a Linux test machine running PowerShell 7 with a scripted
fake model server. Everything below is written for Windows but has **not yet been run there**:

* Starting under **Windows PowerShell 5.1** itself (`Explorer-Dev.bat`, `-CheckOnly`) and the
  Edge/Chrome `--app` window.
* **`Explorer.lnk`** creation (`scripts\New-ToolShortcut.ps1`, WScript.Shell COM) and starting
  from it (`conhost.exe --headless`).
* **DPAPI** encryption of credentials (`ConvertFrom-SecureString`); on Linux the tests used a
  test-only base64 fallback.
* Child **`powershell.exe -NoProfile -NonInteractive -EncodedCommand`** processes for
  `net_query`, `run_command` and plugins (tested with `pwsh` on Linux), including the effect of
  the machine's execution policy and of AppLocker/WDAC Constrained Language Mode.
* **WinRM** queries (`Invoke-Command` with a stored credential).
* **PowerCLI** queries (`Connect-VIServer`, certificate handling, `Disconnect-VIServer`).
* **`ssh.exe`** queries, both with an SSH key and with a password (the password path uses
  `SSH_ASKPASS` with a `.cmd` helper and is the least certain part).
* Stopping a running Windows child process from the **Stop** button.
* The UI in **Edge** (it was exercised in headless Chrome on Linux).
* The **Anthropic** API option (only the OpenAI-compatible path was exercised).
* The packager producing a zip that includes `Explorer.lnk`.

## Tests

* `tests\Run-CoreTests.ps1`: gate, scope, credential store, explorer tools, plugin host, agent
  helpers (no Pester needed; runs on Windows PowerShell 5.1 and PowerShell 7).
* `tests\Run-HostSmoke.ps1`: starts the host and `tests\mock_llm.py` (a scripted fake model) and
  drives the whole HTTP API. Needs PowerShell 7 and Python 3; elsewhere it prints SKIP.
* `tests\Explorer.Tests.ps1`, `tests\LoopbackPort.Tests.ps1`: Pester 5 checks for Windows.
* `src\Start-Explorer.ps1 -CheckOnly`: a quick self-check of the tool set.

Developer note: `BYOB_EXPLORER_ALLOW_PS7=1` lets the host start under PowerShell 7 (no browser is
opened); `BYOB_EXPLORER_RETRY_DELAYS=a,b` shortens the model retry waits. Both exist for the test
runtime only.

## License

MIT. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
