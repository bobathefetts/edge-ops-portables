# NetGate.ps1 - Read-only command gate for the BYOB network explorer.
# Runs on Windows PowerShell 5.1 and PowerShell 7. ASCII only. Dot-source this file.
#
# SECURITY BOUNDARY. The model proposes command text; these functions decide
# whether that text may run WITHOUT asking the user. Design rules:
#   * Default deny. Anything not positively recognised as read-only is refused.
#   * PowerShell text is parsed with the real parser and every AST node is
#     inspected (nested script blocks, sub-expressions and expandable strings
#     included). Unknown AST node types are refused.
#   * Linux text is checked by a conservative tokenizer (not a shell parser):
#     any shell feature it does not fully understand is refused.
#   * It is acceptable to refuse harmless commands. It is not acceptable to
#     allow a state-changing one. When in doubt, deny.
#
# Exports:
#   Test-ReadOnlyCommand      -Command -Scope [-Mode] [-ProtectedPathFragments]
#   Test-LinuxReadOnlyCommand -Command
#   Test-TargetInScope        -Target -Scope            (returns [bool])
#   Read-ScopeConfig          -Path                     (returns scope object or $null)
#
# Scope semantics (documented for reviewers):
#   * scope.json: { "allow": [...], "deny": [...] }. Entries are IPv4 addresses,
#     IPv4 CIDR blocks, or host name patterns (-like wildcards, case-insensitive).
#   * Deny wins over allow. Host name matching is exact or wildcard only: the
#     short name "esx01" does NOT match "esx01.sw4.lab" (add "esx01.*" if wanted).
#   * IPv4 targets are matched only against IPv4/CIDR entries; names only against
#     name patterns. A name is NOT resolved to an address (DNS is not consulted).
#   * localhost, 127.0.0.0/8, ::1, "." and this computer's name are always in scope.
#   * A missing or invalid scope file gives $null scope: every non-local target is denied.

# =============================================================================
#  POLICY TABLES (audit these)
# =============================================================================
function Get-NetGatePolicy {
    $p = @{}

    # --- TABLE 1: alias -> real command. Resolved BEFORE any check. Dangerous
    #     aliases map to their real (denied) cmdlets on purpose. Lines are
    #     "alias=Target" so duplicate keys cannot silently break the table.
    $aliasLines = @(
        '%=ForEach-Object', 'foreach=ForEach-Object', '?=Where-Object', 'where=Where-Object',
        'select=Select-Object', 'sort=Sort-Object', 'group=Group-Object', 'measure=Measure-Object',
        'ft=Format-Table', 'fl=Format-List', 'fw=Format-Wide', 'fc=Format-Custom', 'fhx=Format-Hex',
        'gci=Get-ChildItem', 'dir=Get-ChildItem', 'ls=Get-ChildItem',
        'gc=Get-Content', 'cat=Get-Content', 'type=Get-Content',
        'gi=Get-Item', 'gp=Get-ItemProperty', 'gpv=Get-ItemPropertyValue',
        'gps=Get-Process', 'ps=Get-Process', 'gsv=Get-Service',
        'gwmi=Get-WmiObject', 'gcim=Get-CimInstance', 'gm=Get-Member',
        'echo=Write-Output', 'write=Write-Output', 'sls=Select-String', 'gcm=Get-Command',
        'ghy=Get-History', 'h=Get-History', 'history=Get-History',
        'gl=Get-Location', 'pwd=Get-Location', 'gdr=Get-PSDrive', 'gu=Get-Unique',
        'diff=Compare-Object', 'compare=Compare-Object', 'oh=Out-Host', 'tee=Tee-Object',
        'gal=Get-Alias', 'gv=Get-Variable', 'gjb=Get-Job', 'gmo=Get-Module', 'gsn=Get-PSSession',
        'rvpa=Resolve-Path', 'help=Get-Help', 'man=Get-Help', 'ogv=Out-GridView',
        # dangerous aliases (resolve to denied cmdlets)
        'sc=Set-Content', 'del=Remove-Item', 'erase=Remove-Item', 'rd=Remove-Item', 'ri=Remove-Item',
        'rm=Remove-Item', 'rmdir=Remove-Item', 'kill=Stop-Process', 'spps=Stop-Process',
        'iex=Invoke-Expression', 'icm=Invoke-Command', 'iwr=Invoke-WebRequest', 'curl=Invoke-WebRequest',
        'wget=Invoke-WebRequest', 'irm=Invoke-RestMethod', 'saps=Start-Process', 'start=Start-Process',
        'sasv=Start-Service', 'spsv=Stop-Service', 'set=Set-Variable', 'sv=Set-Variable',
        'si=Set-Item', 'sp=Set-ItemProperty', 'ni=New-Item', 'md=New-Item', 'mkdir=New-Item',
        'mi=Move-Item', 'move=Move-Item', 'mv=Move-Item', 'ren=Rename-Item', 'rni=Rename-Item',
        'cp=Copy-Item', 'copy=Copy-Item', 'cpi=Copy-Item', 'cpp=Copy-ItemProperty', 'ac=Add-Content',
        'clc=Clear-Content', 'cli=Clear-Item', 'clp=Clear-ItemProperty', 'clv=Clear-Variable',
        'nal=New-Alias', 'sal=Set-Alias', 'ipmo=Import-Module', 'rmo=Remove-Module',
        'etsn=Enter-PSSession', 'exsn=Exit-PSSession', 'nsn=New-PSSession', 'rsn=Remove-PSSession',
        'sajb=Start-Job', 'rcjb=Receive-Job', 'rjb=Remove-Job', 'spjb=Stop-Job', 'wjb=Wait-Job',
        'epcsv=Export-Csv', 'ipcsv=Import-Csv', 'epal=Export-Alias', 'ipal=Import-Alias',
        'ipsn=Import-PSSession', 'cd=Set-Location', 'chdir=Set-Location', 'sl=Set-Location',
        'pushd=Push-Location', 'popd=Pop-Location', 'cls=Clear-Host', 'clear=Clear-Host',
        'rp=Remove-ItemProperty', 'rv=Remove-Variable', 'nv=New-Variable', 'nmo=New-Module',
        'npssc=New-PSSessionConfigurationFile', 'ise=powershell_ise', 'r=Invoke-History',
        'ihy=Invoke-History', 'ii=Invoke-Item', 'swmi=Set-WmiInstance', 'rwmi=Remove-WmiObject',
        'iwmi=Invoke-WmiMethod', 'lp=Out-Printer', 'shcm=Show-Command', 'trcm=Trace-Command',
        'sleep=Start-Sleep', 'dbp=Disable-PSBreakpoint', 'ebp=Enable-PSBreakpoint',
        'rbp=Remove-PSBreakpoint', 'sbp=Set-PSBreakpoint', 'asnp=Add-PSSnapin', 'rsnp=Remove-PSSnapin',
        'nsn=New-PSSession', 'rcsn=Receive-PSSession', 'cnsn=Connect-PSSession', 'dnsn=Disconnect-PSSession',
        'sujb=Suspend-Job', 'rujb=Resume-Job', 'ndr=New-PSDrive', 'mount=New-PSDrive', 'rdr=Remove-PSDrive',
        'scb=Set-Clipboard', 'gcb=Get-Clipboard', 'stz=Set-TimeZone', 'gtz=Get-TimeZone', 'fimo=Find-Module',
        'inmo=Install-Module', 'pumo=Publish-Module', 'upmo=Update-Module', 'iiq=Invoke-Item'
    )
    $map = @{}
    foreach ($l in $aliasLines) {
        $kv = $l.Split([char[]]@('='), 2)
        $map[$kv[0].ToLowerInvariant()] = $kv[1]
    }
    $p.Aliases = $map

    # --- TABLE 2: cmdlet allowlist.
    # Verbs whose every cmdlet is allowed unless listed in DeniedCmdlets / DeniedNounRegex.
    $p.AllowedVerbs = @('Get', 'Test', 'Resolve', 'Search', 'ConvertTo', 'ConvertFrom')
    # Exact names allowed (verbs like Format/Select/Find are exact-name only).
    $p.ExactAllowed = @(
        'ForEach-Object', 'Where-Object', 'Select-Object', 'Sort-Object', 'Group-Object',
        'Measure-Object', 'Compare-Object', 'Write-Output', 'Out-String', 'Out-Null',
        'Join-Path', 'Split-Path', 'Select-String', 'Select-Xml', 'Import-Module',
        'Format-Table', 'Format-List', 'Format-Wide', 'Format-Custom', 'Format-Hex',
        'Find-NetRoute'
    )
    # Denied even though the verb is allowed.
    $p.DeniedCmdlets = @(
        'Get-Credential', 'Get-Clipboard', 'Get-History', 'ConvertTo-SecureString', 'ConvertFrom-SecureString',
        'Get-EsxCli', 'Get-View', 'Get-VMHostFirmware', 'Get-PfxCertificate', 'Get-VICredentialStoreItem',
        'Get-WindowsUpdateLog', 'Get-BitLockerVolume', 'Get-BitLockerVolumeKeyProtector', 'Get-LapsADPassword',
        'Get-AdmPwdPassword', 'Get-PSReadLineOption', 'Test-Cluster', 'Test-ClusterResourceFailure',
        'Search-Mailbox', 'Measure-Command', 'Get-ADDBAccount', 'Get-ADReplAccount', 'Get-Secret',
        'Get-SecretInfo', 'Get-SecretVault', 'Get-StoredCredential', 'ConvertTo-PSSessionConfigurationFile',
        'Get-WindowsUpdate', 'Get-WUInstall', 'Get-WUList',  # PSWindowsUpdate: Get-WindowsUpdate -Install installs updates
        'Get-Variable'   # all modes: Get-Variable ExecutionContext -ValueOnly would hand out the engine object
    )
    # Denied only when the query runs inside the PowerCLI wrapper (session objects live in-process).
    # (Get-Variable is now denied in every mode via DeniedCmdlets; the entry is kept as belt-and-braces.)
    $p.DeniedCmdletsVsphere = @('Get-Variable')
    # Nouns that are denied under any verb (secret material).
    $p.DeniedNounRegex = '(?i)(Credential|Secret|Password|Clipboard|SecureString)'

    # Cmdlets that can bind a remote computer from pipeline input. They must be
    # the FIRST command of their pipeline (targets then come only from literal args).
    $p.RemoteCapable = @(
        'Test-Connection', 'Test-NetConnection', 'Test-WSMan', 'Get-Service', 'Get-Process',
        'Get-WmiObject', 'Get-CimInstance', 'Get-CimAssociatedInstance', 'Get-EventLog', 'Get-WinEvent',
        'Get-HotFix', 'Get-Counter', 'Resolve-DnsName', 'Test-ComputerSecureChannel', 'Get-ComputerInfo'
    )

    # Cmdlets that evaluate script blocks given as arguments. Their arguments must be
    # literals (constants, literal arrays, literal hashtables, literal script blocks)
    # except for the named value parameters in LiteralArgExemptParams.
    $p.ScriptBlockEvaluators = @(
        'ForEach-Object', 'Where-Object', 'Select-Object', 'Sort-Object', 'Group-Object', 'Measure-Object',
        'Compare-Object', 'Format-Table', 'Format-List', 'Format-Wide', 'Format-Custom', 'ConvertTo-Html'
    )
    $p.LiteralArgExemptParams = @('first', 'last', 'skip', 'skiplast', 'index', 'inputobject', 'referenceobject',
        'differenceobject', 'value', 'top', 'bottom', 'culture', 'syncwindow', 'depth', 'title', 'head', 'body',
        'precontent', 'postcontent', 'column', 'width')
    # NOTE: switches (AutoSize, Wrap, Unique, ...) must NOT be listed above, or a following
    # non-literal positional would be mistaken for their value and escape the literal check.

    # --- TABLE 3: parameters. Each entry is "name:minimumAbbreviationLength".
    # A given parameter is denied when it is a prefix of the name and at least that long.
    $p.DeniedParams = @(
        'repair:3', 'credential:2', 'fix:2', 'outfile:4', 'filepath:3', 'append:2', 'asjob:2', 'parallel:3',
        'session:2', 'pssession:3', 'argumentlist:2', 'args:4', 'wait:2', 'stream:3', 'usetransaction:4',
        'usetx:5', 'outvariable:4', 'ov:2', 'pipelinevariable:3', 'pv:2', 'errorvariable:3', 'ev:2',
        'warningvariable:3', 'wv:2', 'informationvariable:3', 'iv:2', 'destinationpath:5', 'bundle:2', 'online:2',
        'install:3', 'download:4', 'acceptall:4', 'autoreboot:4', 'reboot:3', 'hide:3'
    )
    # Per-cmdlet extra denials (minimum length 1: even "-R" is denied).
    $p.CmdletDeniedParams = @{
        'Test-ComputerSecureChannel' = @('repair:1')
        'Get-Content'                = @('wait:1', 'stream:2')
        'ForEach-Object'             = @('parallel:1', 'asjob:2', 'throttlelimit:2', 'timeoutseconds:2')
        'Select-Object'              = @('wait:1')
    }
    # ScriptBlock parameter only allowed on these:
    $p.ScriptBlockParamOk = @('Where-Object', 'ForEach-Object', 'Select-Object', 'Sort-Object', 'Group-Object')
    # Import-Module: only these parameters.
    $p.ImportModuleParams = @('name', 'force', 'disablenamechecking', 'erroraction', 'warningaction', 'verbose',
        'minimumversion', 'requiredversion', 'maximumversion', 'noclobber')

    # Target-bearing parameters ("name:minimumAbbreviationLength"). Values must be constant and in scope.
    $p.TargetParams = @('computername:1', 'cn:2', 'cimsession:2', 'server:2', 'targetname:2', 'destination:4',
        'remoteaddress:4', 'remoteipaddress:7', 'ipaddress:3', '__server:3')
    # Cmdlet-specific target parameters.
    $p.CmdletTargetParams = @{ 'Test-Connection' = @('source:2') }
    # Cmdlets whose first positional argument is a target.
    $p.PositionalTargetCmdlets = @('Test-Connection', 'Test-NetConnection', 'Test-WSMan')
    # Value-taking (non-target) parameters of those cmdlets, so their value is not mistaken for a target.
    $p.PositionalValueParams = @('port', 'count', 'buffersize', 'delay', 'timetolive', 'ttl', 'maxhops', 'hops',
        'commontcpport', 'informationlevel', 'throttlelimit', 'protocol', 'authentication', 'impersonation',
        'constrainsourceaddress', 'constraininterface', 'dcomauthentication', 'wsmanauthentication',
        'applicationname', 'certificatethumbprint', 'timeoutseconds', 'erroraction', 'warningaction')

    # --- TABLE 4: AST node types.
    $p.DeniedAst = @('FileRedirectionAst', 'FunctionDefinitionAst', 'WhileStatementAst', 'DoWhileStatementAst',
        'DoUntilStatementAst', 'ForStatementAst', 'TrapStatementAst', 'DataStatementAst', 'UsingStatementAst',
        'DynamicKeywordStatementAst', 'ConfigurationDefinitionAst', 'TypeDefinitionAst', 'UsingExpressionAst',
        'AttributeAst', 'BlockStatementAst', 'FunctionMemberAst', 'PropertyMemberAst', 'ErrorStatementAst',
        'ErrorExpressionAst', 'NamedAttributeArgumentAst')
    $p.AllowedAst = @('ScriptBlockAst', 'NamedBlockAst', 'StatementBlockAst', 'PipelineAst', 'CommandAst',
        'CommandExpressionAst', 'CommandParameterAst', 'StringConstantExpressionAst', 'ExpandableStringExpressionAst',
        'ConstantExpressionAst', 'VariableExpressionAst', 'MemberExpressionAst', 'InvokeMemberExpressionAst',
        'IndexExpressionAst', 'ArrayLiteralAst', 'ArrayExpressionAst', 'HashtableAst', 'ParenExpressionAst',
        'SubExpressionAst', 'ScriptBlockExpressionAst', 'BinaryExpressionAst', 'UnaryExpressionAst',
        'ConvertExpressionAst', 'TypeExpressionAst', 'TypeConstraintAst', 'AssignmentStatementAst',
        'IfStatementAst', 'ForEachStatementAst', 'SwitchStatementAst', 'TryStatementAst', 'CatchClauseAst',
        'ThrowStatementAst', 'BreakStatementAst', 'ContinueStatementAst', 'ReturnStatementAst',
        'ExitStatementAst', 'MergingRedirectionAst', 'ParamBlockAst', 'ParameterAst', 'PipelineChainAst',
        'TernaryExpressionAst')

    # --- TABLE 5: variables.
    $p.EnvReadAllowed = @('computername', 'username', 'userdomain', 'userdnsdomain', 'logonserver', 'systemroot')
    $p.DeniedVariables = @('executioncontext', 'psdefaultparametervalues', 'defaultviserver', 'defaultviservers')
    # Names that may never be assigned (plus anything ending in "preference").
    $p.ProtectedVariables = @('executioncontext', 'psdefaultparametervalues', 'psmodulepath', 'profile', 'home',
        'host', '_', 'psitem', 'args', 'input', 'this', 'true', 'false', 'psboundparameters', 'myinvocation',
        'pscmdlet', 'psscriptroot', 'pscommandpath', 'shellid', 'psversiontable', 'pshome', 'pid', 'ofs',
        'maximumhistorycount', 'pssessionconfigurationname', 'psemailserver', 'pssessionoption',
        'pssessionapplicationname', 'formatenumerationlimit', 'nestedpromptlevel', 'stacktrace', 'error',
        'lastexitcode', 'matches', 'iswindows', 'islinux', 'ismacos', 'iscoreclr', 'pwd', 'sender',
        'eventargs', 'event', 'eventsubscriber', 'foreach', 'switch', 'psculture', 'psuiculture',
        'psnativecommandargumentpassing', 'enabledexperimentalfeatures', 'consolefilename', 'psstyle')
    $p.DeniedDrives = @('function', 'alias', 'variable', 'env', 'global', 'script', 'private', 'using', 'workflow')

    # --- TABLE 6: methods, members and types.
    # Instance methods (called on any object).
    $p.InstanceMethods = @('ToString', 'Trim', 'TrimStart', 'TrimEnd', 'Split', 'Contains', 'StartsWith', 'EndsWith',
        'Substring', 'ToLower', 'ToUpper', 'ToLowerInvariant', 'ToUpperInvariant', 'IndexOf', 'PadLeft',
        'PadRight', 'Equals', 'CompareTo', 'GetType', 'AddDays', 'AddHours', 'AddMinutes', 'ToShortDateString',
        'ToUniversalTime', 'ToLocalTime', 'Where', 'ForEach')
    # Static methods (only on an allowed [type] literal, e.g. [string]::Join).
    $p.StaticMethods = @('Join', 'Round', 'Floor', 'Ceiling', 'Max', 'Min', 'Abs', 'Parse', 'TryParse',
        'IsNullOrEmpty', 'IsNullOrWhiteSpace', 'Format', 'Match', 'Matches', 'IsMatch', 'Equals', 'Compare',
        'Escape', 'Split', 'Concat', 'Truncate')
    # Member names (property or method) that are never allowed, and string constants never allowed.
    $p.DeniedMembers = @('scriptblock', 'psobject', 'psbase', 'script', 'getterscript', 'setterscript',
        'sessionsecret', 'invokecommand', 'implementingtype', 'getnetworkcredential', 'password')
    $p.DeniedStrings = @('scriptblock', 'psobject', 'psbase', 'getterscript', 'setterscript', 'sessionsecret')
    $p.AllowedTypes = @('string', 'int', 'int32', 'int64', 'long', 'double', 'decimal', 'bool', 'boolean',
        'datetime', 'timespan', 'version', 'ipaddress', 'net.ipaddress', 'math', 'regex',
        'text.regularexpressions.regex', 'array', 'string[]', 'int[]', 'object[]', 'hashtable',
        'collections.hashtable', 'pscustomobject', 'management.automation.pscustomobject', 'ordered',
        'char', 'byte', 'guid', 'void', 'xml', 'xml.xmldocument', 'int32[]', 'char[]', 'uint32', 'uint64',
        'int16', 'uint16', 'single', 'float')

    # --- TABLE 7: native Windows commands that may run (rules in Test-NetGateNative).
    $p.NativeAllowed = @('ping', 'tracert', 'pathping', 'nslookup', 'ipconfig', 'arp', 'route', 'netstat',
        'hostname', 'whoami', 'systeminfo', 'getmac', 'nbtstat', 'w32tm', 'nltest', 'dcdiag', 'repadmin',
        'klist', 'net', 'netsh', 'tasklist', 'schtasks', 'wevtutil', 'gpresult', 'driverquery', 'quser',
        'qwinsta', 'query', 'kubectl')
    return $p
}

