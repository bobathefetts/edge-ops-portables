# BYOB Explorer LLM client (OpenAI-compatible /v1/chat/completions, Anthropic /v1/messages,
# prompt-based tool fallback). Windows PowerShell 5.1 and PowerShell 7. ASCII only.
#
# Conversation format used by callers is always OpenAI-style:
#   @{ role='user'; content='text' | @(parts) }
#   @{ role='assistant'; content='text'; tool_calls=@(@{ id; type='function'; function=@{ name; arguments='{json}' } }) }
#   @{ role='tool'; tool_call_id='...'; content='result' }
# The Anthropic branch converts this format on the way out.
#
# HTTP is done with HttpWebRequest asynchronously so a Stop request ($CancelState.cancel = $true)
# aborts a waiting model call within about 200 ms, and the timeout is enforced by this code.
# Error messages include the server's response body (truncated) but never request headers or keys.

function Find-LocalLlmEndpoints {
    param([string]$BaseUrl = '', [string]$ApiKey = '')
    $probes = New-Object System.Collections.ArrayList
    if ($BaseUrl) {
        [void]$probes.Add(@{ name = 'Configured server'; url = $BaseUrl.Trim().TrimEnd('/'); api = 'openai' })
    }
    foreach ($p in @(
        @{ name = 'llama-server'; url = 'http://127.0.0.1:8080/v1'; api = 'openai' },
        @{ name = 'vLLM'; url = 'http://127.0.0.1:8000/v1'; api = 'openai' },
        @{ name = 'Ollama'; url = 'http://127.0.0.1:11434/v1'; api = 'openai' },
        @{ name = 'LM Studio'; url = 'http://127.0.0.1:1234/v1'; api = 'openai' }
    )) { [void]$probes.Add($p) }
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($p in $probes) {
        try {
            $headers = @{}
            if ($ApiKey -and $p.name -eq 'Configured server') { $headers['Authorization'] = "Bearer $ApiKey" }
            $resp = Invoke-ByobHttpRequest -Url ($p.url + '/models') -Method 'GET' -Headers $headers -TimeoutSec 3
            if ($resp.Status -ne 200) { continue }
            $obj = ConvertFrom-Json -InputObject $resp.Body
            $models = @($obj.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
            $found.Add([ordered]@{ name = $p.name; url = $p.url; api = $p.api; models = $models })
        } catch { }
    }
    return ,$found.ToArray()
}

function Get-ByobInnerWebException {
    param($Exception)
    $e = $Exception
    while ($e) {
        if ($e -is [System.Net.WebException]) { return $e }
        $e = $e.InnerException
    }
    return $null
}

function Wait-ByobAsync {
    # Waits on an IAsyncResult, honouring Stop and a deadline. Aborts the request on either.
    param($AsyncResult, $Request, [datetime]$Deadline, $CancelState, [int]$TimeoutSec)
    while (-not $AsyncResult.AsyncWaitHandle.WaitOne(200)) {
        if ($CancelState -and $CancelState.cancel) {
            try { $Request.Abort() } catch { }
            throw (New-Object System.OperationCanceledException 'Stopped by user.')
        }
        if ((Get-Date) -gt $Deadline) {
            try { $Request.Abort() } catch { }
            throw "Model request timed out after $TimeoutSec seconds (request_timeout_sec in Settings > Run limits)."
        }
    }
}

function Invoke-ByobHttpRequest {
    # Returns @{ Status = <int>; Body = <string> } for any HTTP response (including 4xx/5xx).
    # Throws on connection failure, timeout or cancel.
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Method = 'POST',
        [hashtable]$Headers = @{},
        [string]$Body = '',
        [int]$TimeoutSec = 600,
        $CancelState = $null
    )
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Proxy = $null          # the model server is on a private link; never route through a system proxy
    $req.AllowAutoRedirect = $false
    $req.KeepAlive = $false
    $req.Timeout = [Math]::Max(1000, $TimeoutSec * 1000)
    $req.ReadWriteTimeout = [Math]::Max(1000, $TimeoutSec * 1000)
    foreach ($k in $Headers.Keys) {
        if ($k -ieq 'Content-Type') { continue }
        $req.Headers[[string]$k] = [string]$Headers[$k]
    }
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSec))
    try {
        if ($Method -ne 'GET') {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $req.ContentType = 'application/json; charset=utf-8'
            $req.ContentLength = $bytes.Length
            $arS = $req.BeginGetRequestStream($null, $null)
            Wait-ByobAsync -AsyncResult $arS -Request $req -Deadline $deadline -CancelState $CancelState -TimeoutSec $TimeoutSec
            $stream = $req.EndGetRequestStream($arS)
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
        }
        $ar = $req.BeginGetResponse($null, $null)
        Wait-ByobAsync -AsyncResult $ar -Request $req -Deadline $deadline -CancelState $CancelState -TimeoutSec $TimeoutSec
        $resp = $null
        try {
            $resp = $req.EndGetResponse($ar)
        } catch {
            $we = Get-ByobInnerWebException $_.Exception
            if ($we -and $we.Response) { $resp = $we.Response } else { throw }
        }
        try {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
            $reader.Close()
            return @{ Status = [int]$resp.StatusCode; Body = [string]$text }
        } finally { try { $resp.Close() } catch { } }
    } catch [System.OperationCanceledException] {
        throw
    } catch {
        $ex = $_.Exception
        if ($ex -is [System.OperationCanceledException]) { throw }
        if ($ex.Message -match 'timed out after') { throw }
        $msg = $ex.Message
        $we = Get-ByobInnerWebException $ex
        if ($we) { $msg = $we.Message }
        throw "Could not reach the model server at $Url : $msg"
    }
}

