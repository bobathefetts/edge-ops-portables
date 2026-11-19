# BYOB Explorer host: loopback HTTP server + UI + background agent turns.
# Windows PowerShell 5.1, zero EXEs/DLLs, no C# compile. ASCII only.
# Serves the UI on http://localhost:8833-8835/ (loopback only) and opens it in an Edge/Chrome --app window.
#
# Dev/test override: when $env:BYOB_EXPLORER_ALLOW_PS7 = '1' the host also runs on PowerShell 7
# (Linux test runtime). It logs a warning, never opens a browser and skips Windows-only startup code.
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$CheckOnly,
    [switch]$Yolo,
    [string]$Workspace = '',
    [string]$Model = '',
    [string]$InferenceUrl = '',
    [string]$DataDir = '',     # default: <app>\data
    [string]$LogDir = ''       # default: <app>\logs
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$toolId = 'byob-explorer'
$productName = 'BYOB Explorer'
$blockStart = 8833
$blockEnd = 8835
$isWindowsOs = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$devPs7 = ($env:BYOB_EXPLORER_ALLOW_PS7 -eq '1')

if (-not $LogDir) { $LogDir = Join-Path $root 'logs' }
$logFile = Join-Path $LogDir ('Explorer_{0:yyyy_MM_dd_HHmmss}.log' -f (Get-Date))
New-Item -ItemType Directory -Force $LogDir | Out-Null

function Add-Log([string]$level, [string]$text) {
    try { [IO.File]::AppendAllText($logFile, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$level] $text`r`n", [Text.Encoding]::UTF8) } catch { }
}

function Show-Fatal([string]$text) {
    Add-Log 'FATAL' $text
    if ($CheckOnly -or -not $isWindowsOs -or $devPs7 -or -not [Environment]::UserInteractive) {
        [Console]::Error.WriteLine("FATAL: $text")
        return
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show("$productName could not start.`n`n$text`n`nLog: $logFile", $productName)
    } catch { }
}

trap {
    Show-Fatal "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}

if ($PSVersionTable.PSVersion.Major -ne 5) {
    if ($devPs7) {
        Add-Log 'WARN' "Running on PowerShell $($PSVersionTable.PSVersion) because BYOB_EXPLORER_ALLOW_PS7=1 (dev/test only). No browser will be opened."
        $NoBrowser = $true
    } else {
        throw "Run with Windows PowerShell 5.1 (powershell.exe), not $($PSVersionTable.PSVersion)."
    }
}

if ($DataDir) { $DataDir = [IO.Path]::GetFullPath($DataDir) } else { $DataDir = Join-Path $root 'data' }
$dataDir = $DataDir
if ($PSBoundParameters.ContainsKey('DataDir')) { $env:TEMP = Join-Path $dataDir 'temp' } else { $env:TEMP = Join-Path (Join-Path $root 'temp') 'sys' }
$env:TMP = $env:TEMP
$chatsDir = Join-Path $dataDir 'chats'
$undoRoot = Join-Path $dataDir 'undo'
$defaultWs = Join-Path $root 'workspace'
New-Item -ItemType Directory -Force $env:TEMP, $dataDir, $chatsDir, $undoRoot | Out-Null

$versionFile = Join-Path $root 'VERSION'
$version = '0.1.0'
if (Test-Path -LiteralPath $versionFile) { $version = ([IO.File]::ReadAllText($versionFile)).Trim() }

$hostCfgFile = Join-Path (Join-Path $root 'config') 'settings.json'
$hostCfg = [pscustomobject]@{ port = $blockStart }
if (Test-Path -LiteralPath $hostCfgFile) { try { $hostCfg = [IO.File]::ReadAllText($hostCfgFile) | ConvertFrom-Json } catch { } }
if ($hostCfg.portRangeStart -and $hostCfg.portRangeEnd) { $blockStart = [int]$hostCfg.portRangeStart; $blockEnd = [int]$hostCfg.portRangeEnd }

$preferredPort = $blockStart
if ($Port -gt 0) { $preferredPort = $Port } elseif ($hostCfg.port) { $preferredPort = [int]$hostCfg.port }
$rangeStart = $blockStart
$rangeEnd = $blockEnd
if ($Port -gt 0) { $rangeStart = $Port; $rangeEnd = $Port }

$moduleFiles = @('LoopbackPort.ps1', 'NetGate.ps1', 'CredStore.ps1', 'ExplorerTools.ps1', 'ByobLlm.ps1', 'ByobTools.ps1', 'PluginHost.ps1', 'ExplorerAgent.ps1')
foreach ($mf in $moduleFiles) { . (Join-Path $here $mf) }

$uiIndex = Join-Path (Join-Path $here 'ui') 'index.html'

if ($CheckOnly) {
    Assert-LoopbackPrefix -Prefix "http://localhost:$preferredPort/"
    if (-not (Test-Path -LiteralPath $uiIndex)) { throw "Missing $uiIndex" }
    $expectBase = @('list_files', 'read_file', 'search_files', 'write_file', 'edit_file', 'run_command', 'create_artifact', 'update_plan', 'remember', 'delegate')
    $expectExplorer = @('net_query', 'ssh_query', 'kb_write', 'kb_read', 'frontier', 'list_credentials', 'baseline_diff')
    $base = @(Get-ByobToolDefinitions -IncludeDelegate $true)
    $exp = @(Get-ExplorerToolDefinitions)
    $baseNames = @($base | ForEach-Object { $_.name })
    $expNames = @($exp | ForEach-Object { $_.name })
    if (@(Compare-Object $baseNames $expectBase).Count -ne 0) { throw "Base tool set is wrong: $($baseNames -join ', ')" }
    if (@(Compare-Object $expNames $expectExplorer).Count -ne 0) { throw "Explorer tool set is wrong: $($expNames -join ', ')" }
    $all = @($base) + @($exp)
    $dupes = @($all | Group-Object { $_.name } | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count -gt 0) { throw "Duplicate tool names: $(@($dupes | ForEach-Object { $_.Name }) -join ', ')" }
    foreach ($d in $all) {
        if (-not $d.name -or -not $d.description -or -not $d.params -or -not $d.access) { throw "Tool definition incomplete: $($d.name)" }
        if ($d.name -match '(?i)outlook') { throw "Unexpected tool: $($d.name)" }
    }
    $runCmd = @($base | Where-Object { $_.name -eq 'run_command' })[0]
    if ($runCmd.access -ne 'execute') { throw 'run_command must have access execute.' }
    $plugins = @(Get-ExplorerPlugins -AppRoot $root -Workspace '' -DataDir $dataDir)
    $okPlugins = @($plugins | Where-Object { $_.valid })
    $badPlugins = @($plugins | Where-Object { -not $_.valid })
    foreach ($bp in $badPlugins) { Write-Host "Plugin skipped: $($bp.id): $($bp.error)" }
    $plgTools = @(Get-PluginToolDefinitions -Plugins $okPlugins).Count
    $msg = "Self-check passed ($productName v$version, tools: $($base.Count) base + $($exp.Count) explorer + $plgTools plugin, plugins: $($okPlugins.Count) ok / $($badPlugins.Count) skipped, data: $dataDir)."
    Add-Log 'sys' $msg
    Write-Host $msg
    exit 0
}

# ---------------------------------------------------------------------------- settings & state
$userSettingsFile = Join-Path $dataDir 'settings.json'
$userSecretsFile = Join-Path $dataDir 'secrets.json'
$workspacesFile = Join-Path $dataDir 'workspaces.json'

function Read-JsonOrDefault([string]$Path, $DefaultObj) {
    if (Test-Path -LiteralPath $Path) {
        try { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { }
    }
    return $DefaultObj
}

function Write-Utf8Json([string]$Path, $Obj) {
    [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 16), (New-Object System.Text.UTF8Encoding $false))
}

function Get-PropOrDefault($Obj, [string]$Name, $Default) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties.Name -contains $Name -and $null -ne $Obj.$Name) { return $Obj.$Name }
    return $Default
}

