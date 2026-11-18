# BYOB Portable host. Windows PowerShell 5.1 only. ASCII only.
# Started by BYOB.lnk (conhost.exe --headless, no console window) or BYOB-Dev.bat.
#   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File src\Start-BYOB.ps1 [-Port n] [-Desktop] [-Headless] [-OpenBrowser] [-NoBrowser] [-Direct] [-CheckOnly] [-Yolo] [-Workspace dir] [-Model name] [-InferenceUrl url]
param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$OpenBrowser,
    [switch]$Desktop,
    [switch]$Headless,
    [switch]$Direct,
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
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show("BYOB Portable could not start.`n`n$text`n`nLog: $logFile", 'BYOB Portable')
    } catch { }
}

trap {
    Show-Fatal "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}

if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw "Run with Windows PowerShell 5.1 (powershell.exe), not $($PSVersionTable.PSVersion)."
}

# Keep TEMP/TMP inside the portable folder so nothing spills to user profile temp.
$env:TEMP = Join-Path $root 'temp\sys'
$env:TMP = $env:TEMP
New-Item -ItemType Directory -Force $env:TEMP | Out-Null

# Force BYOB to keep all state (byob.db, settings.json, secrets.json, undo, window.ron) inside .\data\.
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null
$env:BYOB_HOME = $dataDir

$versionFile = Join-Path $root 'VERSION'
$version = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { '0.0.0' }

$settingsFile = Join-Path $root 'config\settings.json'
$settings = if (Test-Path $settingsFile) {
    Get-Content $settingsFile -Raw | ConvertFrom-Json
} else {
    [pscustomobject]@{ port = $blockStart; portRangeStart = $blockStart; portRangeEnd = $blockEnd; mode = 'desktop'; workspace = 'workspace'; storage = 'sqlite' }
}

$runDesktop = if ($Headless) {
    $false
} elseif ($Desktop) {
    $true
} elseif ($settings.mode) {
    ([string]$settings.mode).ToLowerInvariant() -ne 'headless'
} else {
    $true
}

$preferredPort = if ($Port -gt 0) { $Port } elseif ($settings.port) { [int]$settings.port } else { $blockStart }
$rangeStart = if ($Port -gt 0) { $Port } else { $blockStart }
$rangeEnd = if ($Port -gt 0) { $Port } else { $blockEnd }

$binExe = Join-Path $root 'bin\byob.exe'
$proxyCs = Join-Path $here 'ProxyServer.cs'
$outlookPluginDir = Join-Path $root 'plugins\outlook-classic'
. (Join-Path $here 'LoopbackPort.ps1')

$defaultWorkspace = if ($Workspace) {
    $Workspace
} elseif ($settings.workspace) {
    $w = [string]$settings.workspace
    if ([IO.Path]::IsPathRooted($w)) { $w } else { Join-Path $root $w }
} else {
    Join-Path $root 'workspace'
}
New-Item -ItemType Directory -Force $defaultWorkspace | Out-Null

if ($CheckOnly) {
    Assert-LoopbackPrefix -Prefix "http://localhost:$preferredPort/"
    if (-not (Test-Path $binExe)) {
        throw "Missing portable binary '$binExe'. Run scripts\Build-Portable.ps1 first."
    }
    if (-not $Direct -and -not (Test-Path $proxyCs)) {
        throw "Missing proxy source '$proxyCs'."
    }
    if (-not (Test-Path (Join-Path $outlookPluginDir 'byob-plugin.json'))) {
        throw "Missing Outlook Classic plugin manifest under '$outlookPluginDir'."
    }
    Add-Log 'sys' "Self-check passed (version=$version, mode=$(if ($runDesktop) { 'desktop' } else { 'headless' }), BYOB_HOME=$dataDir, workspace=$defaultWorkspace, plugin=$outlookPluginDir)."
    Write-Host "Self-check passed (BYOB v$version, mode: $(if ($runDesktop) { 'desktop' } else { 'headless' }), Outlook plugin ready, portable home: $dataDir)."
    exit 0
}

if (-not (Test-Path $binExe)) {
    throw "Missing '$binExe'. Run scripts\Build-Portable.ps1 (or BYOB-Dev.bat after building) to populate bin\."
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

# Self-detection across BYOB's port block (reuse policy).
$candidates = @($preferredPort) + @($rangeStart..$rangeEnd | Where-Object { $_ -ne $preferredPort })
$chosenPort = 0
foreach ($p in $candidates) {
    if (Test-LoopbackPortFree -Port $p) {
        $chosenPort = $p
        break
    }
    $idInfo = Invoke-LoopbackIdProbe -ProbePort $p
    if ($idInfo -and $idInfo.tool -eq $toolId) {
        $cmp = Compare-DottedVersion -A ([string]$idInfo.version) -B $version
        if ($cmp -ne $null -and $cmp -ge 0) {
            if ($cmp -gt 0) { Add-Log 'sys' "Stale launcher: reusing newer BYOB v$($idInfo.version) on port $p." }
            else { Add-Log 'sys' "Reusing running BYOB v$($idInfo.version) on port $p." }
            if ($OpenBrowser -or (-not $NoBrowser -and -not $runDesktop)) {
                Start-Process "http://127.0.0.1:$p/"
            }
            exit 0
        }
        Add-Log 'sys' "Older BYOB ($($idInfo.version)) on port $p; requesting graceful shutdown."
        [void](Request-LoopbackShutdown -ProbePort $p)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 5000 -and -not (Test-LoopbackPortFree -Port $p)) {
            Start-Sleep -Milliseconds 150
        }
        if (Test-LoopbackPortFree -Port $p) {
            $chosenPort = $p
            break
        }
    }
}