# =============================================================================
#  SCOPE
# =============================================================================
function ConvertTo-NetGateIPv4Number {
    param([string]$Text)
    if ($Text -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $null }
    $n = [int64]0
    for ($i = 1; $i -le 4; $i++) {
        $o = [int]$Matches[$i]
        if ($o -gt 255) { return $null }
        $n = ($n * 256) + $o
    }
    return $n
}

function Test-NetGateIPv4InCidr {
    param([int64]$Ip, [string]$Entry)
    $parts = $Entry.Split('/')
    $base = ConvertTo-NetGateIPv4Number $parts[0]
    if ($null -eq $base) { return $false }
    $prefix = 32
    if ($parts.Count -eq 2) { $prefix = [int]$parts[1] }
    $size = [int64][Math]::Pow(2, 32 - $prefix)
    return ([int64][Math]::Floor($Ip / $size) -eq [int64][Math]::Floor($base / $size))
}

function Test-NetGateScopeEntryValid {
    param([string]$Entry)
    if ($Entry -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(/(\d{1,2}))?$') {
        if ($null -eq (ConvertTo-NetGateIPv4Number $Matches[1])) { return $false }
        if ($Matches[3] -and [int]$Matches[3] -gt 32) { return $false }
        return $true
    }
    return ($Entry -match '^[A-Za-z0-9*?._-]{1,253}$')
}

function Read-ScopeConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $obj = ConvertFrom-Json -InputObject $raw
    } catch { return $null }
    if ($null -eq $obj -or -not ($obj.PSObject.Properties.Name -contains 'allow')) { return $null }
    $allow = @()
    $deny = @()
    foreach ($e in @($obj.allow)) {
        $s = ([string]$e).Trim()
        if (-not $s) { continue }
        if (-not (Test-NetGateScopeEntryValid $s)) { return $null }
        $allow += $s
    }
    if ($obj.PSObject.Properties.Name -contains 'deny') {
        foreach ($e in @($obj.deny)) {
            $s = ([string]$e).Trim()
            if (-not $s) { continue }
            if (-not (Test-NetGateScopeEntryValid $s)) { return $null }
            $deny += $s
        }
    }
    return [pscustomobject]@{ allow = [string[]]$allow; deny = [string[]]$deny; path = $Path }
}

function Test-NetGateLocalName {
    param([string]$Target)
    $t = $Target.Trim().TrimEnd('.').ToLowerInvariant()
    if ($Target.Trim() -eq '.') { return $true }
    if ($t -in @('localhost', '::1', '[::1]', '0:0:0:0:0:0:0:1')) { return $true }
    $n = ConvertTo-NetGateIPv4Number $t
    if ($null -ne $n -and $n -ge 2130706432 -and $n -le 2147483647) { return $true }   # 127.0.0.0/8
    $me = [string]$env:COMPUTERNAME
    if (-not $me) { try { $me = [Environment]::MachineName } catch { $me = '' } }
    if ($me -and $t -eq $me.ToLowerInvariant()) { return $true }
    return $false
}

