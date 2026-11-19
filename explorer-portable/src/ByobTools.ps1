# BYOB Explorer base tools: workspace files, run_command, artifacts, plan, memory, delegate.
# Windows PowerShell 5.1 and PowerShell 7. ASCII only.
# Paths inside the app data folder (Context.DataDir: credentials, settings, plugin trust) are refused
# by every file tool so the model can neither read the credential store nor self-trust a plugin.

function Resolve-SafeWorkspacePath {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$RelOrAbs
    )
    $rootFull = [IO.Path]::GetFullPath($WorkspaceRoot)
    if ([IO.Path]::IsPathRooted($RelOrAbs)) {
        $cand = [IO.Path]::GetFullPath($RelOrAbs)
    } else {
        $cand = [IO.Path]::GetFullPath((Join-Path $rootFull $RelOrAbs))
    }
    return $cand
}

function Read-OfficeXmlText {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $sb = New-Object System.Text.StringBuilder
        if ($ext -eq '.docx') {
            $entry = $zip.GetEntry('word/document.xml')
            if ($entry) {
                $sr = New-Object System.IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
                $xml = [xml]$sr.ReadToEnd(); $sr.Dispose()
                $nodes = $xml.SelectNodes('//*[local-name()="p"]')
                foreach ($p in $nodes) {
                    $line = ($p.SelectNodes('.//*[local-name()="t"]') | ForEach-Object { $_.'#text' }) -join ''
                    if ($line) { [void]$sb.AppendLine($line) }
                }
            }
        } elseif ($ext -eq '.pptx') {
            $slides = @($zip.Entries | Where-Object { $_.FullName -match '^ppt/slides/slide\d+\.xml$' } | Sort-Object FullName)
            foreach ($s in $slides) {
                [void]$sb.AppendLine("--- $($s.Name) ---")
                $sr = New-Object System.IO.StreamReader($s.Open(), [Text.Encoding]::UTF8)
                $xml = [xml]$sr.ReadToEnd(); $sr.Dispose()
                $texts = $xml.SelectNodes('//*[local-name()="t"]') | ForEach-Object { $_.'#text' }
                [void]$sb.AppendLine(($texts -join ' '))
            }
        } elseif ($ext -eq '.xlsx') {
            $shared = @()
            $ssEntry = $zip.GetEntry('xl/sharedStrings.xml')
            if ($ssEntry) {
                $sr = New-Object System.IO.StreamReader($ssEntry.Open(), [Text.Encoding]::UTF8)
                $xml = [xml]$sr.ReadToEnd(); $sr.Dispose()
                $shared = @($xml.SelectNodes('//*[local-name()="si"]') | ForEach-Object {
                    ($_.SelectNodes('.//*[local-name()="t"]') | ForEach-Object { $_.'#text' }) -join ''
                })
            }
            $sheets = @($zip.Entries | Where-Object { $_.FullName -match '^xl/worksheets/sheet\d+\.xml$' } | Sort-Object FullName)
            foreach ($sh in $sheets) {
                [void]$sb.AppendLine("--- $($sh.Name) ---")
                $sr = New-Object System.IO.StreamReader($sh.Open(), [Text.Encoding]::UTF8)
                $xml = [xml]$sr.ReadToEnd(); $sr.Dispose()
                foreach ($row in $xml.SelectNodes('//*[local-name()="row"]')) {
                    $cells = @()
                    foreach ($c in $row.SelectNodes('./*[local-name()="c"]')) {
                        $t = $c.GetAttribute('t')
                        $vNode = $c.SelectSingleNode('./*[local-name()="v"]')
                        $val = if ($vNode) { $vNode.InnerText } else { '' }
                        if ($t -eq 's' -and $val -match '^\d+$' -and [int]$val -lt $shared.Count) {
                            $val = $shared[[int]$val]
                        }
                        $cells += $val
                    }
                    [void]$sb.AppendLine(($cells -join "`t"))
                }
            }
        }
        return $sb.ToString().Trim()
    } finally {
        $zip.Dispose()
    }
}