function Get-ClampedNumber($Value, [double]$Default, [double]$Min, [double]$Max, [switch]$Integer) {
    $v = $Default
    if ($null -ne $Value -and [string]$Value -ne '') { try { $v = [double]$Value } catch { $v = $Default } }
    if ($v -lt $Min) { $v = $Min }
    if ($v -gt $Max) { $v = $Max }
    if ($Integer) { return [int][Math]::Round($v) }
    return $v
}

function ConvertTo-ExplorerSettings($In) {
    # Normalises a settings object: every key present, values validated, unknown keys dropped.
    $inf = Get-PropOrDefault $In 'inference' $null
    $api = [string](Get-PropOrDefault $inf 'api' 'auto')
    if ($api -notin @('auto', 'openai', 'anthropic')) { $api = 'auto' }
    $appr = [string](Get-PropOrDefault $In 'approvals' 'ask_writes')
    if ($appr -notin @('ask_all', 'ask_writes', 'yolo')) { $appr = 'ask_writes' }
    $theme = [string](Get-PropOrDefault $In 'theme' 'dark')
    if ($theme -notin @('dark', 'light')) { $theme = 'dark' }
    $extra = [string](Get-PropOrDefault $In 'extra_instructions' '')
    if ($extra.Length -gt 8000) { $extra = $extra.Substring(0, 8000) }
    return [pscustomobject][ordered]@{
        inference = [pscustomobject][ordered]@{
            base_url = ([string](Get-PropOrDefault $inf 'base_url' '')).Trim()
            model = ([string](Get-PropOrDefault $inf 'model' '')).Trim()
            api = $api
        }
        approvals = $appr
        theme = $theme
        extra_instructions = $extra
        request_timeout_sec = (Get-ClampedNumber (Get-PropOrDefault $In 'request_timeout_sec' $null) 600 10 7200 -Integer)
        max_tokens = (Get-ClampedNumber (Get-PropOrDefault $In 'max_tokens' $null) 4096 64 200000 -Integer)
        temperature = [Math]::Round((Get-ClampedNumber (Get-PropOrDefault $In 'temperature' $null) 0.2 0 2), 2)
        context_char_budget = (Get-ClampedNumber (Get-PropOrDefault $In 'context_char_budget' $null) 240000 2000 10000000 -Integer)
        max_steps_chat = (Get-ClampedNumber (Get-PropOrDefault $In 'max_steps_chat' $null) 40 1 5000 -Integer)
        max_steps_explore = (Get-ClampedNumber (Get-PropOrDefault $In 'max_steps_explore' $null) 300 1 5000 -Integer)
    }
}

$script:Settings = ConvertTo-ExplorerSettings (Read-JsonOrDefault $userSettingsFile $null)
if ($InferenceUrl) { $script:Settings.inference.base_url = $InferenceUrl }
if ($Model) { $script:Settings.inference.model = $Model }
if ($Yolo) { $script:Settings.approvals = 'yolo' }

# Live view of the settings for running turns (approval-mode changes apply to the next tool call).
$script:SettingsHolder = [hashtable]::Synchronized(@{ value = $script:Settings })

$script:Secrets = Read-JsonOrDefault $userSecretsFile ([pscustomobject]@{ api_key = '' })
if (-not ($script:Secrets.PSObject.Properties.Name -contains 'api_key')) { $script:Secrets = [pscustomobject]@{ api_key = '' } }
if ($env:BYOB_API_KEY) { $script:Secrets.api_key = $env:BYOB_API_KEY }