function Test-TargetInScope {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target,
        $Scope
    )
    $t = $Target.Trim()
    if (-not $t) { return $false }
    if (Test-NetGateLocalName $t) { return $true }
    if ($null -eq $Scope) { return $false }
    $t = $t.TrimEnd('.').ToLowerInvariant()
    $allow = @($Scope.allow | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $deny = @($Scope.deny | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })

    $ipNum = ConvertTo-NetGateIPv4Number $t
    if ($null -ne $ipNum) {
        foreach ($d in $deny) {
            if ($d -match '^\d+\.\d+\.\d+\.\d+(/\d+)?$' -and (Test-NetGateIPv4InCidr -Ip $ipNum -Entry $d)) { return $false }
        }
        foreach ($a in $allow) {
            if ($a -match '^\d+\.\d+\.\d+\.\d+(/\d+)?$' -and (Test-NetGateIPv4InCidr -Ip $ipNum -Entry $a)) { return $true }
        }
        return $false
    }
    # Anything that is not a plain host name (IPv6, wildcards, odd encodings) is out of scope.
    if ($t -notmatch '^[a-z0-9_]([a-z0-9_.-]{0,251}[a-z0-9_])?$') { return $false }
    if ($t -match '^[0-9.]+$') { return $false }          # partial / encoded IPv4 (e.g. "10.1", "167772161")
    if ($t -match '^0x[0-9a-f]+$') { return $false }
    foreach ($d in $deny) {
        if ($d -notmatch '^\d+\.\d+\.\d+\.\d+(/\d+)?$' -and $t -like $d) { return $false }
    }
    foreach ($a in $allow) {
        if ($a -notmatch '^\d+\.\d+\.\d+\.\d+(/\d+)?$' -and $t -like $a) { return $true }
    }
    return $false
}

function Test-NetGateIgnorableIPv4 {
    # Dotted quads that cannot be a target: 0.0.0.0, broadcast, loopback, and netmasks.
    param([string]$Text)
    $n = ConvertTo-NetGateIPv4Number $Text
    if ($null -eq $n) { return $true }
    if ($n -eq 0 -or $n -eq 4294967295) { return $true }
    if ($n -ge 2130706432 -and $n -le 2147483647) { return $true }
    if ($Text -match '^255\.') {
        # contiguous-ones netmask?
        $inv = 4294967295 - $n
        if ((($inv + 1) -band $inv) -eq 0) { return $true }
    }
    return $false
}

function Get-NetGateTextTargets {
    # IPv4 literals, UNC hosts and URL hosts found anywhere in the text.
    param([string]$Text)
    $out = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Text, '(?<![0-9.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?![0-9]|\.[0-9])')) {
        $ip = $m.Groups[1].Value
        if ($null -ne (ConvertTo-NetGateIPv4Number $ip) -and -not (Test-NetGateIgnorableIPv4 $ip)) { [void]$out.Add($ip) }
    }
    foreach ($m in [regex]::Matches($Text, '(?:^|[^\\])\\\\([^\\/\s''"`;|,)]+)')) { [void]$out.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($Text, '(?:^|[\s''"(=,])//([^/\s''"`;|,)]+)')) { [void]$out.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($Text, '(?i)[a-z][a-z0-9+.-]*://\[?([^/:\s''"`;|,)\]]*)')) {
        if ($m.Groups[1].Value) { [void]$out.Add($m.Groups[1].Value) }
    }
    return ,$out.ToArray()
}

# =============================================================================
#  POWERSHELL GATE
# =============================================================================
function New-NetGateResult {
    param([bool]$Allowed, [string]$Reason, $Targets)
    $t = @()
    if ($Targets) { $t = @($Targets | Select-Object -Unique) }
    return [pscustomobject]@{ Allowed = $Allowed; Reason = $Reason; Targets = [string[]]$t }
}

function Test-NetGateParamMatch {
    # True when $Given (a typed parameter name) is an abbreviation of an entry "name:minLen".
    param([string]$Given, [string[]]$Entries)
    $g = $Given.ToLowerInvariant()
    foreach ($e in $Entries) {
        $kv = $e.Split(':')
        $name = $kv[0]
        $min = [int]$kv[1]
        if ($g.Length -ge $min -and $name.StartsWith($g)) { return $name }
    }
    return $null
}

function Get-NetGateConstantValues {
    # Returns string[] when the AST is a constant (or array of constants); otherwise $null.
    param($Ast)
    if ($null -eq $Ast) { return $null }
    $tn = $Ast.GetType().Name
    if ($tn -eq 'StringConstantExpressionAst') { return ,([string[]]@([string]$Ast.Value)) }
    if ($tn -eq 'ConstantExpressionAst') { return ,([string[]]@([string]$Ast.Extent.Text)) }
    if ($tn -eq 'ExpandableStringExpressionAst' -and @($Ast.NestedExpressions).Count -eq 0) { return ,([string[]]@([string]$Ast.Value)) }
    if ($tn -eq 'ArrayLiteralAst') {
        $vals = @()
        foreach ($el in $Ast.Elements) {
            $v = Get-NetGateConstantValues $el
            if ($null -eq $v) { return $null }
            $vals += $v
        }
        return ,([string[]]$vals)
    }
    if ($tn -eq 'ParenExpressionAst' -or $tn -eq 'ArrayExpressionAst') {
        # (constant) or @(constant, ...) with exactly one simple pipeline
        $inner = $null
        if ($tn -eq 'ParenExpressionAst') { $inner = $Ast.Pipeline } else { $stmts = @($Ast.SubExpression.Statements); if ($stmts.Count -eq 1) { $inner = $stmts[0] } }
        if ($inner -and $inner.GetType().Name -eq 'PipelineAst' -and @($inner.PipelineElements).Count -eq 1) {
            $el = $inner.PipelineElements[0]
            if ($el.GetType().Name -eq 'CommandExpressionAst') { return (Get-NetGateConstantValues $el.Expression) }
        }
        return $null
    }
    return $null
}

function Test-NetGateIsLiteralArg {
    # Literal-only check used for script-block-evaluating cmdlets.
    param($Ast)
    if ($null -eq $Ast) { return $true }
    $tn = $Ast.GetType().Name
    if ($tn -in @('StringConstantExpressionAst', 'ConstantExpressionAst', 'HashtableAst', 'ScriptBlockExpressionAst')) { return $true }
    if ($tn -eq 'ExpandableStringExpressionAst') { return $true }
    if ($tn -eq 'ArrayLiteralAst') {
        foreach ($el in $Ast.Elements) { if (-not (Test-NetGateIsLiteralArg $el)) { return $false } }
        return $true
    }
    return $false
}

function Get-NetGateVarInfo {
    # Splits a VariablePath into drive/scope and name.
    param($VariableAst)
    $up = [string]$VariableAst.VariablePath.UserPath
    $drive = ''
    $name = $up
    $idx = $up.IndexOf(':')
    if ($idx -ge 0) { $drive = $up.Substring(0, $idx).ToLowerInvariant(); $name = $up.Substring($idx + 1) }
    return @{ Drive = $drive; Name = $name.ToLowerInvariant(); Raw = $up }
}

function Test-NetGateAssignableVar {
    # Returns $null if $Ast is a plain user variable that may be assigned; else a reason.
    param($Ast, $Policy)
    $tn = $Ast.GetType().Name
    if ($tn -eq 'ConvertExpressionAst') { return (Test-NetGateAssignableVar $Ast.Child $Policy) }
    if ($tn -ne 'VariableExpressionAst') { return 'Only plain variables may be assigned (no properties, indexes, or multiple targets).' }
    if ($Ast.Splatted) { return 'Splatting is not allowed.' }
    $vi = Get-NetGateVarInfo $Ast
    if ($vi.Drive -and $vi.Drive -ne 'local') { return "Assigning `$$($vi.Raw) is not allowed; use a plain local variable." }
    if ($vi.Name -in $Policy.ProtectedVariables -or $vi.Name.EndsWith('preference')) { return "`$$($vi.Raw) is an automatic or preference variable and cannot be assigned." }
    return $null
}

function Test-NetGateNativeKubectl {
    # Shared kubectl rule (Windows native and Linux). Returns $null when allowed, else a reason.
    param([string[]]$A)
    $valueFlags = @('-n', '--namespace', '--context', '--kubeconfig', '--cluster', '--user', '-s', '--server',
        '-o', '--output', '-l', '--selector', '-c', '--container', '--field-selector', '--sort-by', '--since',
        '--tail', '--request-timeout', '-L', '--label-columns', '--template')
    foreach ($x in $A) {
        $lx = $x
        if ($lx -in @('-w', '--watch', '--watch-only', '-f', '--follow', '--raw', '-it', '-i', '-t', '--stdin', '--tty') -or $lx -like '--watch=*' -or $lx -like '--follow=*' -or $lx -like '--raw=*' -or $lx -like '-f=*') {
            return "kubectl flag '$x' is not allowed (no watch/follow/raw/interactive)."
        }
        if ($lx -match '^--(token|password|username|client-key|client-certificate|as|as-group)(=|$)') { return "kubectl flag '$x' is not allowed." }
    }
    $words = @()
    for ($i = 0; $i -lt $A.Count; $i++) {
        $x = $A[$i]
        if ($x.StartsWith('-')) {
            if ($x -notmatch '=' -and $x -in $valueFlags) { $i++ }
            continue
        }
        $words += $x
    }
    if ($words.Count -eq 0) { return 'kubectl needs a read-only subcommand (get, describe, logs, top, version, cluster-info, api-resources, api-versions, explain).' }
    $sub = $words[0].ToLowerInvariant()
    if ($sub -eq 'config') {
        if ($words.Count -lt 2 -or $words[1].ToLowerInvariant() -notin @('view', 'current-context', 'get-contexts')) {
            return 'kubectl config is only allowed with view, current-context or get-contexts.'
        }
        return $null
    }
    if ($sub -notin @('get', 'describe', 'logs', 'top', 'version', 'cluster-info', 'api-resources', 'api-versions', 'explain')) {
        return "kubectl $sub is not read-only. Allowed: get, describe, logs, top, version, cluster-info, api-resources, api-versions, explain, config view."
    }
    if ($sub -eq 'cluster-info' -and $words.Count -gt 1) { return 'kubectl cluster-info dump is not allowed.' }
    return $null
}

