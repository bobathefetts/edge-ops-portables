# CredStore.ps1 - Named lab credentials for the BYOB network explorer.
# Windows PowerShell 5.1 and PowerShell 7. ASCII only. Dot-source this file.
#
# File: <DataDir>\credentials.json - always a JSON array of
#   { name, kind, username, secret, keyPath, note, protected }
#   kind      : windows | vsphere | linux
#   protected : "dpapi" -> secret is ConvertFrom-SecureString output (Windows DPAPI, current user)
#               "none"  -> secret is base64 text. TEST-ONLY fallback used when DPAPI is
#                          unavailable (non-Windows test runtime). Never use for real secrets.
#
# Secrets are never returned by Get-CredentialList, never logged, and never embedded in
# generated script text: Get-CredentialLoaderScript emits code that reads and decrypts
# the file inside the child process itself.

function Test-CredStoreDpapiAvailable {
    return ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
}

function Get-CredStorePath {
    param([Parameter(Mandatory)][string]$DataDir)
    return (Join-Path $DataDir 'credentials.json')
}

function Read-CredStoreRecords {
    param([Parameter(Mandatory)][string]$DataDir)
    $path = Get-CredStorePath -DataDir $DataDir
    $list = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return ,$list }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return ,$list }
    try {
        $parsed = ConvertFrom-Json -InputObject $raw
    } catch {
        throw 'credentials.json is not valid JSON. Fix or delete it (secrets are not shown here).'
    }
    foreach ($r in $parsed) {
        if ($null -eq $r) { continue }
        [void]$list.Add([pscustomobject]@{
            name      = [string]$r.name
            kind      = [string]$r.kind
            username  = [string]$r.username
            secret    = [string]$r.secret
            keyPath   = [string]$r.keyPath
            note      = [string]$r.note
            protected = [string]$r.protected
        })
    }
    return ,$list
}

function Write-CredStoreRecords {
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][AllowEmptyCollection()]$Records)
    if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Force $DataDir | Out-Null }
    $items = @($Records)
    if ($items.Count -eq 0) {
        $json = '[]'
    } else {
        $parts = @()
        foreach ($r in $items) { $parts += ($r | ConvertTo-Json -Compress -Depth 3) }
        $json = '[' + ($parts -join ',') + ']'
    }
    $path = Get-CredStorePath -DataDir $DataDir
    $tmp = $path + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
    [IO.File]::Move($tmp, $path)
}

function Protect-CredStoreSecret {
    param([string]$Plain)
    if (-not $Plain) { return @{ secret = ''; protected = '' } }
    if (Test-CredStoreDpapiAvailable) {
        $ss = ConvertTo-SecureString -String $Plain -AsPlainText -Force
        return @{ secret = (ConvertFrom-SecureString -SecureString $ss); protected = 'dpapi' }
    }
    # TEST-ONLY: no DPAPI on this platform. Base64 is NOT encryption.
    return @{ secret = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Plain)); protected = 'none' }
}

function Get-CredentialList {
    param([Parameter(Mandatory)][string]$DataDir)
    $out = @()
    foreach ($r in (Read-CredStoreRecords -DataDir $DataDir)) {
        $out += [pscustomobject]@{
            name      = $r.name
            kind      = $r.kind
            username  = $r.username
            keyPath   = $r.keyPath
            note      = $r.note
            hasSecret = [bool]$r.secret
        }
    }
    return $out
}

function Set-StoredCredential {
    param(
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('windows', 'vsphere', 'linux')][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Username,
        $Secret,
        [string]$KeyPath,
        [string]$Note
    )
    if ($Name -notmatch '^[A-Za-z0-9_-]{1,40}$') { throw 'Credential name must be 1-40 characters: letters, digits, _ or -.' }
    $records = Read-CredStoreRecords -DataDir $DataDir
    $existing = $null
    foreach ($r in $records) { if ($r.name -ieq $Name) { $existing = $r } }
    if (-not $existing) {
        $existing = [pscustomobject]@{ name = $Name; kind = $Kind; username = ''; secret = ''; keyPath = ''; note = ''; protected = '' }
        [void]$records.Add($existing)
    }
    $existing.name = $Name
    $existing.kind = $Kind.ToLowerInvariant()
    $existing.username = $Username
    if ($PSBoundParameters.ContainsKey('Secret')) {
        $plain = ''
        if ($Secret -is [System.Security.SecureString]) {
            $plain = (New-Object System.Management.Automation.PSCredential ('x', $Secret)).GetNetworkCredential().Password
        } elseif ($null -ne $Secret) {
            $plain = [string]$Secret
        }
        $prot = Protect-CredStoreSecret -Plain $plain
        $existing.secret = $prot.secret
        $existing.protected = $prot.protected
        $plain = $null
    }
    if ($PSBoundParameters.ContainsKey('KeyPath')) { $existing.keyPath = $KeyPath }
    if ($PSBoundParameters.ContainsKey('Note')) { $existing.note = $Note }
    Write-CredStoreRecords -DataDir $DataDir -Records $records
    return [pscustomobject]@{ name = $existing.name; kind = $existing.kind; username = $existing.username; keyPath = $existing.keyPath; note = $existing.note; hasSecret = [bool]$existing.secret }
}

