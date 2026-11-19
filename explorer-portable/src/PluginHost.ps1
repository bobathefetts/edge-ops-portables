# PluginHost.ps1 - Plugin discovery, trust and execution for BYOB Explorer.
# Windows PowerShell 5.1 and PowerShell 7. ASCII only. Dot-source after ExplorerTools.ps1
# (uses Invoke-ExplorerProcess, Get-ExplorerPowerShellExe, Save-ExplorerRawOutput, Format-ExplorerQueryResult).
#
# A plugin is a folder holding byob-plugin.json:
#   { "name": "portcheck", "description": "...",
#     "tools": [ { "name": "check", "description": "...", "access": "read|write|execute",
#                  "params": { JSON schema object }, "script": "check.ps1", "timeout_sec": 60 } ] }
# Locations: <app>\plugins\<folder>\ (id "app:<folder>") and <workspace>\.byob\plugins\<folder>\
# (id "workspace:<folder>").
#
# TRUST. data\plugin-trust.json maps plugin id -> SHA-256 over every file in the folder. A plugin
# whose current hash differs from its trusted hash (new or changed) is UNTRUSTED: its tools are still
# offered to the model but forced to access 'execute' with a confirm text, so every run asks the user.
# Plugin scripts are NOT checked by the read-only gate: trusting a plugin means trusting its code.

$script:PluginManifestName = 'byob-plugin.json'

function ConvertTo-PluginToolName {
    # plg_<plugin>_<tool>, lower case, [a-z0-9_] only, at most 60 characters.
    param([string]$Plugin, [string]$Tool)
    $p = ([string]$Plugin).ToLowerInvariant() -replace '[^a-z0-9_]', '_'
    $t = ([string]$Tool).ToLowerInvariant() -replace '[^a-z0-9_]', '_'
    $n = "plg_${p}_${t}"
    if ($n.Length -gt 60) { $n = $n.Substring(0, 60) }
    return $n
}