if ($chosenPort -eq 0) {
    throw "No free port in BYOB block $rangeStart-$rangeEnd."
}

Assert-LoopbackPrefix -Prefix "http://127.0.0.1:$chosenPort/"

$artifactHost = Join-Path $root 'bin\byob-artifact-host.exe'
if (Test-Path $artifactHost) {
    $env:BYOB_ARTIFACT_HOST = $artifactHost
}

$useProxy = (-not $Direct)
if ($useProxy) {
    try {
        Add-Type -Path $proxyCs
    } catch {
        Add-Log 'WARN' "C# proxy Add-Type failed ($($_.Exception.Message)); falling back to direct byob.exe bind."
        $useProxy = $false
    }
}

# Pick internal backend port if proxying; otherwise byob.exe binds $chosenPort directly.
$backendPort = $chosenPort
if ($useProxy) {
    $backendPort = 0
    foreach ($bp in 8840..8859) {
        if ($bp -ne $chosenPort -and (Test-LoopbackPortFree -Port $bp)) {
            $backendPort = $bp
            break
        }
    }
    if ($backendPort -eq 0) {
        throw 'No free internal loopback port in 8840-8859 for BYOB backend.'
    }
}

$byobArgs = New-Object System.Collections.Generic.List[string]
if ($runDesktop) {
    $byobArgs.Add('--serve')
} else {
    $byobArgs.Add('--headless')
}
$byobArgs.Add("127.0.0.1:$backendPort")
$byobArgs.Add('--workspace')
$byobArgs.Add($defaultWorkspace)
if (Test-Path (Join-Path $outlookPluginDir 'byob-plugin.json')) {
    $byobArgs.Add('--plugin')
    $byobArgs.Add($outlookPluginDir)
}
if ($settings.storage) {
    $byobArgs.Add('--storage')
    $byobArgs.Add([string]$settings.storage)
}
if ($Yolo) { $byobArgs.Add('--yolo') }
if ($Model) { $byobArgs.Add('--model'); $byobArgs.Add($Model) }
if ($InferenceUrl) { $byobArgs.Add('--inference-url'); $byobArgs.Add($InferenceUrl) }

function Format-WinArgs([string[]]$ArgList) {
    $quoted = foreach ($a in $ArgList) {
        if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    return ($quoted -join ' ')
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $binExe
$psi.Arguments = Format-WinArgs -ArgList $byobArgs.ToArray()
$psi.WorkingDirectory = $defaultWorkspace
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

$pidFile = Join-Path $here '.pid'
Set-Content -Path $pidFile -Value $PID -Encoding Ascii

$proxy = $null
$outHandler = $null
$errHandler = $null
try {
    Add-Log 'sys' "Starting BYOB v$version ($($psi.Arguments)) with BYOB_HOME=$dataDir"
    $outHandler = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $logFile -Action {
        if ($EventArgs.Data) {
            try { [IO.File]::AppendAllText($Event.MessageData, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [byob] $($EventArgs.Data)`r`n", [Text.Encoding]::UTF8) } catch { }
        }
    }
    $errHandler = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $logFile -Action {
        if ($EventArgs.Data) {
            try { [IO.File]::AppendAllText($Event.MessageData, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [byob-err] $($EventArgs.Data)`r`n", [Text.Encoding]::UTF8) } catch { }
        }
    }
    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    # Wait for backend TCP listener to come up.
    $ready = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 20000) {
        if ($proc.HasExited) {
            throw "byob.exe exited early with code $($proc.ExitCode). Check $logFile."
        }
        $tc = New-Object System.Net.Sockets.TcpClient
        try {
            $tc.Connect('127.0.0.1', $backendPort)
            $tc.Close()
            $ready = $true
            break
        } catch {
            $tc.Close()
            Start-Sleep -Milliseconds 150
        }
    }
    if (-not $ready) {
        throw "Timed out waiting for byob.exe on 127.0.0.1:$backendPort."
    }

    if ($useProxy) {
        $idPayload = ([ordered]@{
            tool = $toolId
            version = $version
            pid = $PID
            path = $PSCommandPath
            backendPid = $proc.Id
        } | ConvertTo-Json -Compress)
        $proxy = New-Object FleetByobProxy $chosenPort, $backendPort, $idPayload
        $proxy.Start()
    }

    $url = "http://127.0.0.1:$chosenPort/"
    Add-Log 'sys' "Serving BYOB at $url (mode=$(if ($runDesktop) { 'desktop' } else { 'headless' }), host PID $PID, byob PID $($proc.Id))"
    if ($OpenBrowser -or (-not $NoBrowser -and -not $runDesktop)) {
        Start-Process $url
    }

    while (-not $proc.HasExited) {
        if ($proxy -and $proxy.ShutdownRequested) {
            Add-Log 'sys' 'Shutdown requested via /__fleethacker/shutdown.'
            break
        }
        Start-Sleep -Milliseconds 250
    }
} finally {
    if ($proxy) {
        try { $proxy.Stop(); $proxy.Dispose() } catch { }
    }
    if ($proc -and -not $proc.HasExited) {
        try { $proc.Kill(); $proc.WaitForExit(3000) | Out-Null } catch { }
    }
    if ($outHandler) {
        try { Unregister-Event -SourceIdentifier $outHandler.Name -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Job -Job $outHandler -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($errHandler) {
        try { Unregister-Event -SourceIdentifier $errHandler.Name -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Job -Job $errHandler -Force -ErrorAction SilentlyContinue } catch { }
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    Add-Log 'sys' 'BYOB stopped.'
}
