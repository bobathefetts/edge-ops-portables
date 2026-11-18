# BYOB Portable LLM Client & Agent Loop (OpenAI /v1 + Anthropic /v1 + Prompt-Tool Fallback). PS 5.1, ASCII only.

function Find-LocalLlmEndpoints {
    $probes = @(
        @{ name = 'Fairlead';     url = 'http://127.0.0.1:8776/v1';  api = 'openai';    modelsUrl = 'http://127.0.0.1:8776/v1/models' },
        @{ name = 'Phoenix LAI';  url = 'http://127.0.0.1:1234/v1';  api = 'openai';    modelsUrl = 'http://127.0.0.1:1234/v1/models' },
        @{ name = 'Windlass';     url = 'http://127.0.0.1:8777/v1';  api = 'openai';    modelsUrl = 'http://127.0.0.1:8777/v1/models' },
        @{ name = 'llama-server'; url = 'http://127.0.0.1:8080/v1';  api = 'openai';    modelsUrl = 'http://127.0.0.1:8080/v1/models' },
        @{ name = 'Ollama';       url = 'http://127.0.0.1:11434/v1'; api = 'openai';    modelsUrl = 'http://127.0.0.1:11434/v1/models' },
        @{ name = 'vLLM';         url = 'http://127.0.0.1:8000/v1';  api = 'openai';    modelsUrl = 'http://127.0.0.1:8000/v1/models' }
    )
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($p in $probes) {
        try {
            $resp = Invoke-RestMethod -Uri $p.modelsUrl -TimeoutSec 1 -ErrorAction Stop
            $models = @($resp.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
            $found.Add([ordered]@{ name = $p.name; url = $p.url; api = $p.api; models = $models })
        } catch { }
    }
    return ,$found.ToArray()
}

function Invoke-ByobLlmOnce {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Model,
        [string]$ApiKey = '',
        [string]$ApiKind = 'auto',
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][array]$Messages,
        [Parameter(Mandatory)][array]$Tools,
        [double]$Temperature = 0.2,
        [int]$MaxTokens = 4096
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $cleanUrl = $BaseUrl.Trim().TrimEnd('/')
    $isAnthropic = ($ApiKind -eq 'anthropic') -or ($ApiKind -eq 'auto' -and $cleanUrl -match 'anthropic\.com')

    if ($isAnthropic) {
        $headers = @{
            'Content-Type' = 'application/json'
            'anthropic-version' = '2023-06-01'
        }
        if ($ApiKey) { $headers['x-api-key'] = $ApiKey }

        $antMsgs = @()
        foreach ($m in $Messages) {
            if ($m.role -eq 'system') { continue }
            $antMsgs += @{ role = $m.role; content = $m.content }
        }
        $antTools = @($Tools | ForEach-Object {
            @{
                name = $_.name
                description = $_.description
                input_schema = $_.params
            }
        })
        $payload = [ordered]@{
            model = $Model
            max_tokens = $MaxTokens
            system = $SystemPrompt
            messages = $antMsgs
            tools = $antTools
            temperature = $Temperature
        }
        $jsonBody = ($payload | ConvertTo-Json -Depth 14 -Compress)
        $resp = Invoke-RestMethod -Uri "$cleanUrl/messages" -Method Post -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($jsonBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 180

        $textOut = New-Object System.Text.StringBuilder
        $thinkOut = New-Object System.Text.StringBuilder
        $calls = New-Object System.Collections.Generic.List[object]
        foreach ($blk in @($resp.content)) {
            if ($blk.type -eq 'text') { [void]$textOut.Append([string]$blk.text) }
            elseif ($blk.type -eq 'thinking') { [void]$thinkOut.Append([string]$blk.thinking) }
            elseif ($blk.type -eq 'tool_use') {
                $calls.Add(@{ id = [string]$blk.id; name = [string]$blk.name; args = $blk.input })
            }
        }
        return [pscustomobject]@{
            Text = $textOut.ToString()
            Thinking = $thinkOut.ToString()
            ToolCalls = $calls.ToArray()
            RawAssistantContent = $resp.content
            ApiKind = 'anthropic'
        }
    }

    # OpenAI-compatible /chat/completions
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($ApiKey) { $headers['Authorization'] = "Bearer $ApiKey" }

    $oaiMsgs = @(@{ role = 'system'; content = $SystemPrompt }) + $Messages
    $oaiTools = @($Tools | ForEach-Object {
        @{
            type = 'function'
            function = @{
                name = $_.name
                description = $_.description
                parameters = $_.params
            }
        }
    })

    $payload = [ordered]@{
        model = $Model
        messages = $oaiMsgs
        temperature = $Temperature
        max_tokens = $MaxTokens
    }
    if ($oaiTools.Count -gt 0) {
        $payload['tools'] = $oaiTools
        $payload['tool_choice'] = 'auto'
    }

    $jsonBody = ($payload | ConvertTo-Json -Depth 14 -Compress)
    try {
        $resp = Invoke-RestMethod -Uri "$cleanUrl/chat/completions" -Method Post -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($jsonBody)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 180
    } catch {
        # Fallback if a local server rejects `tools` parameter: retry with prompt-based tool schema
        $toolSummary = ($Tools | ForEach-Object { "- $($_.name): $($_.description)" }) -join "`n"
        $fallbackSys = "$SystemPrompt`n`nIf you need to call a tool, respond ONLY with a JSON block:`n```json`n{""tool"":""<name>"",""args"":{...}}`n```nAvailable tools:`n$toolSummary"
        $fbMsgs = @(@{ role = 'system'; content = $fallbackSys }) + $Messages
        $fbPayload = [ordered]@{ model = $Model; messages = $fbMsgs; temperature = $Temperature; max_tokens = $MaxTokens }
        $fbJson = ($fbPayload | ConvertTo-Json -Depth 12 -Compress)
        $resp = Invoke-RestMethod -Uri "$cleanUrl/chat/completions" -Method Post -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($fbJson)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 180
    }

    $choice = $resp.choices[0].message
    $contentText = [string]$choice.content
    $thinkText = ''
    if ($choice.PSObject.Properties.Name -contains 'reasoning_content' -and $choice.reasoning_content) {
        $thinkText = [string]$choice.reasoning_content
    }
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
            if ($rawArgs) {
                try { $parsedArgs = $rawArgs | ConvertFrom-Json } catch { }
            }
            $calls.Add(@{ id = [string]$tc.id; name = [string]$tc.function.name; args = $parsedArgs })
        }
    } else {
        # Check prompt-based JSON tool fallback
        $mJson = [regex]::Match($contentText, '(?s)```json\s*(\{.*?"tool"\s*:.*?\})\s*```|^\s*(\{\s*"tool"\s*:.*\})\s*$')
        if ($mJson.Success) {
            $rawJ = if ($mJson.Groups[1].Success) { $mJson.Groups[1].Value } else { $mJson.Groups[2].Value }
            try {
                $parsed = $rawJ | ConvertFrom-Json
                if ($parsed.tool) {
                    $calls.Add(@{ id = 'call_' + [guid]::NewGuid().ToString('N').Substring(0, 8); name = [string]$parsed.tool; args = $parsed.args })
                    $contentText = ''
                }
            } catch { }
        }
    }

    return [pscustomobject]@{
        Text = $contentText
        Thinking = $thinkText
        ToolCalls = $calls.ToArray()
        RawToolCalls = $choice.tool_calls
        ApiKind = 'openai'
    }
}