function Test-NetGateNative {
    # Native Windows command rules. $A = constant argument strings. Adds targets to $Targets (ArrayList).
    # Returns $null when allowed, else a reason.
    param([string]$Name, [string[]]$A, [System.Collections.ArrayList]$Targets)
    $L = @($A | ForEach-Object { $_.ToLowerInvariant() })
    $n = $A.Count
    function Has([string[]]$opts) { foreach ($o in $opts) { if ($L -contains $o) { return $true } }; return $false }
    function HasPrefix([string[]]$opts) { foreach ($x in $L) { foreach ($o in $opts) { if ($x.StartsWith($o)) { return $true } } }; return $false }
    function SlashValue([string]$flag) {
        # returns values for "/flag x" and "/flag:x" forms
        $vals = @()
        for ($i = 0; $i -lt $L.Count; $i++) {
            if ($L[$i] -eq $flag -or $L[$i] -eq ('-' + $flag.TrimStart('/'))) { if ($i + 1 -lt $A.Count) { $vals += $A[$i + 1] } }
            elseif ($L[$i].StartsWith($flag + ':')) { $vals += $A[$i].Substring($flag.Length + 1) }
        }
        return $vals
    }
    function NoCreds() { if ((Has @('/u', '/p', '-u', '-p')) -or (HasPrefix @('/u:', '/p:', '/user:', '/password:'))) { return $true }; return $false }

    switch ($Name) {
        'ping' {
            if (Has @('-t', '/t')) { return 'ping -t never ends. Use -n <count>.' }
            $vf = @('-n', '-l', '-w', '-i', '-v', '-r', '-s', '-j', '-k', '-S', '/n', '/l', '/w', '/i', '/v', '/r', '/s', '/j', '/k')
            for ($i = 0; $i -lt $n; $i++) {
                if ($A[$i] -in $vf) { $i++; continue }
                if ($A[$i].StartsWith('-') -or $A[$i].StartsWith('/')) { continue }
                [void]$Targets.Add($A[$i])
            }
            return $null
        }
        { $_ -in @('tracert', 'pathping') } {
            $vf = @('-h', '-j', '-w', '-S', '-g', '-p', '-q', '-i', '/h', '/j', '/w', '/g', '/p', '/q', '/i')
            for ($i = 0; $i -lt $n; $i++) {
                if ($A[$i] -in $vf) { $i++; continue }
                if ($A[$i].StartsWith('-') -or $A[$i].StartsWith('/')) { continue }
                [void]$Targets.Add($A[$i])
            }
            return $null
        }
        'nslookup' {
            if ($n -lt 1) { return 'nslookup needs a name to look up (interactive mode is not allowed).' }
            $pos = @($A | Where-Object { -not $_.StartsWith('-') })
            if ($A -contains '-' -or $pos.Count -lt 1) { return 'nslookup interactive mode is not allowed; give a name to look up.' }
            if ($pos.Count -gt 2) { return 'nslookup takes at most a name and a server.' }
            if ($pos.Count -eq 2) { [void]$Targets.Add($pos[1]) }
            return $null
        }
        'ipconfig' {
            if ($n -eq 0) { return $null }
            if ($n -eq 1 -and $L[0] -in @('/all', '/displaydns', '-all', '-displaydns')) { return $null }
            return 'ipconfig is only allowed with no arguments, /all or /displaydns.'
        }
        'arp' {
            if ($n -ge 1 -and $n -le 2 -and $L[0] -in @('-a', '/a', '-g', '/g')) {
                if ($n -eq 2) { [void]$Targets.Add($A[1]) }
                return $null
            }
            return 'arp is only allowed as "arp -a [address]".'
        }
        'route' {
            if ($n -lt 1 -or $L[0] -ne 'print') { return 'route is only allowed as "route print".' }
            if (Has @('-f', '/f', '-p', '/p', 'add', 'delete', 'change')) { return 'route modifying options are not allowed.' }
            return $null
        }
        'netstat' {
            foreach ($x in $A) { if ($x -match '^\d+$') { return 'netstat interval argument is not allowed (it never ends).' } }
            return $null
        }
        'hostname' { if ($n -eq 0) { return $null }; return 'hostname takes no arguments.' }
        'whoami' {
            foreach ($x in $A) { if (-not $x.StartsWith('/')) { return 'whoami only accepts /flags.' } }
            return $null
        }
        { $_ -in @('systeminfo', 'getmac', 'tasklist', 'driverquery') } {
            if (NoCreds) { return "$Name /u and /p are not allowed; use a stored credential with net_query via winrm." }
            foreach ($v in (SlashValue '/s')) { [void]$Targets.Add($v) }
            return $null
        }
        'nbtstat' {
            $ok = @('-a', '-A', '-n', '-c', '-r', '-S', '-s')
            for ($i = 0; $i -lt $n; $i++) {
                $x = $A[$i]
                if ($x -cin @('-a', '-A')) {
                    if ($i + 1 -ge $n) { return 'nbtstat -a/-A needs a host.' }
                    [void]$Targets.Add($A[$i + 1]); $i++; continue
                }
                if (-not ($ok -ccontains $x)) { return "nbtstat option '$x' is not allowed. Allowed: -a -A -n -c -r -S -s." }
            }
            return $null
        }
        'w32tm' {
            if (-not (HasPrefix @('/query', '/monitor', '/stripchart'))) { return 'w32tm is only allowed with /query, /monitor or /stripchart.' }
            if (HasPrefix @('/config', '/resync', '/register', '/unregister', '/set', '/debug', '/tz:')) { return 'w32tm configuration options are not allowed.' }
            foreach ($v in (SlashValue '/computer')) { [void]$Targets.Add($v) }
            foreach ($v in (SlashValue '/computers')) { foreach ($c in $v.Split(',')) { if ($c) { [void]$Targets.Add($c) } } }
            return $null
        }
        'nltest' {
            if ($n -eq 0) { return 'nltest needs a query option.' }
            $keys = @('/dsgetdc', '/dclist', '/domain_trusts', '/dsgetsite', '/sc_query', '/server')
            $mods = @('/pdc', '/ds', '/dsp', '/gc', '/kdc', '/timeserv', '/gtimeserv', '/avoidself', '/netbios', '/dns',
                '/ret_dns', '/ret_netbios', '/ip', '/writable', '/force', '/primary', '/forest', '/direct_out',
                '/direct_in', '/all_trusts', '/v', '/trusted_domains')
            foreach ($x in $L) {
                $hit = $false
                foreach ($k in $keys) { if ($x -eq $k -or $x.StartsWith($k + ':')) { $hit = $true } }
                if ($x -in $mods) { $hit = $true }
                if (-not $hit) { return "nltest option '$x' is not allowed. Allowed: /dsgetdc /dclist /domain_trusts /dsgetsite /sc_query /server." }
            }
            foreach ($v in (SlashValue '/server')) { [void]$Targets.Add($v) }
            return $null
        }
        'dcdiag' {
            foreach ($x in $L) {
                if ($x -eq '/fix' -or $x.StartsWith('/f:') -or $x.StartsWith('/ferr:') -or $x -match 'fix|recreate|repair') { return 'dcdiag /fix, /f: and /ferr: are not allowed.' }
            }
            if (NoCreds) { return 'dcdiag /u and /p are not allowed.' }
            foreach ($v in (SlashValue '/s')) { [void]$Targets.Add($v) }
            return $null
        }
        'repadmin' {
            $main = @('/showrepl', '/replsummary', '/showconn', '/showutdvec', '/queue')
            $mods = @('/csv', '/verbose', '/all', '/errorsonly', '/bysrc', '/bydest', '/intersite', '/latency', '/nocache', '/repsto', '/conn', '/v')
            if (-not (Has $main)) { return 'repadmin is only allowed with /showrepl, /replsummary, /showconn, /showutdvec or /queue.' }
            foreach ($x in $L) {
                if ($x.StartsWith('/')) {
                    if ($x -notin $main -and $x -notin $mods -and -not $x.StartsWith('/sort:')) { return "repadmin option '$x' is not allowed." }
                } elseif ($x -ne '*' -and $x -notmatch '=') {
                    [void]$Targets.Add($x)
                }
            }
            return $null
        }
        'klist' {
            $okSub = @('tickets', 'tgt', 'sessions', 'kcd_cache', 'query_bind')
            for ($i = 0; $i -lt $n; $i++) {
                $x = $L[$i]
                if ($x -in @('-li', '-lh')) { $i++; continue }
                if ($x -notin $okSub) { return "klist '$x' is not allowed. Allowed: tickets, tgt, sessions, kcd_cache, query_bind." }
            }
            return $null
        }
        'net' {
            if ($n -lt 1) { return 'net needs a read-only subcommand.' }
            $sub = $L[0]
            $rest = @()
            if ($n -gt 1) { $rest = @($L[1..($n - 1)]) }
            foreach ($x in $rest) {
                if ($x -match '=' -or $x -match '^/(add|delete|del|active|set|setsntp|times|passwordreq|passwordchg|expires|homedir|fullname|comment|workstations|scriptpath|profilepath|grant|remark|users|cache|unlimited|y|yes|no|persistent|savecred|smartcard|maxpwage|minpwage|minpwlen|uniquepw|forcelogoff|lockout)') {
                    return "net $sub option '$x' modifies state and is not allowed."
                }
            }
            $pos = @($rest | Where-Object { -not $_.StartsWith('/') })
            $flags = @($rest | Where-Object { $_.StartsWith('/') })
            switch ($sub) {
                'view' { foreach ($f in $flags) { if ($f -notmatch '^/(domain(:.*)?|all|network:.*)$') { return "net view option '$f' is not allowed." } }; if ($pos.Count -gt 1) { return 'net view takes at most one \\host.' }; return $null }
                { $_ -in @('user', 'group', 'localgroup') } {
                    foreach ($f in $flags) { if ($f -ne '/domain') { return "net $sub option '$f' is not allowed (only /domain)." } }
                    if ($pos.Count -gt 1) { return "net $sub takes at most one name (more arguments would change it)." }
                    return $null
                }
                'share' { if ($flags.Count -gt 0 -or $pos.Count -gt 1) { return 'net share is only allowed with zero or one share name.' }; return $null }
                'accounts' { foreach ($f in $flags) { if ($f -ne '/domain') { return 'net accounts is only allowed with no options or /domain.' } }; if ($pos.Count -gt 0) { return 'net accounts takes no names.' }; return $null }
                'config' { if ($rest.Count -gt 1 -or ($rest.Count -eq 1 -and $rest[0] -notin @('server', 'workstation', 'rdr', 'srv'))) { return 'net config is only allowed as "net config server|workstation".' }; return $null }
                { $_ -in @('statistics', 'stats') } { if ($rest.Count -gt 1 -or ($rest.Count -eq 1 -and $rest[0] -notin @('server', 'workstation', 'srv', 'rdr'))) { return 'net statistics is only allowed as "net statistics server|workstation".' }; return $null }
                'time' {
                    foreach ($f in $flags) { if ($f -notmatch '^/(domain(:.*)?|rtsdomain(:.*)?|querysntp)$') { return "net time option '$f' is not allowed." } }
                    if ($pos.Count -gt 1) { return 'net time takes at most one \\host.' }
                    return $null
                }
                'session' { if ($flags.Count -gt 0 -or $pos.Count -gt 1) { return 'net session is only allowed with zero arguments or one \\computer.' }; return $null }
                'use' { if ($rest.Count -gt 0) { return 'net use is only allowed with no arguments (list connections).' }; return $null }
                'start' { if ($rest.Count -gt 0) { return 'net start is only allowed with no arguments (lists running services).' }; return $null }
                default { return "net $sub is not allowed. Allowed: view, share, user, group, localgroup, accounts, config, statistics, time, session, use, start." }
            }
        }
        'netsh' {
            if ($L -notcontains 'show') { return 'netsh is only allowed with a "show" command.' }
            $bad = @('set', 'add', 'delete', 'reset', 'import', 'export', 'exec', 'install', 'uninstall', 'dump', 'start',
                'stop', 'flush', 'clear', 'connect', 'disconnect', 'commit', 'renew', 'release', 'trace', 'backup',
                'restore', 'load', 'unload', 'remove', 'change', 'enable', 'disable', 'offline', 'online', 'run')
            foreach ($x in $L) {
                if ($x -in $bad) { return "netsh '$x' is not allowed (read-only show commands only)." }
                if ($x -in @('-r', '-f', '-u', '-p', '/r', '/f', '/u', '/p')) { return "netsh option '$x' is not allowed." }
                if ($x -match '^(key=clear)$') { return 'netsh key=clear reveals secrets and is not allowed.' }
            }
            return $null
        }
        'schtasks' {
            if ($L -notcontains '/query') { return 'schtasks is only allowed with /query.' }
            $okf = @('/query', '/fo', '/nh', '/v', '/tn', '/xml', '/s', '/hresult')
            foreach ($x in $L) { if ($x.StartsWith('/') -and $x -notin $okf) { return "schtasks option '$x' is not allowed." } }
            foreach ($v in (SlashValue '/s')) { [void]$Targets.Add($v) }
            return $null
        }
        'wevtutil' {
            if ($n -lt 1 -or $L[0] -notin @('qe', 'gl', 'gli', 'el', 'ep', 'gp', 'query-events', 'get-log', 'get-loginfo', 'enum-logs', 'enum-publishers', 'get-publisher')) {
                return 'wevtutil is only allowed with qe, gl, gli, el, ep, gp.'
            }
            foreach ($x in $L) {
                if ($x -match '^/(u|p|username|password):' -or $x -in @('/u', '/p')) { return 'wevtutil /u and /p are not allowed.' }
                if ($x -match '^/(r|remote):(.+)$') { [void]$Targets.Add($Matches[2]) }
            }
            return $null
        }
        'gpresult' {
            foreach ($x in $L) { if ($x -in @('/f', '/x', '/h', '-f', '-x', '-h')) { return 'gpresult /f, /x and /h write files and are not allowed. Use /r or /v.' } }
            if (NoCreds) { return 'gpresult /u and /p are not allowed.' }
            foreach ($v in (SlashValue '/s')) { [void]$Targets.Add($v) }
            return $null
        }
        { $_ -in @('quser', 'qwinsta') } {
            foreach ($x in $A) { if ($x -match '^/server:(.+)$') { [void]$Targets.Add($Matches[1]) } }
            return $null
        }
        'query' {
            if ($n -lt 1 -or $L[0] -notin @('user', 'session', 'process', 'termserver')) { return 'query is only allowed with user, session, process or termserver.' }
            foreach ($x in $A) { if ($x -match '^/server:(.+)$') { [void]$Targets.Add($Matches[1]) } }
            return $null
        }
        'kubectl' { return (Test-NetGateNativeKubectl -A $A) }
        default { return "Native command '$Name' is not on the read-only allowlist." }
    }
}