$wsInitial = $defaultWs
if ($Workspace) {
    if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { New-Item -ItemType Directory -Force $Workspace | Out-Null }
    $wsInitial = (Resolve-Path -LiteralPath $Workspace).Path
}
if (-not (Test-Path -LiteralPath $wsInitial)) { New-Item -ItemType Directory -Force $wsInitial | Out-Null }
$script:Workspaces = @(Read-JsonOrDefault $workspacesFile @() | Where-Object { $_ -and $_.id -and $_.path })
if ($script:Workspaces.Count -eq 0) {
    $script:Workspaces = @([pscustomobject]@{ id = 'ws_default'; name = 'Workspace'; path = $wsInitial })
}
if ($Workspace -and -not ($script:Workspaces | Where-Object { $_.path -eq $wsInitial })) {
    $script:Workspaces = @([pscustomobject]@{ id = 'ws_' + [guid]::NewGuid().ToString('N').Substring(0, 6); name = (Split-Path -Leaf $wsInitial); path = $wsInitial }) + @($script:Workspaces)
}
Write-Utf8Json $workspacesFile @($script:Workspaces)

function Get-ChatFile([string]$ChatId) {
    if ($ChatId -notmatch '^chat_[A-Za-z0-9]{1,40}$') { throw (New-Object System.ArgumentException 'Invalid chat id.') }
    return (Join-Path $chatsDir "$ChatId.json")
}

function Get-WorkspaceById([string]$Id) {
    $w = @($script:Workspaces | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
    if ($w.Count -eq 0) { return $null }
    return $w[0]
}

function Get-WorkspaceScopePath([string]$WsPath) { return (Join-Path (Join-Path $WsPath '.byob') 'scope.json') }

function New-ExplorerChat([string]$WorkspaceId) {
    if (-not (Get-WorkspaceById $WorkspaceId)) { $WorkspaceId = $script:Workspaces[0].id }
    return [pscustomobject]@{
        id = 'chat_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        title = 'New chat'
        workspaceId = $WorkspaceId
        createdAt = (Get-Date).ToString('s')
        updatedAt = (Get-Date).ToString('s')
        messages = @(); plan = @(); artifacts = @()
    }
}

function Load-AllChats {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in (Get-ChildItem -LiteralPath $chatsDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $c = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($c -and $c.id) { $list.Add($c) }
        } catch { }
    }
    if ($list.Count -eq 0) {
        $c = New-ExplorerChat $script:Workspaces[0].id
        Write-Utf8Json (Get-ChatFile $c.id) $c
        $list.Add($c)
    }
    return ,$list.ToArray()
}

$script:Chats = [hashtable]::Synchronized(@{})
foreach ($c in (Load-AllChats)) { $script:Chats[$c.id] = $c }
$script:Runs = [hashtable]::Synchronized(@{})     # chatId -> run state shared with the turn runspace
$script:RunHandles = @{}                           # chatId -> @{ PS; RS; Handle } (host side only)

# ---------------------------------------------------------------------------- loopback port
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

$listener = $null
$candidates = @($preferredPort) + @($rangeStart..$rangeEnd | Where-Object { $_ -ne $preferredPort })
foreach ($p in $candidates) {
    if (Test-LoopbackPortFree -Port $p) {
        try { $listener = Start-LoopbackListener -PreferredPort $p -RangeStart $p -RangeEnd $p -ListenHost 'localhost'; break } catch { $listener = $null }
    }
    $idInfo = Invoke-LoopbackIdProbe -ProbePort $p
    if ($idInfo -and $idInfo.tool -eq $toolId) {
        Add-Log 'sys' "Reusing running $productName on port $p."
        if (-not $NoBrowser -and $isWindowsOs) { Start-Process "http://localhost:$p/" }
        exit 0
    }
}
if (-not $listener) { throw "No free port in the $productName block $rangeStart-$rangeEnd." }

$actualPort = Get-ListenerPort -Listener $listener
$url = "http://localhost:$actualPort/"

function Open-ExplorerWindow([string]$TargetUrl) {
    $edgePaths = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )
    $chromePaths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $exe = ($edgePaths + $chromePaths) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if ($exe) { return (Start-Process -FilePath $exe -ArgumentList "--app=$TargetUrl", '--window-size=1320,860' -PassThru) }
    Start-Process $TargetUrl
    return $null
}