function Save-UndoBackup {
    param(
        [Parameter(Mandatory)][string]$UndoDir,
        [Parameter(Mandatory)][string]$TurnId,
        [Parameter(Mandatory)][string]$TargetPath
    )
    New-Item -ItemType Directory -Force $UndoDir | Out-Null
    $manifestPath = Join-Path $UndoDir "$TurnId.json"
    $records = @()
    if (Test-Path $manifestPath) {
        $records = @(Get-Content $manifestPath -Raw | ConvertFrom-Json)
    }
    $alreadyTracked = $false
    foreach ($r in $records) { if ($r.path -eq $TargetPath) { $alreadyTracked = $true; break } }
    if ($alreadyTracked) { return }

    $existed = Test-Path -LiteralPath $TargetPath -PathType Leaf
    $backupFile = ''
    if ($existed) {
        $backupFile = Join-Path $UndoDir ("$TurnId-" + [guid]::NewGuid().ToString('N') + '.bak')
        Copy-Item -LiteralPath $TargetPath -Destination $backupFile -Force
    }
    $records = @($records) + @([pscustomobject]@{
        path = $TargetPath
        existed = $existed
        backup = $backupFile
    })
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $json = if ($records.Count -eq 1) { '[' + ($records[0] | ConvertTo-Json -Compress) + ']' } else { ($records | ConvertTo-Json -Compress) }
    [IO.File]::WriteAllText($manifestPath, $json, $utf8)
}

function Invoke-UndoTurn {
    param(
        [Parameter(Mandatory)][string]$UndoDir,
        [Parameter(Mandatory)][string]$TurnId
    )
    $manifestPath = Join-Path $UndoDir "$TurnId.json"
    if (-not (Test-Path $manifestPath)) { return 0 }
    $records = @(Get-Content $manifestPath -Raw | ConvertFrom-Json)
    $restored = 0
    foreach ($r in $records) {
        if ($r.existed -and $r.backup -and (Test-Path -LiteralPath $r.backup)) {
            $parent = Split-Path -Parent $r.path
            if ($parent) { New-Item -ItemType Directory -Force $parent | Out-Null }
            Copy-Item -LiteralPath $r.backup -Destination $r.path -Force
            Remove-Item -LiteralPath $r.backup -Force -ErrorAction SilentlyContinue
            $restored++
        } elseif (-not $r.existed -and (Test-Path -LiteralPath $r.path)) {
            Remove-Item -LiteralPath $r.path -Force -ErrorAction SilentlyContinue
            $restored++
        }
    }
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    return $restored
}