function Test-ReadOnlyCommand {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        $Scope,
        [ValidateSet('local', 'winrm', 'vsphere')][string]$Mode = 'local',
        [string[]]$ProtectedPathFragments = @()
    )
    $targets = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Command)) { return (New-NetGateResult $false 'Command is empty.' $null) }
    if ($Command.Length -gt 4000) { return (New-NetGateResult $false 'Command is longer than 4000 characters. Split it into smaller queries.' $null) }
    foreach ($frag in $ProtectedPathFragments) {
        if ($frag -and $Command.IndexOf($frag, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return (New-NetGateResult $false 'The command references the app credential store, which is never readable by queries.' $null)
        }
    }
    if ($Command.IndexOf('__explorer', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return (New-NetGateResult $false 'Names starting with __explorer are reserved for the query wrapper.' $null)
    }
    if ($Command -match '(?im)^\s*#\s*requires') { return (New-NetGateResult $false '#requires is not allowed.' $null) }
    if ($Command -match '(?i)<!ENTITY|<!DOCTYPE') { return (New-NetGateResult $false 'XML DTD/ENTITY declarations are not allowed.' $null) }
    if ($Command -match '(?i)AdmPwd|msLAPS|unicodePwd|userPassword|ms-Mcs') { return (New-NetGateResult $false 'Reading password attributes is not allowed.' $null) }
    if ($Command -match '\\\\[.?]\\|//[.?]/') { return (New-NetGateResult $false 'Device paths (\\.\ and \\?\) are not allowed.' $null) }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
    if ($errors -and @($errors).Count -gt 0) {
        return (New-NetGateResult $false ("PowerShell syntax error: " + $errors[0].Message) $null)
    }
    $P = Get-NetGatePolicy

    $nodes = $ast.FindAll({ param($n) $true }, $true)
    foreach ($node in $nodes) {
        $tn = $node.GetType().Name
        if ($tn -in $P.DeniedAst) {
            $what = $tn -replace 'Ast$', ''
            if ($tn -eq 'FileRedirectionAst') { return (New-NetGateResult $false 'Redirecting output to a file (>, >>, 2>file) is not allowed. Output is saved to raw\ automatically.' $targets) }
            return (New-NetGateResult $false "$what is not allowed in read-only queries (no functions, loops other than foreach, classes, using, traps or data sections)." $targets)
        }
        if ($tn -notin $P.AllowedAst) { return (New-NetGateResult $false "PowerShell construct $tn is not allowed in read-only queries." $targets) }

        switch ($tn) {
            'StringConstantExpressionAst' {
                $sv = [string]$node.Value
                if ($sv.ToLowerInvariant() -in $P.DeniedStrings) { return (New-NetGateResult $false "The string '$sv' is not allowed." $targets) }
                if ($sv -match '(?i)(^|[^a-z0-9_])(function|alias|variable|env)::?') { return (New-NetGateResult $false "Paths on the function:, alias:, variable: or env: drives are not allowed." $targets) }
            }
            'VariableExpressionAst' {
                if ($node.Splatted) { return (New-NetGateResult $false 'Splatting (@var) is not allowed; write parameters out literally.' $targets) }
                $vi = Get-NetGateVarInfo $node
                if ($vi.Name -in $P.DeniedVariables) { return (New-NetGateResult $false "`$$($vi.Raw) is not allowed." $targets) }
                if ($vi.Drive) {
                    if ($vi.Drive -eq 'env') {
                        if ($vi.Name -notin $P.EnvReadAllowed) { return (New-NetGateResult $false "Reading `$env:$($vi.Name) is not allowed. Allowed: COMPUTERNAME, USERNAME, USERDOMAIN, USERDNSDOMAIN, LOGONSERVER, SystemRoot." $targets) }
                    } elseif ($vi.Drive -ne 'local') {
                        return (New-NetGateResult $false "Scoped or drive-qualified variable `$$($vi.Raw) is not allowed." $targets)
                    }
                }
            }
            'AssignmentStatementAst' {
                $why = Test-NetGateAssignableVar $node.Left $P
                if ($why) { return (New-NetGateResult $false $why $targets) }
                $lv = $node.Left
                if ($lv.GetType().Name -eq 'ConvertExpressionAst') { $lv = $lv.Child }
                $lvi = Get-NetGateVarInfo $lv
                if ($lvi.Drive -eq 'env') { return (New-NetGateResult $false 'Writing environment variables is not allowed.' $targets) }
            }
            'UnaryExpressionAst' {
                $op = [string]$node.TokenKind
                if ($op -in @('PlusPlus', 'MinusMinus', 'PostfixPlusPlus', 'PostfixMinusMinus')) {
                    $why = Test-NetGateAssignableVar $node.Child $P
                    if ($why) { return (New-NetGateResult $false $why $targets) }
                }
            }
            'BinaryExpressionAst' {
                $op = [string]$node.Operator
                if ($op -in @('As', 'Is', 'IsNot') -and $node.Right.GetType().Name -ne 'TypeExpressionAst') {
                    return (New-NetGateResult $false "-as/-is must use a [type] literal, not a string or expression." $targets)
                }
            }
            { $_ -in @('TypeExpressionAst', 'TypeConstraintAst', 'ConvertExpressionAst') } {
                $tnm = $null
                if ($tn -eq 'ConvertExpressionAst') { $tnm = $node.Type.TypeName } else { $tnm = $node.TypeName }
                $full = ([string]$tnm.FullName).ToLowerInvariant()
                if ($full.StartsWith('system.')) { $full = $full.Substring(7) }
                if ($full -notin $P.AllowedTypes) {
                    return (New-NetGateResult $false "Type [$($tnm.FullName)] is not allowed. Allowed types: string, int, long, double, bool, datetime, timespan, version, ipaddress, math, regex, hashtable, pscustomobject, ordered, xml, arrays." $targets)
                }
            }
            { $_ -in @('MemberExpressionAst', 'InvokeMemberExpressionAst') } {
                if ($node.Member.GetType().Name -ne 'StringConstantExpressionAst') {
                    return (New-NetGateResult $false 'Dynamic member names ($x.$name) are not allowed.' $targets)
                }
                $mn = [string]$node.Member.Value
                if ($mn.ToLowerInvariant() -in $P.DeniedMembers) { return (New-NetGateResult $false "Member '$mn' is not allowed." $targets) }
                if ($tn -eq 'InvokeMemberExpressionAst') {
                    if ($node.Static) {
                        if ($node.Expression.GetType().Name -ne 'TypeExpressionAst') { return (New-NetGateResult $false 'Static calls are only allowed on a [type] literal.' $targets) }
                        if (-not ($P.StaticMethods -contains $mn)) {
                            return (New-NetGateResult $false "Static method ::$mn() is not allowed. Allowed: $($P.StaticMethods -join ', ')." $targets)
                        }
                    } else {
                        if (-not ($P.InstanceMethods -contains $mn)) {
                            return (New-NetGateResult $false "Method .$mn() is not allowed (it may change state). Allowed methods: $($P.InstanceMethods -join ', '). Use -replace instead of .Replace()." $targets)
                        }
                        if ($mn -in @('ForEach', 'Where')) {
                            $margs = @($node.Arguments)
                            if ($margs.Count -lt 1 -or $margs[0].GetType().Name -ne 'ScriptBlockExpressionAst') {
                                return (New-NetGateResult $false ".$mn() must be given a literal { script block }." $targets)
                            }
                            for ($k = 1; $k -lt $margs.Count; $k++) {
                                if ($mn -eq 'ForEach' -or $null -eq (Get-NetGateConstantValues $margs[$k])) { return (New-NetGateResult $false ".$mn() extra arguments must be constants." $targets) }
                            }
                        }
                    }
                }
            }
            'HashtableAst' {
                $tgtNames = @('computername', 'cn', '__server', 'server', 'destination', 'ipaddress', 'targetname', 'cimsession', 'remoteaddress', 'session', 'pscomputername')
                foreach ($pair in $node.KeyValuePairs) {
                    $kvals = Get-NetGateConstantValues $pair.Item1
                    if ($null -eq $kvals) { return (New-NetGateResult $false 'Hashtable keys must be constants.' $targets) }
                    $k = $kvals[0].ToLowerInvariant()
                    if ($k -in $tgtNames) { return (New-NetGateResult $false "Building objects with a '$k' property is not allowed (it could redirect a query to another computer). Pass -ComputerName with a literal value." $targets) }
                    if ($k -in @('n', 'name', 'l', 'label')) {
                        $vtxt = $pair.Item2.Extent.Text.Trim(@([char]39, [char]34, ' ')).ToLowerInvariant()
                        if ($vtxt -in $tgtNames) { return (New-NetGateResult $false "A calculated property named '$vtxt' is not allowed (it could redirect a query to another computer)." $targets) }
                    }
                }
            }
            'CommandAst' {
                $res = Test-NetGateCommandAst -Node $node -Policy $P -Scope $Scope -Targets $targets -Mode $Mode
                if ($res) { return (New-NetGateResult $false $res $targets) }
            }
        }
    }

    # Text-level target scan: IPv4 literals, UNC hosts, URL hosts.
    foreach ($t in (Get-NetGateTextTargets $Command)) { [void]$targets.Add($t) }
    foreach ($t in @($targets | Select-Object -Unique)) {
        if (-not (Test-TargetInScope -Target $t -Scope $Scope)) {
            if ($null -eq $Scope) {
                return (New-NetGateResult $false "Target '$t' cannot be checked: no scope file. Create .byob\scope.json in the workspace, e.g. {""allow"":[""10.20.30.0/24"",""esx01""],""deny"":[]}." $targets)
            }
            return (New-NetGateResult $false "Target '$t' is outside the allowed scope (.byob\scope.json). Only query in-scope hosts; ask the user to extend the scope if needed." $targets)
        }
    }
    return (New-NetGateResult $true 'Read-only command allowed.' $targets)
}

function Test-NetGateCommandAst {
    # Returns $null when this CommandAst is allowed, else a reason. Adds targets.
    param($Node, $Policy, $Scope, [System.Collections.ArrayList]$Targets, [string]$Mode = 'local')
    $P = $Policy
    if ([string]$Node.InvocationOperator -eq 'Dot') { return 'Dot-sourcing is not allowed.' }
    $rawName = $Node.GetCommandName()
    if (-not $rawName) { return 'The command name must be a literal (no & $variable, & (expression) or invoking script blocks).' }
    if ($rawName -match '[\\/:]') { return "Running files or paths ('$rawName') is not allowed; only allowlisted commands may run." }
    if ($rawName -match '(?i)\.(ps1|psm1|psd1|bat|cmd|vbs|vbe|js|jse|wsf|wsh|msc|hta|com|scr|cpl|lnk)$') { return "Running script files ('$rawName') is not allowed." }

    $isExe = $false
    $name = $rawName
    if ($name -match '(?i)\.exe$') { $isExe = $true; $name = $name.Substring(0, $name.Length - 4) }
    if ($name.Contains('.')) { return "Command '$rawName' is not on the read-only allowlist." }
    $lname = $name.ToLowerInvariant()
    if (-not $isExe -and $P.Aliases.ContainsKey($lname)) { $name = $P.Aliases[$lname]; $lname = $name.ToLowerInvariant() }

    $elements = @($Node.CommandElements)
    $argEls = @()
    if ($elements.Count -gt 1) { $argEls = @($elements[1..($elements.Count - 1)]) }

    # ---------------- native commands ----------------
    if ($isExe -or $name -notmatch '^[A-Za-z]+-[A-Za-z0-9]+$') {
        if ($lname -notin $P.NativeAllowed) {
            return "Native command '$rawName' is not on the read-only allowlist. Allowed: $($P.NativeAllowed -join ', '), plus Get-/Test-/Resolve- cmdlets."
        }
        $A = @()
        foreach ($el in $argEls) {
            $etn = $el.GetType().Name
            if ($el.Extent.Text -match '--%') { return 'The stop-parsing token --% is not allowed.' }
            if ($etn -eq 'CommandParameterAst') {
                if ($el.Argument) {
                    $av = Get-NetGateConstantValues $el.Argument
                    if ($null -eq $av) { return "Arguments to $name must be literal text (no variables or expressions)." }
                }
                $A += [string]$el.Extent.Text
                continue
            }
            $vals = Get-NetGateConstantValues $el
            if ($null -eq $vals -or $etn -in @('ParenExpressionAst', 'ArrayExpressionAst')) { return "Arguments to $name must be literal text (no variables or expressions)." }
            if ($etn -eq 'ConstantExpressionAst' -or $etn -eq 'StringConstantExpressionAst' -or $etn -eq 'ExpandableStringExpressionAst') {
                if ($etn -eq 'ConstantExpressionAst') { $A += [string]$el.Extent.Text } else { $A += [string]$el.Value }
            } else {
                $A += $vals
            }
        }
        return (Test-NetGateNative -Name $lname -A ([string[]]$A) -Targets $Targets)
    }

    # ---------------- cmdlets ----------------
    $canon = $name
    $verb = $name.Split('-')[0]
    $noun = $name.Substring($verb.Length + 1)
    $exactHit = $null
    foreach ($e in $P.ExactAllowed) { if ($e -ieq $name) { $exactHit = $e } }
    foreach ($d in $P.DeniedCmdlets) { if ($d -ieq $name) { return "$name is not allowed in read-only queries." } }
    if ($Mode -eq 'vsphere') { foreach ($d in $P.DeniedCmdletsVsphere) { if ($d -ieq $name) { return "$name is not allowed in vsphere queries." } } }
    if ($noun -match $P.DeniedNounRegex) { return "$name handles credentials or secrets and is not allowed." }
    if ($exactHit) { $canon = $exactHit }
    else {
        $verbOk = $false
        foreach ($v in $P.AllowedVerbs) { if ($v -ieq $verb) { $verbOk = $true; $canon = $v + '-' + $noun } }
        if (-not $verbOk) {
            return "$name is not a read-only command. Allowed verbs: $($P.AllowedVerbs -join ', '); plus ForEach-Object, Where-Object, Select-Object, Sort-Object, Group-Object, Measure-Object, Compare-Object, Format-Table/List/Wide, Out-String, Write-Output."
        }
    }

    # Remote-capable cmdlets must start their pipeline (no pipeline-bound ComputerName).
    $parent = $Node.Parent
    if ($parent -and $parent.GetType().Name -eq 'PipelineAst') {
        $pe = @($parent.PipelineElements)
        if ($pe.Count -gt 1 -and $pe[0].Extent.StartOffset -ne $Node.Extent.StartOffset) {
            foreach ($rc in $P.RemoteCapable) {
                if ($rc -ieq $canon) { return "Do not pipe objects into $canon (it can bind a remote computer from the pipeline). Call it first in the pipeline with literal arguments." }
            }
        }
    }

    $denyEntries = @($P.DeniedParams)
    foreach ($k in $P.CmdletDeniedParams.Keys) { if ($k -ieq $canon) { $denyEntries += $P.CmdletDeniedParams[$k] } }
    $tgtEntries = @($P.TargetParams)
    foreach ($k in $P.CmdletTargetParams.Keys) { if ($k -ieq $canon) { $tgtEntries += $P.CmdletTargetParams[$k] } }
    $isSbEval = $false
    foreach ($s in $P.ScriptBlockEvaluators) { if ($s -ieq $canon) { $isSbEval = $true } }
    $isPosTarget = $false
    foreach ($s in $P.PositionalTargetCmdlets) { if ($s -ieq $canon) { $isPosTarget = $true } }
    $sbParamOk = $false
    foreach ($s in $P.ScriptBlockParamOk) { if ($s -ieq $canon) { $sbParamOk = $true } }

    $positionals = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $argEls.Count; $i++) {
        $el = $argEls[$i]
        if ($el.GetType().Name -ne 'CommandParameterAst') {
            [void]$positionals.Add($el)
            if ($isSbEval -and -not (Test-NetGateIsLiteralArg $el)) { return "$canon arguments must be literal (constants, @{...} or { script block }), not variables or expressions." }
            continue
        }
        $pn = [string]$el.ParameterName
        $lpn = $pn.ToLowerInvariant()
        $value = $el.Argument
        $valueIsNext = $false
        if (-not $value -and ($i + 1) -lt $argEls.Count -and $argEls[$i + 1].GetType().Name -ne 'CommandParameterAst') { $value = $argEls[$i + 1]; $valueIsNext = $true }

        $hit = Test-NetGateParamMatch -Given $lpn -Entries $denyEntries
        if ($hit) { return "Parameter -$pn ($hit) is not allowed in read-only queries." }
        if ((Test-NetGateParamMatch -Given $lpn -Entries @('scriptblock:2')) -and -not $sbParamOk) { return "Parameter -$pn is not allowed on $canon." }
        if ($canon -eq 'Import-Module' -and $lpn -notin $P.ImportModuleParams) { return "Import-Module parameter -$pn is not allowed." }

        $tHit = Test-NetGateParamMatch -Given $lpn -Entries $tgtEntries
        if ($tHit) {
            if ($lpn -eq 'c' -and $canon -ieq 'Test-Connection') { $tHit = 'computername' }
            $vals = Get-NetGateConstantValues $value
            if ($null -eq $vals) { return "-$pn must be a literal host name or address (no variables or expressions). Write parameter names in full." }
            foreach ($v in $vals) { [void]$Targets.Add($v) }
            if ($valueIsNext) { $i++ }
            continue
        }
        if ($canon -eq 'Select-Object' -and (Test-NetGateParamMatch -Given $lpn -Entries @('expandproperty:2'))) {
            $vals = Get-NetGateConstantValues $value
            if ($null -eq $vals) { return 'Select-Object -ExpandProperty must be a literal property name.' }
            foreach ($v in $vals) { if ($v -match '[*?\[]') { return 'Select-Object -ExpandProperty does not accept wildcards here; give the exact property name.' } }
        }
        if ($canon -eq 'ForEach-Object' -and (Test-NetGateParamMatch -Given $lpn -Entries @('membername:1'))) {
            $vals = Get-NetGateConstantValues $value
            if ($null -eq $vals -or -not ($P.InstanceMethods -contains $vals[0]) -or $vals[0] -in @('ForEach', 'Where')) { return 'ForEach-Object -MemberName is not allowed; use ForEach-Object { $_.Property } or Select-Object -ExpandProperty.' }
        }
        if ($isSbEval) {
            if ($valueIsNext -or $el.Argument) {
                $exempt = $false
                foreach ($x in $P.LiteralArgExemptParams) { if ($x.StartsWith($lpn) -and $lpn.Length -ge 2) { $exempt = $true } }
                if (-not $exempt -and -not (Test-NetGateIsLiteralArg $value)) { return "$canon -$pn must be literal (constants, @{...} or { script block }), not a variable or expression." }
            }
            if ($valueIsNext) { $i++ }
            continue
        }
        if ($isPosTarget -and $valueIsNext) {
            foreach ($x in $P.PositionalValueParams) { if ($x.StartsWith($lpn)) { $i++; break } }
        }
    }

    if ($canon -eq 'Import-Module') {
        $nameVals = @()
        foreach ($el in $positionals) {
            $v = Get-NetGateConstantValues $el
            if ($null -eq $v) { return 'Import-Module needs a literal module name.' }
            $nameVals += $v
        }
        for ($i = 0; $i -lt $argEls.Count; $i++) {
            $el = $argEls[$i]
            if ($el.GetType().Name -eq 'CommandParameterAst' -and 'name'.StartsWith(([string]$el.ParameterName).ToLowerInvariant())) {
                $vv = $el.Argument
                if (-not $vv -and ($i + 1) -lt $argEls.Count) { $vv = $argEls[$i + 1] }
                $v = Get-NetGateConstantValues $vv
                if ($null -eq $v) { return 'Import-Module needs a literal module name.' }
                $nameVals += $v
            }
        }
        foreach ($mv in $nameVals) {
            if ($mv -match '[\\/:]' -or $mv -match '(?i)\.(ps1|psm1|psd1|dll|cdxml|xaml|exe)$' -or $mv -match '(?i)\.ps') { return "Import-Module '$mv' must be a module name, not a path or file." }
        }
    }

    if ($canon -eq 'ForEach-Object') {
        foreach ($el in $positionals) {
            if ($el.GetType().Name -eq 'ScriptBlockExpressionAst') { continue }
            $v = Get-NetGateConstantValues $el
            if ($null -eq $v -or -not ($P.InstanceMethods -contains $v[0]) -or $v[0] -in @('ForEach', 'Where')) {
                return 'ForEach-Object with a member name can call methods and is not allowed; use ForEach-Object { $_.Property } or Select-Object -ExpandProperty.'
            }
        }
    }

    if ($isPosTarget) {
        foreach ($el in $positionals) {
            $v = Get-NetGateConstantValues $el
            if ($null -eq $v) { return "$canon target must be a literal host name or address (no variables or expressions)." }
            foreach ($x in $v) {
                if ($x -match '^\d+$' -and [int64]$x -le 65535) { continue }
                [void]$Targets.Add($x)
            }
        }
    }
    return $null
}

