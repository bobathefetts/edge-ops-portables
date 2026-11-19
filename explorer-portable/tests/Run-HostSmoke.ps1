# Run-HostSmoke.ps1 - End-to-end smoke test of src\Start-Explorer.ps1 over its HTTP API.
# Starts tests\mock_llm.py (scripted OpenAI-compatible model) and the host on free loopback ports with a
# temporary data folder and workspaces, then drives the API like the UI does.
# Needs PowerShell 7 + python3 (the Linux test runtime): the host runs under the dev override
# BYOB_EXPLORER_ALLOW_PS7=1. Anywhere else it prints SKIP and exits 0. ASCII only.
# Usage: pwsh -NoProfile -File tests/Run-HostSmoke.ps1      (exit code 1 on any failure)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($PSVersionTable.PSVersion.Major -lt 7) { Write-Host 'Host smoke: SKIP (needs PowerShell 7 with the dev override; run tests\Run-CoreTests.ps1 on Windows PowerShell 5.1).'; exit 0 }
$python = Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { Write-Host 'Host smoke: SKIP (python3 not found for the mock model server).'; exit 0 }
. (Join-Path (Join-Path $root 'src') 'ByobLlm.ps1')     # Invoke-ByobHttpRequest

$script:Pass = 0
$script:Fail = 0
function Assert-True([bool]$Cond, [string]$Msg) {
    if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host "FAIL: $Msg" }
}

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    return $p
}

$Secret = 'Sup3r-S3cret-Value!42'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('explorer-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$dataDir = Join-Path $tmp 'data'
$logDir = Join-Path $tmp 'logs'
$ws1 = Join-Path $tmp 'ws1'
$ws2 = Join-Path $tmp 'ws2'
New-Item -ItemType Directory -Force $dataDir, $logDir, $ws1, $ws2 | Out-Null
$script:Responses = New-Object System.Text.StringBuilder
$mockProc = $null
$hostProc = $null

function Start-Child([string]$File, [string]$Arguments, [hashtable]$Env = @{}) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
    return [System.Diagnostics.Process]::Start($psi)
}

function Invoke-Api([string]$Method, [string]$Path, $Body = $null) {
    $json = ''
    if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Depth 12 -Compress) }
    $r = Invoke-ByobHttpRequest -Url ($script:Base + $Path) -Method $Method -Body $json -TimeoutSec 60
    [void]$script:Responses.AppendLine($r.Body)
    $obj = $null
    try { $obj = ConvertFrom-Json -InputObject $r.Body } catch { }
    return [pscustomobject]@{ Status = $r.Status; Obj = $obj; Raw = $r.Body }
}

function Invoke-Mock([string]$Method, [string]$Path) {
    $r = Invoke-ByobHttpRequest -Url ($script:MockBase + $Path) -Method $Method -Body '{}' -TimeoutSec 30
    return (ConvertFrom-Json -InputObject $r.Body)
}

function Get-MockLog { return @((Invoke-Mock 'GET' '/__log').log) }
$script:Violations = @()
$script:ModelRequests = 0
function Reset-Mock {
    # Keep pairing violations and the secret scan across scenarios before clearing the mock's log.
    foreach ($e in (Get-MockLog)) {
        $script:ModelRequests++
        foreach ($v in @($e.violations)) { if ($v) { $script:Violations += "[$($e.scenario)] $v" } }
        if ([string]$e.raw -match [regex]::Escape($Secret)) { $script:Violations += "[$($e.scenario)] secret sent to the model" }
    }
    $null = Invoke-Mock 'POST' '/__reset'
}

function New-TestChat([string]$WsId) {
    return (Invoke-Api 'POST' '/api/chats' @{ action = 'new'; workspaceId = $WsId }).Obj.id
}

function Wait-Turn([string]$ChatId, [int]$TimeoutSec = 60, [scriptblock]$OnEvent = $null) {
    $events = New-Object System.Collections.ArrayList
    $since = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Api 'GET' "/api/chat/events?chatId=$ChatId&since=$since"
        foreach ($e in @($r.Obj.events)) {
            if ($null -eq $e) { continue }
            [void]$events.Add($e)
            if ($OnEvent) { & $OnEvent $e }
        }
        $since = [int]$r.Obj.next
        if (-not $r.Obj.running) {
            # one more read for events added just before running turned false
            $r2 = Invoke-Api 'GET' "/api/chat/events?chatId=$ChatId&since=$since"
            foreach ($e in @($r2.Obj.events)) { if ($null -ne $e) { [void]$events.Add($e); if ($OnEvent) { & $OnEvent $e } } }
            return ,$events.ToArray()
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Host "WARN: turn in $ChatId did not finish within ${TimeoutSec}s"
    return ,$events.ToArray()
}

function Send-Turn([string]$ChatId, [string]$Text, [string]$Mode = 'chat') {
    return (Invoke-Api 'POST' '/api/chat/send' @{ chatId = $ChatId; text = $Text; mode = $Mode })
}

function Get-FinalEvent($Events) { return @($Events | Where-Object { $_.type -in @('done', 'error') } | Select-Object -Last 1)[0] }

function Set-TestSettings([hashtable]$Overrides) {
    $s = (Invoke-Api 'GET' '/api/state').Obj.settings
    foreach ($k in $Overrides.Keys) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $Overrides[$k] -Force }
    return (Invoke-Api 'POST' '/api/settings' @{ settings = $s })
}