function Get-ByobToolDefinitions {
    param([bool]$IncludeDelegate = $true)
    $tools = @(
        @{
            name = 'list_files'
            access = 'read'
            description = 'List files and folders inside the workspace (or a subdirectory).'
            params = @{
                type = 'object'
                properties = @{
                    path = @{ type = 'string'; description = 'Relative folder path (default ".").' }
                    max_entries = @{ type = 'integer'; description = 'Max entries to return (default 150).' }
                }
            }
        },
        @{
            name = 'read_file'
            access = 'read'
            description = 'Read a text/code file with line numbers, or extract text/tables from .docx, .pptx, or .xlsx files.'
            params = @{
                type = 'object'
                properties = @{
                    path = @{ type = 'string'; description = 'File path relative to workspace (or absolute).' }
                    start_line = @{ type = 'integer'; description = '1-based start line (default 1).' }
                    end_line = @{ type = 'integer'; description = '1-based end line (default 250).' }
                }
                required = @('path')
            }
        },
        @{
            name = 'search_files'
            access = 'read'
            description = 'Search workspace text files for a regex or text pattern.'
            params = @{
                type = 'object'
                properties = @{
                    pattern = @{ type = 'string'; description = 'Text or regex pattern.' }
                    path = @{ type = 'string'; description = 'Subfolder (default ".").' }
                    max_hits = @{ type = 'integer'; description = 'Max matches (default 40).' }
                }
                required = @('pattern')
            }
        },
        @{
            name = 'write_file'
            access = 'write'
            description = 'Write or overwrite a file in the workspace (automatically backed up for turn undo).'
            params = @{
                type = 'object'
                properties = @{
                    path = @{ type = 'string'; description = 'File path.' }
                    content = @{ type = 'string'; description = 'Full file content.' }
                }
                required = @('path', 'content')
            }
        },
        @{
            name = 'edit_file'
            access = 'write'
            description = 'Replace exact text in a workspace file (automatically backed up for turn undo).'
            params = @{
                type = 'object'
                properties = @{
                    path = @{ type = 'string'; description = 'File path.' }
                    target = @{ type = 'string'; description = 'Exact existing text.' }
                    replacement = @{ type = 'string'; description = 'Replacement text.' }
                }
                required = @('path', 'target', 'replacement')
            }
        },
        @{
            name = 'run_command'
            access = 'execute'
            description = 'Run ANY Windows PowerShell 5.1 command inside the workspace directory. NOT checked by the read-only gate, so the user is always asked first. Prefer net_query/ssh_query for investigation.'
            params = @{
                type = 'object'
                properties = @{
                    command = @{ type = 'string'; description = 'PowerShell command to execute.' }
                    timeout_sec = @{ type = 'integer'; description = 'Timeout seconds (default 30, max 600).' }
                }
                required = @('command')
            }
        },
        @{
            name = 'create_artifact'
            access = 'write'
            description = 'Create or update a side-pane artifact (Markdown document, CSV/JSON spreadsheet, HTML interactive app, or Chart JSON) with version history.'
            params = @{
                type = 'object'
                properties = @{
                    id = @{ type = 'string'; description = 'Optional existing artifact ID to add a new version.' }
                    title = @{ type = 'string'; description = 'Short title.' }
                    content_type = @{ type = 'string'; enum = @('text/markdown', 'text/csv', 'text/html', 'application/vnd.byob.chart+json', 'text/plain'); description = 'Artifact MIME/content type.' }
                    content = @{ type = 'string'; description = 'Full artifact content.' }
                }
                required = @('title', 'content_type', 'content')
            }
        },
        @{
            name = 'update_plan'
            access = 'read'
            description = 'Update the step plan checklist shown to the user.'
            params = @{
                type = 'object'
                properties = @{
                    steps = @{
                        type = 'array'
                        items = @{
                            type = 'object'
                            properties = @{
                                title = @{ type = 'string' }
                                status = @{ type = 'string'; enum = @('pending', 'in_progress', 'done') }
                            }
                            required = @('title', 'status')
                        }
                    }
                }
                required = @('steps')
            }
        },
        @{
            name = 'remember'
            access = 'write'
            description = 'Save a persistent note to memory.md across chats.'
            params = @{
                type = 'object'
                properties = @{
                    note = @{ type = 'string'; description = 'Concise note to remember.' }
                    scope = @{ type = 'string'; enum = @('global', 'workspace'); description = 'Where to save (default global).' }
                }
                required = @('note')
            }
        }
    )

    if ($IncludeDelegate) {
        $tools += @{
            name = 'delegate'
            access = 'read'
            description = 'Run a focused read-only subagent (it can use read-access tools only: files, kb, read-only queries) and return a concise report.'
            params = @{
                type = 'object'
                properties = @{
                    task = @{ type = 'string'; description = 'Clear instructions for the subagent.' }
                }
                required = @('task')
            }
        }
    }
    return $tools
}

