# ExplorerTools.ps1 - Network explorer tools for BYOB (Windows PowerShell 5.1 + PowerShell 7). ASCII only.
# Requires NetGate.ps1 and CredStore.ps1 to be dot-sourced first.
#
# Exports:
#   Get-ExplorerToolDefinitions                 -> tool definitions (same shape as Get-ByobToolDefinitions)
#   Invoke-ExplorerTool -Name -Args -Context     -> tool result string, or $null for tools it does not own
#   Get-ExplorerSystemPrompt -Workspace -CredentialNames
#
# Context hashtable: Workspace (required), DataDir (required), CredentialNames (optional),
#   CancelState (optional hashtable with a 'cancel' key: a running child process is killed when it turns true).

# =============================================================================
#  Helpers
# =============================================================================
function Get-ExplorerArg {
    param($A, [string]$Key, $Default = $null)
    if ($null -eq $A) { return $Default }
    if ($A -is [System.Collections.IDictionary]) {
        if ($A.Contains($Key) -and $null -ne $A[$Key]) { return $A[$Key] }
        return $Default
    }
    if ($A.PSObject.Properties.Name -contains $Key -and $null -ne $A.$Key) { return $A.$Key }
    return $Default
}

function Test-ExplorerIsWindows {
    return ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
}

function Get-ExplorerPowerShellExe {
    if (Test-ExplorerIsWindows) {
        return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
    # Test runtime (PowerShell 7 on Linux): use the current pwsh executable.
    return [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}

function ConvertTo-ExplorerWinArg {
    # Quote one argument for ProcessStartInfo.Arguments using MSVCRT / CommandLineToArgvW rules.
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append([char]92, ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0; continue
        }
        if ($bs -gt 0) { [void]$sb.Append([char]92, $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append([char]92, ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertFrom-ExplorerClixml {
    # powershell.exe -EncodedCommand writes error/progress records to stderr as CLIXML; make it readable.
    param([string]$Text)
    if (-not $Text) { return '' }
    if ($Text -notmatch '#< CLIXML') { return $Text }
    $out = New-Object System.Text.StringBuilder
    foreach ($m in [regex]::Matches($Text, '<S S="(Error|Warning|Verbose|Debug|Information)">(.*?)</S>')) {
        $s = $m.Groups[2].Value -replace '_x000D__x000A_', "`n" -replace '_x000A_', "`n" -replace '_x000D_', ''
        $s = $s.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&apos;', "'").Replace('&amp;', '&')
        [void]$out.Append($s)
    }
    return $out.ToString()
}

function Invoke-ExplorerProcess {
    # Runs a process with captured output and an enforced timeout (kill on timeout).
    # $Environment entries are set ONLY on the child's ProcessStartInfo, never on this process.
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSec = 60,
        [hashtable]$Environment,
        $CancelState = $null     # hashtable with a 'cancel' key; when it turns true the child is killed
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    if ($Environment) { foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k] } }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($Environment) { foreach ($k in @($Environment.Keys)) { $psi.EnvironmentVariables.Remove([string]$k) } }
    try { $proc.StandardInput.Close() } catch { }
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = $false
    $cancelled = $false
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $proc.WaitForExit(200)) {
        if ($CancelState -and $CancelState.cancel) { $cancelled = $true }
        if ((Get-Date) -gt $deadline) { $timedOut = $true }
        if ($cancelled -or $timedOut) {
            try { $proc.Kill() } catch { }
            try { [void]$proc.WaitForExit(5000) } catch { }
            break
        }
    }
    $out = ''
    $err = ''
    try { if ($stdoutTask.Wait(5000)) { $out = $stdoutTask.Result } } catch { }
    try { if ($stderrTask.Wait(5000)) { $err = $stderrTask.Result } } catch { }
    $code = -1
    if (-not $timedOut -and -not $cancelled) { try { $code = $proc.ExitCode } catch { } }
    try { $proc.Dispose() } catch { }
    if ($cancelled) { $err = ([string]$err) + "`n[stopped by user: process killed]" }
    return [pscustomobject]@{ ExitCode = $code; StdOut = [string]$out; StdErr = (ConvertFrom-ExplorerClixml ([string]$err)); TimedOut = $timedOut; Cancelled = $cancelled }
}

function Get-ExplorerSlug {
    param([string]$Text)
    $s = ([string]$Text).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).Trim('-') }
    if (-not $s) { $s = 'query' }
    return $s
}

function Save-ExplorerRawOutput {
    # Writes the full output with a header to <Workspace>\raw\ and returns the workspace-relative path.
    param([string]$Workspace, [string]$Via, [string]$Target, [string]$CredentialName, [string]$Purpose,
        [string]$Command, [string]$ExitCode, [string]$Output)
    $rawDir = Join-Path $Workspace 'raw'
    if (-not (Test-Path -LiteralPath $rawDir)) { New-Item -ItemType Directory -Force $rawDir | Out-Null }
    $now = Get-Date
    $base = $now.ToString('yyyyMMdd-HHmmss') + '-' + (Get-ExplorerSlug $Purpose)
    $name = "$base.txt"
    $n = 2
    while (Test-Path -LiteralPath (Join-Path $rawDir $name)) { $name = "$base-$n.txt"; $n++ }
    $hdr = New-Object System.Text.StringBuilder
    [void]$hdr.AppendLine("# time: " + $now.ToString('s'))
    [void]$hdr.AppendLine("# via: $Via")
    [void]$hdr.AppendLine("# target: $Target")
    [void]$hdr.AppendLine("# credential: $CredentialName")
    [void]$hdr.AppendLine("# purpose: $Purpose")
    [void]$hdr.AppendLine("# exit: $ExitCode")
    [void]$hdr.AppendLine('# command:')
    [void]$hdr.AppendLine($Command)
    [void]$hdr.AppendLine('# ---- output ----')
    [IO.File]::WriteAllText((Join-Path $rawDir $name), ($hdr.ToString() + $Output), (New-Object System.Text.UTF8Encoding $false))
    return "raw/$name"
}

function Format-ExplorerQueryResult {
    param([string]$RelPath, [string]$ExitCode, [string]$Output, [bool]$TimedOut, [int]$TimeoutSec)
    $o = ([string]$Output).TrimEnd()
    if ($o.Length -gt 6000) {
        $o = $o.Substring(0, 4000) + "`n... [truncated $($o.Length - 6000) chars; full output in $RelPath] ...`n" + $o.Substring($o.Length - 2000)
    }
    if (-not $o) { $o = '(no output)' }
    $head = "Raw output saved: $RelPath | exit code: $ExitCode"
    if ($TimedOut) { $head += " | TIMED OUT after ${TimeoutSec}s (process killed; output may be partial)" }
    return "$head`n$o"
}

function Resolve-ExplorerWorkspacePath {
    # Resolves a workspace-relative path; returns $null when it escapes the workspace.
    param([string]$Workspace, [string]$Rel)
    if ([string]::IsNullOrWhiteSpace($Rel)) { return $null }
    $root = [IO.Path]::GetFullPath($Workspace).TrimEnd([char[]]@('\', '/'))
    if ([IO.Path]::IsPathRooted($Rel)) { $full = [IO.Path]::GetFullPath($Rel) }
    else { $full = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $Rel)) }
    $cmp = [StringComparison]::OrdinalIgnoreCase
    if ($full.Equals($root, $cmp)) { return $full }
    if (-not ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, $cmp) -or $full.StartsWith($root + '/', $cmp))) { return $null }
    return $full
}

