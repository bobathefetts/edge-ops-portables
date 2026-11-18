# Yap Edge-Ops host. Windows PowerShell 5.1 only. ASCII only.
# Zero Python, zero third-party EXEs/DLLs: uses PowerShell 5.1 + .NET C# (Add-Type) + Edge Whisper WASM (plus System.Speech fallback).
# Started by Yap.lnk (conhost.exe --headless, no console window) or Yap-Dev.bat.
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$toolId = 'yap'
$blockStart = 8835
$blockEnd = 8837

$logFile = Join-Path $root ('logs\Yap_{0:yyyy_MM_dd_HHmmss}.log' -f (Get-Date))
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
        [void][System.Windows.Forms.MessageBox]::Show("Yap could not start.`n`n$text`n`nLog: $logFile", 'Yap')
    } catch { }
}

trap {
    Show-Fatal "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}

if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw "Run with Windows PowerShell 5.1 (powershell.exe), not $($PSVersionTable.PSVersion)."
}

# Keep temp files inside the portable folder.
$env:TEMP = Join-Path $root 'temp\sys'
$env:TMP = $env:TEMP
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $env:TEMP, $dataDir | Out-Null

$versionFile = Join-Path $root 'VERSION'
$version = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '0.3.0' }

$hostSettingsFile = Join-Path $root 'config\settings.json'
$hostSettings = if (Test-Path $hostSettingsFile) {
    Get-Content $hostSettingsFile -Raw | ConvertFrom-Json
} else {
    [pscustomobject]@{ port = $blockStart; portRangeStart = $blockStart; portRangeEnd = $blockEnd; openBrowserOnLaunch = $true }
}

$preferredPort = if ($Port -gt 0) { $Port } elseif ($hostSettings.port) { [int]$hostSettings.port } else { $blockStart }
$rangeStart = if ($Port -gt 0) { $Port } else { $blockStart }
$rangeEnd = if ($Port -gt 0) { $Port } else { $blockEnd }

. (Join-Path $here 'LoopbackPort.ps1')
. (Join-Path $here 'YapCleanup.ps1')

$nativeCs = Join-Path $here 'YapNative.cs'
$uiRoot = Join-Path $here 'ui'
$voiceRoot = Join-Path $uiRoot 'vendor\voice'
$voiceManifestPath = Join-Path $root 'config\voice-assets.json'

# Load SHA-256 manifest for local Whisper WASM assets (PacketRat pattern).
$script:VoiceHashes = @{}
if (Test-Path $voiceManifestPath) {
    $vm = Get-Content $voiceManifestPath -Raw | ConvertFrom-Json
    foreach ($entry in @($vm.files)) {
        $script:VoiceHashes[[string]$entry.name] = ([string]$entry.sha256).ToLowerInvariant()
    }
}

function Test-VoiceAssetHash([string]$RelName, [string]$FullPath) {
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return $false }
    if (-not $script:VoiceHashes.ContainsKey($RelName)) { return $false }
    $actual = (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    return ($actual -eq $script:VoiceHashes[$RelName])
}

# Load signed GAC assemblies first (never blocked by C# compile policy).
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$script:HasSystemSpeech = $false
try {
    Add-Type -AssemblyName System.Speech
    $script:HasSystemSpeech = $true
} catch { }

# Compile C# Win32 hook / WinMM / SendInput / Pill helper (graceful fallback if WDAC blocks Add-Type).
$script:NativeAvailable = $false
try {
    Add-Type -Path $nativeCs -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
    $script:NativeAvailable = $true
} catch {
    Add-Log 'WARN' "C# Add-Type unavailable ($($_.Exception.Message)); using browser Hold-to-Talk fallback."
}

