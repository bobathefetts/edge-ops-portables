# Yap Portable host. Windows PowerShell 5.1 only. ASCII only.
# Started by Yap.lnk (conhost.exe --headless, no console window) or Yap-Dev.bat.
#   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File src\Start-Yap.ps1 [-Port n] [-NoBrowser] [-CheckOnly]
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
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show("Yap Portable could not start.`n`n$text`n`nLog: $logFile", 'Yap Portable')
    } catch { }
}

trap {
    Show-Fatal "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}

if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw "Run with Windows PowerShell 5.1 (powershell.exe), not $($PSVersionTable.PSVersion)."
}

# Redirect TEMP/TMP and caches inside the portable folder.
$env:TEMP = Join-Path $root 'temp\sys'
$env:TMP = $env:TEMP
$env:HF_HOME = Join-Path $root 'temp\hf'
$env:XDG_CACHE_HOME = Join-Path $root 'temp\cache'
New-Item -ItemType Directory -Force $env:TEMP, $env:HF_HOME, $env:XDG_CACHE_HOME | Out-Null

# Force Yap into 100% portable mode (no %USERPROFILE%\.yap, no registry, no Start Menu).
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null
$env:YAP_PORTABLE = '1'
$env:YAP_HOME = $dataDir
$env:YAP_ASSETS = $root

$versionFile = Join-Path $root 'VERSION'
$version = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '0.0.0' }

$settingsFile = Join-Path $root 'config\settings.json'
$settings = if (Test-Path $settingsFile) {
    Get-Content $settingsFile -Raw | ConvertFrom-Json
} else {
    [pscustomobject]@{ port = $blockStart; portRangeStart = $blockStart; portRangeEnd = $blockEnd; openBrowserOnLaunch = $true }
}

$preferredPort = if ($Port -gt 0) { $Port } elseif ($settings.port) { [int]$settings.port } else { $blockStart }
$rangeStart = if ($Port -gt 0) { $Port } else { $blockStart }
$rangeEnd = if ($Port -gt 0) { $Port } else { $blockEnd }

$pythonw = Join-Path $root 'runtime\python\pythonw.exe'
$pythonExe = Join-Path $root 'runtime\python\python.exe'
$yapEntry = Join-Path $here 'app\yap.pyw'
$uiIndex = Join-Path $here 'ui\index.html'
. (Join-Path $here 'LoopbackPort.ps1')

if ($CheckOnly) {
    Assert-LoopbackPrefix -Prefix "http://localhost:$preferredPort/"
    if (-not (Test-Path $pythonExe)) {
        throw "Missing portable Python runtime '$pythonExe'. Run scripts\Build-Portable.ps1 first."
    }
    if (-not (Test-Path $yapEntry)) {
        throw "Missing Yap entrypoint '$yapEntry'."
    }
    if (-not (Test-Path $uiIndex)) {
        throw "Missing dashboard UI '$uiIndex'."
    }
    & $pythonExe -c "import sys; sys.path.insert(0, r'$here\app'); import yap.config, yap.assets, yap.startup; assert yap.startup.is_portable(), 'not portable'; print('OK:', yap.config.APP_DIR, yap.assets.ASSET_DIR)"
    if ($LASTEXITCODE -ne 0) {
        throw 'Portable Python import check failed.'
    }
    Add-Log 'sys' "Self-check passed (version=$version, YAP_HOME=$dataDir, YAP_ASSETS=$root)."
    Write-Host "Self-check passed (Yap v$version, portable home: $dataDir)."
    exit 0
}

$runnerExe = if (Test-Path $pythonw) { $pythonw } else { $pythonExe }
if (-not (Test-Path $runnerExe)) {
    $buildScript = Join-Path $root 'scripts\Build-Portable.ps1'
    if (Test-Path $buildScript) {
        Add-Log 'sys' 'runtime\python missing; bootstrapping portable Python runtime via scripts\Build-Portable.ps1...'
        & $buildScript
        $runnerExe = if (Test-Path $pythonw) { $pythonw } else { $pythonExe }
    }
    if (-not (Test-Path $runnerExe)) {
        throw "Missing '$runnerExe'. Download Yap-v0.2.1.zip from Releases or run scripts\Build-Portable.ps1."
    }
}

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
                $body = $sr.ReadToEnd()
                return ($body | ConvertFrom-Json)
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
    } catch {
        return $false
    }
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