function Resolve-ExplorerKbPath {
    # Validates a kb file name and returns the full path, or throws.
    param([string]$Workspace, [string]$File)
    $f = ([string]$File).Trim()
    if ($f.StartsWith('kb/') -or $f.StartsWith('kb\')) { $f = $f.Substring(3) }
    if ($f -notmatch '^[A-Za-z0-9._/-]{1,120}\.md$' -or $f.Contains('..') -or $f.StartsWith('/') -or $f.Contains('//')) {
        throw "Invalid kb file '$File'. Use a relative name like 20-network.md or hosts/esx01.md (letters, digits, . _ - /, ending in .md, no '..')."
    }
    $kbRoot = [IO.Path]::GetFullPath((Join-Path $Workspace 'kb'))
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($kbRoot, $f))
    if (-not $full.StartsWith($kbRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Invalid kb file '$File' (outside kb/)."
    }
    return $full
}

function Write-ExplorerUtf8 {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-ExplorerScope {
    param([string]$Workspace)
    return (Read-ScopeConfig -Path (Join-Path (Join-Path $Workspace '.byob') 'scope.json'))
}

function Test-ExplorerTargetName {
    param([string]$Target)
    return ($Target -match '^[A-Za-z0-9][A-Za-z0-9._:-]{0,252}$')
}

# =============================================================================
#  Frontier
# =============================================================================
function Read-ExplorerFrontier {
    param([string]$Workspace)
    $path = Join-Path (Join-Path $Workspace 'kb') 'frontier.json'
    $items = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $path) {
        $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $obj = ConvertFrom-Json -InputObject $raw
            foreach ($it in @($obj.items)) {
                if ($null -eq $it) { continue }
                [void]$items.Add([pscustomobject]@{
                    id = [string]$it.id; target = [string]$it.target; question = [string]$it.question
                    priority = [int]$it.priority; status = [string]$it.status; note = [string]$it.note
                    added = [string]$it.added; updated = [string]$it.updated
                })
            }
        }
    }
    return ,$items
}

function Write-ExplorerFrontier {
    param([string]$Workspace, $Items)
    $path = Join-Path (Join-Path $Workspace 'kb') 'frontier.json'
    $parts = @()
    foreach ($it in @($Items)) { $parts += ($it | ConvertTo-Json -Compress -Depth 3) }
    Write-ExplorerUtf8 -Path $path -Text ('{"items":[' + ($parts -join ",`n") + ']}')
}

function Invoke-ExplorerFrontier {
    param([string]$Workspace, $A)
    $action = ([string](Get-ExplorerArg $A 'action' 'list')).ToLowerInvariant()
    $items = Read-ExplorerFrontier -Workspace $Workspace
    $now = (Get-Date).ToString('s')
    switch ($action) {
        'add' {
            $new = Get-ExplorerArg $A 'items' @()
            if ($new -is [string]) { $new = ConvertFrom-Json -InputObject $new }
            $keys = @{}
            $maxId = 0
            foreach ($it in $items) {
                $keys[($it.target.ToLowerInvariant() + '|' + $it.question.ToLowerInvariant())] = $it.id
                if ($it.id -match '^F(\d+)$' -and [int]$Matches[1] -gt $maxId) { $maxId = [int]$Matches[1] }
            }
            $added = @()
            $dupes = 0
            foreach ($n in @($new)) {
                if ($null -eq $n) { continue }
                $t = ([string](Get-ExplorerArg $n 'target' '')).Trim()
                $q = ([string](Get-ExplorerArg $n 'question' '')).Trim()
                if (-not $t -and -not $q) { continue }
                $k = $t.ToLowerInvariant() + '|' + $q.ToLowerInvariant()
                if ($keys.ContainsKey($k)) { $dupes++; continue }
                $pr = 3
                try { $pr = [int](Get-ExplorerArg $n 'priority' 3) } catch { $pr = 3 }
                $pr = [Math]::Max(1, [Math]::Min(5, $pr))
                $maxId++
                $id = 'F{0:000}' -f $maxId
                [void]$items.Add([pscustomobject]@{ id = $id; target = $t; question = $q; priority = $pr; status = 'open'; note = ''; added = $now; updated = $now })
                $keys[$k] = $id
                $added += $id
            }
            Write-ExplorerFrontier -Workspace $Workspace -Items $items
            $open = @($items | Where-Object { $_.status -eq 'open' }).Count
            return "Frontier: added $($added.Count) ($($added -join ', ')), skipped $dupes duplicate(s). Open items: $open."
        }
        { $_ -in @('done', 'skip') } {
            $id = ([string](Get-ExplorerArg $A 'id' '')).Trim().ToUpperInvariant()
            $note = [string](Get-ExplorerArg $A 'note' '')
            $hit = $null
            foreach ($it in $items) { if ($it.id -eq $id) { $hit = $it } }
            if (-not $hit) { return "Frontier item '$id' not found." }
            if ($action -eq 'done') { $hit.status = 'done' } else { $hit.status = 'skipped' }
            $hit.note = $note
            $hit.updated = $now
            Write-ExplorerFrontier -Workspace $Workspace -Items $items
            $open = @($items | Where-Object { $_.status -eq 'open' }).Count
            return "Frontier: $id marked $($hit.status). Open items: $open."
        }
        'list' {
            $open = @($items | Where-Object { $_.status -eq 'open' } | Sort-Object priority, id)
            $done = @($items | Where-Object { $_.status -eq 'done' }).Count
            $skip = @($items | Where-Object { $_.status -eq 'skipped' }).Count
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("Frontier: $($open.Count) open, $done done, $skip skipped.")
            $shown = 0
            foreach ($it in $open) {
                if ($shown -ge 40) { [void]$sb.AppendLine("... $($open.Count - 40) more open item(s)"); break }
                [void]$sb.AppendLine(("{0} p{1} {2} :: {3}" -f $it.id, $it.priority, $it.target, $it.question))
                $shown++
            }
            return $sb.ToString().TrimEnd()
        }
        default { return "Unknown frontier action '$action'. Use add, list, done or skip." }
    }
}

# =============================================================================
#  Diff
# =============================================================================
function Get-ExplorerDiffLines {
    # Returns body lines of a file; for raw query files the header is dropped.
    param([string]$Path)
    $lines = @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8))
    for ($i = 0; $i -lt [Math]::Min($lines.Count, 400); $i++) {
        if ($lines[$i] -eq '# ---- output ----') {
            if ($i + 1 -lt $lines.Count) { return ,([string[]]$lines[($i + 1)..($lines.Count - 1)]) }
            return ,([string[]]@())
        }
    }
    return ,([string[]]$lines)
}