if ($CheckOnly) {
    Assert-LoopbackPrefix -Prefix "http://localhost:$preferredPort/"
    if (-not (Test-Path (Join-Path $uiRoot 'index.html'))) { throw 'Missing src\ui\index.html.' }
    if (-not (Test-Path (Join-Path $uiRoot 'voice-worker.js'))) { throw 'Missing src\ui\voice-worker.js.' }
    if (-not (Test-Path $voiceManifestPath)) { throw 'Missing config\voice-assets.json.' }
    $missing = @()
    foreach ($rel in $script:VoiceHashes.Keys) {
        $fp = Join-Path $voiceRoot ($rel -replace '/', '\')
        if (-not (Test-VoiceAssetHash -RelName $rel -FullPath $fp)) { $missing += $rel }
    }
    if ($missing.Count -gt 0) {
        throw "Whisper WASM asset(s) missing or hash mismatch: $($missing -join ', '). Run scripts\Build-Portable.ps1."
    }
    $cleanCheck = Invoke-YapBasicCleanup -Text 'um hello, hello world. new paragraph this is a test'
    if ($cleanCheck -ne "Hello world.`n`nThis is a test") {
        throw "Cleanup sanity check unexpected: $cleanCheck"
    }
    Add-Log 'sys' "Self-check passed (v$version, nativeCSharp=$($script:NativeAvailable), systemSpeech=$($script:HasSystemSpeech), voiceAssets=$($script:VoiceHashes.Count))."
    Write-Host "Self-check passed (Yap v$version, zero-Python Edge-Ops build, nativeCSharp=$($script:NativeAvailable), voiceAssets=$($script:VoiceHashes.Count))."
    exit 0
}

# User config inside .\data\config.json
$cfgPath = Join-Path $dataDir 'config.json'
$historyPath = Join-Path $dataDir 'history.jsonl'
$defaultCfg = [ordered]@{
    hotkey = 'ctrl+win'
    min_hold_seconds = 0.35
    input_device = $null
    cleanup_enabled = $true
    cleanup_backend = 'basic'
    llm_endpoint = 'http://127.0.0.1:8776/v1'
    llm_model = 'qwen3.5:2b'
    cleanup_timeout_seconds = 15
    cleanup_extra_instructions = ''
    dictionary = @('Whisper', 'Edge-Ops')
    append_space = $true
    restore_clipboard = $true
    sounds = $true
    show_overlay = $true
    history_enabled = $true
}

function Load-YapUserConfig {
    $cfg = [ordered]@{}
    foreach ($k in $defaultCfg.Keys) { $cfg[$k] = $defaultCfg[$k] }
    if (Test-Path $cfgPath) {
        try {
            $u = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($p in $u.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch { }
    }
    Save-YapUserConfig $cfg
    return [pscustomobject]$cfg
}

function Save-YapUserConfig($CfgObj) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($cfgPath, ($CfgObj | ConvertTo-Json -Depth 6), $utf8)
}

$script:UserCfg = Load-YapUserConfig

function Invoke-LoopbackIdProbe([int]$ProbePort) {
    foreach ($ip in @('127.0.0.1', '[::1]')) {
        try {
            $req = [System.Net.HttpWebRequest]::Create("http://${ip}:${ProbePort}/__fleethacker/id")
            $req.Host = "localhost:$ProbePort"
            $req.Method = 'GET'
            $req.Proxy = $null
            $req.Timeout = 1000
            $req.ReadWriteTimeout = 1000
            $resp = $req.GetResponse()
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                return ($sr.ReadToEnd() | ConvertFrom-Json)
            } finally { $resp.Close() }
        } catch { }
    }
    return $null
}

function Request-LoopbackShutdown([int]$ProbePort) {
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:${ProbePort}/__fleethacker/shutdown")
        $req.Host = "localhost:$ProbePort"
        $req.Method = 'POST'
        $req.Proxy = $null
        $req.ContentLength = 0
        $req.Headers['X-FleetHacker-Shutdown'] = '1'
        $req.Timeout = 1500
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch { return $false }
}

function Compare-DottedVersion([string]$A, [string]$B) {
    $va = $null; $vb = $null
    $ma = [regex]::Match($A, '^\s*v?(\d+(?:\.\d+){0,3})')
    $mb = [regex]::Match($B, '^\s*v?(\d+(?:\.\d+){0,3})')
    if (-not $ma.Success -or -not $mb.Success) { return $null }
    if ([Version]::TryParse($ma.Groups[1].Value, [ref]$va) -and [Version]::TryParse($mb.Groups[1].Value, [ref]$vb)) {
        return $va.CompareTo($vb)
    }
    return $null
}

# Self-detection across Yap's port block (reuse policy).
$listener = $null
$candidates = @($preferredPort) + @($rangeStart..$rangeEnd | Where-Object { $_ -ne $preferredPort })
foreach ($p in $candidates) {
    if (Test-LoopbackPortFree -Port $p) {
        try {
            $listener = Start-LoopbackListener -PreferredPort $p -RangeStart $p -RangeEnd $p -ListenHost 'localhost'
            break
        } catch { $listener = $null }
    }
    $idInfo = Invoke-LoopbackIdProbe -ProbePort $p
    if ($idInfo -and $idInfo.tool -eq $toolId) {
        $cmp = Compare-DottedVersion -A ([string]$idInfo.version) -B $version
        if ($cmp -ne $null -and $cmp -ge 0) {
            Add-Log 'sys' "Reusing running Yap v$($idInfo.version) on port $p."
            if (-not $NoBrowser) { Start-Process "http://localhost:$p/" }
            exit 0
        }
        [void](Request-LoopbackShutdown -ProbePort $p)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 5000 -and -not (Test-LoopbackPortFree -Port $p)) { Start-Sleep -Milliseconds 150 }
        if (Test-LoopbackPortFree -Port $p) {
            $listener = Start-LoopbackListener -PreferredPort $p -RangeStart $p -RangeEnd $p -ListenHost 'localhost'
            break
        }
    }
}
if (-not $listener) { throw "No free port in Yap block $rangeStart-$rangeEnd." }