# ---------------------------------------------------------------------------- agent turns
function Start-ChatAgentTurn {
    param(
        [Parameter(Mandatory)][string]$ChatId,
        [AllowEmptyString()][string]$UserText = '',
        [array]$Attachments = @(),
        [ValidateSet('chat', 'explore')][string]$Mode = 'chat'
    )
    if ($script:Runs.ContainsKey($ChatId) -and $script:Runs[$ChatId].running) { throw (New-Object System.ArgumentException 'A reply is already running in this chat.') }
    $chat = $script:Chats[$ChatId]
    if (-not $chat) { throw (New-Object System.ArgumentException "Chat not found: $ChatId") }
    $wsObj = Get-WorkspaceById ([string]$chat.workspaceId)
    $wsPath = $defaultWs
    if ($wsObj) { $wsPath = [string]$wsObj.path }
    if (-not (Test-Path -LiteralPath $wsPath)) { New-Item -ItemType Directory -Force $wsPath | Out-Null }

    $turnId = 'turn_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $shown = $UserText
    if ($Mode -eq 'explore') {
        $shown = 'Explore this network'
        if ($UserText.Trim()) { $shown += ' - ' + $UserText.Trim() }
    }
    $userMsg = [pscustomobject]@{
        id = 'msg_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        role = 'user'; text = $shown; mode = $Mode
        attachments = @($Attachments | ForEach-Object { [pscustomobject]@{ name = [string]$_.name } })
        turnId = $turnId; time = (Get-Date).ToString('s')
    }
    $chat.messages = @($chat.messages) + @($userMsg)
    if ($chat.title -eq 'New chat' -and $shown.Trim()) {
        $t = ($shown.Trim() -replace '\s+', ' ')
        if ($t.Length -gt 44) { $t = $t.Substring(0, 44) + '...' }
        $chat.title = $t
    }
    $chat.updatedAt = (Get-Date).ToString('s')
    Write-Utf8Json (Get-ChatFile $ChatId) $chat

    $runState = [hashtable]::Synchronized(@{
        running = $true
        cancel = $false
        turnId = $turnId
        mode = $Mode
        events = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        pendingApproval = $null
        approvalId = ''
        approvalSignal = (New-Object System.Threading.AutoResetEvent $false)
        approvalResult = $false
    })
    $script:Runs[$ChatId] = $runState

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $vars = @{
        RunState = $runState; Chat = $chat; ChatFile = (Get-ChatFile $ChatId); Settings = $script:Settings
        Secrets = $script:Secrets; WorkspacePath = $wsPath; DataDirPath = $dataDir; UndoDir = (Join-Path $undoRoot $ChatId)
        SrcDir = $here; AppRoot = $root; TurnMode = $Mode; TurnText = $UserText; UserAttachments = $Attachments
        ModuleFiles = $moduleFiles; SettingsHolder = $script:SettingsHolder
    }
    foreach ($k in $vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $vars[$k]) }
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $ErrorActionPreference = 'Stop'
        try {
            foreach ($mf in $ModuleFiles) { if ($mf -ne 'LoopbackPort.ps1') { . (Join-Path $SrcDir $mf) } }
            Invoke-ExplorerAgentTurn -RunState $RunState -Chat $Chat -ChatFile $ChatFile -Settings $Settings -Secrets $Secrets `
                -WorkspacePath $WorkspacePath -DataDir $DataDirPath -UndoDir $UndoDir -AppRoot $AppRoot -Mode $TurnMode `
                -Guidance $TurnText -UserAttachments $UserAttachments -SettingsHolder $SettingsHolder
        } catch {
            [void]$RunState.events.Add(@{ type = 'error'; text = "Agent failed: $($_.Exception.Message)" })
        } finally {
            $RunState.running = $false
        }
    })
    $handle = $ps.BeginInvoke()
    $script:RunHandles[$ChatId] = @{ PS = $ps; RS = $rs; Handle = $handle }
}

function Clear-FinishedRuns {
    foreach ($cid in @($script:RunHandles.Keys)) {
        $h = $script:RunHandles[$cid]
        if ($h.Handle.IsCompleted) {
            try { [void]$h.PS.EndInvoke($h.Handle) } catch { }
            try { $h.PS.Dispose() } catch { }
            try { $h.RS.Close(); $h.RS.Dispose() } catch { }
            $script:RunHandles.Remove($cid)
        }
    }
}

# ---------------------------------------------------------------------------- HTTP helpers
function Write-ResponseBytes($Response, [int]$Status, [string]$ContentType, [byte[]]$Bytes, [hashtable]$ExtraHeaders = @{}) {
    $Response.StatusCode = $Status
    $Response.ContentType = $ContentType
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    foreach ($k in $ExtraHeaders.Keys) { $Response.Headers[$k] = $ExtraHeaders[$k] }
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.Close()
}

function Write-JsonResponse($Response, [int]$Status, [string]$Json) {
    Write-ResponseBytes $Response $Status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($Json))
}

function Write-JsonObject($Response, [int]$Status, $Obj) {
    Write-JsonResponse $Response $Status ($Obj | ConvertTo-Json -Depth 16 -Compress)
}