function Compare-ExplorerLines {
    # Line diff. Returns an ArrayList of strings like "-old" / "+new" with "@@" hunk markers.
    param([string[]]$A, [string[]]$B)
    $out = New-Object System.Collections.ArrayList
    $n = $A.Count; $m = $B.Count
    $pre = 0
    while ($pre -lt $n -and $pre -lt $m -and $A[$pre] -ceq $B[$pre]) { $pre++ }
    $suf = 0
    while ($suf -lt ($n - $pre) -and $suf -lt ($m - $pre) -and $A[$n - 1 - $suf] -ceq $B[$m - 1 - $suf]) { $suf++ }
    $a2 = @(); $b2 = @()
    if ($n - $pre - $suf -gt 0) { $a2 = @($A[$pre..($n - $suf - 1)]) }
    if ($m - $pre - $suf -gt 0) { $b2 = @($B[$pre..($m - $suf - 1)]) }
    $na = $a2.Count; $nb = $b2.Count
    if ($na -eq 0 -and $nb -eq 0) { return ,$out }
    if (($na * $nb) -gt 250000) {
        # Too large for LCS in PowerShell: report lines present on only one side.
        [void]$out.Add("@@ -$($pre + 1) +$($pre + 1) @@ (large change; unordered comparison)")
        $setB = @{}; foreach ($x in $b2) { $setB[$x] = $true }
        $setA = @{}; foreach ($x in $a2) { $setA[$x] = $true }
        foreach ($x in $a2) { if (-not $setB.ContainsKey($x)) { [void]$out.Add("-$x") } }
        foreach ($x in $b2) { if (-not $setA.ContainsKey($x)) { [void]$out.Add("+$x") } }
        return ,$out
    }
    # LCS table (lengths of suffixes)
    $w = $nb + 1
    $L = New-Object 'int[]' (($na + 1) * $w)
    for ($i = $na - 1; $i -ge 0; $i--) {
        for ($j = $nb - 1; $j -ge 0; $j--) {
            if ($a2[$i] -ceq $b2[$j]) { $L[$i * $w + $j] = $L[($i + 1) * $w + $j + 1] + 1 }
            else {
                $x1 = $L[($i + 1) * $w + $j]; $x2 = $L[$i * $w + $j + 1]
                if ($x1 -ge $x2) { $L[$i * $w + $j] = $x1 } else { $L[$i * $w + $j] = $x2 }
            }
        }
    }
    $i = 0; $j = 0; $inHunk = $false
    while ($i -lt $na -or $j -lt $nb) {
        if ($i -lt $na -and $j -lt $nb -and $a2[$i] -ceq $b2[$j]) { $i++; $j++; $inHunk = $false; continue }
        if (-not $inHunk) { [void]$out.Add("@@ -$($pre + $i + 1) +$($pre + $j + 1) @@"); $inHunk = $true }
        if ($j -lt $nb -and ($i -ge $na -or $L[$i * $w + $j + 1] -ge $L[($i + 1) * $w + $j])) { [void]$out.Add('+' + $b2[$j]); $j++ }
        else { [void]$out.Add('-' + $a2[$i]); $i++ }
    }
    return ,$out
}

