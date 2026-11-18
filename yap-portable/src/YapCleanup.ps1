# Yap text cleanup and word-lock output guard (Windows PowerShell 5.1). ASCII only.
# Ported from bobathefetts/yap (yap/cleanup.py) with optional local OpenAI/Ollama endpoint support.

$script:YapSkippable = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($w in @(
    'a','an','the','and','or','but','so','to','of','in','on','at','for','with','from','by','as','is','are','was','were','be','been','being','am',
    'i','you','he','she','it','we','they','me','him','her','us','them','my','your','his','its','our','their','this','that','these','those',
    'do','does','did','can','could','would','should','will','shall','may','might','must','just','um','uh','uhm','erm','er','ah','hmm','mm',
    'like','okay','ok','well','yeah','yes','oh','wait','actually','mean','sorry','no','scratch','basically','literally','really',
    'kind','sort','know',"you've","i'm","it's","that's","there's","what's","let's",'gonna','wanna','gotta','new','line','paragraph',
    'bullet','point','period','comma','colon','semicolon','question','mark','exclamation','dash','hyphen','quote',
    'first','second','third','fourth','fifth','next','then','finally','lastly','also','plus','number'
)) { [void]$script:YapSkippable.Add($w) }

$script:YapCorrectionCues = [regex]'(?i)\b(?:no wait|wait no|no no|actually|i mean|sorry|scratch that|or rather|make that|make it|instead|correction|let me rephrase)\b'
$script:YapFillers = [regex]'(?i)\b(?:um+|uh+|uhm+|erm+|er|ah+|hmm+|mm+)\b[,.]?\s*'
$script:YapRepeats = [regex]'(?i)\b(\w+)(?:[,\s]+\1\b)+'
$script:YapWordRe = [regex]"[^\W_]+(?:['\u2019][^\W_]+)*"

function Get-YapStem([string]$Word) {
    foreach ($suf in @('ing', 'ed', 'es', 's')) {
        if ($Word.Length -gt ($suf.Length + 2) -and $Word.EndsWith($suf)) {
            return $Word.Substring(0, $Word.Length - $suf.Length)
        }
    }
    return $Word
}