function Get-ByobBodyExcerpt {
    param([string]$Body)
    $b = ([string]$Body).Trim()
    if ($b.Length -gt 1500) { $b = $b.Substring(0, 1500) + '...' }
    if (-not $b) { $b = '(empty response body)' }
    return $b
}

function ConvertTo-ByobToolCallList {
    # Normalises parsed calls into the OpenAI tool_calls shape used in the conversation.
    param($Calls)
    $out = @()
    foreach ($c in @($Calls)) {
        if ($null -eq $c) { continue }
        $argText = [string]$c.rawArgs
        if (-not $argText) {
            try { $argText = ($c.args | ConvertTo-Json -Depth 12 -Compress) } catch { $argText = '{}' }
            if (-not $argText) { $argText = '{}' }
        }
        $out += @{ id = [string]$c.id; type = 'function'; function = @{ name = [string]$c.name; arguments = $argText } }
    }
    return ,$out
}

function ConvertTo-ByobAnthropicMessages {
    param([array]$Messages)
    $out = New-Object System.Collections.ArrayList
    $pendingResults = $null
    foreach ($m in $Messages) {
        $role = [string]$m.role
        if ($role -eq 'system') { continue }
        if ($role -eq 'tool') {
            if ($null -eq $pendingResults) { $pendingResults = New-Object System.Collections.ArrayList }
            [void]$pendingResults.Add(@{ type = 'tool_result'; tool_use_id = [string]$m.tool_call_id; content = [string]$m.content })
            continue
        }
        if ($null -ne $pendingResults) {
            [void]$out.Add(@{ role = 'user'; content = @($pendingResults.ToArray()) })
            $pendingResults = $null
        }
        if ($role -eq 'assistant') {
            $blocks = @()
            if ([string]$m.content) { $blocks += @{ type = 'text'; text = [string]$m.content } }
            foreach ($tc in @($m.tool_calls)) {
                if ($null -eq $tc) { continue }
                $inObj = [pscustomobject]@{}
                try { if ($tc.function.arguments) { $inObj = ConvertFrom-Json -InputObject ([string]$tc.function.arguments) } } catch { }
                $blocks += @{ type = 'tool_use'; id = [string]$tc.id; name = [string]$tc.function.name; input = $inObj }
            }
            if ($blocks.Count -eq 0) { $blocks += @{ type = 'text'; text = '(no text)' } }
            [void]$out.Add(@{ role = 'assistant'; content = $blocks })
        } else {
            $content = $m.content
            if ($content -is [array]) {
                $parts = @()
                foreach ($p in $content) {
                    if ($p.type -eq 'image_url') {
                        $u = [string]$p.image_url.url
                        $mm = [regex]::Match($u, '^data:([^;]+);base64,(.*)$')
                        if ($mm.Success) { $parts += @{ type = 'image'; source = @{ type = 'base64'; media_type = $mm.Groups[1].Value; data = $mm.Groups[2].Value } } }
                    } else {
                        $parts += @{ type = 'text'; text = [string]$p.text }
                    }
                }
                [void]$out.Add(@{ role = 'user'; content = $parts })
            } else {
                [void]$out.Add(@{ role = 'user'; content = [string]$content })
            }
        }
    }
    if ($null -ne $pendingResults) { [void]$out.Add(@{ role = 'user'; content = @($pendingResults.ToArray()) }) }
    return ,$out.ToArray()
}

