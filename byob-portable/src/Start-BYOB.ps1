# BYOB Edge-Ops Host (Pure Windows PowerShell 5.1 -STA, zero EXEs/DLLs, zero C# Add-Type compile). ASCII only.
# Runs BYOB in its own Edge/Chrome --app window on loopback (127.0.0.1:8830-8832) with full Outlook Classic COM integration.
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$CheckOnly,
    [switch]$Yolo,
    [string]$Workspace = '',
    [string]$Model = '',
    [string]$InferenceUrl = ''
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$toolId = 'byob'
$blockStart = 8830
$blockEnd = 8832

$logFile = Join-Path $root ('logs\BYOB_{0:yyyy_MM_dd_HHmmss}.log' -f (Get-Date))
New-Item -ItemType Directory -Force (Split-Path $logFile) | Out-Null

function Add-Log([string]$level, [string]$text) {
    try {
        [IO.File]::AppendAllText($logFile, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$level] $text`r`n", [Text.Encoding]::UTF8)
    } catch { }
}

function Show-Fatal([string]$text) {
    Add-Log 'FATAL' $text
    if ($CheckOnly -or -not [Environment]::UserInteractive) {
        [Console]::Error.WriteLine("FATAL: $text")
        return
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show("BYOB could not start.`n`n$text`n`nLog: $logFile", 'BYOB')
    } catch { }
}

trap {
    Show-Fatal "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}

if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw "Run with Windows PowerShell 5.1 (powershell.exe), not $($PSVersionTable.PSVersion)."
}

$env:TEMP = Join-Path $root 'temp\sys'
$env:TMP = $env:TEMP
$dataDir = Join-Path $root 'data'
$chatsDir = Join-Path $dataDir 'chats'
$undoRoot = Join-Path $dataDir 'undo'
$defaultWs = Join-Path $root 'workspace'
New-Item -ItemType Directory -Force $env:TEMP, $dataDir, $chatsDir, $undoRoot, $defaultWs | Out-Null

$versionFile = Join-Path $root 'VERSION'
$version = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '0.4.0' }

$hostCfgFile = Join-Path $root 'config\settings.json'
$hostCfg = if (Test-Path $hostCfgFile) { Get-Content $hostCfgFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{ port = $blockStart } }

$preferredPort = if ($Port -gt 0) { $Port } elseif ($hostCfg.port) { [int]$hostCfg.port } else { $blockStart }
$rangeStart = if ($Port -gt 0) { $Port } else { $blockStart }
$rangeEnd = if ($Port -gt 0) { $Port } else { $blockEnd }

. (Join-Path $here 'LoopbackPort.ps1')
. (Join-Path $here 'ByobLlm.ps1')
. (Join-Path $here 'ByobTools.ps1')

$outlookComPath = Join-Path $root 'plugins\outlook-classic\outlook_com.ps1'
$outlookPromptPath = Join-Path $root 'plugins\outlook-classic\prompt.md'
if (-not (Test-Path $outlookComPath)) { throw "Missing $outlookComPath" }
. $outlookComPath

$uiIndex = Join-Path $here 'ui\index.html'

if ($CheckOnly) {
    Assert-LoopbackPrefix -Prefix "http://localhost:$preferredPort/"
    if (-not (Test-Path $uiIndex)) { throw "Missing $uiIndex" }
    $toolDefs = Get-ByobToolDefinitions
    if ($toolDefs.Count -lt 18) { throw 'Expected workspace + Outlook tool definitions.' }
    Add-Log 'sys' "Self-check passed (BYOB v$version, zero-EXE PowerShell 5.1 + Edge app mode, tools=$($toolDefs.Count), data=$dataDir)."
    Write-Host "Self-check passed (BYOB v$version, zero-EXE Edge-Ops build, tools=$($toolDefs.Count), portable home: $dataDir)."
    exit 0
}

# Portable user settings & secrets inside .\data\
$userSettingsFile = Join-Path $dataDir 'settings.json'
$userSecretsFile = Join-Path $dataDir 'secrets.json'
$workspacesFile = Join-Path $dataDir 'workspaces.json'

function Read-JsonOrDefault([string]$Path, $DefaultObj) {
    if (Test-Path $Path) {
        try { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { }
    }
    return $DefaultObj
}

function Write-Utf8Json([string]$Path, $Obj) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 16), $utf8)
}

