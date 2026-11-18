# BYOB Portable Workspace, Artifact, Memory, Plan, and Outlook Classic Tools (Windows PowerShell 5.1). ASCII only.

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
            description = 'Run a Windows PowerShell 5.1 command inside the workspace directory.'
            params = @{
                type = 'object'
                properties = @{
                    command = @{ type = 'string'; description = 'PowerShell command to execute.' }
                    timeout_sec = @{ type = 'integer'; description = 'Timeout seconds (default 30).' }
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
        },
        @{
            name = 'outlook_status'
            access = 'read'
            description = 'Check whether Classic Outlook is available and return profile, user email, and Inbox unread count.'
            params = @{ type = 'object'; properties = @{} }
        },
        @{
            name = 'outlook_folders'
            access = 'read'
            description = 'List Classic Outlook MAPI folders and subfolders with total and unread counts.'
            params = @{ type = 'object'; properties = @{} }
        },
        @{
            name = 'outlook_search'
            access = 'read'
            description = 'Search Classic Outlook emails (newest first). Returns EntryID, date, from, to, subject, unread, reply status, and preview.'
            params = @{
                type = 'object'
                properties = @{
                    folder = @{ type = 'string'; description = 'Folder name or path (default Inbox; also Sent Items, Drafts, Archive, or Inbox/Subfolder).' }
                    from = @{ type = 'string'; description = 'Sender contains this.' }
                    to = @{ type = 'string'; description = 'Recipient contains this.' }
                    subject = @{ type = 'string'; description = 'Subject contains this.' }
                    text = @{ type = 'string'; description = 'Subject, sender, or body contains this.' }
                    unread = @{ type = 'boolean'; description = 'true: only unread; false: only read.' }
                    days_back = @{ type = 'integer'; description = 'Days back to scan (default 14; 0 = all).' }
                    limit = @{ type = 'integer'; description = 'Max messages (default 20, max 100).' }
                }
            }
        },
        @{
            name = 'outlook_read'
            access = 'read'
            description = 'Read a Classic Outlook email by entry_id: headers, attachments, and body text.'
            params = @{
                type = 'object'
                properties = @{
                    entry_id = @{ type = 'string'; description = 'EntryID from outlook_search.' }
                    start = @{ type = 'integer'; description = 'Character offset (default 0).' }
                    max_chars = @{ type = 'integer'; description = 'Max chars (1000-40000, default 12000).' }
                }
                required = @('entry_id')
            }
        },
        @{
            name = 'outlook_thread'
            access = 'read'
            description = 'Read all messages in the same Outlook conversation across Inbox and Sent Items.'
            params = @{
                type = 'object'
                properties = @{
                    entry_id = @{ type = 'string'; description = 'EntryID of any message in the conversation.' }
                    limit = @{ type = 'integer'; description = 'Max messages (default 15, max 40).' }
                }
                required = @('entry_id')
            }
        },
        @{
            name = 'outlook_open'
            access = 'read'
            description = 'Display an email item in the Classic Outlook window.'
            params = @{
                type = 'object'
                properties = @{
                    entry_id = @{ type = 'string' }
                }
                required = @('entry_id')
            }
        },
        @{
            name = 'outlook_draft_reply'
            access = 'write'
            description = 'Create a reply draft in Classic Outlook preserving the user signature (saved to Drafts; never auto-sent).'
            params = @{
                type = 'object'
                properties = @{
                    entry_id = @{ type = 'string' }
                    body = @{ type = 'string'; description = 'Plain-text reply body without a manual signature.' }
                    reply_all = @{ type = 'boolean' }
                    subject = @{ type = 'string' }
                    open_window = @{ type = 'boolean' }
                }
                required = @('entry_id', 'body')
            }
        },
        @{
            name = 'outlook_draft_new'
            access = 'write'
            description = 'Create a new email draft in Classic Outlook (saved to Drafts; never auto-sent).'
            params = @{
                type = 'object'
                properties = @{
                    to = @{ type = 'string' }
                    cc = @{ type = 'string' }
                    bcc = @{ type = 'string' }
                    subject = @{ type = 'string' }
                    body = @{ type = 'string' }
                    open_window = @{ type = 'boolean' }
                }
                required = @('to', 'subject', 'body')
            }
        },
        @{
            name = 'outlook_mark'
            access = 'write'
            description = 'Mark emails read/unread, add a category, or move to Archive or a named folder.'
            params = @{
                type = 'object'
                properties = @{
                    entry_ids = @{ type = 'array'; items = @{ type = 'string' } }
                    action = @{ type = 'string'; enum = @('read', 'unread', 'category', 'move', 'archive') }
                    value = @{ type = 'string'; description = 'Category name or destination folder.' }
                }
                required = @('entry_ids', 'action')
            }
        },
        @{
            name = 'outlook_send'
            access = 'network'
            confirm = 'Sends this email from your Classic Outlook account. It cannot be unsent.'
            description = 'Send an email or existing draft via Classic Outlook. Always requires explicit user approval.'
            params = @{
                type = 'object'
                properties = @{
                    to = @{ type = 'string' }
                    cc = @{ type = 'string' }
                    bcc = @{ type = 'string' }
                    subject = @{ type = 'string' }
                    body = @{ type = 'string' }
                    draft_entry_id = @{ type = 'string' }
                    in_reply_to = @{ type = 'string' }
                }
            }
        }
    )

    if ($IncludeDelegate) {
        $tools += @{
            name = 'delegate'
            access = 'read'
            description = 'Run a focused subagent task to research workspace files or Outlook emails and return a concise report.'
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
    $allowSensitive = [bool]$Context.AllowSensitiveMail

    switch ($Name) {
        'list_files' {
            $rel = [string](Arg 'path' '.')
            $max = [int](Arg 'max_entries' 150)
            $dir = Resolve-SafeWorkspacePath -WorkspaceRoot $ws -RelOrAbs $rel
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
            $content = [string](Arg 'content' '')
            $parent = Split-Path -Parent $p
            if ($parent) { New-Item -ItemType Directory -Force $parent | Out-Null }
            Save-UndoBackup -UndoDir $undoDir -TurnId $turnId -TargetPath $p
            [IO.File]::WriteAllText($p, $content, (New-Object System.Text.UTF8Encoding $false))
            return "Wrote $($content.Length) chars to $p"
        }
        'edit_file' {
            $p = Resolve-SafeWorkspacePath -WorkspaceRoot $ws -RelOrAbs ([string](Arg 'path' ''))
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
            $timeoutSec = [Math]::Max(5, [Math]::Min(180, [int](Arg 'timeout_sec' 30)))
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
            $psi.WorkingDirectory = $ws
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit($timeoutSec * 1000)) {
                try { $proc.Kill() } catch { }
                return "Command timed out after ${timeoutSec}s."
            }
            $out = $stdoutTask.GetAwaiter().GetResult()
            $err = $stderrTask.GetAwaiter().GetResult()
            $combined = "Exit code: $($proc.ExitCode)`n$out"
            if ($err) { $combined += "`n[stderr]`n$err" }
            if ($combined.Length -gt 16000) { $combined = $combined.Substring(0, 16000) + "`n...(truncated)" }
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
        'outlook_status' { return ((Invoke-OutlookStatus) | ConvertTo-Json -Depth 6) }
        'outlook_folders' { return ((Invoke-OutlookFolders) | ConvertTo-Json -Depth 6) }
        'outlook_search' {
            $daysRaw = Arg 'days_back' 14
            $limRaw = Arg 'limit' 20
            $unread = Arg 'unread' $null
            $res = Invoke-OutlookSearch `
                -Folder ([string](Arg 'folder' 'Inbox')) `
                -From ([string](Arg 'from' '')) `
                -To ([string](Arg 'to' '')) `
                -Subject ([string](Arg 'subject' '')) `
                -Text ([string](Arg 'text' '')) `
                -Unread $unread `
                -DaysBack ([int]$daysRaw) `
                -Limit ([int]$limRaw) `
                -AllowSensitive $allowSensitive
            return ($res | ConvertTo-Json -Depth 8)
        }
        'outlook_read' {
            $res = Invoke-OutlookRead `
                -EntryID ([string](Arg 'entry_id' '')) `
                -Start ([int](Arg 'start' 0)) `
                -MaxChars ([int](Arg 'max_chars' 12000)) `
                -AllowSensitive $allowSensitive
            return ($res | ConvertTo-Json -Depth 6)
        }
        'outlook_thread' {
            $res = Invoke-OutlookThread `
                -EntryID ([string](Arg 'entry_id' '')) `
                -Limit ([int](Arg 'limit' 15)) `
                -AllowSensitive $allowSensitive
            return ($res | ConvertTo-Json -Depth 8)
        }
        'outlook_open' {
            return ((Invoke-OutlookOpen -EntryID ([string](Arg 'entry_id' ''))) | ConvertTo-Json -Depth 4)
        }
        'outlook_draft_reply' {
            $res = Invoke-OutlookDraftReply `
                -EntryID ([string](Arg 'entry_id' '')) `
                -Body ([string](Arg 'body' '')) `
                -ReplyAll ([bool](Arg 'reply_all' $false)) `
                -Subject ([string](Arg 'subject' '')) `
                -OpenWindow ([bool](Arg 'open_window' $false))
            return ($res | ConvertTo-Json -Depth 4)
        }
        'outlook_draft_new' {
            $res = Invoke-OutlookDraftNew `
                -To ([string](Arg 'to' '')) `
                -Cc ([string](Arg 'cc' '')) `
                -Bcc ([string](Arg 'bcc' '')) `
                -Subject ([string](Arg 'subject' '')) `
                -Body ([string](Arg 'body' '')) `
                -OpenWindow ([bool](Arg 'open_window' $false))
            return ($res | ConvertTo-Json -Depth 4)
        }
        'outlook_mark' {
            $eids = @(Arg 'entry_ids' @() | ForEach-Object { [string]$_ })
            $res = Invoke-OutlookMark -EntryIDs $eids -Action ([string](Arg 'action' '')) -Value ([string](Arg 'value' ''))
            return ($res | ConvertTo-Json -Depth 4)
        }
        'outlook_send' {
            $res = Invoke-OutlookSend `
                -To ([string](Arg 'to' '')) `
                -Cc ([string](Arg 'cc' '')) `
                -Bcc ([string](Arg 'bcc' '')) `
                -Subject ([string](Arg 'subject' '')) `
                -Body ([string](Arg 'body' '')) `
                -DraftEntryID ([string](Arg 'draft_entry_id' '')) `
                -InReplyTo ([string](Arg 'in_reply_to' ''))
            return ($res | ConvertTo-Json -Depth 4)
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