function Invoke-ByobTool {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Args,
        [Parameter(Mandatory)][hashtable]$Context
    )

    $a = if ($Args) { $Args } else { [pscustomobject]@{} }
    function Arg($Key, $Def = $null) {
        if ($a -is [System.Collections.IDictionary]) {
            if ($a.Contains($Key)) { return $a[$Key] }
            return $Def
        }
        if ($a.PSObject.Properties.Name -contains $Key) { return $a.$Key }
        return $Def
    }

    $ws = $Context.Workspace
    $dataDir = $Context.DataDir
    $undoDir = $Context.UndoDir
    $turnId = $Context.TurnId
    $guardPath = {
        param([string]$P)
        if ($dataDir) {
            $dd = [IO.Path]::GetFullPath([string]$dataDir).TrimEnd([char[]]@('\', '/'))
            $full = [IO.Path]::GetFullPath($P)
            $cmp = [StringComparison]::OrdinalIgnoreCase
            if ($full.Equals($dd, $cmp) -or $full.StartsWith($dd + [IO.Path]::DirectorySeparatorChar, $cmp) -or $full.StartsWith($dd + '/', $cmp)) {
                throw "That path is inside the app's private data folder (credentials, settings, plugin trust) and is off limits to tools."
            }
        }
    }

    switch ($Name) {
        'list_files' {
            $rel = [string](Arg 'path' '.')
            $max = [int](Arg 'max_entries' 150)
            $dir = Resolve-SafeWorkspacePath -WorkspaceRoot $ws -RelOrAbs $rel
            & $guardPath $dir
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return "Folder not found: $dir" }
            $items = Get-ChildItem -LiteralPath $dir -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\\.git\\|\\node_modules\\|\\\.byob\\' } |
                Select-Object -First $max |
                ForEach-Object {
                    $r = $_.FullName.Substring($dir.Length).TrimStart('\')
                    if ($_.PSIsContainer) { "$r/" } else { "$r ($($_.Length) B)" }
                }
            if (-not $items) { return '(empty folder)' }
            return ($items -join "`n")
        }
        'read_file' {
            $p = Resolve-SafeWorkspacePath -WorkspaceRoot $ws -RelOrAbs ([string](Arg 'path' ''))
            & $guardPath $p
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return "File not found: $p" }
            $ext = [IO.Path]::GetExtension($p).ToLowerInvariant()
            if ($ext -in @('.docx', '.pptx', '.xlsx')) {
                $txt = Read-OfficeXmlText -Path $p
                if ($txt.Length -gt 24000) { $txt = $txt.Substring(0, 24000) + "`n...(truncated)" }
                return $txt
            }
            $start = [Math]::Max(1, [int](Arg 'start_line' 1))
            $end = [Math]::Max($start, [int](Arg 'end_line' ($start + 249)))
            $lines = [IO.File]::ReadAllLines($p, [Text.Encoding]::UTF8)
            $total = $lines.Length
            if ($total -eq 0) { return '(empty file)' }
            $hi = [Math]::Min($total, $end)
            $out = New-Object System.Text.StringBuilder
            [void]$out.AppendLine("File: $p (lines $start-$hi of $total)")
            for ($i = $start; $i -le $hi; $i++) {
                [void]$out.AppendLine(('{0,4}: {1}' -f $i, $lines[$i - 1]))
            }
            return $out.ToString()
        }
        'search_files' {
            $pat = [string](Arg 'pattern' '')
            $rel = [string](Arg 'path' '.')
            $max = [int](Arg 'max_hits' 40)
            $dir = Resolve-SafeWorkspacePath -WorkspaceRoot $ws -RelOrAbs $rel
            & $guardPath $dir
            if (-not (Test-Path -LiteralPath $dir)) { return "Path not found: $dir" }
            $hits = Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\\.git\\|\\node_modules\\' -and $_.Length -lt 2MB } |
                Select-String -Pattern $pat -ErrorAction SilentlyContinue |
                Select-Object -First $max |
                ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }
            if (-not $hits) { return 'No matches.' }
            return ($hits -join "`n")
        }
        'write_file' {
            $p = Resolve-SafeWorkspacePath -WorkspaceRoot $ws -RelOrAbs ([string](Arg 'path' ''))
            & $guardPath $p
            $content = [string](Arg 'content' '')
            $parent = Split-Path -Parent $p
            if ($parent) { New-Item -ItemType Directory -Force $parent | Out-Null }
            Save-UndoBackup -UndoDir $undoDir -TurnId $turnId -TargetPath $p
            [IO.File]::WriteAllText($p, $content, (New-Object System.Text.UTF8Encoding $false))
            return "Wrote $($content.Length) chars to $p"
        }
        'edit_file' {
            $p = Resolve-SafeWorkspacePath -WorkspaceRoot $ws -RelOrAbs ([string](Arg 'path' ''))
            & $guardPath $p
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return "File not found: $p" }
            $target = [string](Arg 'target' '')
            $replacement = [string](Arg 'replacement' '')
            $text = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
            if (-not $text.Contains($target)) { return 'Target text not found in file.' }
            Save-UndoBackup -UndoDir $undoDir -TurnId $turnId -TargetPath $p
            $updated = $text.Replace($target, $replacement)
            [IO.File]::WriteAllText($p, $updated, (New-Object System.Text.UTF8Encoding $false))
            return "Edited $p"
        }
        'run_command' {
            $cmd = [string](Arg 'command' '')
            if (-not $cmd.Trim()) { return 'run_command needs a command.' }
            $timeoutSec = 30
            try { $timeoutSec = [int](Arg 'timeout_sec' 30) } catch { $timeoutSec = 30 }
            $timeoutSec = [Math]::Max(5, [Math]::Min(600, $timeoutSec))
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
            if ($enc.Length -gt 30000) { return 'Command is too long to run. Put it in a script file and run that.' }
            # No -ExecutionPolicy override: the machine's policy applies to anything the command starts.
            $res = Invoke-ExplorerProcess -FileName (Get-ExplorerPowerShellExe) -Arguments "-NoProfile -NonInteractive -EncodedCommand $enc" -WorkingDirectory $ws -TimeoutSec $timeoutSec -CancelState $Context.CancelState
            $exit = [string]$res.ExitCode
            if ($res.TimedOut) { $exit = "timeout after ${timeoutSec}s (process killed)" }
            if ($res.Cancelled) { $exit = 'stopped by user (process killed)' }
            $combined = "Exit code: $exit`n$($res.StdOut)"
            if ($res.StdErr -and $res.StdErr.Trim()) { $combined += "`n[stderr]`n$($res.StdErr)" }
            if ($combined.Length -gt 16000) { $combined = $combined.Substring(0, 12000) + "`n...(truncated $($combined.Length - 16000) chars)...`n" + $combined.Substring($combined.Length - 4000) }
            return $combined.Trim()
        }
        'create_artifact' {
            $artId = [string](Arg 'id' '')
            if (-not $artId) { $artId = 'art_' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
            $title = [string](Arg 'title' 'Artifact')
            $ctype = [string](Arg 'content_type' 'text/markdown')
            $content = [string](Arg 'content' '')
            $art = & $Context.SaveArtifact $artId $title $ctype $content
            return "Saved artifact '$($art.title)' (id=$($art.id), version=$($art.version), type=$($art.content_type))."
        }
        'update_plan' {
            $steps = @(Arg 'steps' @())
            & $Context.SavePlan $steps
            return "Updated plan with $($steps.Count) step(s)."
        }
        'remember' {
            $note = [string](Arg 'note' '')
            $scope = [string](Arg 'scope' 'global')
            $memFile = if ($scope -eq 'workspace') { Join-Path $ws '.byob\memory.md' } else { Join-Path $dataDir 'memory.md' }
            New-Item -ItemType Directory -Force (Split-Path -Parent $memFile) | Out-Null
            [IO.File]::AppendAllText($memFile, "- [$(Get-Date -Format 'yyyy-MM-dd')] $note`r`n", (New-Object System.Text.UTF8Encoding $false))
            return "Saved note to $memFile"
        }
        'delegate' {
            $subTask = [string](Arg 'task' '')
            return (& $Context.RunSubagent $subTask)
        }
        default {
            return "Unknown tool: $Name"
        }
    }
}