function Read-RequestJson($Request) {
    # Never echoes the body in an error (it may hold a password).
    $text = (New-Object System.IO.StreamReader($Request.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
    if (-not $text.Trim()) { return [pscustomobject]@{} }
    try { $o = ConvertFrom-Json -InputObject $text } catch { throw (New-Object System.ArgumentException 'Request body is not valid JSON.') }
    if ($null -eq $o) { return [pscustomobject]@{} }
    return $o
}

function Test-BodyHas($Body, [string]$Name) { return ($null -ne $Body -and $Body.PSObject.Properties.Name -contains $Name) }

function Get-QueryWorkspace($Request) {
    $id = [string]$Request.QueryString['workspaceId']
    $ws = $null
    if ($id) { $ws = Get-WorkspaceById $id } else { $ws = $script:Workspaces[0] }
    if (-not $ws) { throw (New-Object System.ArgumentException "Workspace not found: $id") }
    return $ws
}

# ---------------------------------------------------------------------------- scope / kb helpers
function Test-ExplorerScopeEntry([string]$Entry, [bool]$IsAllow) {
    # Returns $null when valid, else a reason.
    if ($Entry -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(/(\d{1,2}))?$') {
        if ($null -eq (ConvertTo-NetGateIPv4Number $Matches[1])) { return 'is not a valid IPv4 address (each part must be 0-255).' }
        if ($Matches[2]) {
            $pfx = [int]$Matches[3]
            if ($pfx -gt 32) { return 'has a prefix over /32.' }
            if ($IsAllow -and $pfx -eq 0) { return 'is 0.0.0.0/0 (the whole internet). List your lab subnets instead.' }
            if ($IsAllow -and $pfx -lt 8) { return "is wider than /8 (/$pfx). List smaller lab subnets; the widest allowed is /8." }
        }
        return $null
    }
    if ($Entry -match '/') { return 'is not a valid IPv4 CIDR block (use a.b.c.d/nn).' }
    if ($Entry.Length -gt 253 -or $Entry -notmatch '^[A-Za-z0-9*?._-]+$') { return 'is not an IPv4 address, IPv4 CIDR block or host name pattern (letters, digits, . _ - and the wildcards * ?).' }
    if ($IsAllow -and $Entry -match '^[*?.]+$') { return 'would match every host name. Use a pattern such as *.lab.local.' }
    return $null
}

function Get-ExplorerScopeLines($Value) {
    $out = @()
    foreach ($v in @($Value)) {
        if ($null -eq $v) { continue }
        foreach ($line in ([string]$v -split "\r?\n")) { $t = $line.Trim(); if ($t) { $out += $t } }
    }
    return ,$out
}

function Get-KbFileHeading([string]$Path) {
    try {
        $n = 0
        foreach ($line in [IO.File]::ReadLines($Path)) {
            if ($line -match '^#') { return $line.TrimStart('#').Trim() }
            $n++
            if ($n -gt 40) { break }
        }
    } catch { }
    return ''
}

function Resolve-ExplorerViewPath([string]$WsPath, [string]$Rel) {
    # kb/... or raw/... only; returns the full path or throws ArgumentException.
    $r = ([string]$Rel).Replace('\', '/').Trim()
    if ($r -notmatch '^(kb|raw)/[A-Za-z0-9 ._/-]{1,200}$' -or $r.Contains('..') -or $r.Contains('//')) {
        throw (New-Object System.ArgumentException 'Path must be a file under kb/ or raw/.')
    }
    $top = $r.Substring(0, $r.IndexOf('/'))
    $base = [IO.Path]::GetFullPath((Join-Path $WsPath $top)).TrimEnd([char[]]@('\', '/'))
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($base, $r.Substring($top.Length + 1).Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-Object System.ArgumentException 'Path must be a file under kb/ or raw/.')
    }
    return $full
}

function Get-StateObject {
    $wsArr = @()
    foreach ($w in $script:Workspaces) {
        $sc = Read-ScopeConfig -Path (Get-WorkspaceScopePath ([string]$w.path))
        $count = 0
        if ($sc) { $count = @($sc.allow).Count }
        $wsArr += [ordered]@{ id = $w.id; name = $w.name; path = $w.path; scopeExists = [bool]$sc; scopeCount = $count; scopeFileExists = (Test-Path -LiteralPath (Get-WorkspaceScopePath ([string]$w.path))) }
    }
    $running = @()
    foreach ($k in @($script:Runs.Keys)) { if ($script:Runs[$k].running) { $running += $k } }
    $credCount = 0
    try { $credCount = @(Get-CredentialList -DataDir $dataDir).Count } catch { }
    return [ordered]@{
        product = $productName
        version = $version
        dataDir = $dataDir
        settings = $script:Settings
        hasApiKey = [bool]$script:Secrets.api_key
        workspaces = $wsArr
        chats = @($script:Chats.Values | Sort-Object updatedAt -Descending)
        credentialCount = $credCount
        runningChats = $running
        pluginReadme = (Join-Path (Join-Path $root 'plugins') 'README.md')
    }
}

# ---------------------------------------------------------------------------- main loop
$pidFile = Join-Path $dataDir 'explorer.pid'
Set-Content -LiteralPath $pidFile -Value $PID -Encoding Ascii

try {
    Add-Log 'sys' "Serving $productName v$version at $url (data=$dataDir, PowerShell $($PSVersionTable.PSVersion))"
    Write-Host "$productName v$version listening on $url"
    if (-not $NoBrowser -and $isWindowsOs) { $null = Open-ExplorerWindow -TargetUrl $url }

    $pendingContext = $listener.BeginGetContext($null, $null)
    $stopRequested = $false

    while ($listener.IsListening -and -not $stopRequested) {
        if (-not $pendingContext.AsyncWaitHandle.WaitOne(120)) { Clear-FinishedRuns; continue }
        $ctx = $listener.EndGetContext($pendingContext)
        $pendingContext = $listener.BeginGetContext($null, $null)
        $path = ''
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
                Write-JsonObject $resp 200 ([ordered]@{ tool = $toolId; product = $productName; version = $version; pid = $PID; path = $PSCommandPath })
            } elseif ($path -eq '/__fleethacker/shutdown' -and $method -eq 'POST') {
                if ($req.Headers['X-FleetHacker-Shutdown'] -ne '1') { Write-JsonResponse $resp 403 '{"error":"missing_shutdown_header"}' }
                else { Write-JsonResponse $resp 200 '{"ok":true}'; $stopRequested = $true }
            } elseif ($path -eq '/api/state' -and $method -eq 'GET') {
                Write-JsonObject $resp 200 (Get-StateObject)
            } elseif ($path -eq '/api/detect-models' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                $key = [string]$script:Secrets.api_key
                if ([string]$body.api_key) { $key = [string]$body.api_key }
                $found = Find-LocalLlmEndpoints -BaseUrl ([string]$body.base_url) -ApiKey $key
                Write-JsonObject $resp 200 @{ endpoints = @($found) }
            } elseif ($path -eq '/api/test-connection' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                $key = [string]$script:Secrets.api_key
                if ([string]$body.api_key) { $key = [string]$body.api_key }
                try {
                    if (-not [string]$body.base_url -or -not [string]$body.model) { throw 'Enter the base URL and the model name first.' }
                    $r = Invoke-ByobLlmOnce -BaseUrl ([string]$body.base_url) -Model ([string]$body.model) -ApiKey $key -ApiKind ([string]$body.api) -SystemPrompt 'Reply OK.' -Messages @(@{ role = 'user'; content = 'Say OK.' }) -Tools @() -MaxTokens 16 -TimeoutSec 60
                    Write-JsonObject $resp 200 @{ ok = $true; reply = [string]$r.Text }
                } catch {
                    Write-JsonObject $resp 200 @{ ok = $false; error = $_.Exception.Message }
                }
            } elseif ($path -eq '/api/settings' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                if (Test-BodyHas $body 'settings') {
                    $script:Settings = ConvertTo-ExplorerSettings $body.settings
                    $script:SettingsHolder.value = $script:Settings
                    Write-Utf8Json $userSettingsFile $script:Settings
                }
                if ((Test-BodyHas $body 'api_key') -and $null -ne $body.api_key) {
                    $script:Secrets.api_key = [string]$body.api_key
                    Write-Utf8Json $userSecretsFile $script:Secrets
                }
                Write-JsonObject $resp 200 @{ ok = $true; settings = $script:Settings }
            } elseif ($path -eq '/api/credentials' -and $method -eq 'GET') {
                Write-JsonObject $resp 200 @{ credentials = @(Get-CredentialList -DataDir $dataDir) }
            } elseif ($path -eq '/api/credentials' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                $act = [string]$body.action
                $name = ([string]$body.name).Trim()
                if ($act -eq 'delete') {
                    if (-not $name) { throw (New-Object System.ArgumentException 'Give the credential name to delete.') }
                    $removed = Remove-StoredCredential -DataDir $dataDir -Name $name
                    Write-JsonObject $resp 200 @{ ok = $true; removed = [bool]$removed }
                } elseif ($act -eq 'save') {
                    if ($name -notmatch '^[A-Za-z0-9_-]{1,40}$') { throw (New-Object System.ArgumentException 'Credential name must be 1-40 characters: letters, digits, _ or -.') }
                    $kind = ([string]$body.kind).ToLowerInvariant()
                    if ($kind -notin @('windows', 'vsphere', 'linux')) { throw (New-Object System.ArgumentException 'Kind must be windows, vsphere or linux.') }
                    $user = ([string]$body.username).Trim()
                    if ($user.Length -gt 128) { throw (New-Object System.ArgumentException 'User name is too long (128 characters max).') }
                    $p = @{ DataDir = $dataDir; Name = $name; Kind = $kind; Username = $user }
                    if ((Test-BodyHas $body 'secret') -and [string]$body.secret) {
                        if (([string]$body.secret).Length -gt 512) { throw (New-Object System.ArgumentException 'Password is too long (512 characters max).') }
                        $p.Secret = [string]$body.secret
                    } elseif ((Test-BodyHas $body 'clearSecret') -and [bool]$body.clearSecret) {
                        $p.Secret = ''
                    }
                    if (Test-BodyHas $body 'keyPath') {
                        $kp = ([string]$body.keyPath).Trim()
                        if ($kp.Length -gt 260) { throw (New-Object System.ArgumentException 'SSH key path is too long.') }
                        $p.KeyPath = $kp
                    }
                    if (Test-BodyHas $body 'note') {
                        $nt = ([string]$body.note).Trim()
                        if ($nt.Length -gt 200) { throw (New-Object System.ArgumentException 'Note is too long (200 characters max).') }
                        $p.Note = $nt
                    }
                    $saved = Set-StoredCredential @p
                    $p = $null
                    Write-JsonObject $resp 200 @{ ok = $true; credential = $saved }
                } else {
                    throw (New-Object System.ArgumentException "Unknown action '$act' (use save or delete).")
                }
            } elseif ($path -eq '/api/scope' -and $method -eq 'GET') {
                $ws = Get-QueryWorkspace $req
                $sp = Get-WorkspaceScopePath ([string]$ws.path)
                $sc = Read-ScopeConfig -Path $sp
                $allowArr = @(); $denyArr = @()
                $valid = $true
                if ($sc) { $allowArr = @($sc.allow); $denyArr = @($sc.deny) }
                elseif (Test-Path -LiteralPath $sp) {
                    $valid = $false
                    try { $raw = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($sp)); $allowArr = @($raw.allow | ForEach-Object { [string]$_ }); $denyArr = @($raw.deny | ForEach-Object { [string]$_ }) } catch { }
                }
                Write-JsonObject $resp 200 ([ordered]@{ exists = [bool]$sc; valid = $valid; allow = $allowArr; deny = $denyArr; path = $sp; workspaceId = $ws.id })
            } elseif ($path -eq '/api/scope' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                $ws = Get-WorkspaceById ([string]$body.workspaceId)
                if (-not $ws) { throw (New-Object System.ArgumentException 'Workspace not found.') }
                $allowIn = Get-ExplorerScopeLines $body.allow
                $denyIn = Get-ExplorerScopeLines $body.deny
                $errs = @()
                if ($allowIn.Count -gt 500 -or $denyIn.Count -gt 500) { $errs += 'At most 500 entries per list.' }
                foreach ($e in $allowIn) { $why = Test-ExplorerScopeEntry $e $true; if ($why) { $errs += "Allow '$e' $why" } }
                foreach ($e in $denyIn) { $why = Test-ExplorerScopeEntry $e $false; if ($why) { $errs += "Deny '$e' $why" } }
                if ($errs.Count -gt 0) {
                    Write-JsonObject $resp 400 @{ error = ($errs -join ' '); errors = $errs }
                } else {
                    $sp = Get-WorkspaceScopePath ([string]$ws.path)
                    New-Item -ItemType Directory -Force (Split-Path -Parent $sp) | Out-Null
                    $json = '{"allow":' + (ConvertTo-Json -InputObject @($allowIn) -Compress) + ',"deny":' + (ConvertTo-Json -InputObject @($denyIn) -Compress) + '}'
                    [IO.File]::WriteAllText($sp, $json, (New-Object System.Text.UTF8Encoding $false))
                    $chk = Read-ScopeConfig -Path $sp
                    if (-not $chk) { throw 'The scope file was written but could not be read back.' }
                    Add-Log 'sys' "Scope saved for workspace $($ws.id): $($allowIn.Count) allow, $($denyIn.Count) deny."
                    Write-JsonObject $resp 200 ([ordered]@{ ok = $true; exists = $true; allow = @($chk.allow); deny = @($chk.deny); path = $sp })
                }
            } elseif ($path -eq '/api/kb' -and $method -eq 'GET') {
                $ws = Get-QueryWorkspace $req
                $kbRoot = Join-Path ([string]$ws.path) 'kb'
                $files = @()
                if (Test-Path -LiteralPath $kbRoot -PathType Container) {
                    $kbFull = [IO.Path]::GetFullPath($kbRoot).TrimEnd([char[]]@('\', '/'))
                    foreach ($f in @(Get-ChildItem -LiteralPath $kbFull -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)) {
                        $rel = 'kb/' + $f.FullName.Substring($kbFull.Length + 1).Replace('\', '/')
                        $h = ''
                        if ($f.Extension -eq '.md') { $h = Get-KbFileHeading $f.FullName }
                        $files += [ordered]@{ path = $rel; size = $f.Length; modified = $f.LastWriteTime.ToString('s'); heading = $h }
                    }
                }
                $rawRoot = Join-Path ([string]$ws.path) 'raw'
                $rawCount = 0
                if (Test-Path -LiteralPath $rawRoot -PathType Container) { $rawCount = @(Get-ChildItem -LiteralPath $rawRoot -File -ErrorAction SilentlyContinue).Count }
                Write-JsonObject $resp 200 ([ordered]@{ workspaceId = $ws.id; files = $files; frontier = (Get-ExplorerFrontierCounts -Workspace ([string]$ws.path)); rawCount = $rawCount })
            } elseif ($path -eq '/api/kb/file' -and $method -eq 'GET') {
                $ws = Get-QueryWorkspace $req
                $full = Resolve-ExplorerViewPath ([string]$ws.path) ([string]$req.QueryString['path'])
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Write-JsonResponse $resp 404 '{"error":"file not found"}'; continue }
                $cap = 204800
                $fs = [IO.File]::OpenRead($full)
                try {
                    $len = $fs.Length
                    $n = [int][Math]::Min($len, $cap)
                    $buf = New-Object byte[] $n
                    $read = 0
                    while ($read -lt $n) { $k = $fs.Read($buf, $read, $n - $read); if ($k -le 0) { break }; $read += $k }
                } finally { $fs.Close() }
                $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
                Write-JsonObject $resp 200 ([ordered]@{ path = ([string]$req.QueryString['path']).Replace('\', '/'); size = $len; truncated = ($len -gt $cap); content = $text })
            } elseif ($path -eq '/api/plugins' -and $method -eq 'GET') {
                $ws = Get-QueryWorkspace $req
                $pl = @(Get-ExplorerPlugins -AppRoot $root -Workspace ([string]$ws.path) -DataDir $dataDir)
                $outP = @()
                foreach ($p in $pl) {
                    $outP += [ordered]@{
                        id = $p.id; location = $p.location; folder = $p.folder; path = $p.path; name = $p.name; description = $p.description
                        valid = $p.valid; error = $p.error; hash = $p.hash; trusted = $p.trusted; changed = $p.changed
                        tools = @($p.tools | ForEach-Object { [ordered]@{ name = $_.name; exposed = $_.exposed; description = $_.description; access = $_.access; effectiveAccess = $_.effectiveAccess; script = $_.script } })
                    }
                }
                Write-JsonObject $resp 200 ([ordered]@{ workspaceId = $ws.id; plugins = $outP; readme = (Join-Path (Join-Path $root 'plugins') 'README.md') })
            } elseif ($path -eq '/api/plugins' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                $act = [string]$body.action
                if ($act -notin @('trust', 'untrust')) { throw (New-Object System.ArgumentException "Unknown action '$act' (use trust or untrust).") }
                $id = [string]$body.id
                if ($id -notmatch '^(app|workspace):[^\\/:]{1,200}$') { throw (New-Object System.ArgumentException 'Invalid plugin id.') }
                $wsPath = ''
                $ws = $null
                if ([string]$body.workspaceId) { $ws = Get-WorkspaceById ([string]$body.workspaceId) } else { $ws = $script:Workspaces[0] }
                if ($ws) { $wsPath = [string]$ws.path }
                try {
                    $r = Set-PluginTrustState -DataDir $dataDir -AppRoot $root -Workspace $wsPath -Id $id -Action $act -ExpectedHash ([string]$body.hash)
                } catch {
                    throw (New-Object System.ArgumentException $_.Exception.Message)
                }
                Add-Log 'sys' "Plugin $act : $id"
                Write-JsonObject $resp 200 @{ ok = $true; changed = [bool]$r }
            } elseif ($path -eq '/api/workspaces' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                $wsPath = ([string]$body.path).Trim()
                if (-not $wsPath -or -not [IO.Path]::IsPathRooted($wsPath)) { throw (New-Object System.ArgumentException 'Give a full folder path, e.g. C:\Lab\SW4.') }
                if (-not (Test-Path -LiteralPath $wsPath -PathType Container)) { New-Item -ItemType Directory -Force $wsPath | Out-Null }
                $full = (Resolve-Path -LiteralPath $wsPath).Path
                $existing = @($script:Workspaces | Where-Object { $_.path -eq $full })
                if ($existing.Count -gt 0) { Write-JsonObject $resp 200 $existing[0]; continue }
                $wsName = Split-Path -Leaf $full
                if ([string]$body.name) { $wsName = [string]$body.name }
                $wsObj = [pscustomobject]@{ id = 'ws_' + [guid]::NewGuid().ToString('N').Substring(0, 6); name = $wsName; path = $full }
                $script:Workspaces = @($script:Workspaces) + @($wsObj)
                Write-Utf8Json $workspacesFile @($script:Workspaces)
                Write-JsonObject $resp 200 $wsObj
            } elseif ($path -eq '/api/chats' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                $act = [string]$body.action
                if ($act -eq 'new') {
                    $c = New-ExplorerChat ([string]$body.workspaceId)
                    $script:Chats[$c.id] = $c
                    Write-Utf8Json (Get-ChatFile $c.id) $c
                    Write-JsonObject $resp 200 $c
                } elseif ($act -eq 'delete') {
                    $cid = [string]$body.chatId
                    if ($script:Runs.ContainsKey($cid) -and $script:Runs[$cid].running) { throw (New-Object System.ArgumentException 'Stop the running reply before deleting this chat.') }
                    $script:Chats.Remove($cid)
                    Remove-Item -LiteralPath (Get-ChatFile $cid) -Force -ErrorAction SilentlyContinue
                    Write-JsonResponse $resp 200 '{"ok":true}'
                } elseif ($act -eq 'undo') {
                    $cid = [string]$body.chatId
                    $null = Get-ChatFile $cid
                    $n = Invoke-UndoTurn -UndoDir (Join-Path $undoRoot $cid) -TurnId ([string]$body.turnId)
                    Write-JsonObject $resp 200 @{ ok = $true; restored = $n }
                } else {
                    throw (New-Object System.ArgumentException 'unknown_action')
                }
            } elseif ($path -eq '/api/chat/send' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                $mode = [string]$body.mode
                if (-not $mode) { $mode = 'chat' }
                if ($mode -notin @('chat', 'explore')) { throw (New-Object System.ArgumentException "mode must be chat or explore.") }
                $atts = @()
                if ($body.attachments) { $atts = @($body.attachments) }
                $text = [string]$body.text
                if ($mode -eq 'chat' -and -not $text.Trim() -and $atts.Count -eq 0) { throw (New-Object System.ArgumentException 'Type a message first.') }
                Start-ChatAgentTurn -ChatId ([string]$body.chatId) -UserText $text -Attachments $atts -Mode $mode
                Write-JsonResponse $resp 200 '{"ok":true}'
            } elseif ($path -eq '/api/chat/events' -and $method -eq 'GET') {
                $cid = [string]$req.QueryString['chatId']
                $since = 0
                if ($req.QueryString['since'] -match '^\d+$') { $since = [int]$req.QueryString['since'] }
                $rsObj = $null
                if ($script:Runs.ContainsKey($cid)) { $rsObj = $script:Runs[$cid] }
                if ($null -eq $rsObj) {
                    Write-JsonResponse $resp 200 '{"running":false,"next":0,"events":[]}'
                } else {
                    $evts = @()
                    $count = $rsObj.events.Count
                    for ($i = $since; $i -lt $count; $i++) { $evts += $rsObj.events[$i] }
                    Write-JsonObject $resp 200 ([ordered]@{ running = [bool]$rsObj.running; next = $count; turnId = $rsObj.turnId; mode = $rsObj.mode; events = $evts })
                }
            } elseif ($path -eq '/api/chat/approve' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                $cid = [string]$body.chatId
                $ok = $false
                if ($script:Runs.ContainsKey($cid)) {
                    $rsObj = $script:Runs[$cid]
                    $want = [string]$body.id
                    if ($rsObj.pendingApproval -and (-not $want -or $want -eq [string]$rsObj.approvalId)) {
                        $rsObj.approvalResult = [bool]$body.approved
                        [void]$rsObj.approvalSignal.Set()
                        $ok = $true
                    }
                }
                Write-JsonObject $resp 200 @{ ok = $ok }
            } elseif ($path -eq '/api/chat/stop' -and $method -eq 'POST') {
                $body = Read-RequestJson $req
                $cid = [string]$body.chatId
                if ($script:Runs.ContainsKey($cid)) {
                    $script:Runs[$cid].cancel = $true
                    [void]$script:Runs[$cid].approvalSignal.Set()
                }
                Write-JsonResponse $resp 200 '{"ok":true}'
            } elseif ($path -eq '/api/artifact/raw' -and $method -eq 'GET') {
                $cid = [string]$req.QueryString['chatId']
                $aid = [string]$req.QueryString['id']
                $ver = 0
                if ($req.QueryString['version'] -match '^\d+$') { $ver = [int]$req.QueryString['version'] }
                $c = $script:Chats[$cid]
                $art = @()
                if ($c) { $art = @($c.artifacts | Where-Object { $_.id -eq $aid -and [int]$_.version -eq $ver } | Select-Object -First 1) }
                if ($art.Count -eq 0) {
                    Write-JsonResponse $resp 404 '{"error":"artifact_not_found"}'
                } else {
                    # CSP sandbox: the artifact always runs in an opaque origin, even when opened directly,
                    # so its scripts cannot call this API.
                    Write-ResponseBytes $resp 200 'text/html; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes([string]$art[0].content)) @{ 'Content-Security-Policy' = 'sandbox allow-scripts' }
                }
            } elseif ($path -eq '/favicon.ico') {
                Write-ResponseBytes $resp 204 'image/x-icon' (New-Object byte[] 0)
            } elseif ($path -eq '/' -or $path -eq '/index.html') {
                Write-ResponseBytes $resp 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($uiIndex)) @{ 'X-Frame-Options' = 'DENY' }
            } else {
                Write-JsonResponse $resp 404 '{"error":"not_found"}'
            }
        } catch [System.ArgumentException] {
            try { Write-JsonObject $ctx.Response 400 @{ error = $_.Exception.Message } } catch { }
        } catch {
            # Log only the path and message (never request bodies: they may hold passwords).
            Add-Log 'WARN' "API error ($path): $($_.Exception.Message)"
            try { Write-JsonObject $ctx.Response 500 @{ error = $_.Exception.Message } } catch { }
        }
    }
} finally {
    foreach ($k in @($script:Runs.Keys)) { try { $script:Runs[$k].cancel = $true; [void]$script:Runs[$k].approvalSignal.Set() } catch { } }
    if ($listener) { try { $listener.Close() } catch { } }
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
    Add-Log 'sys' "$productName stopped."
}