$script:Settings = Read-JsonOrDefault $userSettingsFile ([pscustomobject]@{
    inference = [pscustomobject]@{ base_url = 'http://127.0.0.1:11434/v1'; model = ''; api = 'auto' }
    approvals = 'ask_writes'   # ask_all | ask_writes | yolo
    theme = 'dark'
    outlook_days_back = 14
    outlook_allow_sensitive = $false
    extra_instructions = ''
})
if ($InferenceUrl) { $script:Settings.inference.base_url = $InferenceUrl }
if ($Model) { $script:Settings.inference.model = $Model }
if ($Yolo) { $script:Settings.approvals = 'yolo' }

$script:Secrets = Read-JsonOrDefault $userSecretsFile ([pscustomobject]@{ api_key = '' })
if ($env:BYOB_API_KEY) { $script:Secrets.api_key = $env:BYOB_API_KEY }

$wsInitial = if ($Workspace -and (Test-Path $Workspace -PathType Container)) { (Resolve-Path $Workspace).Path } else { $defaultWs }
$script:Workspaces = @(Read-JsonOrDefault $workspacesFile @([pscustomobject]@{ id = 'ws_default'; name = 'Workspace'; path = $wsInitial }))
if ($script:Workspaces.Count -eq 0) {
    $script:Workspaces = @([pscustomobject]@{ id = 'ws_default'; name = 'Workspace'; path = $wsInitial })
}
if ($Workspace -and -not ($script:Workspaces | Where-Object { $_.path -eq $wsInitial })) {
    $script:Workspaces += [pscustomobject]@{ id = 'ws_' + [guid]::NewGuid().ToString('N').Substring(0, 6); name = (Split-Path -Leaf $wsInitial); path = $wsInitial }
}
Write-Utf8Json $workspacesFile $script:Workspaces

function Get-ChatFile([string]$ChatId) { return (Join-Path $chatsDir "$ChatId.json") }

function Load-AllChats {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in (Get-ChildItem -Path $chatsDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $c = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($c -and $c.id) { $list.Add($c) }
        } catch { }
    }
    if ($list.Count -eq 0) {
        $c = [pscustomobject]@{
            id = 'chat_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            title = 'New chat'
            workspaceId = $script:Workspaces[0].id
            createdAt = (Get-Date).ToString('s')
            updatedAt = (Get-Date).ToString('s')
            messages = @()
            plan = @()
            artifacts = @()
        }
        Write-Utf8Json (Get-ChatFile $c.id) $c
        $list.Add($c)
    }
    return ,$list.ToArray()
}

$script:Chats = [hashtable]::Synchronized(@{})
foreach ($c in (Load-AllChats)) { $script:Chats[$c.id] = $c }

$script:Runs = [hashtable]::Synchronized(@{}) # chatId -> @{ running, cancel, events, pendingApproval, approvalEvent, approvalDecision }

function Invoke-LoopbackIdProbe([int]$ProbePort) {
    foreach ($ip in @('127.0.0.1', '[::1]')) {
        try {
            $req = [System.Net.HttpWebRequest]::Create("http://${ip}:${ProbePort}/__fleethacker/id")
            $req.Host = "localhost:$ProbePort"
            $req.Method = 'GET'; $req.Proxy = $null; $req.Timeout = 1000
            $resp = $req.GetResponse()
            try { return ((New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd() | ConvertFrom-Json) } finally { $resp.Close() }
        } catch { }
    }
    return $null
}

function Request-LoopbackShutdown([int]$ProbePort) {
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:${ProbePort}/__fleethacker/shutdown")
        $req.Host = "localhost:$ProbePort"; $req.Method = 'POST'; $req.Proxy = $null; $req.ContentLength = 0
        $req.Headers['X-FleetHacker-Shutdown'] = '1'; $req.Timeout = 1500
        $resp = $req.GetResponse(); $resp.Close(); return $true
    } catch { return $false }
}