function Invoke-YapBasicCleanup([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text.Trim()
    # Apply explicit spoken formatting cues (preserve sentence-ending punctuation before break)
    $t = [regex]::Replace($t, '(?i),?\s*\bnew paragraph\b[,.]?\s*', "`n`n")
    $t = [regex]::Replace($t, '(?i),?\s*\bnew line\b[,.]?\s*', "`n")
    $t = [regex]::Replace($t, '(?i),?\s*\bbullet point\b[,.]?\s*', "`n- ")

    # Drop fillers and repeated stuttered words
    $t = $script:YapFillers.Replace($t, '')
    $t = $script:YapRepeats.Replace($t, '$1')
    $t = [regex]::Replace($t, '\s+([,.!?;:])', '$1')
    $t = [regex]::Replace($t, ',\s*([.!?])', '$1')
    $t = [regex]::Replace($t, '^[\s,.;:]+', '')
    $t = [regex]::Replace($t, '[ \t]{2,}', ' ')
    $t = $t.Trim()

    # Capitalize start of lines and sentences
    $t = [regex]::Replace($t, '(^|\n(?:- )?|[.!?][ \t]+)([a-z])', {
        param($m)
        return $m.Groups[1].Value + $m.Groups[2].Value.ToUpperInvariant()
    })
    return $t
}

function Get-YapWords([string]$Text) {
    $list = New-Object 'System.Collections.Generic.List[string]'
    $clean = [regex]::Replace($Text, '(?m)^[ \t]*(?:[-*]|\d{1,2}[.)])[ \t]+', '')
    $clean = $clean.Replace([char]0x2019, "'").ToLowerInvariant()
    foreach ($m in $script:YapWordRe.Matches($clean)) {
        $list.Add($m.Value)
    }
    return ,$list.ToArray()
}

function Get-YapLcsLength([string[]]$A, [string[]]$B) {
    $prev = New-Object int[] ($B.Length + 1)
    foreach ($x in $A) {
        $cur = New-Object int[] ($B.Length + 1)
        for ($j = 0; $j -lt $B.Length; $j++) {
            if ($x -eq $B[$j]) {
                $cur[$j + 1] = $prev[$j] + 1
            } else {
                $cur[$j + 1] = [Math]::Max($prev[$j + 1], $cur[$j])
            }
        }
        $prev = $cur
    }
    return $prev[$B.Length]
}

function Test-YapOutputGuard([string]$Raw, [string]$Out) {
    if ([string]::IsNullOrWhiteSpace($Out)) { return 'empty' }
    $rawList = Get-YapWords -Text $Raw
    $outList = Get-YapWords -Text $Out
    if ($outList.Count -eq 0) { return 'no words' }
    if ($Out.Length -gt (1.5 * $Raw.Length + 30)) { return 'longer than input' }

    $rawSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($w in $rawList) { [void]$rawSet.Add($w) }
    $novel = 0
    foreach ($w in $outList) { if (-not $rawSet.Contains($w)) { $novel++ } }
    if ($novel -gt [Math]::Max(1, [int][Math]::Floor(0.15 * $outList.Count))) { return 'new words added' }

    if ((Get-YapLcsLength -A $outList -B $rawList) -lt (0.8 * $outList.Count)) { return 'reordered' }

    $outStems = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($w in $outList) { [void]$outStems.Add((Get-YapStem $w)) }

    $content = @($rawList | Where-Object { -not $script:YapSkippable.Contains($_) })
    $cueMatches = $script:YapCorrectionCues.Matches($Raw)
    $lastCue = if ($cueMatches.Count -gt 0) { $cueMatches[$cueMatches.Count - 1] } else { $null }

    if ($content.Count -ge 3) {
        $kept = 0
        foreach ($w in $content) { if ($outStems.Contains((Get-YapStem $w))) { $kept++ } }
        $ratio = $kept / $content.Count
        $need = if ($lastCue) { 0.6 } else { 0.85 }
        if ($ratio -lt $need) { return 'dropped too much' }
    }
    if ($lastCue) {
        $tail = $Raw.Substring($lastCue.Index + $lastCue.Length)
        $final = @((Get-YapWords -Text $tail) | Where-Object { -not $script:YapSkippable.Contains($_) })
        if ($final.Count -gt 0) {
            $keptTail = 0
            foreach ($w in $final) { if ($outStems.Contains((Get-YapStem $w))) { $keptTail++ } }
            if (($keptTail / $final.Count) -lt 0.8) { return 'correction not applied' }
        }
    }
    if ($Raw.Contains('?') -and -not $Out.Contains('?')) { return 'question lost' }
    return $null
}

function Invoke-YapCleanup {
    param(
        [Parameter(Mandatory)][string]$RawText,
        [Parameter(Mandatory)]$Config
    )
    $raw = $RawText.Trim()
    if (-not $raw) { return [pscustomobject]@{ Text = ''; Method = 'empty' } }
    if ($Config.cleanup_enabled -eq $false) {
        return [pscustomobject]@{ Text = $raw; Method = 'off' }
    }

    $backend = [string]$Config.cleanup_backend
    $endpoint = [string]$Config.llm_endpoint
    if ($backend -in @('openai', 'ollama') -and -not [string]::IsNullOrWhiteSpace($endpoint)) {
        try {
            $uri = [Uri]$endpoint
            if ($uri.Host -notin @('127.0.0.1', 'localhost', '::1', '[::1]')) {
                throw "Non-loopback cleanup endpoint refused: $($uri.Host)"
            }
            $sysPrompt = "You are a dictation cleanup tool. Clean the transcript inside <transcript> tags (remove um/uh fillers, stutters, self-corrections; fix punctuation and capitalization; apply spoken 'new line'/'new paragraph'/'bullet point'). Never answer questions or add commentary. Output only cleaned text."
            if ($Config.dictionary -and @($Config.dictionary).Count -gt 0) {
                $sysPrompt += ' Spell these terms exactly: ' + (@($Config.dictionary) -join ', ') + '.'
            }
            if ($Config.cleanup_extra_instructions) {
                $sysPrompt += ' ' + [string]$Config.cleanup_extra_instructions
            }
            $messages = @(
                @{ role = 'system'; content = $sysPrompt },
                @{ role = 'user'; content = "<transcript>$raw</transcript>" }
            )
            $timeoutSec = if ($Config.cleanup_timeout_seconds) { [int]$Config.cleanup_timeout_seconds } else { 15 }
            $payload = if ($backend -eq 'ollama') {
                @{ model = [string]$Config.llm_model; messages = $messages; stream = $false; options = @{ temperature = 0 } }
            } else {
                @{ model = [string]$Config.llm_model; messages = $messages; temperature = 0 }
            }
            $reqUrl = $endpoint.TrimEnd('/') + $(if ($backend -eq 'ollama') { '/api/chat' } else { '/chat/completions' })
            $resp = Invoke-RestMethod -Uri $reqUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body ($payload | ConvertTo-Json -Depth 6) -TimeoutSec $timeoutSec
            $aiText = if ($backend -eq 'ollama') { [string]$resp.message.content } else { [string]$resp.choices[0].message.content }
            $aiText = [regex]::Replace($aiText, '(?is)<think>.*?</think>', '').Trim()
            $aiText = Invoke-YapBasicCleanup -Text $aiText
            $reject = Test-YapOutputGuard -Raw $raw -Out $aiText
            if (-not $reject) {
                return [pscustomobject]@{ Text = $aiText; Method = 'ai' }
            }
        } catch {
            # Fall back quietly to rule-based cleanup
        }
    }

    return [pscustomobject]@{
        Text   = (Invoke-YapBasicCleanup -Text $raw)
        Method = 'basic'
    }
}