function Get-PluginFolderHash {
    # SHA-256 over all files (sorted relative paths with '/' separators; each file contributes
    # its relative path, a NUL, its byte length, a NUL and its content). Hex, lower case.
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)
    $byRel = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        $byRel[$rel] = $f.FullName
    }
    # Ordinal sort gives the same order on every machine and culture.
    $arr = [string[]]@($byRel.Keys)
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $zero = [byte[]]@(0)
        foreach ($rel in $arr) {
            $content = [IO.File]::ReadAllBytes($byRel[$rel])
            $hdr = [Text.Encoding]::UTF8.GetBytes($rel)
            $len = [Text.Encoding]::ASCII.GetBytes([string]$content.Length)
            [void]$sha.TransformBlock($hdr, 0, $hdr.Length, $null, 0)
            [void]$sha.TransformBlock($zero, 0, 1, $null, 0)
            [void]$sha.TransformBlock($len, 0, $len.Length, $null, 0)
            [void]$sha.TransformBlock($zero, 0, 1, $null, 0)
            if ($content.Length -gt 0) { [void]$sha.TransformBlock($content, 0, $content.Length, $null, 0) }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        return (($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Read-PluginTrust {
    param([Parameter(Mandatory)][string]$DataDir)
    $path = Join-Path $DataDir 'plugin-trust.json'
    $map = @{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    try {
        $obj = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
        foreach ($p in $obj.PSObject.Properties) { $map[[string]$p.Name] = [string]$p.Value }
    } catch { }
    return $map
}

function Write-PluginTrust {
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][hashtable]$Map)
    if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Force $DataDir | Out-Null }
    $o = [ordered]@{}
    foreach ($k in @($Map.Keys | Sort-Object)) { $o[$k] = $Map[$k] }
    $json = '{}'
    if ($o.Count -gt 0) { $json = ([pscustomobject]$o | ConvertTo-Json -Depth 3) }
    [IO.File]::WriteAllText((Join-Path $DataDir 'plugin-trust.json'), $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-PluginRoots {
    param([string]$AppRoot, [string]$Workspace)
    $roots = @()
    if ($AppRoot) { $roots += @{ Location = 'app'; Path = (Join-Path $AppRoot 'plugins') } }
    if ($Workspace) { $roots += @{ Location = 'workspace'; Path = (Join-Path (Join-Path $Workspace '.byob') 'plugins') } }
    return $roots
}

function Read-PluginManifest {
    # Returns @{ Ok; Error; Name; Description; Tools } for one plugin folder.
    param([Parameter(Mandatory)][string]$Folder)
    $res = @{ Ok = $false; Error = ''; Name = ''; Description = ''; Tools = @() }
    $mf = Join-Path $Folder $script:PluginManifestName
    if (-not (Test-Path -LiteralPath $mf -PathType Leaf)) { $res.Error = "No $($script:PluginManifestName) in the folder."; return $res }
    try { $m = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)) }
    catch { $res.Error = "$($script:PluginManifestName) is not valid JSON."; return $res }
    if ($null -eq $m) { $res.Error = 'Manifest is empty.'; return $res }
    $name = [string]$m.name
    if ($name -notmatch '^[A-Za-z0-9_-]{1,40}$') { $res.Error = 'Manifest "name" must be 1-40 characters: letters, digits, _ or -.'; return $res }
    $res.Name = $name
    $res.Description = [string]$m.description
    $toolsIn = @($m.tools | Where-Object { $null -ne $_ })
    if ($toolsIn.Count -lt 1 -or $toolsIn.Count -gt 20) { $res.Error = 'Manifest "tools" must list 1-20 tools.'; return $res }
    $rootFull = [IO.Path]::GetFullPath($Folder).TrimEnd([char[]]@('\', '/'))
    $tools = @()
    $seen = @{}
    foreach ($t in $toolsIn) {
        $tn = [string]$t.name
        if ($tn -notmatch '^[A-Za-z0-9_-]{1,40}$') { $res.Error = "Tool name '$tn' must be 1-40 characters: letters, digits, _ or -."; return $res }
        if ($seen.ContainsKey($tn.ToLowerInvariant())) { $res.Error = "Tool '$tn' is listed twice."; return $res }
        $seen[$tn.ToLowerInvariant()] = $true
        $access = ([string]$t.access).ToLowerInvariant()
        if (-not $access) { $access = 'execute' }
        if ($access -notin @('read', 'write', 'execute')) { $res.Error = "Tool '$tn': access must be read, write or execute."; return $res }
        $script = [string]$t.script
        if ($script -notmatch '^[A-Za-z0-9_./\\-]{1,120}\.ps1$' -or $script.Contains('..')) { $res.Error = "Tool '$tn': script must be a relative .ps1 path inside the plugin folder."; return $res }
        $sp = [IO.Path]::GetFullPath([IO.Path]::Combine($rootFull, $script.Replace('\', [IO.Path]::DirectorySeparatorChar).Replace('/', [IO.Path]::DirectorySeparatorChar)))
        if (-not $sp.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $res.Error = "Tool '$tn': script is outside the plugin folder."; return $res }
        if (-not (Test-Path -LiteralPath $sp -PathType Leaf)) { $res.Error = "Tool '$tn': script '$script' not found."; return $res }
        $timeout = 60
        if ($null -ne $t.timeout_sec) { try { $timeout = [int]$t.timeout_sec } catch { $res.Error = "Tool '$tn': timeout_sec must be a number."; return $res } }
        $timeout = [Math]::Max(1, [Math]::Min(600, $timeout))
        $params = $t.params
        if ($null -eq $params) { $params = [pscustomobject]@{ type = 'object'; properties = [pscustomobject]@{} } }
        if ($params -isnot [System.Management.Automation.PSCustomObject] -or [string]$params.type -ne 'object') { $res.Error = "Tool '$tn': params must be a JSON schema object with type 'object'."; return $res }
        $tools += @{ Name = $tn; Description = [string]$t.description; Access = $access; Script = $script; ScriptPath = $sp; TimeoutSec = $timeout; Params = $params }
    }
    $res.Tools = $tools
    $res.Ok = $true
    return $res
}

function Get-ExplorerPlugins {
    # Discovers plugins in both locations. Returns an array of plugin objects (valid and invalid).
    param([string]$AppRoot, [string]$Workspace, [Parameter(Mandatory)][string]$DataDir)
    $trust = Read-PluginTrust -DataDir $DataDir
    $out = @()
    $exposed = @{}
    foreach ($root in (Get-PluginRoots -AppRoot $AppRoot -Workspace $Workspace)) {
        if (-not (Test-Path -LiteralPath $root.Path -PathType Container)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root.Path -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $id = "$($root.Location):$($dir.Name)"
            $p = [ordered]@{
                id = $id; location = $root.Location; folder = $dir.Name; path = $dir.FullName
                name = $dir.Name; description = ''; valid = $false; error = ''; hash = ''
                trusted = $false; changed = $false; tools = @()
            }
            if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName $script:PluginManifestName) -PathType Leaf)) { continue }
            try { $p.hash = Get-PluginFolderHash -Path $dir.FullName } catch { $p.error = "Could not hash plugin files: $($_.Exception.Message)" }
            $m = Read-PluginManifest -Folder $dir.FullName
            if (-not $m.Ok) {
                if (-not $p.error) { $p.error = $m.Error }
                $out += [pscustomobject]$p
                continue
            }
            $p.name = $m.Name
            $p.description = $m.Description
            if ($p.hash -and $trust.ContainsKey($id)) {
                if ($trust[$id] -eq $p.hash) { $p.trusted = $true } else { $p.changed = $true }
            }
            $tl = @()
            $dupe = ''
            foreach ($t in $m.Tools) {
                $ex = ConvertTo-PluginToolName -Plugin $m.Name -Tool $t.Name
                if ($exposed.ContainsKey($ex)) { $dupe = "Tool name $ex is already used by plugin $($exposed[$ex])." ; break }
                $eff = $t.Access
                if (-not $p.trusted) { $eff = 'execute' }
                $tl += [pscustomobject]@{
                    name = $t.Name; exposed = $ex; description = $t.Description; access = $t.Access; effectiveAccess = $eff
                    script = $t.Script; scriptPath = $t.ScriptPath; timeoutSec = $t.TimeoutSec; params = $t.Params
                }
            }
            if ($dupe) { $p.error = $dupe; $out += [pscustomobject]$p; continue }
            foreach ($t in $tl) { $exposed[$t.exposed] = $id }
            $p.tools = $tl
            $p.valid = $true
            $out += [pscustomobject]$p
        }
    }
    return $out    # callers wrap the call in @(...)
}

function Get-PluginToolDefinitions {
    # Tool definitions in the same shape as Get-ByobToolDefinitions, for valid plugins only.
    param([array]$Plugins)
    $defs = @()
    foreach ($p in @($Plugins)) {
        if (-not $p.valid) { continue }
        foreach ($t in @($p.tools)) {
            $state = 'trusted'
            if (-not $p.trusted) { $state = 'UNTRUSTED: every run asks the user' }
            $d = @{
                name = $t.exposed
                access = $t.effectiveAccess
                description = "[plugin $($p.name), $state] $($t.description)"
                params = $t.params
                pluginId = $p.id
            }
            if (-not $p.trusted) { $d.confirm = "Plugin '$($p.name)' is new or has changed since you last trusted it. Read its code before allowing." }
            $defs += $d
        }
    }
    return $defs    # callers wrap the call in @(...)
}

function Find-PluginTool {
    param([array]$Plugins, [string]$Name)
    foreach ($p in @($Plugins)) {
        if (-not $p.valid) { continue }
        foreach ($t in @($p.tools)) { if ($t.exposed -eq $Name) { return @{ Plugin = $p; Tool = $t } } }
    }
    return $null
}

function Set-PluginTrustState {
    # Trust (records the current hash) or untrust a plugin by id. When ExpectedHash is given and the
    # plugin's files changed since the caller looked at them, nothing is trusted and an error is thrown.
    param([Parameter(Mandatory)][string]$DataDir, [string]$AppRoot, [string]$Workspace,
        [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][ValidateSet('trust', 'untrust')][string]$Action,
        [string]$ExpectedHash = '')
    $trust = Read-PluginTrust -DataDir $DataDir
    if ($Action -eq 'untrust') {
        $had = $trust.ContainsKey($Id)
        if ($had) { $trust.Remove($Id); Write-PluginTrust -DataDir $DataDir -Map $trust }
        return $had
    }
    $plugins = @(Get-ExplorerPlugins -AppRoot $AppRoot -Workspace $Workspace -DataDir $DataDir)
    $hit = $null
    foreach ($p in $plugins) { if ($p.id -eq $Id) { $hit = $p } }
    if (-not $hit) { throw "Plugin '$Id' was not found." }
    if (-not $hit.valid) { throw "Plugin '$Id' is not valid and cannot be trusted: $($hit.error)" }
    if ($ExpectedHash -and $ExpectedHash -ne $hit.hash) { throw "Plugin '$Id' changed since the list was loaded. Refresh, re-read its code, then trust it again." }
    $trust[$Id] = $hit.hash
    Write-PluginTrust -DataDir $DataDir -Map $trust
    return $true
}

function Invoke-PluginTool {
    # Returns the tool result string, or $null when $Name is not a plugin tool.
    # Context: Workspace, DataDir, AppRoot, CancelState (optional), Plugins (optional; refreshed when absent).
    param([Parameter(Mandatory)][string]$Name, $Args, [Parameter(Mandatory)][hashtable]$Context)
    if (-not $Name.StartsWith('plg_')) { return $null }
    $plugins = $Context.Plugins
    if ($null -eq $plugins) { $plugins = @(Get-ExplorerPlugins -AppRoot $Context.AppRoot -Workspace $Context.Workspace -DataDir $Context.DataDir) }
    $hit = Find-PluginTool -Plugins $plugins -Name $Name
    if (-not $hit) { return "Unknown plugin tool: $Name (the plugin may have been removed or is invalid)." }
    $ws = [string]$Context.Workspace
    $t = $hit.Tool
    $a = $Args
    if ($null -eq $a) { $a = [pscustomobject]@{} }
    $argJson = '{}'
    try { $argJson = ($a | ConvertTo-Json -Depth 12 -Compress) } catch { $argJson = '{}' }
    if (-not $argJson) { $argJson = '{}' }
    if ($argJson.Length -gt 8000) { return 'Plugin arguments are over 8000 characters.' }
    $q = { param([string]$s) $s.Replace("'", "''") }
    $argB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argJson))
    $lines = @(
        "`$ErrorActionPreference = 'Continue'",
        "`$ProgressPreference = 'SilentlyContinue'",
        "`$PluginRoot = '$(& $q $hit.Plugin.path)'",
        "`$WorkspaceRoot = '$(& $q $ws)'",
        "`$__plgArgs = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$argB64')))",
        "try { `$__plgSb = [scriptblock]::Create([IO.File]::ReadAllText('$(& $q $t.scriptPath)', [Text.Encoding]::UTF8)) } catch { 'ERROR: could not load plugin script: ' + `$_.Exception.Message; exit 1 }",
        "try { & `$__plgSb `$__plgArgs 2>&1 | Out-String -Width 220 } catch { 'ERROR: ' + `$_.Exception.Message; exit 1 }",
        "if (`$LASTEXITCODE) { exit `$LASTEXITCODE }"
    )
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($lines -join "`r`n")))
    if ($enc.Length -gt 30000) { return 'Plugin call is too long to run.' }
    $res = Invoke-ExplorerProcess -FileName (Get-ExplorerPowerShellExe) -Arguments "-NoProfile -NonInteractive -EncodedCommand $enc" -WorkingDirectory $ws -TimeoutSec $t.timeoutSec -CancelState $Context.CancelState
    $output = $res.StdOut
    if ($res.StdErr -and $res.StdErr.Trim()) { $output = $output.TrimEnd() + "`n[stderr]`n" + $res.StdErr }
    $exit = [string]$res.ExitCode
    if ($res.TimedOut) { $exit = 'timeout' }
    $rel = Save-ExplorerRawOutput -Workspace $ws -Via 'plugin' -Target $hit.Plugin.id -CredentialName '' -Purpose ("plugin " + $Name) -Command ("$Name $argJson") -ExitCode $exit -Output $output
    return (Format-ExplorerQueryResult -RelPath $rel -ExitCode $exit -Output $output -TimedOut $res.TimedOut -TimeoutSec $t.timeoutSec)
}