# =============================================================================
#  LINUX GATE (commands sent over ssh)
# =============================================================================
function Split-NetGateLinuxCommand {
    # Conservative tokenizer. Returns @{ Error = <reason or $null>; Segments = list of word lists }.
    # Each word is @{ Text = <dequoted>; Glob = <bool: unquoted * ? [ present> }.
    param([string]$Text)
    $segments = New-Object System.Collections.ArrayList
    $words = New-Object System.Collections.ArrayList
    $sb = New-Object System.Text.StringBuilder
    $started = $false
    $glob = $false
    $state = 'none'
    $i = 0
    $len = $Text.Length
    $fail = { param($m) return @{ Error = $m; Segments = $null } }
    while ($i -lt $len) {
        $c = $Text[$i]
        if ($state -eq 'single') {
            if ($c -eq [char]39) { $state = 'none' } else { [void]$sb.Append($c) }
            $i++; continue
        }
        if ($state -eq 'double') {
            if ($c -eq [char]34) { $state = 'none' }
            elseif ($c -eq '$' -or $c -eq '`' -or $c -eq '\') { return (& $fail "Character '$c' inside double quotes is not allowed; use single quotes.") }
            else { [void]$sb.Append($c) }
            $i++; continue
        }
        if ($c -eq ' ' -or $c -eq "`t") {
            if ($started) { [void]$words.Add(@{ Text = $sb.ToString(); Glob = $glob }); [void]$sb.Clear(); $started = $false; $glob = $false }
            $i++; continue
        }
        if ($c -eq [char]39) { $state = 'single'; $started = $true; $i++; continue }
        if ($c -eq [char]34) { $state = 'double'; $started = $true; $i++; continue }
        if ($c -eq '>') {
            $cur = $sb.ToString()
            $rest = $Text.Substring($i)
            $okTok = $null
            if ($cur -eq '2' -and $started -and -not $glob) {
                foreach ($tok in @('>/dev/null', '>&1')) {
                    if ($rest.StartsWith($tok)) {
                        $after = $i + $tok.Length
                        if ($after -ge $len -or (' ;|&').IndexOf($Text[$after]) -ge 0) { $okTok = $tok }
                    }
                }
            }
            if (-not $okTok) { return (& $fail 'Output redirection is not allowed (only 2>/dev/null and 2>&1).') }
            [void]$sb.Clear(); $started = $false; $glob = $false
            $i += $okTok.Length; continue
        }
        if ($c -eq '&') {
            if ($i + 1 -lt $len -and $Text[$i + 1] -eq '&') {
                if ($started) { [void]$words.Add(@{ Text = $sb.ToString(); Glob = $glob }); [void]$sb.Clear(); $started = $false; $glob = $false }
                if ($words.Count -eq 0) { return (& $fail 'Empty command segment.') }
                [void]$segments.Add($words.ToArray()); $words = New-Object System.Collections.ArrayList
                $i += 2; continue
            }
            return (& $fail "Background '&' is not allowed.")
        }
        if ($c -eq '|' -or $c -eq ';') {
            if ($started) { [void]$words.Add(@{ Text = $sb.ToString(); Glob = $glob }); [void]$sb.Clear(); $started = $false; $glob = $false }
            if ($words.Count -eq 0) { return (& $fail 'Empty command segment.') }
            [void]$segments.Add($words.ToArray()); $words = New-Object System.Collections.ArrayList
            if ($c -eq '|' -and $i + 1 -lt $len -and $Text[$i + 1] -eq '|') { $i++ }
            $i++; continue
        }
        if ($c -eq '\') { return (& $fail 'Backslash outside single quotes is not allowed.') }
        if ($c -eq '$') { return (& $fail "'$' (variables, `$(...), `${...}) is not allowed outside single quotes.") }
        if ($c -eq '`') { return (& $fail 'Backticks are not allowed.') }
        if ('(){}!<'.IndexOf($c) -ge 0) { return (& $fail "Shell character '$c' is not allowed (no subshells, brace expansion, history or input redirection).") }
        if ($c -eq '#' -and -not $started) { return (& $fail 'Shell comments are not allowed.') }
        if ($c -eq '*' -or $c -eq '?' -or $c -eq '[') { $glob = $true }
        [void]$sb.Append($c); $started = $true
        $i++
    }
    if ($state -ne 'none') { return (& $fail 'Unterminated quote.') }
    if ($started) { [void]$words.Add(@{ Text = $sb.ToString(); Glob = $glob }) }
    if ($words.Count -eq 0) { return (& $fail 'Empty command segment.') }
    [void]$segments.Add($words.ToArray())
    return @{ Error = $null; Segments = $segments }
}

function Test-NetGateLinuxSecretArg {
    # True when a (dequoted) argument names, or as a glob could match, a secret file.
    param([string]$Arg, [bool]$Glob)
    $a = $Arg
    $secretRegex = @('(^|/)g?shadow-?$', 'sudoers', 'id_(rsa|dsa|ecdsa|ed25519)', '\.ssh/', '(^|/)\.ssh$', '/root/\.ssh',
        'ssh_host_.*_key$', '/private(/|$)', '\.key$', '\.kdbx$', '(^|/)environ$', '_history$', 'opasswd',
        '\.pgpass', '\.netrc', '\.git-credentials', '\.docker/config\.json', '\.aws/credentials', '\.keytab$',
        '(^|/)kcore$')
    foreach ($r in $secretRegex) { if ($a -match $r) { return $true } }
    if ($Glob) {
        $samples = @('/etc/shadow', '/etc/gshadow', '/etc/shadow-', '/etc/sudoers', '/root/.ssh/id_rsa', '/home/user/.ssh/id_rsa',
            '.ssh/id_rsa', 'id_rsa', '/etc/ssh/ssh_host_rsa_key', '/etc/ssl/private/server.key', '/etc/pki/tls/private/server.key',
            '/etc/kubernetes/pki/ca.key', '/proc/1/environ', '/root/.bash_history', '.bash_history', 'x.kdbx', '/etc/krb5.keytab',
            'shadow', '/etc/security/opasswd')
        foreach ($s in $samples) { if ($s -like $a) { return $true } }
    }
    return $false
}

function Test-NetGateShortFlag {
    # True when $Word is a short-option cluster (e.g. -fn) containing any of $Chars (case-sensitive).
    param([string]$Word, [string]$Chars)
    if ($Word -notmatch '^-[A-Za-z0-9]+$') { return $false }
    foreach ($ch in $Chars.ToCharArray()) { if ($Word.Substring(1).IndexOf($ch) -ge 0) { return $true } }
    return $false
}

function Test-NetGateLinuxSegment {
    # One pipeline segment. Returns $null when allowed, else a reason. Adds targets.
    param([object[]]$Words, [System.Collections.ArrayList]$Targets)
    $cmd = [string]$Words[0].Text
    $A = @()
    $G = @()
    for ($i = 1; $i -lt $Words.Count; $i++) { $A += [string]$Words[$i].Text; $G += [bool]$Words[$i].Glob }
    $n = $A.Count
    if ($cmd -match '^[A-Za-z_][A-Za-z0-9_]*=') { return 'Environment-variable assignments before a command are not allowed.' }
    if ($cmd.Contains('/')) { return "Commands must be given by name, not path ('$cmd')." }
    if ($Words[0].Glob) { return 'Wildcards in the command name are not allowed.' }
    if ($cmd -in @('sudo', 'su', 'doas', 'pkexec')) { return "$cmd is not allowed: queries run with the credential's own rights only." }
    $flags = @($A | Where-Object { $_.StartsWith('-') })
    $pos = @($A | Where-Object { -not $_.StartsWith('-') })

    $readers = @('cat', 'head', 'tail', 'grep', 'egrep', 'fgrep', 'sort', 'uniq', 'cut', 'column', 'getent', 'openssl', 'wc', 'file')
    if ($cmd -in $readers) {
        for ($i = 0; $i -lt $n; $i++) {
            if (Test-NetGateLinuxSecretArg -Arg $A[$i] -Glob $G[$i]) { return "Reading '$($A[$i])' is not allowed (secret material: shadow, private keys, sudoers, history, credentials)." }
        }
    }

    switch -CaseSensitive ($cmd) {
        { $_ -in @('cat', 'ls', 'stat', 'cut', 'tr', 'column', 'echo', 'printf', 'true', 'test', '[', 'uptime', 'uname',
                'id', 'whoami', 'who', 'w', 'last', 'free', 'df', 'du', 'lsblk', 'lscpu', 'lsmem', 'lspci', 'lsusb',
                'lsmod', 'dmidecode', 'findmnt', 'ps', 'pgrep', 'netstat', 'getenforce', 'sestatus', 'nproc', 'vmstat',
                'iostat', 'mpstat', 'lsof', 'wc') } { return $null }
        'file' { if ($A -contains '-C' -or $A -contains '--compile') { return 'file -C writes files.' }; return $null }
        { $_ -in @('grep', 'egrep', 'fgrep') } {
            foreach ($x in $A) {
                if ((Test-NetGateShortFlag $x 'rR') -or $x -in @('--recursive', '--dereference-recursive') -or $x -match '^--directories=recurse' -or $x -match '^-d$') {
                    return 'Recursive grep is not allowed (it can read secret files). Grep specific files instead.'
                }
            }
            return $null
        }
        { $_ -in @('head', 'tail') } {
            foreach ($x in $A) { if ((Test-NetGateShortFlag $x 'fF') -or $x -like '--follow*' -or $x -eq '--retry') { return "$cmd -f never ends; use -n <lines>." } }
            return $null
        }
        'sort' {
            foreach ($x in $A) { if ((Test-NetGateShortFlag $x 'o') -or $x -like '--output*' -or $x -like '--compress-program*') { return 'sort -o / --compress-program are not allowed.' } }
            return $null
        }
        'uniq' { if ($pos.Count -gt 1) { return 'uniq with an output file is not allowed.' }; return $null }
        'date' { foreach ($x in $A) { if ((Test-NetGateShortFlag $x 's') -or $x -like '--set*') { return 'date -s sets the clock and is not allowed.' } }; return $null }
        'lastlog' { foreach ($x in $A) { if ((Test-NetGateShortFlag $x 'CS') -or $x -in @('--clear', '--set')) { return 'lastlog -C/-S modify records.' } }; return $null }
        'blkid' { foreach ($x in $A) { if (Test-NetGateShortFlag $x 'g') { return 'blkid -g modifies the cache.' } }; return $null }
        'ss' { foreach ($x in $A) { if ((Test-NetGateShortFlag $x 'K') -or $x -eq '--kill') { return 'ss -K kills sockets and is not allowed.' } }; return $null }
        'sar' { foreach ($x in $A) { if (Test-NetGateShortFlag $x 'o') { return 'sar -o writes a file.' } }; return $null }
        'getent' { if ($pos.Count -ge 1 -and $pos[0] -in @('shadow', 'gshadow')) { return 'getent shadow/gshadow is not allowed.' }; return $null }
        { $_ -in @('nslookup') } {
            if ($pos.Count -lt 1) { return 'nslookup needs a name (interactive mode is not allowed).' }
            if ($pos.Count -ge 2) { [void]$Targets.Add($pos[1]) }
            return $null
        }
        'host' { if ($pos.Count -lt 1) { return 'host needs a name.' }; if ($pos.Count -ge 2) { [void]$Targets.Add($pos[1]) }; return $null }
        'dig' { foreach ($x in $A) { if ($x.StartsWith('@')) { [void]$Targets.Add($x.Substring(1)) } }; return $null }
        'hostname' {
            $ok = @('-s', '-f', '-d', '-i', '-I', '-A', '-a', '-y', '-v', '--short', '--fqdn', '--long', '--domain', '--ip-address', '--all-ip-addresses', '--all-fqdns', '--alias', '--yp', '--nis')
            foreach ($x in $A) { if (-not ($ok -ccontains $x)) { return 'hostname only accepts display flags (a name argument would change it).' } }
            return $null
        }
        'hostnamectl' { if ($n -eq 0 -or ($n -eq 1 -and $A[0] -eq 'status')) { return $null }; return 'hostnamectl is only allowed with no arguments or "status".' }
        'mount' {
            if ($n -eq 0) { return $null }
            for ($i = 0; $i -lt $n; $i++) {
                if ($A[$i] -eq '-l') { continue }
                if ($A[$i] -eq '-t' -and $i + 1 -lt $n) { $i++; continue }
                return 'mount is only allowed with no arguments, -l or -t <types> (listing).'
            }
            return $null
        }
        'top' { if (($A -ccontains '-b') -and ($A -ccontains '-n')) { return $null }; foreach ($x in $A) { if ($x -match '^-b.*n|^-n.*b') { return $null } }; return 'top must be run as "top -b -n 1".' }
        'ip' {
            $bad = @('add', 'del', 'delete', 'set', 'flush', 'change', 'replace', 'append', 'exec', 'save', 'restore', 'monitor', 'prepend', 'update', 'attach', 'detach')
            foreach ($x in $A) {
                if ($x.ToLowerInvariant() -in $bad) { return "ip '$x' modifies state and is not allowed (show-style commands only)." }
                if ($x -in @('-b', '-batch', '-force', '--batch', '--force') -or $x -like '-batch*') { return 'ip -batch/-force is not allowed.' }
            }
            return $null
        }
        'route' { if ($n -eq 0 -or ($n -eq 1 -and $A[0] -in @('-n', '-e', '-ne', '-en'))) { return $null }; return 'route is only allowed with no arguments or -n.' }
        'arp' { foreach ($x in $A) { if ($x -notin @('-n', '-a', '-an', '-na', '-e')) { return 'arp is only allowed with -n / -a.' } }; return $null }
        'ping' {
            $count = $null
            $vf = @('-c', '-i', '-w', '-W', '-s', '-t', '-I', '-l', '-p', '-Q', '-M', '-m')
            for ($i = 0; $i -lt $n; $i++) {
                $x = $A[$i]
                if ($x -ceq '-f' -or (Test-NetGateShortFlag $x 'fb') -or $x -ceq '-i') { return 'ping -f/-b/-i are not allowed.' }
                if ($x -cmatch '^-c(\d+)$') { $count = [int]$Matches[1]; continue }
                if ($x -cin $vf) {
                    if ($i + 1 -ge $n) { return "ping $x needs a value." }
                    if ($x -ceq '-c') { if ($A[$i + 1] -match '^\d+$') { $count = [int]$A[$i + 1] } else { return 'ping -c needs a number.' } }
                    $i++; continue
                }
                if ($x.StartsWith('-')) { continue }
                [void]$Targets.Add($x)
            }
            if ($null -eq $count -or $count -lt 1 -or $count -gt 5) { return 'ping needs -c <n> with n between 1 and 5.' }
            return $null
        }
        { $_ -in @('traceroute', 'tracepath') } {
            $vf = @('-m', '-q', '-w', '-p', '-i', '-s', '-f', '-z', '-N', '-l', '-t', '-g', '-M', '-P', '-b')
            for ($i = 0; $i -lt $n; $i++) {
                if ($A[$i] -cin $vf) { $i++; continue }
                if ($A[$i].StartsWith('-')) { continue }
                if ($A[$i] -match '^\d+$') { continue }
                [void]$Targets.Add($A[$i])
            }
            return $null
        }
        'resolvectl' {
            $p2 = @($pos)
            if ($p2.Count -lt 1) { return $null }
            $sub = $p2[0]
            if ($sub -notin @('status', 'query', 'statistics', 'dns', 'domain')) { return 'resolvectl is only allowed with status, query, statistics, dns or domain.' }
            if ($sub -in @('dns', 'domain') -and $p2.Count -gt 2) { return "resolvectl $sub with values would change settings." }
            if ($sub -eq 'statistics' -and $p2.Count -gt 1) { return 'resolvectl statistics takes no arguments.' }
            return $null
        }
        'timedatectl' { if ($pos.Count -eq 0 -or ($pos.Count -eq 1 -and $pos[0] -in @('status', 'show', 'timesync-status', 'show-timesync'))) { return $null }; return 'timedatectl is only allowed with status, show, timesync-status or show-timesync.' }
        'chronyc' {
            $okSub = @('sources', 'sourcestats', 'tracking', 'activity', 'ntpdata', 'serverstats', 'clients', 'selectdata')
            for ($i = 0; $i -lt $n; $i++) {
                $x = $A[$i]
                if ($x -in @('-n', '-c', '-a', '-4', '-6', '-m')) { continue }
                if ($x -eq '-h') { if ($i + 1 -lt $n) { [void]$Targets.Add($A[$i + 1]); $i++; continue } }
                if ($x.StartsWith('-')) { return "chronyc option '$x' is not allowed." }
                if ($x -in $okSub) { return $null }
                return "chronyc '$x' is not allowed. Allowed: $($okSub -join ', ')."
            }
            return 'chronyc needs a read-only subcommand (sources, tracking, ...).'
        }
        'ntpq' {
            $hasP = $false
            foreach ($x in $A) {
                if ($x -in @('-p', '-pn', '-np')) { $hasP = $true; continue }
                if ($x -eq '-n') { continue }
                if ($x.StartsWith('-')) { return 'ntpq is only allowed with -p / -pn.' }
                [void]$Targets.Add($x)
            }
            if (-not $hasP) { return 'ntpq is only allowed with -p / -pn.' }
            return $null
        }
        'systemctl' {
            foreach ($x in $A) { if ($x -in @('-H', '-M') -or $x -like '--host*' -or $x -like '--machine*') { return 'systemctl remote/machine options are not allowed.' } }
            if ($pos.Count -lt 1) { return 'systemctl needs a read-only verb (status, show, list-units, ...).' }
            $okv = @('status', 'show', 'list-units', 'list-unit-files', 'list-sockets', 'list-timers', 'list-dependencies', 'is-active', 'is-enabled', 'is-failed', 'cat', 'get-default', 'list-jobs', 'list-machines')
            if ($pos[0] -notin $okv) { return "systemctl $($pos[0]) is not read-only. Allowed: $($okv -join ', ')." }
            return $null
        }
        'journalctl' {
            foreach ($x in $A) {
                if ((Test-NetGateShortFlag $x 'f') -or $x -like '--follow*' -or $x -like '--vacuum*' -or $x -in @('--rotate', '--flush', '--sync', '--relinquish-var', '--smart-relinquish-var', '--setup-keys', '--update-catalog')) {
                    return "journalctl '$x' is not allowed (no follow or maintenance options). Use -n <lines> or --since."
                }
            }
            return $null
        }
        'dmesg' {
            foreach ($x in $A) {
                if ((Test-NetGateShortFlag $x 'cCwWnDE') -or $x -in @('--clear', '--read-clear', '--follow', '--follow-new', '--console-off', '--console-on') -or $x -like '--console-level*') {
                    return "dmesg '$x' is not allowed (it clears, follows or changes console settings)."
                }
            }
            return $null
        }
        'rpm' {
            if ($n -lt 1 -or -not ($A[0] -cmatch '^-q[a-zA-Z]*$' -or $A[0] -eq '--query')) { return 'rpm is only allowed as a query (rpm -q...).' }
            $okLong = @('--query', '--queryformat', '--qf', '--all', '--info', '--list', '--file', '--requires', '--provides',
                '--whatprovides', '--whatrequires', '--changelog', '--last', '--scripts', '--dump', '--nosignature',
                '--nodigest', '--configfiles', '--docfiles', '--state', '--package')
            foreach ($x in $A) {
                if ($x -match '%\{lua|%\(') { return 'rpm macro expressions are not allowed.' }
                if ($x.StartsWith('--')) {
                    $ln = $x.Split('=')[0]
                    if ($ln -notin $okLong) { return "rpm option '$x' is not allowed." }
                    continue
                }
                if ($x.StartsWith('-') -and $x -cnotmatch '^-q?[qailfdcsRp]+$') { return "rpm option '$x' is not allowed (query options only)." }
            }
            return $null
        }
        'dpkg' {
            $okf = @('-l', '-s', '-L', '--list', '--status', '--listfiles')
            if ($n -lt 1 -or -not ($okf -ccontains $A[0])) { return 'dpkg is only allowed with -l, -s or -L.' }
            foreach ($x in $A) { if ($x.StartsWith('-') -and -not ($okf -ccontains $x)) { return "dpkg option '$x' is not allowed." } }
            return $null
        }
        { $_ -in @('dnf', 'yum') } {
            foreach ($x in $A) { if ($x -in @('-y', '--assumeyes') -or $x -like '--setopt*' -or $x -like '--downloaddir*' -or $x -like '--installroot*') { return "$cmd option '$x' is not allowed." } }
            if ($pos.Count -lt 1 -or $pos[0] -notin @('list', 'info', 'repolist', 'history')) { return "$cmd is only allowed with list, info, repolist or history." }
            if ($pos[0] -eq 'history' -and $pos.Count -gt 1 -and $pos[1] -notin @('list', 'info')) { return "$cmd history is only allowed bare or with list/info." }
            return $null
        }
        { $_ -in @('apt', 'apt-cache') } {
            if ($pos.Count -lt 1 -or $pos[0] -notin @('list', 'show', 'policy')) { return "$cmd is only allowed with list, show or policy." }
            foreach ($x in $A) { if ($x -match '^-(o|c)$' -or $x -like '--option*' -or $x -like '--config-file*') { return "$cmd option '$x' is not allowed." } }
            return $null
        }
        'find' {
            foreach ($x in $A) {
                if ($x -in @('-delete', '-exec', '-execdir', '-ok', '-okdir', '-fls') -or $x -like '-fprint*') { return "find $x is not allowed (it deletes, executes or writes)." }
            }
            return $null
        }
        'kubectl' { return (Test-NetGateNativeKubectl -A ([string[]]$A)) }
        'crictl' {
            foreach ($x in $A) { if ($x -in @('-f', '--follow', '-r', '--runtime-endpoint', '-i', '--image-endpoint') -or $x -like '--follow=*') { return "crictl option '$x' is not allowed." } }
            $okv = @('ps', 'pods', 'images', 'img', 'info', 'version', 'stats', 'statsp', 'inspect', 'inspecti', 'inspectp', 'logs', 'imagefsinfo')
            if ($pos.Count -lt 1 -or $pos[0] -notin $okv) { return "crictl is only allowed with: $($okv -join ', ')." }
            return $null
        }
        { $_ -in @('podman', 'docker') } {
            foreach ($x in $A) { if ($x -in @('-H', '--host', '-c', '--context', '--url', '--connection', '-f', '--follow') -or $x -like '--host=*' -or $x -like '--url=*' -or $x -like '--follow=*') { return "$cmd option '$x' is not allowed." } }
            if ($pos.Count -lt 1) { return "$cmd needs a read-only subcommand." }
            $sub = $pos[0]
            if ($sub -in @('ps', 'images', 'info', 'version', 'inspect', 'logs', 'top')) { return $null }
            if ($sub -eq 'stats') { if ($A -contains '--no-stream') { return $null }; return "$cmd stats requires --no-stream." }
            if ($sub -in @('network', 'volume')) { if ($pos.Count -ge 2 -and $pos[1] -in @('ls', 'inspect')) { return $null }; return "$cmd $sub is only allowed with ls or inspect." }
            return "$cmd $sub is not read-only. Allowed: ps, images, info, version, inspect, logs, stats --no-stream, top, network ls|inspect, volume ls|inspect."
        }
        'firewall-cmd' {
            if ($n -lt 1) { return 'firewall-cmd needs a --list/--get/--query/--state option.' }
            foreach ($x in $A) {
                $ok = $false
                foreach ($pfx in @('--list', '--get', '--query', '--state', '--zone=', '--permanent', '--info')) { if ($x.StartsWith($pfx)) { $ok = $true } }
                if (-not $ok) { return "firewall-cmd '$x' is not allowed (only --list*, --get*, --query*, --state, --info*, --zone=, --permanent)." }
            }
            return $null
        }
        { $_ -in @('iptables', 'ip6tables') } {
            $hasList = $false
            for ($i = 0; $i -lt $n; $i++) {
                $x = $A[$i]
                if ($x -eq '-t') { if ($i + 1 -lt $n) { $i++; continue }; return "$cmd -t needs a table." }
                if ($x -eq '--line-numbers') { continue }
                if ($x -cmatch '^-[LSnvx]+$') { if ($x -cmatch '[LS]') { $hasList = $true }; continue }
                if ($x -match '^[A-Za-z0-9_-]+$' -and -not $x.StartsWith('-')) { continue }
                return "$cmd option '$x' is not allowed (only -L, -S, -n, -v, -x, -t <table>, --line-numbers)."
            }
            if (-not $hasList) { return "$cmd is only allowed with -L or -S." }
            return $null
        }
        'nft' {
            foreach ($x in $A) { if ($x -in @('-f', '--file', '-i', '--interactive')) { return "nft $x is not allowed." } }
            if ($pos.Count -lt 1 -or $pos[0] -ne 'list') { return 'nft is only allowed with "list ...".' }
            return $null
        }
        'openssl' {
            if ($n -lt 1) { return 'openssl needs version or x509.' }
            if ($A[0] -eq 'version') { return $null }
            if ($A[0] -ne 'x509') { return 'openssl is only allowed as "openssl version" or "openssl x509 -noout ...".' }
            if ($A -notcontains '-noout') { return 'openssl x509 must include -noout.' }
            foreach ($x in $A) { if ($x -in @('-out', '-signkey', '-req', '-key') -or $x -like '-CA*' -or $x -like '-set_*') { return "openssl x509 '$x' is not allowed." } }
            return $null
        }
        'sysctl' {
            foreach ($x in $A) { if ((Test-NetGateShortFlag $x 'wpf') -or $x -in @('--write', '--load', '--system') -or $x.Contains('=')) { return 'sysctl writes are not allowed (no -w, -p, --system or name=value).' } }
            return $null
        }
        'ulimit' { if ($n -eq 1 -and $A[0] -eq '-a') { return $null }; return 'ulimit is only allowed as "ulimit -a".' }
        default {
            return "Linux command '$cmd' is not on the read-only allowlist."
        }
    }
}

function Test-LinuxReadOnlyCommand {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command)
    $targets = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Command)) { return (New-NetGateResult $false 'Command is empty.' $null) }
    if ($Command.Length -gt 2000) { return (New-NetGateResult $false 'Command is longer than 2000 characters.' $null) }
    if ($Command -match "[`r`n]") { return (New-NetGateResult $false 'Newlines are not allowed; use ; or && to chain commands.' $null) }
    if ($Command.IndexOf('<<') -ge 0) { return (New-NetGateResult $false 'Here-documents are not allowed.' $null) }
    foreach ($ch in $Command.ToCharArray()) { if ([int]$ch -lt 32 -and $ch -ne "`t") { return (New-NetGateResult $false 'Control characters are not allowed.' $null) } ; if ([int]$ch -gt 126) { return (New-NetGateResult $false 'Non-ASCII characters are not allowed.' $null) } }
    $split = Split-NetGateLinuxCommand -Text $Command
    if ($split.Error) { return (New-NetGateResult $false $split.Error $null) }
    foreach ($seg in $split.Segments) {
        $why = Test-NetGateLinuxSegment -Words $seg -Targets $targets
        if ($why) { return (New-NetGateResult $false $why $targets) }
    }
    foreach ($t in (Get-NetGateTextTargets $Command)) { [void]$targets.Add($t) }
    return (New-NetGateResult $true 'Read-only command allowed.' $targets)
}