# Port resolution (reuse policy)
$listener = $null
$candidates = @($preferredPort) + @($rangeStart..$rangeEnd | Where-Object { $_ -ne $preferredPort })
foreach ($p in $candidates) {
    if (Test-LoopbackPortFree -Port $p) {
        try { $listener = Start-LoopbackListener -PreferredPort $p -RangeStart $p -RangeEnd $p -ListenHost 'localhost'; break } catch { $listener = $null }
    }
    $idInfo = Invoke-LoopbackIdProbe -ProbePort $p
    if ($idInfo -and $idInfo.tool -eq $toolId) {
        Add-Log 'sys' "Reusing running BYOB on port $p."
        if (-not $NoBrowser) { Start-Process "http://localhost:$p/" }
        exit 0
    }
}
if (-not $listener) { throw "No free port in BYOB block $rangeStart-$rangeEnd." }

$actualPort = Get-ListenerPort -Listener $listener
$url = "http://localhost:$actualPort/"

function Open-ByobWindow([string]$TargetUrl) {
    $edgePaths = @(
        "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )
    $chromePaths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles (x86)\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $exe = ($edgePaths + $chromePaths) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($exe) {
        # --app opens a dedicated standalone BYOB window (no address bar or browser tabs).
        return (Start-Process -FilePath $exe -ArgumentList "--app=$TargetUrl", "--window-size=1280,840" -PassThru)
    }
    Start-Process $TargetUrl
    return $null
}

function Start-ChatAgentTurn {
    param(
        [Parameter(Mandatory)][string]$ChatId,
        [Parameter(Mandatory)][string]$UserText,
        [array]$Attachments = @()
    )
    if ($script:Runs.ContainsKey($ChatId) -and $script:Runs[$ChatId].running) {
        throw 'A reply is already running in this chat.'
    }

    $chat = $script:Chats[$ChatId]
    if (-not $chat) { throw "Chat not found: $ChatId" }

    $wsObj = $script:Workspaces | Where-Object { $_.id -eq $chat.workspaceId } | Select-Object -First 1
    $wsPath = if ($wsObj) { [string]$wsObj.path } else { $defaultWs }
    if (-not (Test-Path $wsPath)) { New-Item -ItemType Directory -Force $wsPath | Out-Null }

    $turnId = 'turn_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $userMsg = [pscustomobject]@{
        id = 'msg_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        role = 'user'
        text = $UserText
        attachments = @($Attachments)
        turnId = $turnId
        time = (Get-Date).ToString('s')
    }
    $chat.messages = @($chat.messages) + @($userMsg)
    if ($chat.title -eq 'New chat' -and $UserText.Trim()) {
        $t = ($UserText.Trim() -replace '\s+', ' ')
        $chat.title = if ($t.Length -gt 44) { $t.Substring(0, 44) + '...' } else { $t }
    }
    $chat.updatedAt = (Get-Date).ToString('s')
    Write-Utf8Json (Get-ChatFile $ChatId) $chat

    $runState = [hashtable]::Synchronized(@{
        running = $true
        cancel = $false
        turnId = $turnId
        events = (New-Object System.Collections.ArrayList)
        pendingApproval = $null
        approvalSignal = (New-Object System.Threading.AutoResetEvent $false)
        approvalResult = $false
    })
    $script:Runs[$ChatId] = $runState

    # Use STA Runspace so Outlook Classic COM (Outlook.Application) works directly inside the turn!
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('RunState', $runState)
    $rs.SessionStateProxy.SetVariable('Chat', $chat)
    $rs.SessionStateProxy.SetVariable('ChatFile', (Get-ChatFile $ChatId))
    $rs.SessionStateProxy.SetVariable('Settings', $script:Settings)
    $rs.SessionStateProxy.SetVariable('Secrets', $script:Secrets)
    $rs.SessionStateProxy.SetVariable('WorkspacePath', $wsPath)
    $rs.SessionStateProxy.SetVariable('DataDir', $dataDir)
    $rs.SessionStateProxy.SetVariable('UndoDir', (Join-Path $undoRoot $ChatId))
    $rs.SessionStateProxy.SetVariable('SrcDir', $here)
    $rs.SessionStateProxy.SetVariable('OutlookComPath', $outlookComPath)
    $rs.SessionStateProxy.SetVariable('OutlookPromptPath', $outlookPromptPath)
    $rs.SessionStateProxy.SetVariable('UserAttachments', $Attachments)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $ErrorActionPreference = 'Stop'
        . (Join-Path $SrcDir 'ByobLlm.ps1')
        . (Join-Path $SrcDir 'ByobTools.ps1')
        . $OutlookComPath

        function Emit($Evt) { [void]$RunState.events.Add($Evt) }
        function Save-Chat {
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [IO.File]::WriteAllText($ChatFile, ($Chat | ConvertTo-Json -Depth 16), $utf8)
        }

        try {
            $baseUrl = [string]$Settings.inference.base_url
            $model = [string]$Settings.inference.model
            if (-not $baseUrl -or -not $model) {
                throw 'No inference endpoint/model configured. Open Settings -> Models or click Detect Local Models.'
            }

            $memGlobal = Join-Path $DataDir 'memory.md'
            $memWs = Join-Path $WorkspacePath '.byob\memory.md'
            $memText = ''
            if (Test-Path $memGlobal) { $memText += "`n## Global Memory`n" + [IO.File]::ReadAllText($memGlobal, [Text.Encoding]::UTF8) }
            if (Test-Path $memWs) { $memText += "`n## Workspace Memory`n" + [IO.File]::ReadAllText($memWs, [Text.Encoding]::UTF8) }
            $outlookGuide = if (Test-Path $OutlookPromptPath) { [IO.File]::ReadAllText($OutlookPromptPath, [Text.Encoding]::UTF8) } else { '' }

            $sysPrompt = @"
You are BYOB, a local desktop AI coworker working in workspace: $WorkspacePath
You can inspect/edit files, extract text from Office documents (.docx/.pptx/.xlsx), run PowerShell commands, build side-pane artifacts (Markdown, CSV, HTML apps, Charts), keep a plan, delegate research, and manage the user's Classic Outlook emails.
$outlookGuide
$memText
"@
            if ($Settings.extra_instructions) { $sysPrompt += "`n## User Instructions`n$($Settings.extra_instructions)" }

            $toolCtx = @{
                Workspace = $WorkspacePath
                DataDir = $DataDir
                UndoDir = $UndoDir
                TurnId = $RunState.turnId
                AllowSensitiveMail = [bool]$Settings.outlook_allow_sensitive
                SaveArtifact = {
                    param($Id, $Title, $CType, $Content)
                    $existing = @($Chat.artifacts | Where-Object { $_.id -eq $Id })
                    $ver = if ($existing.Count -gt 0) { (@($existing | Measure-Object -Property version -Maximum).Maximum + 1) } else { 1 }
                    $art = [pscustomobject]@{
                        id = $Id; title = $Title; content_type = $CType; version = $ver; content = $Content; updatedAt = (Get-Date).ToString('s')
                    }
                    $Chat.artifacts = @($Chat.artifacts) + @($art)
                    Save-Chat
                    Emit @{ type = 'artifact'; artifact = $art }
                    return $art
                }
                SavePlan = {
                    param($Steps)
                    $Chat.plan = @($Steps)
                    Save-Chat
                    Emit @{ type = 'plan'; steps = @($Steps) }
                }
                RunSubagent = {
                    param($Task)
                    $subTools = Get-ByobToolDefinitions -IncludeDelegate $false | Where-Object { $_.access -eq 'read' }
                    $subMsgs = @(@{ role = 'user'; content = $Task })
                    $subSys = "You are a read-only research subagent in $WorkspacePath. Inspect workspace files and Outlook emails, then write a concise factual summary."
                    for ($sr = 0; $sr -lt 6; $sr++) {
                        $r = Invoke-ByobLlmOnce -BaseUrl $baseUrl -Model $model -ApiKey ([string]$Secrets.api_key) -ApiKind ([string]$Settings.inference.api) -SystemPrompt $subSys -Messages $subMsgs -Tools $subTools
                        if ($r.ToolCalls.Count -eq 0) { return $r.Text }
                        $subMsgs += @{ role = 'assistant'; content = ($r.Text); tool_calls = $r.RawToolCalls }
                        foreach ($tc in $r.ToolCalls) {
                            $resText = Invoke-ByobTool -Name $tc.name -Args $tc.args -Context $toolCtx
                            $subMsgs += @{ role = 'tool'; tool_call_id = $tc.id; content = [string]$resText }
                        }
                    }
                    return 'Subagent reached step limit.'
                }
            }

            $allTools = Get-ByobToolDefinitions -IncludeDelegate $true
            $conv = @()
            $msgsList = @($Chat.messages)
            for ($mi = 0; $mi -lt $msgsList.Count; $mi++) {
                $m = $msgsList[$mi]
                if ($m.role -eq 'user') {
                    if ($mi -eq ($msgsList.Count - 1) -and $UserAttachments -and @($UserAttachments).Count -gt 0) {
                        $parts = @(@{ type = 'text'; text = [string]$m.text })
                        foreach ($att in @($UserAttachments)) {
                            if ($att.dataUrl) {
                                $parts += @{ type = 'image_url'; image_url = @{ url = [string]$att.dataUrl } }
                            }
                        }
                        $conv += @{ role = 'user'; content = $parts }
                    } else {
                        $conv += @{ role = 'user'; content = [string]$m.text }
                    }
                } elseif ($m.role -eq 'assistant') {
                    $conv += @{ role = 'assistant'; content = [string]$m.text }
                }
            }

            $toolSteps = @()
            $finalText = ''
            $finalThinking = ''

            for ($round = 0; $round -lt 16; $round++) {
                if ($RunState.cancel) { throw 'Stopped by user.' }
                $llmRes = Invoke-ByobLlmOnce -BaseUrl $baseUrl -Model $model -ApiKey ([string]$Secrets.api_key) -ApiKind ([string]$Settings.inference.api) -SystemPrompt $sysPrompt -Messages $conv -Tools $allTools
                if ($llmRes.Thinking) { $finalThinking += $llmRes.Thinking + "`n" }

                if ($llmRes.ToolCalls.Count -eq 0) {
                    $finalText = [string]$llmRes.Text
                    break
                }

                if ($llmRes.ApiKind -eq 'anthropic') {
                    $conv += @{ role = 'assistant'; content = $llmRes.RawAssistantContent }
                } else {
                    $conv += @{ role = 'assistant'; content = $llmRes.Text; tool_calls = $llmRes.RawToolCalls }
                }

                $antToolResults = @()
                foreach ($tc in $llmRes.ToolCalls) {
                    if ($RunState.cancel) { throw 'Stopped by user.' }
                    $tName = [string]$tc.name
                    $tMeta = $allTools | Where-Object { $_.name -eq $tName } | Select-Object -First 1
                    $access = if ($tMeta) { [string]$tMeta.access } else { 'execute' }
                    $mustConfirm = ($tMeta -and $tMeta.confirm)
                    $policy = [string]$Settings.approvals
                    $needsAsk = $mustConfirm -or ($policy -eq 'ask_all') -or ($policy -ne 'yolo' -and $access -ne 'read')

                    $approved = $true
                    if ($needsAsk) {
                        $reqId = 'apr_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
                        $warn = if ($mustConfirm) { [string]$tMeta.confirm } else { "Allow $tName ($access)?" }
                        $RunState.pendingApproval = @{ id = $reqId; tool = $tName; args = $tc.args; warning = $warn; mustConfirm = [bool]$mustConfirm }
                        Emit @{ type = 'approval_needed'; approval = $RunState.pendingApproval }
                        [void]$RunState.approvalSignal.WaitOne()
                        $approved = [bool]$RunState.approvalResult
                        $RunState.pendingApproval = $null
                    }

                    $tOut = ''
                    $tStatus = 'done'
                    if (-not $approved) {
                        $tOut = 'User denied tool call.'
                        $tStatus = 'denied'
                    } else {
                        Emit @{ type = 'tool_start'; tool = $tName; args = $tc.args }
                        try {
                            $tOut = [string](Invoke-ByobTool -Name $tName -Args $tc.args -Context $toolCtx)
                        } catch {
                            $tOut = "Tool error: $($_.Exception.Message)"
                            $tStatus = 'error'
                        }
                    }

                    $stepObj = [pscustomobject]@{ tool = $tName; args = $tc.args; status = $tStatus; preview = $(if ($tOut.Length -gt 600) { $tOut.Substring(0, 600) + '...' } else { $tOut }) }
                    $toolSteps += $stepObj
                    Emit @{ type = 'tool_done'; step = $stepObj }

                    if ($llmRes.ApiKind -eq 'anthropic') {
                        $antToolResults += @{ type = 'tool_result'; tool_use_id = $tc.id; content = $tOut }
                    } else {
                        $conv += @{ role = 'tool'; tool_call_id = $tc.id; content = $tOut }
                    }
                }
                if ($llmRes.ApiKind -eq 'anthropic') {
                    $conv += @{ role = 'user'; content = $antToolResults }
                }
            }

            if (-not $finalText) { $finalText = '(Completed tool steps.)' }
            $asstMsg = [pscustomobject]@{
                id = 'msg_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
                role = 'assistant'
                text = $finalText
                thinking = $finalThinking.Trim()
                steps = @($toolSteps)
                turnId = $RunState.turnId
                time = (Get-Date).ToString('s')
            }
            $Chat.messages = @($Chat.messages) + @($asstMsg)
            $Chat.updatedAt = (Get-Date).ToString('s')
            Save-Chat
            Emit @{ type = 'done'; message = $asstMsg }
        } catch {
            $errMsg = $_.Exception.Message
            Emit @{ type = 'error'; text = $errMsg }
        } finally {
            $RunState.running = $false
        }
    })
    [void]$ps.BeginInvoke()
}