function Invoke-ExplorerBaselineDiff {
    param([string]$Workspace, [string]$RelA, [string]$RelB)
    $pa = Resolve-ExplorerWorkspacePath -Workspace $Workspace -Rel $RelA
    $pb = Resolve-ExplorerWorkspacePath -Workspace $Workspace -Rel $RelB
    if (-not $pa -or -not $pb) { return 'Both a and b must be paths inside the workspace.' }
    $cap = 200
    $sb = New-Object System.Text.StringBuilder
    $changed = 0
    $omitted = 0
    if ((Test-Path -LiteralPath $pa -PathType Leaf) -and (Test-Path -LiteralPath $pb -PathType Leaf)) {
        $d = Compare-ExplorerLines -A (Get-ExplorerDiffLines $pa) -B (Get-ExplorerDiffLines $pb)
        if ($d.Count -eq 0) { return "No differences between $RelA and $RelB (raw headers ignored)." }
        [void]$sb.AppendLine("--- $RelA"); [void]$sb.AppendLine("+++ $RelB")
        foreach ($line in $d) {
            if ($line.StartsWith('@@')) { [void]$sb.AppendLine($line); continue }
            if ($changed -ge $cap) { $omitted++; continue }
            [void]$sb.AppendLine($line); $changed++
        }
        if ($omitted -gt 0) { [void]$sb.AppendLine("... $omitted more changed line(s) not shown (cap $cap).") }
        return $sb.ToString().TrimEnd()
    }
    if ((Test-Path -LiteralPath $pa -PathType Container) -and (Test-Path -LiteralPath $pb -PathType Container)) {
        $relList = {
            param($root)
            $h = @{}
            foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue)) {
                $r = $f.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
                $h[$r] = $f.FullName
            }
            return $h
        }
        $ha = & $relList ([IO.Path]::GetFullPath($pa))
        $hb = & $relList ([IO.Path]::GetFullPath($pb))
        $removed = @($ha.Keys | Where-Object { -not $hb.ContainsKey($_) } | Sort-Object)
        $addedF = @($hb.Keys | Where-Object { -not $ha.ContainsKey($_) } | Sort-Object)
        $common = @($ha.Keys | Where-Object { $hb.ContainsKey($_) } | Sort-Object)
        [void]$sb.AppendLine("Folder diff $RelA -> $RelB : $($common.Count) common, $($addedF.Count) added, $($removed.Count) removed.")
        foreach ($r in $removed) { [void]$sb.AppendLine("REMOVED $r") }
        foreach ($r in $addedF) { [void]$sb.AppendLine("ADDED   $r") }
        $same = 0
        foreach ($r in $common) {
            $d = Compare-ExplorerLines -A (Get-ExplorerDiffLines $ha[$r]) -B (Get-ExplorerDiffLines $hb[$r])
            if ($d.Count -eq 0) { $same++; continue }
            [void]$sb.AppendLine("=== CHANGED $r")
            foreach ($line in $d) {
                if ($line.StartsWith('@@')) { if ($changed -lt $cap) { [void]$sb.AppendLine($line) }; continue }
                if ($changed -ge $cap) { $omitted++; continue }
                [void]$sb.AppendLine($line); $changed++
            }
        }
        [void]$sb.AppendLine("$same common file(s) unchanged.")
        if ($omitted -gt 0) { [void]$sb.AppendLine("... $omitted more changed line(s) not shown (cap $cap).") }
        return $sb.ToString().TrimEnd()
    }
    return 'a and b must both be existing files or both be existing folders.'
}

# =============================================================================
#  Query wrappers
# =============================================================================
function New-ExplorerQueryWrapper {
    # Builds the child-process script. The model's command travels as base64 and becomes a
    # script block inside the child, so no quoting tricks are possible. Targets are pre-validated.
    param([string]$Via, [string]$Command, [string]$Target, [string]$DataDir, [string]$CredentialName)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("`$ErrorActionPreference = 'Continue'")
    [void]$lines.Add("`$ProgressPreference = 'SilentlyContinue'")
    [void]$lines.Add("`$__explorerSb = [scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))")
    if ($Via -eq 'local') {
        [void]$lines.Add("try { & `$__explorerSb 2>&1 | Out-String -Width 220 } catch { 'ERROR: ' + `$_.Exception.Message; exit 1 }")
        [void]$lines.Add("if (`$LASTEXITCODE) { exit `$LASTEXITCODE }")
    } elseif ($Via -eq 'winrm') {
        [void]$lines.Add((Get-CredentialLoaderScript -DataDir $DataDir -Name $CredentialName -VariableName '__explorerCred'))
        [void]$lines.Add("try { Invoke-Command -ComputerName '$Target' -Credential `$__explorerCred -ScriptBlock `$__explorerSb -ErrorAction Stop 2>&1 | Out-String -Width 220 } catch { 'ERROR: ' + `$_.Exception.Message; exit 1 }")
    } elseif ($Via -eq 'vsphere') {
        [void]$lines.Add((Get-CredentialLoaderScript -DataDir $DataDir -Name $CredentialName -VariableName '__explorerCred'))
        [void]$lines.Add("try { Import-Module VMware.VimAutomation.Core -ErrorAction Stop } catch { 'ERROR: PowerCLI (VMware.VimAutomation.Core) is not available: ' + `$_.Exception.Message; exit 1 }")
        [void]$lines.Add("Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -DisplayDeprecationWarnings `$false -Confirm:`$false | Out-Null")
        [void]$lines.Add("try { `$__explorerVi = Connect-VIServer -Server '$Target' -Credential `$__explorerCred -ErrorAction Stop } catch { 'ERROR: Connect-VIServer failed: ' + `$_.Exception.Message; exit 1 }")
        [void]$lines.Add("Remove-Variable -Name __explorerCred -ErrorAction SilentlyContinue")
        [void]$lines.Add("`$__explorerRc = 0")
        [void]$lines.Add("try { & `$__explorerSb 2>&1 | Out-String -Width 220 } catch { 'ERROR: ' + `$_.Exception.Message; `$__explorerRc = 1 } finally { Disconnect-VIServer -Server `$__explorerVi -Confirm:`$false -ErrorAction SilentlyContinue | Out-Null }")
        [void]$lines.Add("exit `$__explorerRc")
    } else {
        throw "Unknown via '$Via'."
    }
    return (($lines.ToArray()) -join "`r`n")
}