try {
    # ------------------------------------------------------------------ start mock + host
    $mockProc = Start-Child $python.Source ('-I "' + (Join-Path $PSScriptRoot 'mock_llm.py') + '" 0')
    $first = $mockProc.StandardOutput.ReadLine()
    if ($first -notmatch '^PORT (\d+)$') { throw "Mock server did not start: $first" }
    $script:MockBase = "http://127.0.0.1:$($Matches[1])"
    $hostPort = Get-FreePort
    $script:Base = "http://localhost:$hostPort"
    $pwshExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $hostArgs = '-NoProfile -File "' + (Join-Path (Join-Path $root 'src') 'Start-Explorer.ps1') + '" -Port ' + $hostPort + ' -NoBrowser -DataDir "' + $dataDir + '" -LogDir "' + $logDir + '" -Workspace "' + $ws1 + '"'
    $hostProc = Start-Child $pwshExe $hostArgs @{ BYOB_EXPLORER_ALLOW_PS7 = '1'; BYOB_EXPLORER_RETRY_DELAYS = '1,1' }
    $up = $false
    for ($i = 0; $i -lt 150; $i++) {
        try { $r = Invoke-ByobHttpRequest -Url "$script:Base/__fleethacker/id" -Method 'GET' -TimeoutSec 2; if ($r.Status -eq 200) { $up = $true; break } } catch { }
        if ($hostProc.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $up) { throw "Host did not start. stderr: $($hostProc.StandardError.ReadToEnd())" }
    $id = (Invoke-Api 'GET' '/__fleethacker/id').Obj
    Assert-True ($id.tool -eq 'byob-explorer' -and $id.version -eq '0.1.0') "id endpoint: $($id | ConvertTo-Json -Compress)"

    # ------------------------------------------------------------------ state + settings
    $st = (Invoke-Api 'GET' '/api/state').Obj
    Assert-True ($st.product -eq 'BYOB Explorer' -and $st.credentialCount -eq 0) 'state has product and credentialCount 0'
    Assert-True ($st.settings.max_steps_chat -eq 40 -and $st.settings.max_steps_explore -eq 300 -and $st.settings.context_char_budget -eq 240000 -and $st.settings.request_timeout_sec -eq 600) 'settings defaults present'
    $ws1Id = @($st.workspaces | Where-Object { $_.path -eq $ws1 })[0].id
    Assert-True ([bool]$ws1Id -and -not @($st.workspaces | Where-Object { $_.id -eq $ws1Id })[0].scopeExists) 'workspace listed with scopeExists=false'
    $ws2Obj = (Invoke-Api 'POST' '/api/workspaces' @{ path = $ws2 }).Obj
    $ws2Id = $ws2Obj.id
    Assert-True ([bool]$ws2Id) 'second workspace added'
    $r = Set-TestSettings @{ inference = @{ base_url = "$script:MockBase/v1"; model = 'mock-model'; api = 'openai' }; approvals = 'ask_writes'; max_steps_chat = 'abc'; temperature = 9 }
    Assert-True ($r.Status -eq 200 -and $r.Obj.settings.max_steps_chat -eq 40 -and $r.Obj.settings.temperature -eq 2) 'settings normalised (bad number -> default, clamp temperature)'
    $r = Invoke-Api 'POST' '/api/settings' @{ settings = @{ inference = @{ base_url = "$script:MockBase/v1"; model = 'mock-model'; api = 'openai' }; approvals = 'ask_writes' } }
    $r = Invoke-Api 'POST' '/api/test-connection' @{ base_url = "$script:MockBase/v1"; model = 'mock-model'; api = 'openai' }
    Assert-True ($r.Obj.ok -and $r.Obj.reply -eq 'OK') "test-connection: $($r.Raw)"
    $r = Invoke-Api 'POST' '/api/detect-models' @{ base_url = "$script:MockBase/v1" }
    Assert-True (@($r.Obj.endpoints | Where-Object { $_.models -contains 'mock-model' }).Count -ge 1) 'detect-models finds the configured server'

    # ------------------------------------------------------------------ credentials
    $r = Invoke-Api 'POST' '/api/credentials' @{ action = 'save'; name = 'lab-win'; kind = 'windows'; username = 'LAB\admin'; secret = $Secret; note = 'domain admin' }
    Assert-True ($r.Status -eq 200 -and $r.Obj.credential.hasSecret -and $r.Obj.credential.name -eq 'lab-win') "credential save: $($r.Status)"
    $r = Invoke-Api 'POST' '/api/credentials' @{ action = 'save'; name = 'lab-vc'; kind = 'vsphere'; username = 'administrator@vsphere.local'; secret = $Secret; note = 'vcenter vc01' }
    $r = Invoke-Api 'GET' '/api/credentials'
    $creds = @($r.Obj.credentials)
    Assert-True ($creds.Count -eq 2 -and @($creds | Where-Object { $_.hasSecret }).Count -eq 2) 'credential list shows two with hasSecret'
    Assert-True (@($creds | Where-Object { $_.PSObject.Properties.Name -contains 'secret' }).Count -eq 0) 'credential list has no secret field'
    $r = Invoke-Api 'POST' '/api/credentials' @{ action = 'save'; name = 'lab-win'; kind = 'windows'; username = 'LAB\admin2' }
    $r = Invoke-Api 'GET' '/api/credentials'
    $lw = @($r.Obj.credentials | Where-Object { $_.name -eq 'lab-win' })[0]
    Assert-True ($lw.username -eq 'LAB\admin2' -and $lw.hasSecret -and $lw.note -eq 'domain admin') 'update without secret keeps secret and note'
    $r = Invoke-Api 'POST' '/api/credentials' @{ action = 'save'; name = 'bad name!'; kind = 'windows'; username = 'x'; secret = $Secret }
    Assert-True ($r.Status -eq 400 -and $r.Raw -match 'name') "bad credential name -> 400: $($r.Raw)"
    $r = Invoke-Api 'POST' '/api/credentials' @{ action = 'save'; name = 'okname'; kind = 'telnet'; username = 'x'; secret = $Secret }
    Assert-True ($r.Status -eq 400 -and $r.Raw -match 'Kind') "bad kind -> 400: $($r.Raw)"
    $r = Invoke-ByobHttpRequest -Url "$script:Base/api/credentials" -Method 'POST' -Body ('{"action":"save","secret":"' + $Secret + '"') -TimeoutSec 10
    [void]$script:Responses.AppendLine($r.Body)
    Assert-True ($r.Status -eq 400 -and $r.Body -notmatch [regex]::Escape($Secret)) 'malformed JSON -> 400 without echoing the body'
    $r = Invoke-Api 'POST' '/api/credentials' @{ action = 'save'; name = 'tmp1'; kind = 'linux'; username = 'root'; keyPath = '/keys/id'; note = 'n' }
    $r = Invoke-Api 'POST' '/api/credentials' @{ action = 'delete'; name = 'tmp1' }
    Assert-True ($r.Obj.ok -and $r.Obj.removed) 'credential delete'
    Assert-True ((Invoke-Api 'GET' '/api/state').Obj.credentialCount -eq 2) 'state credentialCount 2'

    # ------------------------------------------------------------------ scope
    $r = Invoke-Api 'GET' "/api/scope?workspaceId=$ws1Id"
    Assert-True ($r.Status -eq 200 -and -not $r.Obj.exists) 'scope GET before set: exists=false'
    foreach ($bad in @(@{ e = '10.9.0.0/33'; m = '32' }, @{ e = '10.0.0.0/7'; m = 'wider than /8' }, @{ e = '0.0.0.0/0'; m = 'whole internet' }, @{ e = '*'; m = 'every host' }, @{ e = 'bad host!'; m = 'not an IPv4' }, @{ e = '300.1.1.1'; m = '0-255' })) {
        $r = Invoke-Api 'POST' '/api/scope' @{ workspaceId = $ws1Id; allow = @('10.9.0.0/24', $bad.e); deny = @() }
        Assert-True ($r.Status -eq 400 -and $r.Raw -match [regex]::Escape($bad.m)) "scope rejects '$($bad.e)': $($r.Raw)"
    }
    Assert-True (-not (Test-Path (Join-Path (Join-Path $ws1 '.byob') 'scope.json'))) 'rejected scope wrote no file'
    $r = Invoke-Api 'POST' '/api/scope' @{ workspaceId = $ws1Id; allow = @('10.9.0.0/24', 'esx01', '*.lab.local', '10.0.0.0/8'); deny = @('10.9.0.1') }
    Assert-True ($r.Status -eq 200 -and @($r.Obj.allow).Count -eq 4 -and @($r.Obj.deny).Count -eq 1) "scope save: $($r.Raw)"
    $r = Invoke-Api 'GET' "/api/scope?workspaceId=$ws1Id"
    Assert-True ($r.Obj.exists -and @($r.Obj.allow) -contains 'esx01') 'scope GET after set'
    $st = (Invoke-Api 'GET' '/api/state').Obj
    Assert-True (@($st.workspaces | Where-Object { $_.id -eq $ws1Id })[0].scopeExists -and @($st.workspaces | Where-Object { $_.id -eq $ws2Id })[0].scopeExists -eq $false) 'state scopeExists per workspace'

    # ------------------------------------------------------------------ basic chat turn
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $r = Send-Turn $chat 'SCENARIO:basic check the year'
    Assert-True ($r.Status -eq 200) 'send basic'
    $ev = Wait-Turn $chat 60
    $fin = Get-FinalEvent $ev
    Assert-True ($fin.type -eq 'done' -and $fin.message.text -eq 'Basic done.') "basic final message: $($fin | ConvertTo-Json -Compress -Depth 8)"
    Assert-True (@($ev | Where-Object { $_.type -eq 'progress' }).Count -eq 3) 'three progress events'
    $doneSteps = @($ev | Where-Object { $_.type -eq 'tool_done' } | ForEach-Object { $_.step })
    Assert-True ($doneSteps.Count -eq 3 -and $doneSteps[0].status -eq 'done' -and $doneSteps[0].preview -match 'raw/' -and $doneSteps[2].status -eq 'blocked' -and $doneSteps[2].preview -match '^BLOCKED') 'tool steps: query ran, kb written, Remove-Item BLOCKED'
    Assert-True (@($ev | Where-Object { $_.type -eq 'approval_needed' }).Count -eq 0) 'read tools ran without approval in ask_writes'
    Assert-True (Test-Path (Join-Path (Join-Path $ws1 'kb') '00-index.md')) 'kb_write created kb/00-index.md'
    $log = Get-MockLog
    $sys = [string]$log[0].messages[0].content
    Assert-True ($sys -match 'lab-win' -and $sys -match 'lab-vc' -and $sys -match 'PLUGINS' -and $sys -notmatch [regex]::Escape($Secret)) 'system prompt has credential names, plugin note, no secret'
    Assert-True ($sys -notmatch '(?i)outlook') 'system prompt has no Outlook text'
    $tn = @($log[0].toolNames)
    Assert-True ($tn -contains 'net_query' -and $tn -contains 'run_command' -and $tn -contains 'plg_portscan_scan' -and @($tn | Where-Object { $_ -match 'outlook' }).Count -eq 0 -and $tn.Count -eq 18) "tool list offered to the model ($($tn.Count)): $($tn -join ',')"

    # ------------------------------------------------------------------ approvals
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:approve run something'
    $script:apr = $null
    $ev = Wait-Turn $chat 60 { param($e) if ($e.type -eq 'approval_needed') { $script:apr = $e.approval; $null = Invoke-Api 'POST' '/api/chat/approve' @{ chatId = $chat; approved = $true; id = $e.approval.id } } }
    Assert-True ($script:apr.tool -eq 'run_command' -and $script:apr.warning -match 'NOT checked') 'run_command asked for approval with gate warning'
    $st1 = @($ev | Where-Object { $_.type -eq 'tool_done' })[0].step
    Assert-True ($st1.status -eq 'done' -and $st1.preview -match 'approved-run-ok') "approved run_command ran: $($st1.preview)"
    Assert-True ((Get-FinalEvent $ev).message.text -eq 'Approve scenario done.') 'approve final'

    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:deny run something'
    $ev = Wait-Turn $chat 60 { param($e) if ($e.type -eq 'approval_needed') { $null = Invoke-Api 'POST' '/api/chat/approve' @{ chatId = $chat; approved = $false; id = $e.approval.id } } }
    $st1 = @($ev | Where-Object { $_.type -eq 'tool_done' })[0].step
    Assert-True ($st1.status -eq 'denied' -and $st1.preview -notmatch 'should-not-appear') 'denied run_command did not run'
    Assert-True (@($ev | Where-Object { $_.type -eq 'tool_start' }).Count -eq 0) 'no tool_start for denied call'
    Assert-True ((Get-FinalEvent $ev).message.text -eq 'Deny scenario done.') 'deny final'
    $r = Invoke-Api 'POST' '/api/chat/approve' @{ chatId = $chat; approved = $true }
    Assert-True (-not $r.Obj.ok) 'stray approve with nothing pending is ignored'

    # live approval mode: switch to ask_all while a turn waits; the next read-only call must ask
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:approve'
    $script:asked = @()
    $ev = Wait-Turn $chat 60 {
        param($e)
        if ($e.type -eq 'approval_needed') {
            $script:asked += $e.approval.tool
            $null = Set-TestSettings @{ approvals = 'ask_all' }
            $null = Invoke-Api 'POST' '/api/chat/approve' @{ chatId = $chat; approved = $true; id = $e.approval.id }
        }
    }
    $null = Set-TestSettings @{ approvals = 'ask_writes' }
    Assert-True ($script:asked.Count -eq 1 -and (Get-FinalEvent $ev).message.text -eq 'Approve scenario done.') 'settings change during a turn does not break it'
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Set-TestSettings @{ approvals = 'ask_all' }
    $null = Send-Turn $chat 'SCENARIO:basic'
    $script:asked = @()
    $ev = Wait-Turn $chat 60 { param($e) if ($e.type -eq 'approval_needed') { $script:asked += $e.approval.tool; if ($script:asked.Count -eq 1) { $null = Set-TestSettings @{ approvals = 'ask_writes' } }; $null = Invoke-Api 'POST' '/api/chat/approve' @{ chatId = $chat; approved = $true; id = $e.approval.id } } }
    Assert-True ($script:asked.Count -eq 1 -and $script:asked[0] -eq 'net_query') "approval mode change applies to the running turn (asked: $($script:asked -join ','))"

    # ------------------------------------------------------------------ loop guard + bad streak
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:loop'
    $ev = Wait-Turn $chat 60
    $steps = @($ev | Where-Object { $_.type -eq 'tool_done' } | ForEach-Object { $_.step })
    Assert-True ($steps.Count -eq 6 -and $steps[0].preview -match '^BLOCKED' -and $steps[1].preview -match '^BLOCKED' -and $steps[2].preview -match '^LOOP GUARD') 'third identical call hits LOOP GUARD'
    Assert-True (@($ev | Where-Object { $_.type -eq 'nudge' -and $_.kind -eq 'bad_streak' }).Count -eq 1) 'bad-streak nudge event'
    $log = Get-MockLog
    $lastReq = $log[$log.Count - 1]
    $lastUser = @($lastReq.messages | Where-Object { $_.role -eq 'user' } | Select-Object -Last 1)[0]
    Assert-True ([string]$lastUser.content -match 'Stop repeating' -and [string]$lastUser.content -match 'frontier') 'model received the stop-repeating message'
    Assert-True ((Get-FinalEvent $ev).message.text -eq 'Loop done.') 'loop final'

    # ------------------------------------------------------------------ retry + failure
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:retry'
    $ev = Wait-Turn $chat 60
    Assert-True (@($ev | Where-Object { $_.type -eq 'retry' }).Count -eq 1 -and (Get-FinalEvent $ev).message.text -eq 'Recovered after retry.') 'transient HTTP 500 retried then recovered'
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:fail'
    $ev = Wait-Turn $chat 60
    $fin = Get-FinalEvent $ev
    Assert-True ($fin.type -eq 'error' -and $fin.text -match 'failed 3 times' -and $fin.text -match 'model exploded badly' -and $fin.text -match '500') "persistent failure -> error with body: $($fin.text)"
    Assert-True (@($ev | Where-Object { $_.type -eq 'retry' }).Count -eq 2) 'two retries before giving up'
    Assert-True (@(Get-MockLog).Count -eq 3) 'three attempts reached the model'

    # ------------------------------------------------------------------ compaction
    $null = Set-TestSettings @{ context_char_budget = 16000 }
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:compact'
    $ev = Wait-Turn $chat 90
    Assert-True (@($ev | Where-Object { $_.type -eq 'compacted' }).Count -ge 1) 'compacted event emitted'
    Assert-True ((Get-FinalEvent $ev).message.text -eq 'Compact done.') "compact final: $((Get-FinalEvent $ev).text)"
    $log = Get-MockLog
    $sumReq = @($log | Where-Object { -not $_.hasTools })
    Assert-True ($sumReq.Count -ge 1 -and $sumReq[0].raw -match 'Progress summary request') 'summary call made without tools'
    $after = @($log | Where-Object { $_.hasTools -and $_.raw -match 'Progress summary so far' })
    Assert-True ($after.Count -ge 1 -and $after[0].raw -match 'SUMMARY: long queries ran' -and $after[0].raw -match 'SCENARIO:compact') 'rebuilt conversation = original request + summary'
    $null = Set-TestSettings @{ context_char_budget = 240000 }

    # ------------------------------------------------------------------ explore mode
    Reset-Mock
    $chat = New-TestChat $ws2Id
    $t0 = Get-Date
    $null = Send-Turn $chat '' 'explore'
    $ev = Wait-Turn $chat 30
    $fin = Get-FinalEvent $ev
    Assert-True ($fin.message.endReason -eq 'no_scope' -and $fin.message.text -match 'Settings > Scope') "explore without scope refused: $($fin.message.text)"
    Assert-True (@(Get-MockLog).Count -eq 0) 'explore without scope did not call the model'

    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:explore' 'explore'
    $ev = Wait-Turn $chat 90
    $fin = Get-FinalEvent $ev
    Assert-True ($fin.type -eq 'done' -and $fin.message.text -eq 'Explore complete.') "explore final: $($fin.message.text)"
    Assert-True (@($ev | Where-Object { $_.type -eq 'nudge' -and -not $_.kind }).Count -eq 1) 'explore auto-continue nudge once'
    Assert-True (@($ev | Where-Object { $_.type -eq 'progress' -and $_.mode -eq 'explore' -and $_.maxSteps -eq 300 }).Count -eq 5) 'five explore progress events (budget 300)'
    $log = Get-MockLog
    Assert-True ([string]$log[0].raw -match 'EXPLORE MODE' -and [string]$log[0].raw -match '10\.9\.0\.0/24' -and [string]$log[0].raw -match 'lab-vc') 'explore instruction includes scope and vsphere credential'
    Assert-True (@($log | Where-Object { $_.raw -match 'Continue exploring: take the next open frontier item.' }).Count -ge 1) 'model received the continue nudge'
    $kb = (Invoke-Api 'GET' "/api/kb?workspaceId=$ws1Id").Obj
    Assert-True ($kb.frontier.open -eq 0 -and $kb.frontier.done -eq 2) "frontier empty after explore: $($kb.frontier | ConvertTo-Json -Compress)"
    $chatState = @((Invoke-Api 'GET' '/api/state').Obj.chats | Where-Object { $_.id -eq $chat })[0]
    Assert-True ($chatState.messages[0].text -eq 'Explore this network - SCENARIO:explore' -and $chatState.messages[0].mode -eq 'explore') 'explore user message stored with a short display text'

    # step budget (explore, 3 steps)
    $null = Set-TestSettings @{ max_steps_explore = 3 }
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:budget' 'explore'
    $ev = Wait-Turn $chat 60
    $fin = Get-FinalEvent $ev
    Assert-True ($fin.message.endReason -eq 'budget' -and $fin.message.text -match 'Step budget reached: used 3 of 3' -and $fin.message.text -match 'Frontier: 3 open, 2 done' -and $fin.message.text -match 'kb/frontier.json' -and $fin.message.text -match 'Press Explore again') "budget message: $($fin.message.text)"
    $null = Set-TestSettings @{ max_steps_explore = 300 }

    # ------------------------------------------------------------------ Stop
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:slow'
    Start-Sleep -Milliseconds 1500
    $t0 = Get-Date
    $null = Invoke-Api 'POST' '/api/chat/stop' @{ chatId = $chat }
    $ev = Wait-Turn $chat 20
    $el = ((Get-Date) - $t0).TotalSeconds
    Assert-True ((Get-FinalEvent $ev).message.endReason -eq 'stopped' -and $el -lt 5) "Stop during a model call ends the turn promptly ($([Math]::Round($el,1))s)"

    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:stoprun'
    $script:stopT0 = $null
    $ev = Wait-Turn $chat 30 { param($e) if ($e.type -eq 'approval_needed') { $script:stopT0 = Get-Date; $null = Invoke-Api 'POST' '/api/chat/stop' @{ chatId = $chat } } }
    $el = ((Get-Date) - $script:stopT0).TotalSeconds
    Assert-True ((Get-FinalEvent $ev).message.endReason -eq 'stopped' -and $el -lt 5 -and @($ev | Where-Object { $_.type -eq 'tool_start' }).Count -eq 0) "Stop during an approval wait ($([Math]::Round($el,1))s), tool not run"

    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:stoprun'
    $script:started = $false
    $ev = Wait-Turn $chat 40 {
        param($e)
        if ($e.type -eq 'approval_needed') { $null = Invoke-Api 'POST' '/api/chat/approve' @{ chatId = $chat; approved = $true; id = $e.approval.id } }
        if ($e.type -eq 'tool_start') { $script:started = $true; Start-Sleep -Milliseconds 1500; $script:stopT0 = Get-Date; $null = Invoke-Api 'POST' '/api/chat/stop' @{ chatId = $chat } }
    }
    $el = ((Get-Date) - $script:stopT0).TotalSeconds
    $stp = @($ev | Where-Object { $_.type -eq 'tool_done' })[0].step
    Assert-True ($script:started -and (Get-FinalEvent $ev).message.endReason -eq 'stopped' -and $el -lt 6) "Stop kills a running command ($([Math]::Round($el,1))s)"
    Assert-True ($stp.preview -match 'stopped by user' -and $stp.preview -notmatch 'never-printed') "killed command output: $($stp.preview)"

    # ------------------------------------------------------------------ delegate (read-only subagent)
    Reset-Mock
    $chat = New-TestChat $ws1Id
    $null = Send-Turn $chat 'SCENARIO:delegate'
    $ev = Wait-Turn $chat 60
    $log = Get-MockLog
    $subReq = @($log | Where-Object { $_.scenario -eq 'sub' })
    $subTools = @($subReq | ForEach-Object { $_.toolNames } | Select-Object -Unique)
    Assert-True ($subReq.Count -eq 2 -and $subTools -contains 'kb_read' -and $subTools -notcontains 'run_command' -and $subTools -notcontains 'write_file' -and $subTools -notcontains 'delegate' -and $subTools -notcontains 'plg_portscan_scan') "subagent got read tools only: $($subTools -join ',')"
    $dstep = @($ev | Where-Object { $_.type -eq 'tool_done' })[0].step
    Assert-True ($dstep.preview -match 'Sub summary' -and (Get-FinalEvent $ev).message.text -eq 'Delegate done.') 'delegate returned the subagent summary'

    # ------------------------------------------------------------------ kb API
    $kb = (Invoke-Api 'GET' "/api/kb?workspaceId=$ws1Id").Obj
    $net = @($kb.files | Where-Object { $_.path -eq 'kb/20-network.md' })[0]
    Assert-True ($net.heading -eq 'Network' -and $net.size -gt 0 -and $kb.rawCount -ge 1) 'kb listing has heading, size, raw count'
    $r = Invoke-Api 'GET' "/api/kb/file?workspaceId=$ws1Id&path=kb/20-network.md"
    Assert-True ($r.Status -eq 200 -and $r.Obj.content -match '10\.9\.0\.0/24') 'kb file read'
    $rawName = @(Get-ChildItem (Join-Path $ws1 'raw') -File)[0].Name
    $r = Invoke-Api 'GET' "/api/kb/file?workspaceId=$ws1Id&path=raw/$rawName"
    Assert-True ($r.Status -eq 200 -and $r.Obj.content -match '# via:') 'raw file read'
    foreach ($bad in @('kb/../../data/credentials.json', '../x', 'kb/..%2F..%2Fx', '.byob/scope.json', 'kb//x.md', '/etc/passwd', 'raw/../kb/x')) {
        $r = Invoke-Api 'GET' ("/api/kb/file?workspaceId=$ws1Id&path=" + [uri]::EscapeDataString($bad))
        Assert-True ($r.Status -eq 400) "kb file traversal rejected: $bad -> $($r.Status)"
    }
    $r = Invoke-Api 'GET' "/api/kb/file?workspaceId=$ws1Id&path=kb/missing.md"
    Assert-True ($r.Status -eq 404) 'missing kb file -> 404'

    # ------------------------------------------------------------------ plugins
    $pl = (Invoke-Api 'GET' "/api/plugins?workspaceId=$ws1Id").Obj
    $sp = @($pl.plugins | Where-Object { $_.id -eq 'app:sample-portscan' })[0]
    Assert-True ($sp.valid -and -not $sp.trusted -and $sp.tools[0].exposed -eq 'plg_portscan_scan' -and $sp.tools[0].effectiveAccess -eq 'execute') 'sample plugin listed, untrusted, forced execute'
    $badDir = Join-Path (Join-Path (Join-Path $ws1 '.byob') 'plugins') 'broken'
    New-Item -ItemType Directory -Force $badDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $badDir 'byob-plugin.json'), '{ not json')
    $pl = (Invoke-Api 'GET' "/api/plugins?workspaceId=$ws1Id").Obj
    $bp = @($pl.plugins | Where-Object { $_.id -eq 'workspace:broken' })[0]
    Assert-True ($bp -and -not $bp.valid -and $bp.error -match 'JSON') 'malformed workspace plugin reported'

    $openL = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
    $openL.Start()
    $openPort = $openL.LocalEndpoint.Port
    $closedPort = Get-FreePort
    try {
        Reset-Mock
        $chat = New-TestChat $ws1Id
        $null = Send-Turn $chat "SCENARIO:plugin PORTS:$openPort,$closedPort"
        $script:aprs = @()
        $ev = Wait-Turn $chat 90 { param($e) if ($e.type -eq 'approval_needed') { $script:aprs += $e.approval; $null = Invoke-Api 'POST' '/api/chat/approve' @{ chatId = $chat; approved = $true; id = $e.approval.id } } }
        Assert-True ($script:aprs.Count -eq 2 -and $script:aprs[0].mustConfirm -and $script:aprs[0].warning -match 'new or has changed') 'untrusted plugin asks every time with the trust warning'
        $ps = @($ev | Where-Object { $_.type -eq 'tool_done' } | ForEach-Object { $_.step })
        Assert-True ($ps.Count -eq 2 -and $ps[0].preview -match "port ${openPort}: open" -and $ps[0].preview -match "port ${closedPort}: closed") "plugin scanned in-scope loopback: $($ps[0].preview)"
        Assert-True ($ps[1].preview -match 'REFUSED' -and $ps[1].preview -match 'outside the workspace scope') "plugin refused out-of-scope target: $($ps[1].preview)"

        $r = Invoke-Api 'POST' '/api/plugins' @{ action = 'trust'; id = 'app:sample-portscan'; workspaceId = $ws1Id; hash = 'deadbeef' }
        Assert-True ($r.Status -eq 400 -and $r.Raw -match 'changed since') 'trust with stale hash refused'
        $r = Invoke-Api 'POST' '/api/plugins' @{ action = 'trust'; id = 'app:sample-portscan'; workspaceId = $ws1Id; hash = $sp.hash }
        Assert-True ($r.Status -eq 200 -and $r.Obj.ok) 'trust sample plugin'
        $sp2 = @((Invoke-Api 'GET' "/api/plugins?workspaceId=$ws1Id").Obj.plugins | Where-Object { $_.id -eq 'app:sample-portscan' })[0]
        Assert-True ($sp2.trusted -and $sp2.tools[0].effectiveAccess -eq 'read') 'trusted plugin uses declared read access'
        Reset-Mock
        $chat = New-TestChat $ws1Id
        $null = Send-Turn $chat "SCENARIO:plugin PORTS:$openPort,$closedPort"
        $ev = Wait-Turn $chat 90 { param($e) if ($e.type -eq 'approval_needed') { $null = Invoke-Api 'POST' '/api/chat/approve' @{ chatId = $chat; approved = $false; id = $e.approval.id } } }
        Assert-True (@($ev | Where-Object { $_.type -eq 'approval_needed' }).Count -eq 0 -and @($ev | Where-Object { $_.type -eq 'tool_start' }).Count -eq 2) 'trusted read plugin runs without asking'
        $r = Invoke-Api 'POST' '/api/plugins' @{ action = 'untrust'; id = 'app:sample-portscan' }
        $sp3 = @((Invoke-Api 'GET' "/api/plugins?workspaceId=$ws1Id").Obj.plugins | Where-Object { $_.id -eq 'app:sample-portscan' })[0]
        Assert-True ($r.Obj.ok -and -not $sp3.trusted) 'untrust sample plugin'
    } finally { $openL.Stop() }

    # ------------------------------------------------------------------ static checks over the run
    Reset-Mock
    Assert-True ($script:ModelRequests -gt 30 -and $script:Violations.Count -eq 0) "tool-call pairing valid and no secret in any of $($script:ModelRequests) model requests: $($script:Violations -join '; ')"
    $r = Invoke-Api 'GET' '/api/state'
    $esc = [regex]::Escape($Secret)
    Assert-True ($script:Responses.ToString() -notmatch $esc) 'secret never appeared in any API response or event'
    $leak = @()
    foreach ($f in @(Get-ChildItem $dataDir -Recurse -File) + @(Get-ChildItem $logDir -Recurse -File) + @(Get-ChildItem $ws1 -Recurse -File) + @(Get-ChildItem $ws2 -Recurse -File)) {
        if ($f.Name -eq 'credentials.json') { continue }
        if ([IO.File]::ReadAllText($f.FullName) -match $esc) { $leak += $f.FullName }
    }
    Assert-True ($leak.Count -eq 0) "secret not in chats, settings, logs, kb or raw files: $($leak -join ', ')"
    $credText = [IO.File]::ReadAllText((Join-Path $dataDir 'credentials.json'))
    Assert-True ($credText -match '"protected":"none"') 'test runtime uses the TEST-ONLY base64 fallback (no DPAPI on Linux; not asserted as encryption)'
} catch {
    $script:Fail++
    Write-Host "FAIL (exception): $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
} finally {
    try { $null = Invoke-ByobHttpRequest -Url "$script:Base/__fleethacker/shutdown" -Method 'POST' -Headers @{ 'X-FleetHacker-Shutdown' = '1' } -Body '{}' -TimeoutSec 5 } catch { }
    if ($hostProc) { if (-not $hostProc.WaitForExit(8000)) { try { $hostProc.Kill() } catch { } } }
    if ($mockProc -and -not $mockProc.HasExited) { try { $mockProc.Kill() } catch { } }
    if ($hostProc -and $script:Fail -gt 0) {
        $errText = ''
        try { $errText = $hostProc.StandardError.ReadToEnd() } catch { }
        if ($errText) { Write-Host "host stderr:`n$errText" }
        foreach ($lf in @(Get-ChildItem $logDir -File -ErrorAction SilentlyContinue)) { Write-Host "--- $($lf.Name)"; Get-Content $lf.FullName | Select-Object -Last 30 | ForEach-Object { Write-Host $_ } }
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ("Host smoke: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