function Write-ResponseBytes($Response, [int]$Status, [string]$ContentType, [byte[]]$Bytes) {
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.Close()
}

function Write-JsonResponse($Response, [int]$Status, [string]$Json) {
    Write-ResponseBytes $Response $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($Json))
}

$pidFile = Join-Path $here '.pid'
Set-Content -Path $pidFile -Value $PID -Encoding Ascii
$appProc = $null

try {
    Add-Log 'sys' "Serving BYOB v$version (pure PS 5.1 + Edge --app) at $url (data=$dataDir)"
    if (-not $NoBrowser) {
        $appProc = Open-ByobWindow -TargetUrl $url
    }

    $pendingContext = $listener.BeginGetContext($null, $null)
    $stopRequested = $false

    while ($listener.IsListening -and -not $stopRequested) {
        if ($pendingContext.AsyncWaitHandle.WaitOne(120)) {
            $ctx = $listener.EndGetContext($pendingContext)
            $pendingContext = $listener.BeginGetContext($null, $null)
            try {
                $req = $ctx.Request
                $resp = $ctx.Response
                if (-not (Test-LocalRequest -Request $req -Port $actualPort)) {
                    Write-JsonResponse $resp 403 '{"error":"forbidden"}'
                    continue
                }
                $path = $req.Url.AbsolutePath
                $method = $req.HttpMethod.ToUpperInvariant()

                if ($path -eq '/__fleethacker/id' -and $method -eq 'GET') {
                    $idJson = ([ordered]@{ tool = $toolId; version = $version; pid = $PID; path = $PSCommandPath } | ConvertTo-Json -Compress)
                    Write-JsonResponse $resp 200 $idJson
                } elseif ($path -eq '/__fleethacker/shutdown' -and $method -eq 'POST') {
                    if ($req.Headers['X-FleetHacker-Shutdown'] -ne '1') {
                        Write-JsonResponse $resp 403 '{"error":"missing_shutdown_header"}'
                    } else {
                        Write-JsonResponse $resp 200 '{"ok":true}'
                        $stopRequested = $true
                    }
                } elseif ($path -eq '/api/state' -and $method -eq 'GET') {
                    $chatArr = @($script:Chats.Values | Sort-Object updatedAt -Descending)
                    $st = [ordered]@{
                        version = $version
                        dataDir = $dataDir
                        settings = $script:Settings
                        hasApiKey = [bool]$script:Secrets.api_key
                        workspaces = @($script:Workspaces)
                        chats = $chatArr
                    }
                    Write-JsonResponse $resp 200 ($st | ConvertTo-Json -Depth 16 -Compress)
                } elseif ($path -eq '/api/detect-models' -and $method -eq 'POST') {
                    $found = Find-LocalLlmEndpoints
                    Write-JsonResponse $resp 200 ((@{ endpoints = $found } | ConvertTo-Json -Depth 6 -Compress))
                } elseif ($path -eq '/api/test-connection' -and $method -eq 'POST') {
                    $body = (New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    $key = if ($body.api_key) { [string]$body.api_key } else { [string]$script:Secrets.api_key }
                    $r = Invoke-ByobLlmOnce -BaseUrl ([string]$body.base_url) -Model ([string]$body.model) -ApiKey $key -ApiKind ([string]$body.api) -SystemPrompt 'Reply OK.' -Messages @(@{ role = 'user'; content = 'Say OK.' }) -Tools @() -MaxTokens 16
                    Write-JsonResponse $resp 200 ((@{ ok = $true; reply = $r.Text } | ConvertTo-Json -Compress))
                } elseif ($path -eq '/api/settings' -and $method -eq 'POST') {
                    $body = (New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    if ($body.settings) {
                        $script:Settings = $body.settings
                        Write-Utf8Json $userSettingsFile $script:Settings
                    }
                    if ($body.PSObject.Properties.Name -contains 'api_key' -and $null -ne $body.api_key) {
                        $script:Secrets.api_key = [string]$body.api_key
                        Write-Utf8Json $userSecretsFile $script:Secrets
                    }
                    Write-JsonResponse $resp 200 '{"ok":true}'
                } elseif ($path -eq '/api/workspaces' -and $method -eq 'POST') {
                    $body = (New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    $wsPath = [string]$body.path
                    if (-not (Test-Path $wsPath -PathType Container)) { New-Item -ItemType Directory -Force $wsPath | Out-Null }
                    $wsObj = [pscustomobject]@{
                        id = 'ws_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
                        name = if ($body.name) { [string]$body.name } else { (Split-Path -Leaf $wsPath) }
                        path = (Resolve-Path $wsPath).Path
                    }
                    $script:Workspaces = @($script:Workspaces) + @($wsObj)
                    Write-Utf8Json $workspacesFile $script:Workspaces
                    Write-JsonResponse $resp 200 ($wsObj | ConvertTo-Json -Compress)
                } elseif ($path -eq '/api/chats' -and $method -eq 'POST') {
                    $body = (New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    $act = [string]$body.action
                    if ($act -eq 'new') {
                        $c = [pscustomobject]@{
                            id = 'chat_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
                            title = 'New chat'
                            workspaceId = [string]$body.workspaceId
                            createdAt = (Get-Date).ToString('s')
                            updatedAt = (Get-Date).ToString('s')
                            messages = @(); plan = @(); artifacts = @()
                        }
                        $script:Chats[$c.id] = $c
                        Write-Utf8Json (Get-ChatFile $c.id) $c
                        Write-JsonResponse $resp 200 ($c | ConvertTo-Json -Depth 10 -Compress)
                    } elseif ($act -eq 'delete') {
                        $cid = [string]$body.chatId
                        $script:Chats.Remove($cid)
                        Remove-Item (Get-ChatFile $cid) -Force -ErrorAction SilentlyContinue
                        Write-JsonResponse $resp 200 '{"ok":true}'
                    } elseif ($act -eq 'undo') {
                        $cid = [string]$body.chatId
                        $tid = [string]$body.turnId
                        $n = Invoke-UndoTurn -UndoDir (Join-Path $undoRoot $cid) -TurnId $tid
                        Write-JsonResponse $resp 200 ((@{ ok = $true; restored = $n } | ConvertTo-Json -Compress))
                    } else {
                        Write-JsonResponse $resp 400 '{"error":"unknown_action"}'
                    }
                } elseif ($path -eq '/api/chat/send' -and $method -eq 'POST') {
                    $body = (New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    $atts = if ($body.attachments) { @($body.attachments) } else { @() }
                    Start-ChatAgentTurn -ChatId ([string]$body.chatId) -UserText ([string]$body.text) -Attachments $atts
                    Write-JsonResponse $resp 200 '{"ok":true}'
                } elseif ($path -eq '/api/chat/events' -and $method -eq 'GET') {
                    $cid = [string]$req.QueryString['chatId']
                    $since = [int]($req.QueryString['since'] -as [int])
                    $rsObj = if ($script:Runs.ContainsKey($cid)) { $script:Runs[$cid] } else { $null }
                    if ($null -eq $rsObj) {
                        Write-JsonResponse $resp 200 '{"running":false,"events":[]}'
                    } else {
                        $evts = @()
                        if ($since -lt $rsObj.events.Count) {
                            for ($i = $since; $i -lt $rsObj.events.Count; $i++) { $evts += $rsObj.events[$i] }
                        }
                        $out = [ordered]@{ running = [bool]$rsObj.running; next = $rsObj.events.Count; events = $evts }
                        Write-JsonResponse $resp 200 ($out | ConvertTo-Json -Depth 16 -Compress)
                    }
                } elseif ($path -eq '/api/chat/approve' -and $method -eq 'POST') {
                    $body = (New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    $cid = [string]$body.chatId
                    if ($script:Runs.ContainsKey($cid)) {
                        $script:Runs[$cid].approvalResult = [bool]$body.approved
                        [void]$script:Runs[$cid].approvalSignal.Set()
                    }
                    Write-JsonResponse $resp 200 '{"ok":true}'
                } elseif ($path -eq '/api/chat/stop' -and $method -eq 'POST') {
                    $body = (New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    $cid = [string]$body.chatId
                    if ($script:Runs.ContainsKey($cid)) {
                        $script:Runs[$cid].cancel = $true
                        [void]$script:Runs[$cid].approvalSignal.Set()
                    }
                    Write-JsonResponse $resp 200 '{"ok":true}'
                } elseif ($path -eq '/api/outlook/status' -and $method -eq 'GET') {
                    Write-JsonResponse $resp 200 ((Invoke-OutlookStatus) | ConvertTo-Json -Depth 6 -Compress)
                } elseif ($path -eq '/api/outlook/inbox' -and $method -eq 'GET') {
                    $folder = if ($req.QueryString['folder']) { [string]$req.QueryString['folder'] } else { 'Inbox' }
                    $q = [string]$req.QueryString['q']
                    $days = if ($req.QueryString['days']) { [int]$req.QueryString['days'] } else { [int]$script:Settings.outlook_days_back }
                    $res = Invoke-OutlookSearch -Folder $folder -Text $q -DaysBack $days -Limit 25 -AllowSensitive ([bool]$script:Settings.outlook_allow_sensitive)
                    Write-JsonResponse $resp 200 ($res | ConvertTo-Json -Depth 8 -Compress)
                } elseif ($path -eq '/api/outlook/read' -and $method -eq 'POST') {
                    $body = (New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    $res = Invoke-OutlookRead -EntryID ([string]$body.entryId) -AllowSensitive ([bool]$script:Settings.outlook_allow_sensitive)
                    Write-JsonResponse $resp 200 ($res | ConvertTo-Json -Depth 6 -Compress)
                } elseif ($path -eq '/api/outlook/open' -and $method -eq 'POST') {
                    $body = (New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
                    $res = Invoke-OutlookOpen -EntryID ([string]$body.entryId)
                    Write-JsonResponse $resp 200 ($res | ConvertTo-Json -Depth 4 -Compress)
                } elseif ($path -eq '/api/artifact/raw' -and $method -eq 'GET') {
                    $cid = [string]$req.QueryString['chatId']
                    $aid = [string]$req.QueryString['id']
                    $ver = [int]$req.QueryString['version']
                    $c = $script:Chats[$cid]
                    $art = if ($c) { @($c.artifacts | Where-Object { $_.id -eq $aid -and $_.version -eq $ver } | Select-Object -First 1) } else { @() }
                    if ($art.Count -eq 0) {
                        Write-JsonResponse $resp 404 '{"error":"artifact_not_found"}'
                    } else {
                        $htmlBytes = [Text.Encoding]::UTF8.GetBytes([string]$art[0].content)
                        Write-ResponseBytes $resp 200 'text/html; charset=utf-8' $htmlBytes
                    }
                } elseif ($path -eq '/' -or $path -eq '/index.html') {
                    Write-ResponseBytes $resp 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($uiIndex))
                } else {
                    Write-JsonResponse $resp 404 '{"error":"not_found"}'
                }
            } catch {
                Add-Log 'WARN' "API error ($($ctx.Request.Url.AbsolutePath)): $($_.Exception.Message)"
                try { Write-JsonResponse $ctx.Response 500 ((@{ error = $_.Exception.Message } | ConvertTo-Json -Compress)) } catch { }
            }
        }
    }
} finally {
    if ($listener) { try { $listener.Close() } catch { } }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    Add-Log 'sys' 'BYOB stopped.'
}