# Self-detection on Yap's port block (reuse policy).
$listener = $null
$candidates = @($preferredPort) + @($rangeStart..$rangeEnd | Where-Object { $_ -ne $preferredPort })
foreach ($p in $candidates) {
    if (Test-LoopbackPortFree -Port $p) {
        try {
            $listener = Start-LoopbackListener -PreferredPort $p -RangeStart $p -RangeEnd $p -ListenHost 'localhost'
            break
        } catch {
            $listener = $null
        }
    }
    $idInfo = Invoke-LoopbackIdProbe -ProbePort $p
    if ($idInfo -and $idInfo.tool -eq $toolId) {
        $cmp = Compare-DottedVersion -A ([string]$idInfo.version) -B $version
        if ($cmp -ne $null -and $cmp -ge 0) {
            if ($cmp -gt 0) { Add-Log 'sys' "Stale launcher: reusing newer Yap v$($idInfo.version) on port $p." }
            else { Add-Log 'sys' "Reusing running Yap v$($idInfo.version) on port $p." }
            if (-not $NoBrowser) {
                Start-Process "http://localhost:$p/"
            }
            exit 0
        }
        Add-Log 'sys' "Older Yap ($($idInfo.version)) on port $p; requesting shutdown."
        [void](Request-LoopbackShutdown -ProbePort $p)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 6000 -and -not (Test-LoopbackPortFree -Port $p)) {
            Start-Sleep -Milliseconds 150
        }
        if (Test-LoopbackPortFree -Port $p) {
            $listener = Start-LoopbackListener -PreferredPort $p -RangeStart $p -RangeEnd $p -ListenHost 'localhost'
            break
        }
    }
}

if (-not $listener) {
    throw "No free port in Yap block $rangeStart-$rangeEnd."
}

$actualPort = Get-ListenerPort -Listener $listener
$url = "http://localhost:$actualPort/"
$env:YAP_DASHBOARD_URL = $url

