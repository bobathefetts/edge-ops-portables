# sample-portscan/scan.ps1 - BYOB Explorer sample plugin. Windows PowerShell 5.1 and PowerShell 7. ASCII only.
# Called by the host with one argument (the tool arguments as an object). The host also sets
# $PluginRoot (this folder) and $WorkspaceRoot (the workspace; also the current directory).
param($ToolArgs)
$ErrorActionPreference = 'Stop'

# Load the app's scope checker. Read + [scriptblock]::Create instead of ". file.ps1" so the
# machine's script execution policy does not block it.
$netGate = Join-Path (Join-Path (Join-Path (Join-Path $PluginRoot '..') '..') 'src') 'NetGate.ps1'
. ([scriptblock]::Create([IO.File]::ReadAllText([IO.Path]::GetFullPath($netGate))))

$target = ([string]$ToolArgs.target).Trim()
if ($target -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$') { 'REFUSED: target must be a host name or IPv4 address.'; return }
$ports = @($ToolArgs.ports)
if ($ports.Count -lt 1 -or $ports.Count -gt 30) { 'REFUSED: give 1 to 30 ports.'; return }
$clean = @()
foreach ($p in $ports) {
    $n = 0
    if (-not [int]::TryParse([string]$p, [ref]$n) -or $n -lt 1 -or $n -gt 65535) { "REFUSED: '$p' is not a TCP port number."; return }
    $clean += $n
}

$scope = Read-ScopeConfig -Path (Join-Path (Join-Path $WorkspaceRoot '.byob') 'scope.json')
if (-not (Test-TargetInScope -Target $target -Scope $scope)) {
    "REFUSED: $target is outside the workspace scope (.byob\scope.json). Nothing was scanned."
    return
}

"TCP connect test of $target (1 s timeout per port)"
foreach ($port in $clean) {
    $client = New-Object System.Net.Sockets.TcpClient
    $state = 'no answer (filtered or host down)'
    try {
        $ar = $client.BeginConnect($target, $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(1000)) {
            try { $client.EndConnect($ar); $state = 'open' } catch { $state = 'closed' }
        }
    } catch {
        $state = 'error: ' + $_.Exception.Message
    } finally {
        $client.Close()
    }
    "port {0}: {1}" -f $port, $state
}