function Invoke-ExplorerNetQuery {
    param([hashtable]$Context, $A)
    $ws = [string]$Context.Workspace
    $dataDir = [string]$Context.DataDir
    $command = [string](Get-ExplorerArg $A 'command' '')
    $via = ([string](Get-ExplorerArg $A 'via' 'local')).ToLowerInvariant()
    $target = ([string](Get-ExplorerArg $A 'target' '')).Trim()
    $credName = ([string](Get-ExplorerArg $A 'credential' '')).Trim()
    $purpose = ([string](Get-ExplorerArg $A 'purpose' '')).Trim()
    $timeout = 60
    try { $timeout = [int](Get-ExplorerArg $A 'timeout_sec' 60) } catch { $timeout = 60 }
    $timeout = [Math]::Max(5, [Math]::Min(300, $timeout))

    if (-not $purpose) { return 'net_query needs a short purpose (used for the raw file name and log).' }
    if ($via -notin @('local', 'winrm', 'vsphere')) { return "via must be local, winrm or vsphere." }
    $scope = Get-ExplorerScope -Workspace $ws
    if ($via -ne 'local') {
        if (-not $target) { return "net_query via $via needs a target." }
        if (-not (Test-ExplorerTargetName $target)) { return "Target '$target' is not a valid host name or address." }
        if (-not (Test-TargetInScope -Target $target -Scope $scope)) {
            if ($null -eq $scope) { return "BLOCKED: no scope file. Create .byob\scope.json in the workspace listing in-scope subnets and hosts." }
            return "BLOCKED: target '$target' is outside the allowed scope (.byob\scope.json)."
        }
        if (-not $credName) { return "net_query via $via needs a credential name (see list_credentials)." }
        $rec = Get-StoredCredentialRecord -DataDir $dataDir -Name $credName
        $needKind = 'windows'
        if ($via -eq 'vsphere') { $needKind = 'vsphere' }
        if (-not $rec) { return "Stored credential '$credName' not found. Use list_credentials." }
        if ($rec.kind -ne $needKind) { return "Credential '$credName' is kind '$($rec.kind)'; via $via needs a '$needKind' credential." }
        if (-not $rec.secret) { return "Credential '$credName' has no password stored." }
        $credName = $rec.name
    } else {
        $target = 'localhost'
        $credName = ''
    }
    $protect = @('credentials.json')
    if ($dataDir) { $protect += [IO.Path]::GetFullPath($dataDir); $protect += $dataDir }
    $gate = Test-ReadOnlyCommand -Command $command -Scope $scope -Mode $via -ProtectedPathFragments $protect
    if (-not $gate.Allowed) { return "BLOCKED by read-only gate: $($gate.Reason)" }

    $wrapper = New-ExplorerQueryWrapper -Via $via -Command $command -Target $target -DataDir $dataDir -CredentialName $credName
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
    if ($enc.Length -gt 30000) { return 'Command is too long to run. Split it into smaller queries.' }
    $res = Invoke-ExplorerProcess -FileName (Get-ExplorerPowerShellExe) -Arguments "-NoProfile -NonInteractive -EncodedCommand $enc" -WorkingDirectory $ws -TimeoutSec $timeout -CancelState $Context.CancelState
    $output = $res.StdOut
    if ($res.StdErr -and $res.StdErr.Trim()) { $output = $output.TrimEnd() + "`n[stderr]`n" + $res.StdErr }
    $exit = [string]$res.ExitCode
    if ($res.TimedOut) { $exit = 'timeout' }
    $rel = Save-ExplorerRawOutput -Workspace $ws -Via $via -Target $target -CredentialName $credName -Purpose $purpose -Command $command -ExitCode $exit -Output $output
    return (Format-ExplorerQueryResult -RelPath $rel -ExitCode $exit -Output $output -TimedOut $res.TimedOut -TimeoutSec $timeout)
}