function Write-JsonResponse($Response, [int]$Status, [string]$Json) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
    $Response.StatusCode = $Status
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.Close()
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $runnerExe
$psi.Arguments = "`"$yapEntry`""
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

$pidFile = Join-Path $here '.pid'
Set-Content -Path $pidFile -Value $PID -Encoding Ascii

try {
    Add-Log 'sys' "Starting Yap v$version on $url (YAP_HOME=$dataDir)"
    [void]$proc.Start()

    $openBrowser = (-not $NoBrowser) -and ($settings.openBrowserOnLaunch -ne $false)
    if ($openBrowser) {
        Start-Process $url
    }

    $pendingContext = $listener.BeginGetContext($null, $null)
    $stopRequested = $false

    while ($listener.IsListening -and -not $stopRequested) {
        if ($proc.HasExited) {
            Add-Log 'sys' "Yap process exited with code $($proc.ExitCode)."
            break
        }
        if ($pendingContext.AsyncWaitHandle.WaitOne(250)) {
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
                    $idJson = ([ordered]@{
                        tool = $toolId
                        version = $version
                        pid = $PID
                        path = $PSCommandPath
                        yapPid = $proc.Id
                    } | ConvertTo-Json -Compress)
                    Write-JsonResponse $resp 200 $idJson
                } elseif ($path -eq '/__fleethacker/shutdown' -and $method -eq 'POST') {
                    if ($req.Headers['X-FleetHacker-Shutdown'] -ne '1') {
                        Write-JsonResponse $resp 403 '{"error":"missing_shutdown_header"}'
                    } else {
                        Write-JsonResponse $resp 200 '{"ok":true}'
                        $stopRequested = $true
                    }
                } elseif ($path -eq '/api/status' -and $method -eq 'GET') {
                    $stFile = Join-Path $dataDir 'status.json'
                    $st = if (Test-Path $stFile) {
                        try { Get-Content $stFile -Raw | ConvertFrom-Json } catch { $null }
                    } else { $null }
                    $out = [ordered]@{
                        version = $version
                        processAlive = (-not $proc.HasExited)
                        yapPid = $proc.Id
                        dataDir = $dataDir
                        status = if ($st) { $st.status } else { 'Starting...' }
                        ready = if ($st) { [bool]$st.ready } else { $false }
                        hotkey = if ($st) { $st.hotkey } else { 'ctrl+win' }
                        device = if ($st) { $st.device } else { '?' }
                        whisperModel = if ($st) { $st.whisperModel } else { '' }
                        llmModel = if ($st) { $st.llmModel } else { '' }
                    }
                    Write-JsonResponse $resp 200 ($out | ConvertTo-Json -Compress)
                } elseif ($path -eq '/api/config' -and $method -eq 'GET') {
                    $cfgFile = Join-Path $dataDir 'config.json'
                    $cfgText = if (Test-Path $cfgFile) { [IO.File]::ReadAllText($cfgFile, [Text.Encoding]::UTF8) } else { '{}' }
                    Write-JsonResponse $resp 200 $cfgText
                } elseif ($path -eq '/api/config' -and $method -eq 'POST') {
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
                    $body = $sr.ReadToEnd()
                    $parsed = $body | ConvertFrom-Json
                    $cfgFile = Join-Path $dataDir 'config.json'
                    [IO.File]::WriteAllText($cfgFile, ($parsed | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
                    [IO.File]::WriteAllText((Join-Path $dataDir '.reload'), '1', [Text.Encoding]::ASCII)
                    Write-JsonResponse $resp 200 '{"ok":true}'
                } elseif ($path -eq '/api/reload' -and $method -eq 'POST') {
                    [IO.File]::WriteAllText((Join-Path $dataDir '.reload'), '1', [Text.Encoding]::ASCII)
                    Write-JsonResponse $resp 200 '{"ok":true}'
                } elseif ($path -eq '/api/history' -and $method -eq 'GET') {
                    $histFile = Join-Path $dataDir 'history.jsonl'
                    $items = @()
                    if (Test-Path $histFile) {
                        $lines = Get-Content $histFile -Tail 50 -Encoding UTF8
                        foreach ($ln in $lines) {
                            if ($ln.Trim()) {
                                try { $items += ($ln | ConvertFrom-Json) } catch { }
                            }
                        }
                    }
                    $jsonArr = if ($items.Count -eq 0) { '[]' } elseif ($items.Count -eq 1) { '[' + ($items[0] | ConvertTo-Json -Compress) + ']' } else { ($items | ConvertTo-Json -Compress) }
                    Write-JsonResponse $resp 200 $jsonArr
                } elseif ($path -eq '/' -or $path -eq '/index.html') {
                    $htmlBytes = [IO.File]::ReadAllBytes($uiIndex)
                    $resp.StatusCode = 200
                    $resp.ContentType = 'text/html; charset=utf-8'
                    $resp.Headers['X-Content-Type-Options'] = 'nosniff'
                    $resp.ContentLength64 = $htmlBytes.Length
                    $resp.OutputStream.Write($htmlBytes, 0, $htmlBytes.Length)
                    $resp.Close()
                } else {
                    Write-JsonResponse $resp 404 '{"error":"not_found"}'
                }
            } catch {
                try { Write-JsonResponse $ctx.Response 500 '{"error":"internal_error"}' } catch { }
            }
        }
    }
} finally {
    if ($listener) {
        try { $listener.Close() } catch { }
    }
    if ($proc -and -not $proc.HasExited) {
        try {
            [IO.File]::WriteAllText((Join-Path $dataDir '.quit'), '1', [Text.Encoding]::ASCII)
            if (-not $proc.WaitForExit(3500)) {
                $proc.Kill()
                $proc.WaitForExit(2000) | Out-Null
            }
        } catch {
            try { $proc.Kill() } catch { }
        }
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    Add-Log 'sys' 'Yap stopped.'
}
