# ExplorerAgent.ps1 - The agent loop for BYOB Explorer (one chat turn).
# Windows PowerShell 5.1 and PowerShell 7. ASCII only.
# Dot-source after NetGate.ps1, CredStore.ps1, ExplorerTools.ps1, ByobLlm.ps1, ByobTools.ps1, PluginHost.ps1.
#
# Invoke-ExplorerAgentTurn runs inside a background runspace started by Start-Explorer.ps1. It talks
# to the host only through $RunState (a synchronized hashtable):
#   events (ArrayList)      : events for the UI, polled over HTTP
#   cancel (bool)           : set by the Stop button
#   pendingApproval / approvalSignal / approvalResult / approvalId : the approval hand-shake
# Conversation messages are OpenAI-style hashtables (see ByobLlm.ps1). Pairing rule kept at all times:
# an assistant message with tool_calls is followed by exactly one tool message per call id.

$script:ExplorerTrimMarker = "`n[trimmed - full output is in the raw file named above]"
$script:ExplorerExploreNudge = 'Continue exploring: take the next open frontier item.'
$script:ExplorerLoopGuardText = 'LOOP GUARD: you already ran this exact call twice in this turn. Use the earlier result, try a different approach, or finish.'
$script:ExplorerBadStreakText = '[Host] The last 6 tool results were BLOCKED, LOOP GUARD or errors. Stop repeating similar calls. Re-read the frontier (frontier action=list), pick a different item, or finish and report what you have.'

# =============================================================================
#  Small helpers (unit-tested in tests\Run-CoreTests.ps1)
# =============================================================================
function Add-ExplorerEvent {
    param($RunState, $Evt)
    if ($null -ne $RunState -and $null -ne $RunState.events) { [void]$RunState.events.Add($Evt) }
}

function Save-ExplorerChatFile {
    param($Chat, [string]$ChatFile)
    if (-not $ChatFile) { return }
    [IO.File]::WriteAllText($ChatFile, ($Chat | ConvertTo-Json -Depth 16), (New-Object System.Text.UTF8Encoding $false))
}

function Get-ExplorerSettingNumber {
    param($Settings, [string]$Name, [double]$Default, [double]$Min, [double]$Max)
    $v = $Default
    if ($Settings -and $Settings.PSObject.Properties.Name -contains $Name -and $null -ne $Settings.$Name -and [string]$Settings.$Name -ne '') {
        try { $v = [double]$Settings.$Name } catch { $v = $Default }
    }
    if ($v -lt $Min) { $v = $Min }
    if ($v -gt $Max) { $v = $Max }
    return $v
}

function Measure-ExplorerMessages {
    # Total characters of the system prompt plus all message text and tool-call arguments.
    param([string]$SystemPrompt, $Messages)
    $n = ([string]$SystemPrompt).Length
    foreach ($m in @($Messages)) {
        if ($null -eq $m) { continue }
        $c = $m.content
        if ($c -is [array]) {
            foreach ($p in $c) { if ($p.type -eq 'text') { $n += ([string]$p.text).Length } else { $n += 1000 } }
        } else { $n += ([string]$c).Length }
        foreach ($tc in @($m.tool_calls)) {
            if ($null -eq $tc) { continue }
            $n += ([string]$tc.function.arguments).Length + ([string]$tc.function.name).Length + 30
        }
    }
    return $n
}

function Limit-ExplorerToolResults {
    # Trims every tool result except the most recent $KeepRecent to its first $HeadChars characters.
    # Mutates the message hashtables in place. Returns how many results were trimmed.
    param($Messages, [int]$KeepRecent = 6, [int]$HeadChars = 400)
    $idx = @()
    for ($i = 0; $i -lt @($Messages).Count; $i++) { if ($Messages[$i].role -eq 'tool') { $idx += $i } }
    $cut = $idx.Count - $KeepRecent
    $n = 0
    for ($k = 0; $k -lt $cut; $k++) {
        $m = $Messages[$idx[$k]]
        $c = [string]$m.content
        if ($c.EndsWith($script:ExplorerTrimMarker)) { continue }
        if ($c.Length -le ($HeadChars + $script:ExplorerTrimMarker.Length)) { continue }
        $m.content = $c.Substring(0, $HeadChars) + $script:ExplorerTrimMarker
        $n++
    }
    return $n
}