$actualPort = Get-ListenerPort -Listener $listener
$url = "http://localhost:$actualPort/"

function Open-YapBrowser([string]$TargetUrl) {
    $edgePaths = @(
        "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )
    $edge = $edgePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($edge) {
        Start-Process -FilePath $edge -ArgumentList "--app=$TargetUrl"
    } else {
        Start-Process $TargetUrl
    }
}

function Invoke-SystemSpeechWav([byte[]]$Pcm16) {
    if (-not $script:HasSystemSpeech -or -not $script:NativeAvailable) { return '' }
    $wav = [YapNative.WaveRecorder]::WrapWav($Pcm16)
    $ms = New-Object System.IO.MemoryStream (,$wav)
    $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine
    try {
        $engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
        $engine.SetInputToWaveStream($ms)
        $parts = New-Object 'System.Collections.Generic.List[string]'
        while ($true) {
            $res = $engine.Recognize()
            if ($null -eq $res) { break }
            if ($res.Text) { $parts.Add($res.Text.Trim()) }
        }
        return ($parts -join ' ').Trim()
    } finally {
        $engine.Dispose()
        $ms.Dispose()
    }
}

function Add-YapHistory([string]$Raw, [string]$Text, [string]$Stt, [string]$CleanupMethod, [int]$LatencyMs) {
    if ($script:UserCfg.history_enabled -eq $false) { return }
    try {
        $row = ([ordered]@{
            time = (Get-Date).ToString('s')
            text = $Text
            raw = $Raw
            stt = $Stt
            cleanup = $CleanupMethod
            latency_ms = $LatencyMs
        } | ConvertTo-Json -Compress)
        [IO.File]::AppendAllText($historyPath, "$row`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

# Shared thread-safe state between WinForms STA thread and HTTP host loop.
$script:Sync = [hashtable]::Synchronized(@{
    StopRequested = $false
    BrowserLastSeen = [datetime]::MinValue
    BrowserWasmReady = $false
    PendingAudioQueue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[byte[]]')
    PendingPasteQueue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')
    PillQueue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')
    ConfigUpdated = $false
    LastText = ''
    StatusText = 'Ready'
})

$staThread = $null
if ($script:NativeAvailable) {
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $script:Sync)
    $rs.SessionStateProxy.SetVariable('NativeCs', $nativeCs)
    $rs.SessionStateProxy.SetVariable('UserCfg', $script:UserCfg)
    $rs.SessionStateProxy.SetVariable('IcoPath', (Join-Path $root 'assets\yap.ico'))
    $rs.SessionStateProxy.SetVariable('DashboardUrl', $url)

    $psSta = [PowerShell]::Create()
    $psSta.Runspace = $rs
    [void]$psSta.AddScript({
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        Add-Type -Path $NativeCs -ReferencedAssemblies System.Windows.Forms, System.Drawing

        $pill = New-Object YapNative.PillForm
        $rec = New-Object YapNative.WaveRecorder
        $hook = New-Object YapNative.KeyboardHook
        $hook.Install([string]$UserCfg.hotkey)

        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Text = 'Yap (Edge-Ops)'
        if (Test-Path $IcoPath) { $tray.Icon = New-Object System.Drawing.Icon($IcoPath) }
        else { $tray.Icon = [System.Drawing.SystemIcons]::Information }

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $mOpen = $menu.Items.Add('Open Yap Dashboard')
        $mOpen.Add_Click({ Start-Process $DashboardUrl })
        $mQuit = $menu.Items.Add('Quit Yap')
        $mQuit.Add_Click({
            $Sync.StopRequested = $true
            [System.Windows.Forms.Application]::ExitThread()
        })
        $tray.ContextMenuStrip = $menu
        $tray.Visible = $true

        $recStarted = [datetime]::MinValue
        $pillUntil = [datetime]::MinValue
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 50
        $timer.Add_Tick({
            if ($Sync.StopRequested) {
                $timer.Stop()
                [System.Windows.Forms.Application]::ExitThread()
                return
            }
            if ($Sync.ConfigUpdated) {
                $Sync.ConfigUpdated = $false
                $hook.SetHotkey([string]$UserCfg.hotkey)
            }

            $ev = $null
            while ($hook.Events.TryDequeue([ref]$ev)) {
                if ($ev -eq 'start' -and -not $rec.IsRecording) {
                    $devIdx = -1
                    if ($UserCfg.input_device) {
                        $devs = [YapNative.NativeHost]::ListInputDevices()
                        $idx = $devs.IndexOf([string]$UserCfg.input_device)
                        if ($idx -ge 0) { $devIdx = $idx }
                    }
                    try {
                        $rec.Start($devIdx)
                        $recStarted = [datetime]::UtcNow
                        if ($UserCfg.sounds -ne $false) { [System.Media.SystemSounds]::Beep.Play() }
                        if ($UserCfg.show_overlay -ne $false) { $pill.UpdateState('recording', 'Listening...') }
                    } catch {
                        $pill.UpdateState('processing', 'Mic error')
                        $pillUntil = [datetime]::UtcNow.AddSeconds(2.5)
                    }
                } elseif (($ev -eq 'stop' -or $ev -eq 'cancel') -and $rec.IsRecording) {
                    $pcm = $rec.StopAndGetPcm16()
                    $held = ([datetime]::UtcNow - $recStarted).TotalSeconds
                    $minHold = if ($UserCfg.min_hold_seconds) { [double]$UserCfg.min_hold_seconds } else { 0.35 }
                    if ($ev -eq 'cancel' -or $held -lt $minHold -or $rec.PeakLevel -lt 0.003 -or $pcm.Length -lt 3200) {
                        $pill.UpdateState('hidden', '')
                    } else {
                        if ($UserCfg.show_overlay -ne $false) { $pill.UpdateState('processing', 'Transcribing...') }
                        $Sync.PendingAudioQueue.Enqueue($pcm)
                    }
                }
            }

            $pasteText = $null
            while ($Sync.PendingPasteQueue.TryDequeue([ref]$pasteText)) {
                $restore = ($UserCfg.restore_clipboard -ne $false)
                [YapNative.NativeHost]::PasteText($pasteText, $restore)
            }

            $pillItem = $null
            while ($Sync.PillQueue.TryDequeue([ref]$pillItem)) {
                if ($UserCfg.show_overlay -ne $false) {
                    $pill.UpdateState($pillItem.State, $pillItem.Text)
                    $pillUntil = [datetime]::UtcNow.AddSeconds([double]$pillItem.Seconds)
                }
            }

            if ($pillUntil -ne [datetime]::MinValue -and [datetime]::UtcNow -gt $pillUntil -and -not $rec.IsRecording) {
                $pillUntil = [datetime]::MinValue
                $pill.UpdateState('hidden', '')
            }
        })
        $timer.Start()
        try {
            [System.Windows.Forms.Application]::Run()
        } finally {
            $timer.Dispose()
            $hook.Dispose()
            $rec.Dispose()
            $tray.Visible = $false
            $tray.Dispose()
            $pill.Dispose()
        }
    })
    $staHandle = $psSta.BeginInvoke()
    $staThread = $psSta
} else {
    Add-Log 'WARN' 'Running in pure-Edge mode (no Win32 keyboard hook).'
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

function Get-MimeType([string]$Path) {
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.js'   { return 'application/javascript; charset=utf-8' }
        '.mjs'  { return 'application/javascript; charset=utf-8' }
        '.wasm' { return 'application/wasm' }
        '.json' { return 'application/json; charset=utf-8' }
        '.onnx' { return 'application/octet-stream' }
        default { return 'application/octet-stream' }
    }
}

$pidFile = Join-Path $here '.pid'
Set-Content -Path $pidFile -Value $PID -Encoding Ascii

$activeJob = $null
$activeJobT0 = [datetime]::MinValue

try {
    Add-Log 'sys' "Serving Yap v$version on $url (nativeCSharp=$($script:NativeAvailable), data=$dataDir)"
    if (-not $NoBrowser -and $hostSettings.openBrowserOnLaunch -ne $false) {
        Open-YapBrowser -TargetUrl $url
    }

    $pendingContext = $listener.BeginGetContext($null, $null)
    while ($listener.IsListening -and -not $script:Sync.StopRequested) {
        # Start next recorded audio job if none is currently in flight
        if ($null -eq $activeJob) {
            $pcm = $null
            if ($script:Sync.PendingAudioQueue.TryDequeue([ref]$pcm)) {
                $browserFresh = ($script:Sync.BrowserWasmReady -and (([datetime]::UtcNow - $script:Sync.BrowserLastSeen).TotalSeconds -lt 5))
                if ($browserFresh) {
                    $activeJob = @{
                        id = [guid]::NewGuid().ToString('N')
                        pcm = $pcm
                        dispatched = $false
                        sw = [System.Diagnostics.Stopwatch]::StartNew()
                    }
                    $activeJobT0 = [datetime]::UtcNow
                } else {
                    # Immediate Windows System.Speech fallback when Edge Whisper WASM tab is closed
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $raw = Invoke-SystemSpeechWav -Pcm16 $pcm
                    if ($raw) {
                        $cleaned = Invoke-YapCleanup -RawText $raw -Config $script:UserCfg
                        $outText = $cleaned.Text
                        if ($outText) {
                            if ($script:UserCfg.append_space -ne $false -and -not $outText.EndsWith("`n") -and -not $outText.EndsWith(' ')) { $outText += ' ' }
                            $script:Sync.LastText = $outText.Trim()
                            $script:Sync.PendingPasteQueue.Enqueue($outText)
                            Add-YapHistory -Raw $raw -Text $script:Sync.LastText -Stt 'system-speech' -CleanupMethod $cleaned.Method -LatencyMs ([int]$sw.ElapsedMilliseconds)
                            $script:Sync.PillQueue.Enqueue(@{ State = 'message'; Text = 'Done (Windows Speech)'; Seconds = 1.6 })
                        } else {
                            $script:Sync.PillQueue.Enqueue(@{ State = 'hidden'; Text = ''; Seconds = 0 })
                        }
                    } else {
                        $script:Sync.PillQueue.Enqueue(@{ State = 'message'; Text = 'No speech heard'; Seconds = 1.8 })
                    }
                }
            }
        } elseif (([datetime]::UtcNow - $activeJobT0).TotalSeconds -gt 15) {
            # Timeout waiting for browser WASM -> fallback to System.Speech
            $raw = Invoke-SystemSpeechWav -Pcm16 $activeJob.pcm
            $activeJob = $null
            if ($raw) {
                $cleaned = Invoke-YapCleanup -RawText $raw -Config $script:UserCfg
                $outText = $cleaned.Text
                if ($outText) {
                    if ($script:UserCfg.append_space -ne $false -and -not $outText.EndsWith("`n") -and -not $outText.EndsWith(' ')) { $outText += ' ' }
                    $script:Sync.LastText = $outText.Trim()
                    $script:Sync.PendingPasteQueue.Enqueue($outText)
                    Add-YapHistory -Raw $raw -Text $script:Sync.LastText -Stt 'system-speech-fallback' -CleanupMethod $cleaned.Method -LatencyMs 0
                }
            }
            $script:Sync.PillQueue.Enqueue(@{ State = 'hidden'; Text = ''; Seconds = 0 })
        }

        if ($pendingContext.AsyncWaitHandle.WaitOne(60)) {
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
                        $script:Sync.StopRequested = $true
                    }
                } elseif ($path -eq '/api/status' -and $method -eq 'GET') {
                    $wasmAlive = ($script:Sync.BrowserWasmReady -and (([datetime]::UtcNow - $script:Sync.BrowserLastSeen).TotalSeconds -lt 6))
                    $out = [ordered]@{
                        version = $version
                        hotkey = [string]$script:UserCfg.hotkey
                        nativeHook = $script:NativeAvailable
                        wasmReady = $wasmAlive
                        dataDir = $dataDir
                        status = if ($wasmAlive) { 'Ready (Whisper WASM)' } else { 'Ready (Waiting for Edge tab / System.Speech)' }
                    }
                    Write-JsonResponse $resp 200 ($out | ConvertTo-Json -Compress)
                } elseif ($path -eq '/api/devices' -and $method -eq 'GET') {
                    $devs = if ($script:NativeAvailable) { @([YapNative.NativeHost]::ListInputDevices()) } else { @() }
                    $jsonDevs = if ($devs.Count -eq 0) { '{"devices":[]}' } elseif ($devs.Count -eq 1) { '{"devices":["' + $devs[0].Replace('\', '\\').Replace('"', '\"') + '"]}' } else { (@{ devices = $devs } | ConvertTo-Json -Compress) }
                    Write-JsonResponse $resp 200 $jsonDevs
                } elseif ($path -eq '/api/config' -and $method -eq 'GET') {
                    Write-JsonResponse $resp 200 ($script:UserCfg | ConvertTo-Json -Depth 6)
                } elseif ($path -eq '/api/config' -and $method -eq 'POST') {
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
                    $parsed = ($sr.ReadToEnd()) | ConvertFrom-Json
                    foreach ($p in $parsed.PSObject.Properties) {
                        $script:UserCfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                    }
                    Save-YapUserConfig $script:UserCfg
                    $script:Sync.ConfigUpdated = $true
                    Write-JsonResponse $resp 200 '{"ok":true}'
                } elseif ($path -eq '/api/history' -and $method -eq 'GET') {
                    $items = @()
                    if (Test-Path $historyPath) {
                        foreach ($ln in (Get-Content $historyPath -Tail 50 -Encoding UTF8)) {
                            if ($ln.Trim()) { try { $items += ($ln | ConvertFrom-Json) } catch { } }
                        }
                    }
                    $jsonArr = if ($items.Count -eq 0) { '[]' } elseif ($items.Count -eq 1) { '[' + ($items[0] | ConvertTo-Json -Compress) + ']' } else { ($items | ConvertTo-Json -Compress) }
                    Write-JsonResponse $resp 200 $jsonArr
                } elseif ($path -eq '/api/job/next' -and $method -eq 'GET') {
                    $script:Sync.BrowserLastSeen = [datetime]::UtcNow
                    $script:Sync.BrowserWasmReady = ($req.QueryString['ready'] -eq '1')
                    if ($null -ne $activeJob -and -not $activeJob.dispatched) {
                        $activeJob.dispatched = $true
                        $payload = ([ordered]@{
                            id = $activeJob.id
                            pcmBase64 = [Convert]::ToBase64String($activeJob.pcm)
                        } | ConvertTo-Json -Compress)
                        Write-JsonResponse $resp 200 $payload
                    } else {
                        Write-JsonResponse $resp 200 '{"id":null}'
                    }
                } elseif ($path -eq '/api/job/complete' -and $method -eq 'POST') {
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
                    $body = ($sr.ReadToEnd()) | ConvertFrom-Json
                    if ($null -ne $activeJob -and $body.id -eq $activeJob.id) {
                        $sw = $activeJob.sw
                        $activeJob = $null
                        $raw = [string]$body.text
                        if (-not [string]::IsNullOrWhiteSpace($raw)) {
                            $cleaned = Invoke-YapCleanup -RawText $raw -Config $script:UserCfg
                            $outText = $cleaned.Text
                            if ($outText) {
                                if ($script:UserCfg.append_space -ne $false -and -not $outText.EndsWith("`n") -and -not $outText.EndsWith(' ')) { $outText += ' ' }
                                $script:Sync.LastText = $outText.Trim()
                                $script:Sync.PendingPasteQueue.Enqueue($outText)
                                Add-YapHistory -Raw $raw -Text $script:Sync.LastText -Stt ([string]$body.engine) -CleanupMethod $cleaned.Method -LatencyMs ([int]$sw.ElapsedMilliseconds)
                                $script:Sync.PillQueue.Enqueue(@{ State = 'message'; Text = 'Pasted'; Seconds = 1.2 })
                            } else {
                                $script:Sync.PillQueue.Enqueue(@{ State = 'hidden'; Text = ''; Seconds = 0 })
                            }
                        } else {
                            $script:Sync.PillQueue.Enqueue(@{ State = 'message'; Text = 'No speech heard'; Seconds = 1.6 })
                        }
                    }
                    Write-JsonResponse $resp 200 '{"ok":true}'
                } elseif ($path -eq '/api/dictate' -and $method -eq 'POST') {
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
                    $body = ($sr.ReadToEnd()) | ConvertFrom-Json
                    $raw = [string]$body.text
                    $cleaned = Invoke-YapCleanup -RawText $raw -Config $script:UserCfg
                    $outText = $cleaned.Text
                    if ($outText) {
                        $script:Sync.LastText = $outText.Trim()
                        if ($body.paste -eq $true -and $script:NativeAvailable) {
                            $script:Sync.PendingPasteQueue.Enqueue($outText)
                        }
                        Add-YapHistory -Raw $raw -Text $script:Sync.LastText -Stt 'whisper-wasm' -CleanupMethod $cleaned.Method -LatencyMs 0
                    }
                    Write-JsonResponse $resp 200 (([ordered]@{ text = $outText; method = $cleaned.Method }) | ConvertTo-Json -Compress)
                } elseif ($path.StartsWith('/vendor/voice/')) {
                    $rel = $path.Substring('/vendor/voice/'.Length)
                    if ($rel -match '\.\.' -or $rel -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
                        Write-JsonResponse $resp 400 '{"error":"bad_asset_path"}'
                        continue
                    }
                    $fp = Join-Path $voiceRoot ($rel -replace '/', '\')
                    if (-not (Test-VoiceAssetHash -RelName $rel -FullPath $fp)) {
                        Write-JsonResponse $resp 404 '{"error":"asset_missing_or_hash_mismatch"}'
                        continue
                    }
                    Write-ResponseBytes $resp 200 (Get-MimeType $fp) ([IO.File]::ReadAllBytes($fp))
                } elseif ($path -in @('/', '/index.html', '/voice-worker.js', '/voice-worklet.js')) {
                    $relUi = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
                    $fp = Join-Path $uiRoot $relUi
                    if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) {
                        Write-JsonResponse $resp 404 '{"error":"not_found"}'
                        continue
                    }
                    Write-ResponseBytes $resp 200 (Get-MimeType $fp) ([IO.File]::ReadAllBytes($fp))
                } else {
                    Write-JsonResponse $resp 404 '{"error":"not_found"}'
                }
            } catch {
                Add-Log 'WARN' "HTTP handler error: $($_.Exception.Message)"
                try { Write-JsonResponse $ctx.Response 500 '{"error":"internal_error"}' } catch { }
            }
        }
    }
} finally {
    $script:Sync.StopRequested = $true
    if ($listener) { try { $listener.Close() } catch { } }
    if ($staThread) {
        try {
            $staThread.EndInvoke($staHandle) | Out-Null
            $staThread.Dispose()
        } catch { }
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    Add-Log 'sys' 'Yap stopped.'
}