function Remove-StoredCredential {
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][string]$Name)
    $records = Read-CredStoreRecords -DataDir $DataDir
    $keep = @($records | Where-Object { $_.name -ine $Name })
    if ($keep.Count -eq $records.Count) { return $false }
    Write-CredStoreRecords -DataDir $DataDir -Records $keep
    return $true
}

function Get-StoredCredentialRecord {
    # INTERNAL: returns the raw record (secret still protected). Never hand this to the model.
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][string]$Name)
    foreach ($r in (Read-CredStoreRecords -DataDir $DataDir)) { if ($r.name -ieq $Name) { return $r } }
    return $null
}

function Get-StoredCredentialPlainSecret {
    # INTERNAL: decrypts a record's secret for in-process use (ssh askpass). Never log the result.
    param([Parameter(Mandatory)]$Record)
    if (-not $Record.secret) { return '' }
    if ($Record.protected -eq 'dpapi') {
        $ss = ConvertTo-SecureString -String $Record.secret
        return (New-Object System.Management.Automation.PSCredential ('x', $ss)).GetNetworkCredential().Password
    }
    if ($Record.protected -eq 'none') {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Record.secret))
    }
    throw "Stored credential '$($Record.name)' uses an unknown protection type."
}

function Get-CredentialLoaderScript {
    # Returns PowerShell code (a string) that, run in a child powershell.exe as the same
    # user, reads <DataDir>\credentials.json, decrypts the named record and creates
    # $<VariableName> as a PSCredential. The secret never appears in the returned text.
    param(
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$VariableName
    )
    if ($Name -notmatch '^[A-Za-z0-9_-]{1,40}$') { throw 'Invalid credential name.' }
    if ($VariableName -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,60}$') { throw 'Invalid variable name.' }
    $path = (Get-CredStorePath -DataDir ([IO.Path]::GetFullPath($DataDir))).Replace("'", "''")
    $lines = @(
        "`$__explorerCsPath = '$path'",
        "`$__explorerCsName = '$Name'",
        "`$__explorerCsRec = `$null",
        "foreach (`$__explorerCsR in (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(`$__explorerCsPath, [Text.Encoding]::UTF8)))) { if ([string]`$__explorerCsR.name -eq `$__explorerCsName) { `$__explorerCsRec = `$__explorerCsR } }",
        "if (-not `$__explorerCsRec) { throw ""Stored credential '$Name' was not found."" }",
        "if (-not `$__explorerCsRec.secret) { throw ""Stored credential '$Name' has no password."" }",
        "if (`$__explorerCsRec.protected -eq 'dpapi') {",
        "    `$__explorerCsSec = ConvertTo-SecureString -String ([string]`$__explorerCsRec.secret)",
        "} elseif (`$__explorerCsRec.protected -eq 'none') {",
        "    `$__explorerCsSec = New-Object System.Security.SecureString",
        "    foreach (`$__explorerCsCh in ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]`$__explorerCsRec.secret))).ToCharArray()) { `$__explorerCsSec.AppendChar(`$__explorerCsCh) }",
        "    `$__explorerCsSec.MakeReadOnly()",
        "} else { throw ""Stored credential '$Name' uses an unknown protection type."" }",
        "`$$VariableName = New-Object System.Management.Automation.PSCredential ([string]`$__explorerCsRec.username, `$__explorerCsSec)",
        "Remove-Variable -Name __explorerCsPath, __explorerCsName, __explorerCsRec, __explorerCsR, __explorerCsSec, __explorerCsCh -ErrorAction SilentlyContinue"
    )
    return ($lines -join "`r`n")
}