function Invoke-ByobLlmOnce {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Model,
        [string]$ApiKey = '',
        [string]$ApiKind = 'auto',
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][array]$Messages,
        [AllowEmptyCollection()][array]$Tools = @(),
        [double]$Temperature = 0.2,
        [int]$MaxTokens = 4096,
        [int]$TimeoutSec = 600,
        $CancelState = $null
    )

    $cleanUrl = $BaseUrl.Trim().TrimEnd('/')
    $isAnthropic = ($ApiKind -eq 'anthropic') -or ($ApiKind -eq 'auto' -and $cleanUrl -match 'anthropic\.com')

    if ($isAnthropic) {
        # UNTESTED against a real Anthropic endpoint in this build (no network in the test runtime).
        $headers = @{ 'anthropic-version' = '2023-06-01' }
        if ($ApiKey) { $headers['x-api-key'] = $ApiKey }
        $antTools = @($Tools | ForEach-Object { @{ name = $_.name; description = $_.description; input_schema = $_.params } })
        $payload = [ordered]@{
            model = $Model
            max_tokens = $MaxTokens
            system = $SystemPrompt
            messages = @(ConvertTo-ByobAnthropicMessages -Messages $Messages | ForEach-Object { $_ })   # fresh array (PS 5.1 JSON quirk)
            temperature = $Temperature
        }
        if ($antTools.Count -gt 0) { $payload['tools'] = $antTools }
        $jsonBody = ($payload | ConvertTo-Json -Depth 16 -Compress)
        $r = Invoke-ByobHttpRequest -Url "$cleanUrl/messages" -Headers $headers -Body $jsonBody -TimeoutSec $TimeoutSec -CancelState $CancelState
        if ($r.Status -lt 200 -or $r.Status -ge 300) { throw "Model server returned HTTP $($r.Status): $(Get-ByobBodyExcerpt $r.Body)" }
        $resp = ConvertFrom-Json -InputObject $r.Body
        $textOut = New-Object System.Text.StringBuilder
        $thinkOut = New-Object System.Text.StringBuilder
        $calls = New-Object System.Collections.Generic.List[object]
        foreach ($blk in @($resp.content)) {
            if ($blk.type -eq 'text') { [void]$textOut.Append([string]$blk.text) }
            elseif ($blk.type -eq 'thinking') { [void]$thinkOut.Append([string]$blk.thinking) }
            elseif ($blk.type -eq 'tool_use') { $calls.Add(@{ id = [string]$blk.id; name = [string]$blk.name; args = $blk.input; rawArgs = '' }) }
        }
        $arr = $calls.ToArray()
        return [pscustomobject]@{
            Text = $textOut.ToString(); Thinking = $thinkOut.ToString(); ToolCalls = $arr
            RawToolCalls = (ConvertTo-ByobToolCallList $arr); ApiKind = 'anthropic'
        }
    }

    # OpenAI-compatible /chat/completions
    $headers = @{}
    if ($ApiKey) { $headers['Authorization'] = "Bearer $ApiKey" }
    $oaiMsgs = @(@{ role = 'system'; content = $SystemPrompt }) + @($Messages)
    $oaiTools = @($Tools | ForEach-Object { @{ type = 'function'; function = @{ name = $_.name; description = $_.description; parameters = $_.params } } })
    $payload = [ordered]@{ model = $Model; messages = $oaiMsgs; temperature = $Temperature; max_tokens = $MaxTokens }
    if ($oaiTools.Count -gt 0) {
        $payload['tools'] = $oaiTools
        $payload['tool_choice'] = 'auto'
    }
    $jsonBody = ($payload | ConvertTo-Json -Depth 16 -Compress)
    $r = Invoke-ByobHttpRequest -Url "$cleanUrl/chat/completions" -Headers $headers -Body $jsonBody -TimeoutSec $TimeoutSec -CancelState $CancelState
    $usedFallback = $false
    if (($r.Status -eq 400 -or $r.Status -eq 422) -and $oaiTools.Count -gt 0 -and $r.Body -match '(?i)tool') {
        # The server rejected the tools parameter: retry once with a prompt-based tool schema.
        $toolSummary = ($Tools | ForEach-Object { "- $($_.name): $($_.description)" }) -join "`n"
        $fallbackSys = "$SystemPrompt`n`nIf you need to call a tool, respond ONLY with a JSON block:`n``````json`n{""tool"":""<name>"",""args"":{...}}`n```````nAvailable tools:`n$toolSummary"
        $fbMsgs = @(@{ role = 'system'; content = $fallbackSys }) + @($Messages)
        $fbJson = ([ordered]@{ model = $Model; messages = $fbMsgs; temperature = $Temperature; max_tokens = $MaxTokens } | ConvertTo-Json -Depth 16 -Compress)
        $r = Invoke-ByobHttpRequest -Url "$cleanUrl/chat/completions" -Headers $headers -Body $fbJson -TimeoutSec $TimeoutSec -CancelState $CancelState
        $usedFallback = $true
    }
    if ($r.Status -lt 200 -or $r.Status -ge 300) { throw "Model server returned HTTP $($r.Status): $(Get-ByobBodyExcerpt $r.Body)" }
    try { $resp = ConvertFrom-Json -InputObject $r.Body } catch { throw "Model server returned a response that is not JSON: $(Get-ByobBodyExcerpt $r.Body)" }
    if (-not $resp.choices -or @($resp.choices).Count -eq 0) { throw "Model server response has no choices: $(Get-ByobBodyExcerpt $r.Body)" }

    $choice = @($resp.choices)[0].message
    $contentText = [string]$choice.content
    $thinkText = ''
    if ($choice.PSObject.Properties.Name -contains 'reasoning_content' -and $choice.reasoning_content) { $thinkText = [string]$choice.reasoning_content }
    $mThink = [regex]::Match($contentText, '(?is)^\s*<think>(.*?)</think>\s*(.*)$')
    if ($mThink.Success) {
        if (-not $thinkText) { $thinkText = $mThink.Groups[1].Value.Trim() }
        $contentText = $mThink.Groups[2].Value
    }

    $calls = New-Object System.Collections.Generic.List[object]
    if ($choice.PSObject.Properties.Name -contains 'tool_calls' -and $choice.tool_calls) {
        foreach ($tc in @($choice.tool_calls)) {
            $parsedArgs = [pscustomobject]@{}
            $rawArgs = [string]$tc.function.arguments
            if ($rawArgs) { try { $parsedArgs = ConvertFrom-Json -InputObject $rawArgs } catch { } }
            if ($null -eq $parsedArgs) { $parsedArgs = [pscustomobject]@{} }
            $id = [string]$tc.id
            if (-not $id) { $id = 'call_' + [guid]::NewGuid().ToString('N').Substring(0, 12) }
            if (-not $rawArgs) { $rawArgs = '{}' }
            $calls.Add(@{ id = $id; name = [string]$tc.function.name; args = $parsedArgs; rawArgs = $rawArgs })
        }
    } elseif ($usedFallback -or $oaiTools.Count -gt 0) {
        $mJson = [regex]::Match($contentText, '(?s)```json\s*(\{.*?"tool"\s*:.*?\})\s*```|^\s*(\{\s*"tool"\s*:.*\})\s*$')
        if ($mJson.Success) {
            $rawJ = $mJson.Groups[2].Value
            if ($mJson.Groups[1].Success) { $rawJ = $mJson.Groups[1].Value }
            try {
                $parsed = ConvertFrom-Json -InputObject $rawJ
                if ($parsed.tool) {
                    $a = $parsed.args
                    if ($null -eq $a) { $a = [pscustomobject]@{} }
                    $calls.Add(@{ id = 'call_' + [guid]::NewGuid().ToString('N').Substring(0, 12); name = [string]$parsed.tool; args = $a; rawArgs = '' })
                    $contentText = ''
                }
            } catch { }
        }
    }
    $arr = $calls.ToArray()
    return [pscustomobject]@{
        Text = $contentText; Thinking = $thinkText; ToolCalls = $arr
        RawToolCalls = (ConvertTo-ByobToolCallList $arr); ApiKind = 'openai'
    }
}