function Get-ExplorerSshExe {
    if (Test-ExplorerIsWindows) {
        $p = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
        if (Test-Path -LiteralPath $p) { return $p }
        return $null
    }
    $c = Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Invoke-ExplorerSshQuery {
    param([hashtable]$Context, $A)
    $ws = [string]$Context.Workspace
    $dataDir = [string]$Context.DataDir
    $command = [string](Get-ExplorerArg $A 'command' '')
    $target = ([string](Get-ExplorerArg $A 'target' '')).Trim()
    $credName = ([string](Get-ExplorerArg $A 'credential' '')).Trim()
    $purpose = ([string](Get-ExplorerArg $A 'purpose' '')).Trim()
    $timeout = 60
    try { $timeout = [int](Get-ExplorerArg $A 'timeout_sec' 60) } catch { $timeout = 60 }
    $timeout = [Math]::Max(5, [Math]::Min(300, $timeout))

    if (-not $purpose) { return 'ssh_query needs a short purpose.' }
    if (-not (Test-ExplorerTargetName $target)) { return "Target '$target' is not a valid host name or address." }
    $scope = Get-ExplorerScope -Workspace $ws
    if (-not (Test-TargetInScope -Target $target -Scope $scope)) {
        if ($null -eq $scope) { return 'BLOCKED: no scope file. Create .byob\scope.json in the workspace listing in-scope subnets and hosts.' }
        return "BLOCKED: target '$target' is outside the allowed scope (.byob\scope.json)."
    }
    $gate = Test-LinuxReadOnlyCommand -Command $command
    if (-not $gate.Allowed) { return "BLOCKED by read-only gate: $($gate.Reason)" }
    foreach ($t in $gate.Targets) {
        if (-not (Test-TargetInScope -Target $t -Scope $scope)) { return "BLOCKED by read-only gate: target '$t' in the command is outside the allowed scope." }
    }
    if (-not $credName) { return 'ssh_query needs a linux credential name (see list_credentials).' }
    $rec = Get-StoredCredentialRecord -DataDir $dataDir -Name $credName
    if (-not $rec) { return "Stored credential '$credName' not found. Use list_credentials." }
    if ($rec.kind -ne 'linux') { return "Credential '$credName' is kind '$($rec.kind)'; ssh_query needs a 'linux' credential." }
    if ($rec.username -notmatch '^[A-Za-z0-9._][A-Za-z0-9._@-]{0,63}$') { return "Credential '$credName' has an invalid user name for ssh." }
    if (-not $rec.keyPath -and -not $rec.secret) { return "Credential '$credName' has neither a key path nor a password." }
    $ssh = Get-ExplorerSshExe
    if (-not $ssh) { return 'ssh.exe was not found (Windows OpenSSH client is required: C:\Windows\System32\OpenSSH\ssh.exe).' }

    $argList = New-Object System.Collections.ArrayList
    $envVars = $null
    if ($rec.keyPath) {
        foreach ($x in @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new', '-i', $rec.keyPath)) { [void]$argList.Add($x) }
    } else {
        # Password authentication via SSH_ASKPASS.
        # UNTESTED ON WINDOWS: relies on Win32-OpenSSH honouring SSH_ASKPASS / SSH_ASKPASS_REQUIRE=force
        # with a .cmd helper. The password is placed only in the child process environment.
        $runDir = Join-Path $dataDir 'run'
        if (-not (Test-Path -LiteralPath $runDir)) { New-Item -ItemType Directory -Force $runDir | Out-Null }
        if (Test-ExplorerIsWindows) {
            $helper = Join-Path $runDir 'askpass.cmd'
            # Delayed expansion keeps special characters in the password literal (no cmd parsing of the value).
            [IO.File]::WriteAllText($helper, "@echo off`r`nsetlocal EnableDelayedExpansion`r`necho(!BYOB_EXPLORER_SSH_PW!`r`n", (New-Object System.Text.ASCIIEncoding))
        } else {
            $helper = Join-Path $runDir 'askpass.sh'
            [IO.File]::WriteAllText($helper, "#!/bin/sh`nprintf '%s\n' ""`$BYOB_EXPLORER_SSH_PW""`n", (New-Object System.Text.ASCIIEncoding))
        }
        foreach ($x in @('-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'PreferredAuthentications=password,keyboard-interactive', '-o', 'NumberOfPasswordPrompts=1')) { [void]$argList.Add($x) }
        $envVars = @{ SSH_ASKPASS = $helper; SSH_ASKPASS_REQUIRE = 'force'; DISPLAY = 'dummy'; BYOB_EXPLORER_SSH_PW = (Get-StoredCredentialPlainSecret -Record $rec) }
    }
    foreach ($x in @('-l', $rec.username, $target, $command)) { [void]$argList.Add($x) }
    $argText = (@($argList | ForEach-Object { ConvertTo-ExplorerWinArg ([string]$_) }) -join ' ')
    $res = Invoke-ExplorerProcess -FileName $ssh -Arguments $argText -WorkingDirectory $ws -TimeoutSec $timeout -Environment $envVars -CancelState $Context.CancelState
    if ($envVars) { $envVars['BYOB_EXPLORER_SSH_PW'] = $null; $envVars = $null }
    $output = $res.StdOut
    if ($res.StdErr -and $res.StdErr.Trim()) { $output = $output.TrimEnd() + "`n[stderr]`n" + $res.StdErr }
    $exit = [string]$res.ExitCode
    if ($res.TimedOut) { $exit = 'timeout' }
    $rel = Save-ExplorerRawOutput -Workspace $ws -Via 'ssh' -Target $target -CredentialName $rec.name -Purpose $purpose -Command $command -ExitCode $exit -Output $output
    return (Format-ExplorerQueryResult -RelPath $rel -ExitCode $exit -Output $output -TimedOut $res.TimedOut -TimeoutSec $timeout)
}

# =============================================================================
#  Knowledge base
# =============================================================================
function Invoke-ExplorerKbWrite {
    param([string]$Workspace, $A)
    $file = [string](Get-ExplorerArg $A 'file' '')
    $mode = ([string](Get-ExplorerArg $A 'mode' 'replace')).ToLowerInvariant()
    $content = [string](Get-ExplorerArg $A 'content' '')
    $heading = ([string](Get-ExplorerArg $A 'heading' '')).Trim()
    if ($content.Length -gt 60000) { return 'kb_write content is over 60000 characters. Split it across files or sections.' }
    try { $path = Resolve-ExplorerKbPath -Workspace $Workspace -File $file } catch { return $_.Exception.Message }
    $rel = 'kb/' + $path.Substring([IO.Path]::GetFullPath((Join-Path $Workspace 'kb')).Length + 1).Replace('\', '/')
    $old = ''
    if (Test-Path -LiteralPath $path -PathType Leaf) { $old = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
    switch ($mode) {
        'replace' { $new = $content }
        'append' {
            if ($old -and -not $old.EndsWith("`n")) { $old += "`n" }
            $new = $old + $content
        }
        'section' {
            if ($heading.StartsWith('## ')) { $heading = $heading.Substring(3).Trim() }
            if (-not $heading) { return 'kb_write mode=section needs a heading.' }
            $lines = @()
            if ($old) { $lines = @($old -split "\r?\n") }
            $start = -1
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].TrimEnd() -ceq "## $heading") { $start = $i; break } }
            $body = @($content.TrimEnd() -split "\r?\n")
            if ($start -lt 0) {
                $text = $old
                if ($text -and -not $text.EndsWith("`n")) { $text += "`n" }
                if ($text) { $text += "`n" }
                $new = $text + "## $heading`n" + ($body -join "`n") + "`n"
            } else {
                $end = $lines.Count
                for ($j = $start + 1; $j -lt $lines.Count; $j++) { if ($lines[$j] -match '^#{1,2} ') { $end = $j; break } }
                $before = @()
                if ($start -ge 0) { $before = @($lines[0..$start]) }
                $after = @()
                if ($end -lt $lines.Count) { $after = @('') + @($lines[$end..($lines.Count - 1)]) }
                $new = (@($before) + $body + $after) -join "`n"
                if (-not $new.EndsWith("`n")) { $new += "`n" }
            }
        }
        default { return "Unknown kb_write mode '$mode'. Use replace, append or section." }
    }
    Write-ExplorerUtf8 -Path $path -Text $new
    return "kb_write $($mode): $rel now $($new.Length) chars."
}

function Invoke-ExplorerKbRead {
    param([string]$Workspace, $A)
    $file = [string](Get-ExplorerArg $A 'file' '')
    $kbRoot = [IO.Path]::GetFullPath((Join-Path $Workspace 'kb'))
    if (-not $file) {
        if (-not (Test-Path -LiteralPath $kbRoot)) { return 'kb/ is empty (no files yet). Start with kb/00-index.md.' }
        $files = @(Get-ChildItem -LiteralPath $kbRoot -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)
        if ($files.Count -eq 0) { return 'kb/ is empty (no files yet). Start with kb/00-index.md.' }
        $sb = New-Object System.Text.StringBuilder
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($kbRoot.Length + 1).Replace('\', '/')
            $h = ''
            if ($f.Extension -eq '.md') {
                foreach ($line in [IO.File]::ReadLines($f.FullName)) { if ($line -match '^#') { $h = $line.Trim(); break } }
            }
            [void]$sb.AppendLine(("kb/{0} ({1} B) {2}" -f $rel, $f.Length, $h).TrimEnd())
        }
        return $sb.ToString().TrimEnd()
    }
    try { $path = Resolve-ExplorerKbPath -Workspace $Workspace -File $file } catch { return $_.Exception.Message }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "kb file not found: $file" }
    $txt = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if ($txt.Length -gt 24000) { $txt = $txt.Substring(0, 24000) + "`n...(truncated at 24000 chars)" }
    if (-not $txt) { return '(empty file)' }
    return $txt
}

# =============================================================================
#  Tool definitions and dispatcher
# =============================================================================
function Get-ExplorerToolDefinitions {
    $tools = @(
        @{
            name = 'net_query'
            access = 'read'
            description = 'Run ONE read-only PowerShell query (Get-*, Test-*, Resolve-*, ping, ipconfig, netstat, nslookup, kubectl get, PowerCLI Get-*). via=local runs on this laptop, via=winrm runs on a Windows target, via=vsphere connects PowerCLI to an ESXi/vCenter target. A gate blocks anything that is not read-only or not in scope. Full output is saved under raw/.'
            params = @{
                type = 'object'
                properties = @{
                    command = @{ type = 'string'; description = 'PowerShell command text (read-only).' }
                    via = @{ type = 'string'; enum = @('local', 'winrm', 'vsphere'); description = 'Where to run (default local).' }
                    target = @{ type = 'string'; description = 'Host name or IP for winrm/vsphere.' }
                    credential = @{ type = 'string'; description = 'Stored credential name for winrm/vsphere (see list_credentials).' }
                    purpose = @{ type = 'string'; description = 'Short purpose, e.g. "esx01 VM list".' }
                    timeout_sec = @{ type = 'integer'; description = 'Timeout seconds (default 60, 5-300).' }
                }
                required = @('command', 'purpose')
            }
        },
        @{
            name = 'ssh_query'
            access = 'read'
            description = 'Run ONE read-only command on a Linux host over ssh (cat, ls, ss, ip addr, systemctl status, journalctl -n, df, ps, rpm -q, kubectl get ...). No sudo, redirection, or state changes. Full output is saved under raw/.'
            params = @{
                type = 'object'
                properties = @{
                    target = @{ type = 'string'; description = 'Linux host name or IP (must be in scope).' }
                    command = @{ type = 'string'; description = 'Shell command text (read-only).' }
                    credential = @{ type = 'string'; description = 'Stored linux credential name.' }
                    purpose = @{ type = 'string'; description = 'Short purpose.' }
                    timeout_sec = @{ type = 'integer'; description = 'Timeout seconds (default 60, 5-300).' }
                }
                required = @('target', 'command', 'credential', 'purpose')
            }
        },
        @{
            name = 'kb_write'
            access = 'read'
            description = 'Write to the knowledge base (markdown files under kb/). mode=replace writes the whole file, append adds to the end, section replaces the body under "## heading" (or adds it).'
            params = @{
                type = 'object'
                properties = @{
                    file = @{ type = 'string'; description = 'Relative name under kb/, e.g. 20-network.md or hosts/esx01.md.' }
                    mode = @{ type = 'string'; enum = @('replace', 'append', 'section'); description = 'Default replace.' }
                    heading = @{ type = 'string'; description = 'Section heading text (for mode=section), without ##.' }
                    content = @{ type = 'string'; description = 'Markdown text. Cite raw/ files for facts; mark guesses INFERRED.' }
                }
                required = @('file', 'content')
            }
        },
        @{
            name = 'kb_read'
            access = 'read'
            description = 'Read the knowledge base. No file: list every kb file with size and first heading. With file: return its content.'
            params = @{
                type = 'object'
                properties = @{
                    file = @{ type = 'string'; description = 'Optional relative name under kb/.' }
                }
            }
        },
        @{
            name = 'frontier'
            access = 'read'
            description = 'The to-explore list. add: new {target, question, priority 1-5 (1=highest)} items (duplicates skipped). list: open items by priority. done/skip: close an item by id with a note.'
            params = @{
                type = 'object'
                properties = @{
                    action = @{ type = 'string'; enum = @('add', 'list', 'done', 'skip') }
                    items = @{
                        type = 'array'
                        items = @{
                            type = 'object'
                            properties = @{
                                target = @{ type = 'string' }
                                question = @{ type = 'string' }
                                priority = @{ type = 'integer' }
                            }
                            required = @('target', 'question')
                        }
                    }
                    id = @{ type = 'string'; description = 'Item id like F003 (done/skip).' }
                    note = @{ type = 'string'; description = 'What was found or why skipped (done/skip).' }
                }
                required = @('action')
            }
        },
        @{
            name = 'list_credentials'
            access = 'read'
            description = 'List stored credential names with kind (windows, vsphere, linux), user name and note. Secrets are never shown.'
            params = @{ type = 'object'; properties = @{} }
        },
        @{
            name = 'baseline_diff'
            access = 'read'
            description = 'Compare two raw output files (or two baseline folders) and show changed lines. Use to see what changed since a known-good state.'
            params = @{
                type = 'object'
                properties = @{
                    a = @{ type = 'string'; description = 'Workspace-relative path of the older/known-good file or folder.' }
                    b = @{ type = 'string'; description = 'Workspace-relative path of the newer file or folder.' }
                }
                required = @('a', 'b')
            }
        }
    )
    return $tools
}

function Invoke-ExplorerTool {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Args,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $owned = @('net_query', 'ssh_query', 'kb_write', 'kb_read', 'frontier', 'list_credentials', 'baseline_diff')
    if ($owned -notcontains $Name) { return $null }
    $a = $Args
    if ($null -eq $a) { $a = [pscustomobject]@{} }
    $ws = [string]$Context.Workspace
    if (-not $ws) { return 'Explorer tools need a workspace.' }
    switch ($Name) {
        'net_query' { return (Invoke-ExplorerNetQuery -Context $Context -A $a) }
        'ssh_query' { return (Invoke-ExplorerSshQuery -Context $Context -A $a) }
        'kb_write' { return (Invoke-ExplorerKbWrite -Workspace $ws -A $a) }
        'kb_read' { return (Invoke-ExplorerKbRead -Workspace $ws -A $a) }
        'frontier' { return (Invoke-ExplorerFrontier -Workspace $ws -A $a) }
        'list_credentials' {
            $list = @(Get-CredentialList -DataDir ([string]$Context.DataDir))
            if ($list.Count -eq 0) { return 'No stored credentials. Ask the user to add lab credentials in Settings.' }
            $lines = @()
            foreach ($c in $list) {
                $extra = ''
                if ($c.keyPath) { $extra = ' (ssh key)' }
                $line = "{0} | {1} | user {2}{3}" -f $c.name, $c.kind, $c.username, $extra
                if ($c.note) { $line += " | $($c.note)" }
                $lines += $line
            }
            return ($lines -join "`n")
        }
        'baseline_diff' {
            return (Invoke-ExplorerBaselineDiff -Workspace $ws -RelA ([string](Get-ExplorerArg $a 'a' '')) -RelB ([string](Get-ExplorerArg $a 'b' '')))
        }
    }
    return $null
}

# =============================================================================
#  System prompt
# =============================================================================
function Get-ExplorerSystemPrompt {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [string[]]$CredentialNames = @()
    )
    $creds = '(none stored yet - ask the user to add lab credentials)'
    if ($CredentialNames -and @($CredentialNames).Count -gt 0) { $creds = (@($CredentialNames) -join ', ') }
    $p = @"
You are the Network Explorer, a careful read-only investigator for an isolated lab network (VMware ESXi hosts running Windows and Linux VMs), working from a Windows management laptop. Workspace: $Workspace

JOB
1. Explore and document the enclave you are pointed at, building a knowledge base (kb/) of markdown files.
2. Later, answer questions and investigate faults the user describes, using what you learned.

READ-ONLY RULE
You never change anything: no restarts, no config changes, no writes on any host. A gate checks every command and enforces this and the scope list (.byob\scope.json). If a result says BLOCKED, do not try to work around it or rephrase the same action. Pick a different read-only command, or tell the user what change would be needed and let them do it.

TOOLS
- net_query: one read-only PowerShell command. via=local (this laptop: ping, Test-NetConnection, Resolve-DnsName, ipconfig, arp -a, route print), via=winrm (Get-* on a Windows host, needs a windows credential), via=vsphere (PowerCLI Get-VM, Get-VMHost, Get-VirtualSwitch, Get-VirtualPortGroup, Get-Datastore against ESXi/vCenter, needs a vsphere credential).
- ssh_query: one read-only command on a Linux host (needs a linux credential).
- kb_read / kb_write: read and write kb/ files.
- frontier: the to-explore list (add, list, done, skip).
- list_credentials: stored credential names. Available now: $creds
- baseline_diff: compare two raw/ files or folders to see what changed.
Every query saves full output under raw/. Keep commands small; use Select-Object, Format-Table and -n limits.

KB LAYOUT
kb/00-index.md (one line per kb file: name - what it holds), kb/10-inventory.md (hosts, VMs, OS, roles, IPs), kb/20-network.md (subnets, vSwitches, port groups, VLANs, gateways, DNS), kb/30-services.md (services and listening ports per host), kb/40-dependencies.md (what depends on what), kb/50-how-it-works.md (plain-language picture of the system), kb/90-open-questions.md, and one kb/hosts/<name>.md per host.
Every fact you write must cite the raw file it came from, like (raw/20260101-101500-esx01-vm-list.txt). Anything you conclude without direct evidence must be marked INFERRED. Keep 00-index.md current.

EXPLORATION ROUTINE
1. kb_read 00-index.md and frontier list. If the frontier is empty and the kb is new, add starting items (this laptop's IP config, the scope subnets, known ESXi hosts).
2. Pick the highest-priority open item.
3. Run one query for it.
4. Write what you learned to the right kb file(s), with citations.
5. Add newly discovered hosts, services and questions to the frontier.
6. Mark the item done (or skip with a reason).
7. Repeat until the frontier is empty or the user tells you to stop. Report briefly what you covered.

INVESTIGATION ROUTINE (user reports a fault)
1. Restate the symptom in one sentence.
2. Read the kb for what normal looks like for the hosts and services involved.
3. Check current state with read-only queries.
4. Compare with the known-good baseline using baseline_diff on matching raw/ files.
5. Rank the likely causes, each with its evidence (raw file citations).
6. State what change would most likely fix it, but do not make it.
7. Report plainly: symptom, findings, likely cause, recommended fix, what is still unknown.
"@
    $idx = Join-Path (Join-Path $Workspace 'kb') '00-index.md'
    if (Test-Path -LiteralPath $idx -PathType Leaf) {
        $t = [IO.File]::ReadAllText($idx, [Text.Encoding]::UTF8)
        if ($t.Length -gt 6000) { $t = $t.Substring(0, 6000) + "`n...(index truncated)" }
        $p += "`n`nCURRENT kb/00-index.md`n$t"
    }
    $fr = Join-Path (Join-Path $Workspace 'kb') 'frontier.json'
    if (Test-Path -LiteralPath $fr -PathType Leaf) {
        try {
            $items = Read-ExplorerFrontier -Workspace $Workspace
            $open = @($items | Where-Object { $_.status -eq 'open' }).Count
            $p += "`n`nFRONTIER: $open open item(s)."
        } catch { }
    }
    return $p
}