function ConvertTo-ExplorerTranscript {
    # Flattens a conversation to plain text for the summarisation call (no tool pairing involved).
    param($Messages, [int]$MaxChars = 60000)
    $sb = New-Object System.Text.StringBuilder
    foreach ($m in @($Messages)) {
        $c = $m.content
        $text = ''
        if ($c -is [array]) { $text = (@($c | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join ' ') } else { $text = [string]$c }
        switch ([string]$m.role) {
            'user' { [void]$sb.AppendLine("USER: $text") }
            'assistant' {
                if ($text) { [void]$sb.AppendLine("ASSISTANT: $text") }
                foreach ($tc in @($m.tool_calls)) {
                    if ($null -eq $tc) { continue }
                    $a = [string]$tc.function.arguments
                    if ($a.Length -gt 600) { $a = $a.Substring(0, 600) + '...' }
                    [void]$sb.AppendLine("ASSISTANT CALLED $($tc.function.name) $a")
                }
            }
            'tool' {
                if ($text.Length -gt 1500) { $text = $text.Substring(0, 1500) + '...' }
                [void]$sb.AppendLine("TOOL RESULT: $text")
            }
        }
    }
    $t = $sb.ToString()
    if ($t.Length -gt $MaxChars) {
        $head = [int]($MaxChars * 0.2)
        $tail = $MaxChars - $head
        $t = $t.Substring(0, $head) + "`n...(middle of transcript omitted)...`n" + $t.Substring($t.Length - $tail)
    }
    return $t
}

function Get-ExplorerLoopKey {
    param([string]$Name, $ToolArgs)
    $j = '{}'
    if ($null -ne $ToolArgs) { try { $j = ($ToolArgs | ConvertTo-Json -Depth 12 -Compress) } catch { $j = [string]$ToolArgs } }
    return "$Name|$j"
}

function Test-ExplorerBadResult {
    param([string]$Text, [string]$Status)
    if ($Status -in @('error', 'blocked')) { return $true }
    return ([string]$Text -match '^(BLOCKED|LOOP GUARD|Tool error|Unknown tool|Unknown plugin tool)')
}

function Get-ExplorerFrontierCounts {
    param([string]$Workspace)
    $r = @{ open = 0; done = 0; skipped = 0 }
    try {
        foreach ($it in (Read-ExplorerFrontier -Workspace $Workspace)) {
            if ($it.status -eq 'open') { $r.open++ } elseif ($it.status -eq 'done') { $r.done++ } elseif ($it.status -eq 'skipped') { $r.skipped++ }
        }
    } catch { }
    return $r
}

function Get-ExplorerKbSnapshot {
    param([string]$Workspace)
    $h = @{}
    $kb = Join-Path $Workspace 'kb'
    if (-not (Test-Path -LiteralPath $kb -PathType Container)) { return $h }
    $root = [IO.Path]::GetFullPath($kb).TrimEnd([char[]]@('\', '/'))
    foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue)) {
        $rel = 'kb/' + $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        $h[$rel] = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
    }
    return $h
}

function Compare-ExplorerKbSnapshot {
    param([hashtable]$Before, [hashtable]$After)
    $changed = @()
    foreach ($k in @($After.Keys | Sort-Object)) {
        if (-not $Before.ContainsKey($k) -or $Before[$k] -ne $After[$k]) { $changed += $k }
    }
    return ,$changed
}

function Get-ExplorerExploreInstruction {
    param([string]$Guidance, $Scope, [string[]]$VsphereCredentials = @())
    $allow = '(none)'
    $deny = '(none)'
    if ($Scope) {
        if (@($Scope.allow).Count -gt 0) { $allow = (@($Scope.allow) -join ', ') }
        if (@($Scope.deny).Count -gt 0) { $deny = (@($Scope.deny) -join ', ') }
    }
    $vs = ''
    if (@($VsphereCredentials).Count -gt 0) {
        $vs = " A vSphere credential exists ($((@($VsphereCredentials)) -join ', ')): add a priority-1 frontier item for the vCenter/ESXi server (list_credentials shows the credential note, which may name it) and inventory it with net_query via=vsphere."
    }
    $t = @"
EXPLORE MODE. Work on your own, read-only, until the frontier is empty or the user presses Stop. Do not stop to ask questions: write open questions to kb/90-open-questions.md and carry on.
1. kb_read 00-index.md and frontier action=list.
2. If the kb is empty (a new network), start with what this laptop can see, using net_query via=local: its own addresses (ipconfig /all), routes (route print), DNS servers (Get-DnsClientServerAddress) and the ARP/neighbor table (arp -a). Write what you find to kb/20-network.md and keep kb/00-index.md current.
3. Read the scope (allow: $allow; deny: $deny) and add frontier items for every in-scope subnet and named host.$vs
4. Then work the frontier: highest priority first, one item at a time. Write findings to the kb with raw/ citations, add newly found hosts and questions to the frontier, and mark each item done or skipped.
5. When the frontier is empty, finish with a short report of what you covered and what is still unknown.
"@
    if ($Guidance -and $Guidance.Trim()) { $t += "`nExtra guidance from the user: $($Guidance.Trim())" }
    return $t
}

function Get-ExplorerTurnSystemPrompt {
    param([string]$Workspace, [string]$DataDir, [string[]]$CredentialNames = @(), [string]$ExtraInstructions = '', [string]$AppRoot = '')
    $p = Get-ExplorerSystemPrompt -Workspace $Workspace -CredentialNames $CredentialNames
    $readme = Join-Path (Join-Path $AppRoot 'plugins') 'README.md'
    $p += "`n`nPLUGINS`nYou can build your own tools as plugins: write a folder under .byob\plugins\<name>\ with a byob-plugin.json manifest and a .ps1 script (format: read_file $readme). A new or changed plugin shows up as plg_<plugin>_<tool> and asks the user before every run until the user trusts it in Settings > Plugins; plugins are not covered by the read-only gate, so keep them read-only and small."
    foreach ($mem in @(@{ Label = 'GLOBAL MEMORY'; Path = (Join-Path $DataDir 'memory.md') }, @{ Label = 'WORKSPACE MEMORY'; Path = (Join-Path (Join-Path $Workspace '.byob') 'memory.md') })) {
        if (Test-Path -LiteralPath $mem.Path -PathType Leaf) {
            $t = [IO.File]::ReadAllText($mem.Path, [Text.Encoding]::UTF8)
            if ($t.Length -gt 4000) { $t = $t.Substring($t.Length - 4000) + "`n(older memory lines omitted)" }
            if ($t.Trim()) { $p += "`n`n$($mem.Label)`n$t" }
        }
    }
    if ($ExtraInstructions -and $ExtraInstructions.Trim()) { $p += "`n`nUSER INSTRUCTIONS`n$ExtraInstructions" }
    return $p
}

function Get-ExplorerTurnTools {
    # Returns @{ Tools = <definitions>; Plugins = <plugin objects> }.
    param([string]$AppRoot, [string]$Workspace, [string]$DataDir, [bool]$IncludeDelegate = $true)
    $plugins = @()
    try { $plugins = @(Get-ExplorerPlugins -AppRoot $AppRoot -Workspace $Workspace -DataDir $DataDir) } catch { $plugins = @() }
    $tools = @(Get-ByobToolDefinitions -IncludeDelegate $IncludeDelegate) + @(Get-ExplorerToolDefinitions) + @(Get-PluginToolDefinitions -Plugins $plugins)
    return @{ Tools = $tools; Plugins = $plugins }
}

function Invoke-ExplorerToolDispatch {
    # Explorer tools first; $null means "not mine" -> plugin tools -> base tools.
    param([Parameter(Mandatory)][string]$Name, $ToolArgs, [Parameter(Mandatory)][hashtable]$Context)
    $r = Invoke-ExplorerTool -Name $Name -Args $ToolArgs -Context $Context
    if ($null -ne $r) { return [string]$r }
    $r = Invoke-PluginTool -Name $Name -Args $ToolArgs -Context $Context
    if ($null -ne $r) { return [string]$r }
    return [string](Invoke-ByobTool -Name $Name -Args $ToolArgs -Context $Context)
}

function Get-ExplorerRetryDelays {
    # 5 s then 15 s. BYOB_EXPLORER_RETRY_DELAYS="a,b" overrides (used by the host smoke test).
    $d = @(5, 15)
    if ($env:BYOB_EXPLORER_RETRY_DELAYS -match '^\s*\d+\s*,\s*\d+\s*$') {
        $parts = $env:BYOB_EXPLORER_RETRY_DELAYS.Split(',')
        $d = @([int]$parts[0].Trim(), [int]$parts[1].Trim())
    }
    return $d
}

function Invoke-ExplorerModelCall {
    # One model call with up to 2 retries (5 s / 15 s). Throws OperationCanceledException on Stop.
    param($Settings, $Secrets, [string]$SystemPrompt, $Messages, [AllowEmptyCollection()][array]$Tools = @(), $RunState, [int]$MaxTokens = 0)
    $inf = $Settings.inference
    $timeout = [int](Get-ExplorerSettingNumber $Settings 'request_timeout_sec' 600 10 7200)
    if ($MaxTokens -le 0) { $MaxTokens = [int](Get-ExplorerSettingNumber $Settings 'max_tokens' 4096 64 200000) }
    $temp = Get-ExplorerSettingNumber $Settings 'temperature' 0.2 0 2
    $delays = Get-ExplorerRetryDelays
    $msgArr = @($Messages)
    for ($attempt = 0; $attempt -le 2; $attempt++) {
        if ($RunState.cancel) { throw (New-Object System.OperationCanceledException 'Stopped by user.') }
        try {
            return (Invoke-ByobLlmOnce -BaseUrl ([string]$inf.base_url) -Model ([string]$inf.model) -ApiKey ([string]$Secrets.api_key) `
                -ApiKind ([string]$inf.api) -SystemPrompt $SystemPrompt -Messages $msgArr -Tools $Tools `
                -Temperature $temp -MaxTokens $MaxTokens -TimeoutSec $timeout -CancelState $RunState)
        } catch {
            if ($RunState.cancel -or $_.Exception -is [System.OperationCanceledException]) { throw (New-Object System.OperationCanceledException 'Stopped by user.') }
            $msg = $_.Exception.Message
            if ($attempt -ge 2) { throw "The model call failed 3 times. Last error: $msg" }
            $wait = $delays[$attempt]
            Add-ExplorerEvent $RunState @{ type = 'retry'; attempt = ($attempt + 1); waitSec = $wait; error = $msg }
            $until = (Get-Date).AddSeconds($wait)
            while ((Get-Date) -lt $until) {
                if ($RunState.cancel) { throw (New-Object System.OperationCanceledException 'Stopped by user.') }
                Start-Sleep -Milliseconds 200
            }
        }
    }
}

function Invoke-ExplorerContextCheck {
    # Before every model call: trim old tool results, then summarise if still over 70% of the budget.
    param($Conv, [string]$SystemPrompt, [int]$Budget, $OrigUser, $Settings, $Secrets, $RunState)
    $limit = [int]($Budget * 0.7)
    if ((Measure-ExplorerMessages -SystemPrompt $SystemPrompt -Messages $Conv) -le $limit) { return }
    $n = Limit-ExplorerToolResults -Messages $Conv -KeepRecent 6 -HeadChars 400
    if ($n -gt 0) { Add-ExplorerEvent $RunState @{ type = 'trimmed'; count = $n } }
    $total = Measure-ExplorerMessages -SystemPrompt $SystemPrompt -Messages $Conv
    if ($total -le $limit -or $Conv.Count -le 2) { return }
    $transcript = ConvertTo-ExplorerTranscript -Messages $Conv -MaxChars ([Math]::Max(4000, [int]($Budget * 0.5)))
    $ask = "[Progress summary request]`nBelow is the transcript of the work so far in this turn. Write a progress summary of at most 400 words with four parts: what was asked; what was done; key findings with their raw/ file references; what remains to do.`n`nTRANSCRIPT`n$transcript"
    $summary = ''
    try {
        $r = Invoke-ExplorerModelCall -Settings $Settings -Secrets $Secrets -SystemPrompt 'You write short, factual progress summaries for an AI network investigator.' -Messages @(@{ role = 'user'; content = $ask }) -Tools @() -RunState $RunState -MaxTokens 1200
        $summary = ([string]$r.Text).Trim()
    } catch {
        if ($RunState.cancel) { throw }
        $summary = ''
    }
    if (-not $summary) {
        $calls = @()
        foreach ($m in $Conv) { foreach ($tc in @($m.tool_calls)) { if ($tc) { $calls += [string]$tc.function.name } } }
        $summary = "(The summary call failed; host-made summary.) Tool calls so far this turn: $(@($calls).Count) ($((@($calls | Select-Object -Unique)) -join ', ')). Findings are in kb/ and raw/."
    }
    if ($summary.Length -gt 4000) { $summary = $summary.Substring(0, 4000) + '...' }
    $Conv.Clear()
    [void]$Conv.Add($OrigUser)
    [void]$Conv.Add(@{ role = 'user'; content = "[Progress summary so far]`n$summary`n`nContinue from here. Your knowledge base and frontier list are up to date on disk; read them if needed." })
    Add-ExplorerEvent $RunState @{ type = 'compacted'; before = $total; after = (Measure-ExplorerMessages -SystemPrompt $SystemPrompt -Messages $Conv) }
}

# =============================================================================
#  The turn
# =============================================================================
function Invoke-ExplorerAgentTurn {
    param(
        [Parameter(Mandatory)]$RunState,
        [Parameter(Mandatory)]$Chat,
        [string]$ChatFile = '',
        [Parameter(Mandatory)]$Settings,
        $Secrets,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$DataDir,
        [string]$UndoDir = '',
        [string]$AppRoot = '',
        [ValidateSet('chat', 'explore')][string]$Mode = 'chat',
        [string]$Guidance = '',
        $UserAttachments = @(),
        $SettingsHolder = $null    # optional synchronized @{ value = <settings> }: live approval mode
    )
    if ($null -eq $Secrets) { $Secrets = [pscustomobject]@{ api_key = '' } }
    $turnId = [string]$RunState.turnId
    $toolSteps = New-Object System.Collections.ArrayList
    $thinking = New-Object System.Text.StringBuilder
    $endReason = 'done'
    $finalText = ''
    $errText = ''
    $steps = 0
    $maxSteps = 40
    $lastModelText = ''
    $kbBefore = Get-ExplorerKbSnapshot -Workspace $WorkspacePath
    try {
        $maxSteps = [int](Get-ExplorerSettingNumber $Settings ("max_steps_" + $Mode) (@{ chat = 40; explore = 300 })[$Mode] 1 5000)
        $budget = [int](Get-ExplorerSettingNumber $Settings 'context_char_budget' 240000 2000 10000000)
        $scope = Get-ExplorerScope -Workspace $WorkspacePath
        if ($Mode -eq 'explore' -and $null -eq $scope) {
            $endReason = 'no_scope'
            $finalText = 'Explore needs a scope first. Open Settings > Scope and list the subnets and hosts I may touch (one per line), then press Explore again. Nothing was run.'
        } elseif (-not [string]$Settings.inference.base_url -or -not [string]$Settings.inference.model) {
            $endReason = 'error'
            $errText = 'No model is configured. Open Settings > Model, enter the model server URL and model name, then press Test.'
        } else {
            $credList = @(Get-CredentialList -DataDir $DataDir)
            $credNames = [string[]]@($credList | ForEach-Object { $_.name })
            $vsCreds = [string[]]@($credList | Where-Object { $_.kind -eq 'vsphere' } | ForEach-Object { $_.name })
            $sysPrompt = Get-ExplorerTurnSystemPrompt -Workspace $WorkspacePath -DataDir $DataDir -CredentialNames $credNames -ExtraInstructions ([string]$Settings.extra_instructions) -AppRoot $AppRoot

            $toolCtx = @{
                Workspace = $WorkspacePath
                DataDir = $DataDir
                UndoDir = $UndoDir
                TurnId = $turnId
                AppRoot = $AppRoot
                CancelState = $RunState
                CredentialNames = $credNames
                Plugins = $null
                SaveArtifact = {
                    param($Id, $Title, $CType, $Content)
                    $existing = @($Chat.artifacts | Where-Object { $_.id -eq $Id })
                    $ver = 1
                    if ($existing.Count -gt 0) { $ver = [int](@($existing | Measure-Object -Property version -Maximum).Maximum) + 1 }
                    $art = [pscustomobject]@{ id = $Id; title = $Title; content_type = $CType; version = $ver; content = $Content; updatedAt = (Get-Date).ToString('s') }
                    $Chat.artifacts = @($Chat.artifacts) + @($art)
                    Save-ExplorerChatFile -Chat $Chat -ChatFile $ChatFile
                    Add-ExplorerEvent $RunState @{ type = 'artifact'; artifact = $art }
                    return $art
                }
                SavePlan = {
                    param($PlanSteps)
                    $Chat.plan = @($PlanSteps)
                    Save-ExplorerChatFile -Chat $Chat -ChatFile $ChatFile
                    Add-ExplorerEvent $RunState @{ type = 'plan'; steps = @($PlanSteps) }
                }
                RunSubagent = {
                    param($Task)
                    $subSet = Get-ExplorerTurnTools -AppRoot $AppRoot -Workspace $WorkspacePath -DataDir $DataDir -IncludeDelegate $false
                    $subTools = @($subSet.Tools | Where-Object { $_.access -eq 'read' -and -not $_.confirm })
                    $subNames = @($subTools | ForEach-Object { $_.name })
                    $subCtx = $toolCtx.Clone()
                    $subCtx.Plugins = $subSet.Plugins
                    $subMsgs = New-Object System.Collections.ArrayList
                    [void]$subMsgs.Add(@{ role = 'user'; content = [string]$Task })
                    $subSys = "You are a read-only research subagent for a network explorer working in $WorkspacePath. Use only the tools given (read-only). Finish with a concise factual summary that cites raw/ files."
                    $subSeen = @{}
                    for ($sr = 0; $sr -lt 10; $sr++) {
                        if ($RunState.cancel) { return 'Subagent stopped by user.' }
                        $r = Invoke-ExplorerModelCall -Settings $Settings -Secrets $Secrets -SystemPrompt $subSys -Messages $subMsgs -Tools $subTools -RunState $RunState
                        if (@($r.ToolCalls).Count -eq 0) { return [string]$r.Text }
                        [void]$subMsgs.Add(@{ role = 'assistant'; content = [string]$r.Text; tool_calls = @($r.RawToolCalls) })
                        foreach ($stc in $r.ToolCalls) {
                            $sName = [string]$stc.name
                            $sKey = Get-ExplorerLoopKey -Name $sName -ToolArgs $stc.args
                            if ($subNames -notcontains $sName) { $sOut = "Tool $sName is not available to the read-only subagent." }
                            elseif ($subSeen.ContainsKey($sKey) -and $subSeen[$sKey] -ge 2) { $sOut = $script:ExplorerLoopGuardText }
                            else {
                                $subSeen[$sKey] = 1 + [int]$subSeen[$sKey]
                                try { $sOut = Invoke-ExplorerToolDispatch -Name $sName -ToolArgs $stc.args -Context $subCtx } catch { $sOut = "Tool error: $($_.Exception.Message)" }
                            }
                            [void]$subMsgs.Add(@{ role = 'tool'; tool_call_id = [string]$stc.id; content = [string]$sOut })
                        }
                    }
                    return 'Subagent reached its step limit (10) without a final answer.'
                }
            }

            # ---- conversation: earlier turns as plain text, then this turn's user message
            $conv = New-Object System.Collections.ArrayList
            $msgsList = @($Chat.messages)
            for ($mi = 0; $mi -lt $msgsList.Count - 1; $mi++) {
                $m = $msgsList[$mi]
                if ($m.role -eq 'user') { [void]$conv.Add(@{ role = 'user'; content = [string]$m.text }) }
                elseif ($m.role -eq 'assistant' -and [string]$m.text) { [void]$conv.Add(@{ role = 'assistant'; content = [string]$m.text }) }
            }
            $userText = $Guidance
            if ($Mode -eq 'explore') { $userText = Get-ExplorerExploreInstruction -Guidance $Guidance -Scope $scope -VsphereCredentials $vsCreds }
            $origUser = @{ role = 'user'; content = [string]$userText }
            if ($UserAttachments -and @($UserAttachments).Count -gt 0) {
                $parts = @(@{ type = 'text'; text = [string]$userText })
                foreach ($att in @($UserAttachments)) { if ($att.dataUrl) { $parts += @{ type = 'image_url'; image_url = @{ url = [string]$att.dataUrl } } } }
                $origUser = @{ role = 'user'; content = $parts }
            }
            [void]$conv.Add($origUser)

            $loopCounts = @{}
            $badStreak = 0
            $nudges = 0
            while ($true) {
                if ($RunState.cancel) { throw (New-Object System.OperationCanceledException 'Stopped by user.') }
                if ($steps -ge $maxSteps) { $endReason = 'budget'; break }
                $set = Get-ExplorerTurnTools -AppRoot $AppRoot -Workspace $WorkspacePath -DataDir $DataDir -IncludeDelegate $true
                $allTools = $set.Tools
                $toolCtx.Plugins = $set.Plugins
                Invoke-ExplorerContextCheck -Conv $conv -SystemPrompt $sysPrompt -Budget $budget -OrigUser $origUser -Settings $Settings -Secrets $Secrets -RunState $RunState
                $steps++
                Add-ExplorerEvent $RunState @{ type = 'progress'; step = $steps; maxSteps = $maxSteps; mode = $Mode }
                $llm = Invoke-ExplorerModelCall -Settings $Settings -Secrets $Secrets -SystemPrompt $sysPrompt -Messages $conv -Tools $allTools -RunState $RunState
                if ($llm.Thinking) {
                    [void]$thinking.AppendLine([string]$llm.Thinking)
                    if ($thinking.Length -gt 20000) { [void]$thinking.Remove(0, $thinking.Length - 20000) }
                }

                if (@($llm.ToolCalls).Count -eq 0) {
                    $text = [string]$llm.Text
                    $lastModelText = $text
                    if ($Mode -eq 'explore' -and -not $RunState.cancel) {
                        $fc = Get-ExplorerFrontierCounts -Workspace $WorkspacePath
                        if ($fc.open -gt 0 -and $nudges -lt 20) {
                            if ($steps -ge $maxSteps) { $endReason = 'budget'; break }
                            $said = $text
                            if (-not $said.Trim()) { $said = '(no text)' }
                            [void]$conv.Add(@{ role = 'assistant'; content = $said })
                            [void]$conv.Add(@{ role = 'user'; content = $script:ExplorerExploreNudge })
                            $nudges++
                            Add-ExplorerEvent $RunState @{ type = 'nudge'; count = $nudges; open = $fc.open; text = $text }
                            continue
                        }
                    }
                    $finalText = $text
                    break
                }

                [void]$conv.Add(@{ role = 'assistant'; content = [string]$llm.Text; tool_calls = @($llm.RawToolCalls) })
                foreach ($tc in $llm.ToolCalls) {
                    $tName = [string]$tc.name
                    $tArgs = $tc.args
                    $status = 'done'
                    $out = ''
                    $key = Get-ExplorerLoopKey -Name $tName -ToolArgs $tArgs
                    $prev = 0
                    if ($loopCounts.ContainsKey($key)) { $prev = [int]$loopCounts[$key] }
                    $tMeta = $null
                    foreach ($d in $allTools) { if ($d.name -eq $tName) { $tMeta = $d; break } }
                    if ($RunState.cancel) {
                        $out = 'Not run: the user pressed Stop.'
                        $status = 'stopped'
                    } elseif ($prev -ge 2) {
                        $out = $script:ExplorerLoopGuardText
                        $status = 'blocked'
                    } elseif (-not $tMeta) {
                        $out = "Unknown tool: $tName. Use only the tools you were given."
                        $status = 'error'
                    } else {
                        if ($tName.StartsWith('plg_')) {
                            # Re-check the plugin's trust right now (its files may have changed this turn).
                            $fresh = Get-ExplorerTurnTools -AppRoot $AppRoot -Workspace $WorkspacePath -DataDir $DataDir -IncludeDelegate $true
                            $toolCtx.Plugins = $fresh.Plugins
                            $tMeta = $null
                            foreach ($d in $fresh.Tools) { if ($d.name -eq $tName) { $tMeta = $d; break } }
                        }
                        if (-not $tMeta) {
                            $out = "Unknown plugin tool: $tName (the plugin was removed or became invalid)."
                            $status = 'error'
                        } else {
                            $access = [string]$tMeta.access
                            $mustConfirm = [bool]$tMeta.confirm
                            $policy = [string]$Settings.approvals
                            if ($null -ne $SettingsHolder -and $null -ne $SettingsHolder.value) { $policy = [string]$SettingsHolder.value.approvals }
                            $needsAsk = $mustConfirm -or ($policy -eq 'ask_all') -or ($policy -ne 'yolo' -and $access -ne 'read')
                            $approved = $true
                            if ($needsAsk) {
                                $reqId = 'apr_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
                                $warn = "Allow $tName ($access)?"
                                if ($mustConfirm) { $warn = [string]$tMeta.confirm }
                                elseif ($tName -eq 'run_command') { $warn = 'run_command runs ANY PowerShell command on this laptop. It is NOT checked by the read-only gate.' }
                                [void]$RunState.approvalSignal.Reset()
                                $RunState.approvalResult = $false
                                $RunState.approvalId = $reqId
                                $RunState.pendingApproval = @{ id = $reqId; tool = $tName; args = $tArgs; access = $access; warning = $warn; mustConfirm = $mustConfirm }
                                Add-ExplorerEvent $RunState @{ type = 'approval_needed'; approval = $RunState.pendingApproval }
                                while (-not $RunState.approvalSignal.WaitOne(250)) { if ($RunState.cancel) { break } }
                                $approved = [bool]$RunState.approvalResult -and -not $RunState.cancel
                                $RunState.pendingApproval = $null
                                $RunState.approvalId = ''
                                Add-ExplorerEvent $RunState @{ type = 'approval_done'; id = $reqId; approved = $approved }
                            }
                            if ($RunState.cancel) {
                                $out = 'Not run: the user pressed Stop.'
                                $status = 'stopped'
                            } elseif (-not $approved) {
                                $out = 'The user denied this tool call. Do not retry it; choose another approach or ask the user.'
                                $status = 'denied'
                            } else {
                                Add-ExplorerEvent $RunState @{ type = 'tool_start'; tool = $tName; args = $tArgs }
                                $loopCounts[$key] = $prev + 1
                                try {
                                    $out = Invoke-ExplorerToolDispatch -Name $tName -ToolArgs $tArgs -Context $toolCtx
                                } catch {
                                    if ($_.Exception -is [System.OperationCanceledException]) { $out = 'Not finished: the user pressed Stop.'; $status = 'stopped' }
                                    else { $out = "Tool error: $($_.Exception.Message)"; $status = 'error' }
                                }
                                if ($status -eq 'done' -and $out -match '^(BLOCKED|LOOP GUARD)') { $status = 'blocked' }
                            }
                        }
                    }
                    $preview = $out
                    if ($preview.Length -gt 600) { $preview = $preview.Substring(0, 600) + '...' }
                    $stepObj = [pscustomobject]@{ tool = $tName; args = $tArgs; status = $status; preview = $preview }
                    [void]$toolSteps.Add($stepObj)
                    Add-ExplorerEvent $RunState @{ type = 'tool_done'; step = $stepObj }
                    [void]$conv.Add(@{ role = 'tool'; tool_call_id = [string]$tc.id; content = [string]$out })
                    if (Test-ExplorerBadResult -Text $out -Status $status) { $badStreak++ } elseif ($status -ne 'denied' -and $status -ne 'stopped') { $badStreak = 0 }
                }
                if ($badStreak -ge 6) {
                    [void]$conv.Add(@{ role = 'user'; content = $script:ExplorerBadStreakText })
                    Add-ExplorerEvent $RunState @{ type = 'nudge'; kind = 'bad_streak' }
                    $badStreak = 0
                }
            }
        }
    } catch {
        if ($RunState.cancel -or $_.Exception -is [System.OperationCanceledException]) {
            $endReason = 'stopped'
        } else {
            $endReason = 'error'
            $errText = $_.Exception.Message
        }
    }
    if ($RunState.cancel -and $endReason -eq 'done') { $endReason = 'stopped' }

    try {
        if ($endReason -eq 'stopped') {
            $finalText = "Stopped by user after $steps model call(s) and $($toolSteps.Count) tool step(s)."
        } elseif ($endReason -eq 'error') {
            $finalText = "The turn ended with an error: $errText"
        } elseif ($endReason -eq 'budget') {
            $fc = Get-ExplorerFrontierCounts -Workspace $WorkspacePath
            $changed = Compare-ExplorerKbSnapshot -Before $kbBefore -After (Get-ExplorerKbSnapshot -Workspace $WorkspacePath)
            $kbList = 'none'
            if (@($changed).Count -gt 0) { $kbList = (@($changed) -join ', ') }
            $how = 'Send another message to continue'
            if ($Mode -eq 'explore') { $how = 'Press Explore again to continue (it picks up from the frontier)' }
            $finalText = "Step budget reached: used $steps of $maxSteps model calls in $Mode mode.`n`n- Frontier: $($fc.open) open, $($fc.done) done, $($fc.skipped) skipped.`n- KB files changed this turn: $kbList`n- Tool steps this turn: $($toolSteps.Count)`n`n$how, or raise the limit in Settings > Run limits."
            if ($lastModelText -and $lastModelText.Trim()) {
                $lt = $lastModelText.Trim()
                if ($lt.Length -gt 500) { $lt = $lt.Substring(0, 500) + '...' }
                $finalText += "`n`nLast note from the model: $lt"
            }
        } elseif (-not $finalText -or -not $finalText.Trim()) {
            $finalText = '(Completed tool steps.)'
        }
        $asstMsg = [pscustomobject]@{
            id = 'msg_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            role = 'assistant'
            text = $finalText
            thinking = $thinking.ToString().Trim()
            steps = @($toolSteps.ToArray())
            turnId = $turnId
            mode = $Mode
            endReason = $endReason
            stepsUsed = $steps
            time = (Get-Date).ToString('s')
        }
        $Chat.messages = @($Chat.messages) + @($asstMsg)
        $Chat.updatedAt = (Get-Date).ToString('s')
        Save-ExplorerChatFile -Chat $Chat -ChatFile $ChatFile
        if ($endReason -eq 'error') { Add-ExplorerEvent $RunState @{ type = 'error'; text = $finalText; message = $asstMsg } }
        else { Add-ExplorerEvent $RunState @{ type = 'done'; message = $asstMsg; endReason = $endReason } }
    } catch {
        Add-ExplorerEvent $RunState @{ type = 'error'; text = "Could not save the reply: $($_.Exception.Message)" }
    }
}
