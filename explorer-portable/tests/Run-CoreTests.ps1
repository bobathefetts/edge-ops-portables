# Run-CoreTests.ps1 - Plain assertion tests for NetGate.ps1, CredStore.ps1, ExplorerTools.ps1,
# PluginHost.ps1, ExplorerAgent.ps1 helpers, ByobTools.ps1 and ByobLlm.ps1 conversions.
# No Pester dependency. Runs on Windows PowerShell 5.1 and PowerShell 7 (Linux test runtime).
# Usage: pwsh -NoProfile -File tests/Run-CoreTests.ps1     (exit code 1 on any failure)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'src'
. (Join-Path $src 'NetGate.ps1')
. (Join-Path $src 'CredStore.ps1')
. (Join-Path $src 'ExplorerTools.ps1')
. (Join-Path $src 'ByobLlm.ps1')
. (Join-Path $src 'ByobTools.ps1')
. (Join-Path $src 'PluginHost.ps1')
. (Join-Path $src 'ExplorerAgent.ps1')

$script:Pass = 0
$script:Fail = 0
function Assert-True([bool]$Cond, [string]$Msg) {
    if ($Cond) { $script:Pass++ } else { $script:Fail++; Write-Host "FAIL: $Msg" }
}

$scope = [pscustomobject]@{ allow = @('10.20.30.0/24', 'esx01', '*.sw4.lab'); deny = @('10.20.30.1') }
$protect = @('credentials.json', 'C:\app\data')

# ---------------------------------------------------------------- gate: allow
$allow = @(
    "Get-Service | Where-Object { `$_.Status -eq 'Running' } | Select-Object Name, DisplayName",
    'Get-CimInstance Win32_OperatingSystem | fl *',
    'Test-NetConnection 10.20.30.5 -Port 443',
    'Get-WindowsFeature | ? Installed',
    '$s = Get-Service; $s | group Status',
    'ping -n 2 10.20.30.9',
    'ipconfig /all',
    'route print',
    'Resolve-DnsName dc01.sw4.lab -Server 10.20.30.2',
    "Get-VM | Select Name, PowerState, @{n='IPs';e={`$_.Guest.IPAddress -join ' '}}",
    'Get-NetTCPConnection -State Listen | sort LocalPort | ft -AutoSize',
    'kubectl get pods -A -o wide',
    'Get-ChildItem C:\Windows\System32\drivers\etc | Get-Content -TotalCount 5',
    'Get-ChildItem C:\Windows\System32\drivers\etc\hosts | Select-Object -First 3 | Get-Content -TotalCount 5',
    '(Get-Date).AddDays(-1)',
    'Get-WinEvent -LogName System -MaxEvents 20 | fl TimeCreated, Id, Message',
    'Get-Service -ComputerName esx01',
    'Get-Service -ComputerName dc01.sw4.lab, 10.20.30.7',
    'Test-Connection -ComputerName 10.20.30.8 -Count 2',
    'Get-NetIPAddress | Where-Object AddressFamily -eq IPv4 | Format-Table InterfaceAlias, IPAddress, PrefixLength',
    'Get-NetRoute -DestinationPrefix 0.0.0.0/0',
    'foreach ($svc in Get-Service) { if ($svc.Status -eq "Running") { $svc.Name } }',
    '[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2)',
    "'a,b'.Split(',') -join ' '",
    'nslookup dc01.sw4.lab 10.20.30.2',
    'net view \\esx01',
    'netstat -ano',
    'w32tm /query /status',
    'Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, Id, CPU',
    'Get-HotFix | Sort-Object InstalledOn',
    'Import-Module VMware.VimAutomation.Core; Get-VMHost | Select-Object Name, ConnectionState',
    'Get-Service 2>&1 | Out-String',
    '$null = Get-Date; [int]$x = 5; $x++; $x'
)
foreach ($c in $allow) {
    $r = Test-ReadOnlyCommand -Command $c -Scope $scope -ProtectedPathFragments $protect
    Assert-True $r.Allowed "gate should ALLOW: $c  -> $($r.Reason)"
}

# ---------------------------------------------------------------- gate: deny
$deny = @(
    'Restart-Service spooler', 'Stop-Computer', 'Get-Service | Stop-Service', 'Get-Service | % { $_.Stop() }',
    'Get-Process | % { $_.Kill() }', 'sc stop spooler', 'sc.exe stop spooler', 'del C:\x', "iex 'Get-Date'",
    "& 'Remove-Item' x", '$c=''Remove-Item''; & $c x', 'Get-Date > C:\out.txt', 'Get-Date >> C:\out.txt',
    'Get-Date 2> C:\err.txt', 'Get-Date | Out-File x', 'Get-Date | Tee-Object x', "[IO.File]::Delete('x')",
    "[scriptblock]::Create('rm x').Invoke()", 'Invoke-Command -ComputerName 10.20.30.5 { Get-Date }',
    'Test-Connection 8.8.8.8', 'Test-NetConnection $h', 'Get-Service -ComputerName outside01',
    '$t=''8.8.8.8''; ping $t', 'Get-Content \\outside01\c$\x', 'Test-ComputerSecureChannel -Repair',
    'Test-ComputerSecureChannel -R', 'Get-Credential', "ConvertTo-SecureString 'x' -AsPlainText -Force",
    'Get-Content C:\app\data\credentials.json', 'cmd /c del x', 'powershell -c "rm x"',
    'net user bob P@ss /add', 'net user bob P@ss', 'netsh advfirewall set allprofiles state off', 'w32tm /resync',
    'Start-Process notepad', 'function f { } ', 'while ($true) { }', 'for ($i=0;$i -lt 3;$i++) { }',
    '$env:PATH = ''x''', '$env:APPDATA', "`$ExecutionContext.InvokeCommand.InvokeScript('rm x')",
    'Get-Service -Name (Remove-Item x)', '"$(Remove-Item x)"', 'Get-ChildItem | ForEach-Object -Parallel { }',
    'Format-Volume -DriveLetter D', 'Get-VM | Stop-VM', 'Get-View -ViewType VirtualMachine',
    'kubectl delete pod x', 'kubectl get pods -w', 'kubectl exec -it x -- sh', '.\script.ps1', 'C:\tools\thing.exe',
    'Get-Service | Select-Object (', '', '   ',
    'Get-Process | % Kill', 'Get-Process | ForEach-Object -MemberName Kill', '$p = Get-Process; $p.ForEach(''Kill'')',
    "(Get-Item C:\a.txt).Replace('C:\b.txt', `$null)", "(Get-WmiObject Win32_Volume).Format('NTFS')",
    '$p = @{ ComputerName = ''outside01'' }; Get-Service @p', "[pscustomobject]@{ComputerName='outside01'} | Get-Service",
    'Get-Service -C outside01', '${C:\x.txt}', '$global:x = 1', '$s = ''rm x'' -as ''scriptblock''',
    '$x = (Get-Command Get-Date).ScriptBlock', 'Get-Command Clear-Host | Select-Object -ExpandProperty ScriptBlock',
    'Get-Item function:\Clear-Host', 'Get-ChildItem env:', 'Get-Content x -Wait', 'Get-Date -OutVariable x',
    'Measure-Command { Get-Date }', 'Get-ChildItem | Format-Table -Property $p', 'Write-Host hi',
    'Get-Date | ForEach-Object -Process $sb', 'Get-Service | Out-Host', 'Get-Service | Export-Csv x.csv',
    'Import-Module C:\x\evil.psm1', 'Import-Module .\evil.dll', '. .\x.ps1', '& { Remove-Item x }',
    'Get-Date; Remove-Item x', 'Get-Service -ComputerName $h', 'using module Foo',
    'class X { }', 'trap { } Get-Date', 'Get-Service | Get-Service', 'Test-Connection 167772161',
    'ping -t 10.20.30.9', 'ipconfig /release', 'ipconfig /flushdns', 'route add 10.0.0.0 mask 255.0.0.0 10.20.30.1',
    'arp -d *', 'schtasks /run /tn x', 'schtasks /query /s outside01', 'wmic process call create calc',
    'certutil -urlcache -f http://x/y z', 'reg query HKLM\Software', 'nbtstat -R', 'dcdiag /fix', 'repadmin /syncall',
    'klist purge', 'net start spooler', 'net use \\x\y', 'net share x=C:\', 'net localgroup administrators bob /add',
    'netsh interface ip show config dump', 'gpresult /h x.html', 'wevtutil cl System', 'Test-Connection 10.20.30.1',
    'Get-ADUser bob -Properties ms-Mcs-AdmPwd', 'Get-Variable __explorerCred', 'Get-Date -Credential x',
    "Get-Content -Path 'C:\app\data\x.txt'", 'Get-CimInstance Win32_Process | Invoke-CimMethod -MethodName Terminate',
    'Set-Content x y', 'Get-ChildItem -Path //outside01/c$/', '[System.Net.Dns]::GetHostAddresses(''x'')',
    '$a = Get-Service; $a[0] = 1', '$s.Name = ''x''', 'Get-ItemProperty -Path HKLM:\x | % { $_.psobject }',
    'Get-WinEvent -ComputerName outside01 -LogName System', 'Resolve-DnsName x -Server 8.8.8.8',
    'Test-WSMan outside01', 'Get-Service | ft @{n=''ComputerName'';e={''x''}}',
    'Get-Content -Path \\.\pipe\x', 'Get-ChildItem \\?\C:\', 'Get-WindowsUpdate -Install -AcceptAll', 'Get-Thing -Install',
    '$p = @{ Name = ''x'' }; Get-Service @p', 'using namespace System.IO', '$DefaultVIServer | Format-List *',
    'Get-Service | Select-Object -ExpandProperty Scri*', 'Get-Date | Select-Object -Property $sb', 'Get-Service | Sort-Object $sb',
    "Remove$([char]0x2013)Item x", 'Get-Service -ComputerName:outside01', 'gsv -cn outside01', 'Test-Connection -Quiet outside01'
)
$r = Test-ReadOnlyCommand -Command 'Get-Variable' -Scope $scope -Mode vsphere
Assert-True (-not $r.Allowed) 'Get-Variable denied in vsphere mode'
foreach ($gvCmd in @('Get-Variable', 'Get-Variable ExecutionContext -ValueOnly', 'gv', 'gv ExecutionContext -ValueOnly', '(Get-Variable ExecutionContext -ValueOnly).InvokeCommand')) {
    foreach ($gvMode in @('local', 'winrm', 'vsphere')) {
        $r = Test-ReadOnlyCommand -Command $gvCmd -Scope $scope -Mode $gvMode
        Assert-True (-not $r.Allowed) "Get-Variable denied in $gvMode mode: $gvCmd"
    }
}
foreach ($c in $deny) {
    $r = Test-ReadOnlyCommand -Command $c -Scope $scope -ProtectedPathFragments $protect
    Assert-True (-not $r.Allowed) "gate should DENY: $c"
    Assert-True ([bool]$r.Reason) "gate deny should have a reason: $c"
}
$r = Test-ReadOnlyCommand -Command ('Get-Date;' * 600) -Scope $scope
Assert-True (-not $r.Allowed) 'gate should deny > 4000 chars'
$r = Test-ReadOnlyCommand -Command 'Set-Service spooler -StartupType Disabled' -Scope $scope
Assert-True ($r.Reason -match 'Set-Service' -and $r.Reason -match 'Allowed verbs') "deny reason should name the cmdlet and allowed verbs: $($r.Reason)"

# targets reported
$r = Test-ReadOnlyCommand -Command 'Test-NetConnection 10.20.30.5 -Port 443' -Scope $scope
Assert-True ($r.Targets -contains '10.20.30.5') 'targets should include 10.20.30.5'

# null scope
$r = Test-ReadOnlyCommand -Command 'Get-Service' -Scope $null
Assert-True $r.Allowed 'null scope: Get-Service allowed'
$r = Test-ReadOnlyCommand -Command 'Test-Connection 10.20.30.5' -Scope $null
Assert-True (-not $r.Allowed -and $r.Reason -match 'scope') "null scope: Test-Connection denied with scope reason: $($r.Reason)"
$r = Test-ReadOnlyCommand -Command 'Test-Connection localhost' -Scope $null
Assert-True $r.Allowed 'null scope: localhost allowed'

# ---------------------------------------------------------------- scope
Assert-True (Test-TargetInScope -Target '10.20.30.0' -Scope $scope) 'cidr network address in scope'
Assert-True (Test-TargetInScope -Target '10.20.30.255' -Scope $scope) 'cidr broadcast in scope'
Assert-True (-not (Test-TargetInScope -Target '10.20.31.0' -Scope $scope)) 'next /24 out of scope'
Assert-True (-not (Test-TargetInScope -Target '10.20.29.255' -Scope $scope)) 'previous /24 out of scope'
Assert-True (-not (Test-TargetInScope -Target '10.20.30.1' -Scope $scope)) 'deny overrides allow'
Assert-True (Test-TargetInScope -Target 'dc01.sw4.lab' -Scope $scope) 'wildcard host'
Assert-True (Test-TargetInScope -Target 'DC01.SW4.LAB' -Scope $scope) 'wildcard host case-insensitive'
Assert-True (-not (Test-TargetInScope -Target 'sw4.lab' -Scope $scope)) 'wildcard needs a label'
Assert-True (Test-TargetInScope -Target 'esx01' -Scope $scope) 'exact host'
Assert-True (-not (Test-TargetInScope -Target 'esx01.other.lab' -Scope $scope)) 'short name does not match other fqdn'
Assert-True (-not (Test-TargetInScope -Target 'esx02' -Scope $scope)) 'unlisted host'
foreach ($l in @('localhost', '127.0.0.1', '::1', '.', '127.5.5.5')) { Assert-True (Test-TargetInScope -Target $l -Scope $null) "local name $l always in scope" }
if ($env:COMPUTERNAME) { Assert-True (Test-TargetInScope -Target $env:COMPUTERNAME -Scope $null) 'COMPUTERNAME in scope' }
Assert-True (-not (Test-TargetInScope -Target '10.20.30' -Scope $scope)) 'partial IPv4 rejected'
Assert-True (-not (Test-TargetInScope -Target '*' -Scope $scope)) 'wildcard target rejected'
$big = [pscustomobject]@{ allow = @('10.0.0.0/8', '192.168.5.17'); deny = @('10.99.0.0/16') }
Assert-True (Test-TargetInScope -Target '10.255.255.255' -Scope $big) '/8 edge'
Assert-True (-not (Test-TargetInScope -Target '11.0.0.0' -Scope $big)) '/8 outside'
Assert-True (-not (Test-TargetInScope -Target '10.99.3.4' -Scope $big)) 'deny cidr overrides allow cidr'
Assert-True (Test-TargetInScope -Target '192.168.5.17' -Scope $big) 'single IP allow'
Assert-True (-not (Test-TargetInScope -Target '192.168.5.18' -Scope $big)) 'single IP neighbour'

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('explorer-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmpRoot | Out-Null
try {
    $sf = Join-Path $tmpRoot 'scope.json'
    [IO.File]::WriteAllText($sf, '{ "allow": ["10.20.30.0/24", "192.168.5.17", "esx01", "*.sw4.lab"], "deny": ["10.20.30.1"] }')
    $sc = Read-ScopeConfig -Path $sf
    Assert-True ($null -ne $sc -and @($sc.allow).Count -eq 4 -and @($sc.deny).Count -eq 1) 'Read-ScopeConfig parses'
    Assert-True (Test-TargetInScope -Target '192.168.5.17' -Scope $sc) 'scope from file works'
    [IO.File]::WriteAllText($sf, '{ "allow": ["10.20.30.0/33"] }')
    Assert-True ($null -eq (Read-ScopeConfig -Path $sf)) 'invalid cidr -> null scope'
    [IO.File]::WriteAllText($sf, 'not json')
    Assert-True ($null -eq (Read-ScopeConfig -Path $sf)) 'invalid json -> null scope'
    Assert-True ($null -eq (Read-ScopeConfig -Path (Join-Path $tmpRoot 'missing.json'))) 'missing file -> null scope'

    # ------------------------------------------------------------ linux gate
    $lallow = @(
        'systemctl list-units --type=service --state=running --no-pager', 'ss -tuln', 'cat /etc/os-release',
        'ip -br addr; ip route', 'journalctl -u sshd -n 50 --no-pager', 'kubectl get nodes -o wide 2>&1',
        'rpm -qa | sort | head -50', 'df -hT 2>/dev/null', "grep -i 'error' /var/log/messages | tail -n 20",
        'ping -c 3 10.20.30.9', 'cat /etc/*-release', 'uname -a && uptime', 'top -b -n 1 | head -20',
        'docker ps -a', 'docker stats --no-stream', 'firewall-cmd --list-all', 'iptables -L -n -v',
        'getent hosts dc01', 'dig @10.20.30.2 dc01.sw4.lab', 'openssl x509 -in /etc/pki/tls/certs/x.crt -noout -dates'
    )
    foreach ($c in $lallow) {
        $r = Test-LinuxReadOnlyCommand -Command $c
        Assert-True $r.Allowed "linux gate should ALLOW: $c -> $($r.Reason)"
    }
    $r = Test-LinuxReadOnlyCommand -Command 'ping -c 3 10.20.30.9'
    Assert-True ($r.Targets -contains '10.20.30.9') 'linux ping target returned'
    $ldeny = @(
        'rm -rf /tmp/x', 'systemctl restart sshd', 'cat /etc/shadow', 'echo hi > /tmp/x', 'ls $(rm x)', 'ls `rm x`',
        'sudo ss -tulnp', 'ip link set eth0 down', 'tail -f /var/log/messages', 'find / -name x -delete',
        'sysctl -w net.ipv4.ip_forward=1', 'kubectl apply -f x.yaml', "bash -c 'rm x'", 'ls | xargs rm', 'ls & rm x',
        'FOO=1 ls', '/usr/bin/rm x', "echo \'; rm x; echo \'", "r''m x", 'cat /etc/sh*', 'cat /etc/{sha,x}dow',
        'cat ~/.ssh/id_rsa', 'head /root/.ssh/authorized_keys', 'grep -r root /etc', 'ls ${HOME}', 'cat < /etc/passwd',
        "ls`nrm x", 'ping 10.20.30.9', 'ping -c 50 10.20.30.9', 'journalctl -fu sshd', 'dmesg -c', 'date -s now',
        'hostname newname', 'sort -o /tmp/x y', 'docker exec x sh', 'docker run x', 'crictl logs -f x', 'nft flush ruleset',
        'iptables -F', 'getent shadow', 'ls; ', '', 'cat x | tee y', 'awk 1 x', 'sed -n 1p x', 'ls (rm x)',
        'echo "$(rm x)"', 'echo "a" 1>/dev/null', 'ls 2>/tmp/x', 'rpm -e foo', 'dnf install x', 'apt install x',
        'mount /dev/sda1 /mnt', 'ls # x', 'cat /proc/1/environ', 'openssl x509 -in a -out b', 'uniq a b'
    )
    foreach ($c in $ldeny) {
        $r = Test-LinuxReadOnlyCommand -Command $c
        Assert-True (-not $r.Allowed -and [bool]$r.Reason) "linux gate should DENY: $c"
    }

    # ------------------------------------------------------------ credstore
    $dd = Join-Path $tmpRoot 'data'
    $null = Set-StoredCredential -DataDir $dd -Name 'lab-win' -Kind windows -Username 'LAB\admin' -Secret 'S3cret!pw' -Note 'lab domain admin'
    $credFile = Join-Path $dd 'credentials.json'
    $rawJson = [IO.File]::ReadAllText($credFile)
    Assert-True ($rawJson.TrimStart().StartsWith('[')) 'single-record credential file is a JSON array'
    Assert-True ($rawJson -notmatch 'S3cret!pw') 'secret not stored in plain text'
    $bytes = [IO.File]::ReadAllBytes($credFile)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'credential file has no BOM'
    $list = @(Get-CredentialList -DataDir $dd)
    Assert-True ($list.Count -eq 1 -and $list[0].hasSecret -and $list[0].name -eq 'lab-win') 'list shows the credential'
    Assert-True (-not ($list[0].PSObject.Properties.Name -contains 'secret')) 'list never includes secret'
    Assert-True ((($list | ConvertTo-Json) -notmatch 'S3cret')) 'list json has no secret'
    $null = Set-StoredCredential -DataDir $dd -Name 'lab-win' -Kind windows -Username 'LAB\admin2'
    $rec = Get-StoredCredentialRecord -DataDir $dd -Name 'lab-win'
    Assert-True ($rec.username -eq 'LAB\admin2' -and (Get-StoredCredentialPlainSecret -Record $rec) -eq 'S3cret!pw') 'update without secret keeps secret'
    Assert-True ($rec.note -eq 'lab domain admin') 'update without note keeps note'
    $null = Set-StoredCredential -DataDir $dd -Name 'lab-linux' -Kind linux -Username 'root' -KeyPath '/keys/id_lab'
    Assert-True (@(Get-CredentialList -DataDir $dd).Count -eq 2) 'two credentials'
    $threw = $false
    try { $null = Set-StoredCredential -DataDir $dd -Name 'bad name!' -Kind windows -Username 'x' } catch { $threw = $true }
    Assert-True $threw 'invalid credential name rejected'
    $threw = $false
    try { $null = Set-StoredCredential -DataDir $dd -Name ('a' * 41) -Kind windows -Username 'x' } catch { $threw = $true }
    Assert-True $threw 'too-long credential name rejected'
    $loader = Get-CredentialLoaderScript -DataDir $dd -Name 'lab-win' -VariableName 'cred'
    Assert-True ($loader -notmatch 'S3cret') 'loader script does not embed the secret'
    Assert-True ($loader.Contains('credentials.json')) 'loader reads the credential file'
    # Run the loader in-process (it is plain PowerShell) and check the PSCredential.
    $sbL = [scriptblock]::Create($loader + "`r`n`$cred")
    $credObj = & $sbL
    Assert-True ($credObj -is [System.Management.Automation.PSCredential] -and $credObj.UserName -eq 'LAB\admin2' -and $credObj.GetNetworkCredential().Password -eq 'S3cret!pw') 'loader builds PSCredential'
    Assert-True (Remove-StoredCredential -DataDir $dd -Name 'lab-linux') 'remove returns true'
    Assert-True (-not (Remove-StoredCredential -DataDir $dd -Name 'nope')) 'remove missing returns false'
    $rawJson = [IO.File]::ReadAllText($credFile)
    Assert-True ($rawJson.TrimStart().StartsWith('[') -and @(Get-CredentialList -DataDir $dd).Count -eq 1) 'after remove still JSON array with one record'
    $null = Remove-StoredCredential -DataDir $dd -Name 'lab-win'
    Assert-True ([IO.File]::ReadAllText($credFile).Trim() -eq '[]') 'empty store is []'

    # ------------------------------------------------------------ kb tools
    $ws = Join-Path $tmpRoot 'ws'
    New-Item -ItemType Directory -Force $ws | Out-Null
    $ctx = @{ Workspace = $ws; DataDir = $dd }
    $o = Invoke-ExplorerTool -Name 'kb_write' -Args @{ file = '20-network.md'; mode = 'replace'; content = "# Network`n`n## Subnets`nold`n`n## DNS`ndns text`n" } -Context $ctx
    Assert-True ($o -match 'kb/20-network.md') "kb_write replace: $o"
    $o = Invoke-ExplorerTool -Name 'kb_write' -Args @{ file = '20-network.md'; mode = 'append'; content = 'appended line' } -Context $ctx
    $o = Invoke-ExplorerTool -Name 'kb_write' -Args @{ file = '20-network.md'; mode = 'section'; heading = 'Subnets'; content = '10.20.30.0/24 (raw/x.txt)' } -Context $ctx
    $o = Invoke-ExplorerTool -Name 'kb_write' -Args @{ file = '20-network.md'; mode = 'section'; heading = 'Gateways'; content = 'gw 10.20.30.1 INFERRED' } -Context $ctx
    $txt = Invoke-ExplorerTool -Name 'kb_read' -Args @{ file = '20-network.md' } -Context $ctx
    Assert-True ($txt -match '10\.20\.30\.0/24 \(raw/x\.txt\)' -and $txt -notmatch '(?m)^old$') "section replaced: $txt"
    Assert-True ($txt -match 'dns text' -and $txt -match 'appended line') 'other sections kept'
    Assert-True ($txt -match '## Gateways\ngw 10.20.30.1 INFERRED') 'missing section appended'
    $o = Invoke-ExplorerTool -Name 'kb_write' -Args ([pscustomobject]@{ file = 'hosts/esx01.md'; content = '# esx01' }) -Context $ctx
    Assert-True (Test-Path (Join-Path (Join-Path (Join-Path $ws 'kb') 'hosts') 'esx01.md')) 'kb_write subfolder with pscustomobject args'
    $lst = Invoke-ExplorerTool -Name 'kb_read' -Args @{} -Context $ctx
    Assert-True ($lst -match 'kb/20-network.md \(\d+ B\) # Network' -and $lst -match 'kb/hosts/esx01.md') "kb_read list: $lst"
    foreach ($bad in @('../x.md', '/etc/x.md', 'C:\x.md', 'x.txt', 'a/../../x.md', 'kb/../../x.md', '')) {
        $o = Invoke-ExplorerTool -Name 'kb_write' -Args @{ file = $bad; content = 'x' } -Context $ctx
        Assert-True ($o -match 'Invalid kb file') "kb_write rejects '$bad': $o"
    }
    Assert-True (-not (Test-Path (Join-Path $tmpRoot 'x.md'))) 'no traversal file written'
    $o = Invoke-ExplorerTool -Name 'kb_write' -Args @{ file = 'big.md'; content = ('x' * 60001) } -Context $ctx
    Assert-True ($o -match '60000') 'kb_write rejects oversize content'

    # frontier
    $o = Invoke-ExplorerTool -Name 'frontier' -Args @{ action = 'add'; items = @(@{ target = 'esx01'; question = 'What VMs run here?'; priority = 1 }, @{ target = '10.20.30.0/24'; question = 'Which hosts answer ping?' }) } -Context $ctx
    Assert-True ($o -match 'added 2' -and $o -match 'F001' -and $o -match 'F002') "frontier add: $o"
    $o = Invoke-ExplorerTool -Name 'frontier' -Args @{ action = 'add'; items = @(@{ target = 'ESX01'; question = 'what vms run here?' }, @{ target = 'dc01'; question = 'Roles?'; priority = 2 }) } -Context $ctx
    Assert-True ($o -match 'added 1' -and $o -match 'F003' -and $o -match '1 duplicate') "frontier dedupe: $o"
    $o = Invoke-ExplorerTool -Name 'frontier' -Args @{ action = 'list' } -Context $ctx
    $lines = @($o -split "`n")
    Assert-True ($lines[0] -match '3 open, 0 done, 0 skipped' -and $lines[1] -match '^F001 p1' -and $lines[2] -match '^F003 p2' -and $lines[3] -match '^F002 p3') "frontier list order: $o"
    $o = Invoke-ExplorerTool -Name 'frontier' -Args @{ action = 'done'; id = 'F001'; note = '12 VMs (raw/x.txt)' } -Context $ctx
    $o2 = Invoke-ExplorerTool -Name 'frontier' -Args @{ action = 'skip'; id = 'f002'; note = 'no ping allowed' } -Context $ctx
    $o = Invoke-ExplorerTool -Name 'frontier' -Args @{ action = 'list' } -Context $ctx
    Assert-True ($o -match '1 open, 1 done, 1 skipped' -and $o -notmatch 'F001') "frontier after done/skip: $o"
    $o = Invoke-ExplorerTool -Name 'frontier' -Args @{ action = 'add'; items = '[{"target":"esx01","question":"What VMs run here?"}]' } -Context $ctx
    Assert-True ($o -match 'added 0') 'done items still deduplicate; JSON string items accepted'

    # baseline_diff
    $rawDir = Join-Path $ws 'raw'
    New-Item -ItemType Directory -Force $rawDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $rawDir 'a.txt'), "# time: 1`n# ---- output ----`nline1`nline2`nline3`nline4`n")
    [IO.File]::WriteAllText((Join-Path $rawDir 'b.txt'), "# time: 2`n# ---- output ----`nline1`nline2 changed`nline3`nline5`n")
    $d = Invoke-ExplorerTool -Name 'baseline_diff' -Args @{ a = 'raw/a.txt'; b = 'raw/b.txt' } -Context $ctx
    Assert-True ($d -match '(?m)^-line2$' -and $d -match '(?m)^\+line2 changed$' -and $d -match '(?m)^-line4$' -and $d -match '(?m)^\+line5$' -and $d -notmatch 'time:') "baseline_diff files: $d"
    $d = Invoke-ExplorerTool -Name 'baseline_diff' -Args @{ a = 'raw/a.txt'; b = 'raw/a.txt' } -Context $ctx
    Assert-True ($d -match 'No differences') 'baseline_diff identical'
    $d = Invoke-ExplorerTool -Name 'baseline_diff' -Args @{ a = '../../etc/passwd'; b = 'raw/a.txt' } -Context $ctx
    Assert-True ($d -match 'inside the workspace') 'baseline_diff refuses outside paths'
    New-Item -ItemType Directory -Force (Join-Path $ws 'base1'), (Join-Path $ws 'base2') | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $ws 'base1') 'svc.txt'), "a`nb`n")
    [IO.File]::WriteAllText((Join-Path (Join-Path $ws 'base2') 'svc.txt'), "a`nc`n")
    [IO.File]::WriteAllText((Join-Path (Join-Path $ws 'base1') 'gone.txt'), "x`n")
    [IO.File]::WriteAllText((Join-Path (Join-Path $ws 'base2') 'new.txt'), "y`n")
    $d = Invoke-ExplorerTool -Name 'baseline_diff' -Args @{ a = 'base1'; b = 'base2' } -Context $ctx
    Assert-True ($d -match 'REMOVED gone.txt' -and $d -match 'ADDED   new.txt' -and $d -match 'CHANGED svc.txt' -and $d -match '(?m)^\+c$') "baseline_diff folders: $d"

    # list_credentials + fallthrough
    $null = Set-StoredCredential -DataDir $dd -Name 'vc' -Kind vsphere -Username 'administrator@vsphere.local' -Secret 'pw123456' -Note 'vcenter'
    $o = Invoke-ExplorerTool -Name 'list_credentials' -Args @{} -Context $ctx
    Assert-True ($o -match 'vc \| vsphere \| user administrator@vsphere.local' -and $o -notmatch 'pw123456') "list_credentials: $o"
    Assert-True ($null -eq (Invoke-ExplorerTool -Name 'read_file' -Args @{} -Context $ctx)) 'unknown tool returns $null'
    $defs = @(Get-ExplorerToolDefinitions)
    Assert-True ($defs.Count -eq 7 -and @($defs | Where-Object { $_.access -ne 'read' }).Count -eq 0) 'seven read-access tool definitions'
    foreach ($dd2 in $defs) { Assert-True ($dd2.name -and $dd2.description -and $dd2.params) "definition shape: $($dd2.name)" }

    # ------------------------------------------------------------ net_query end to end (local, child process)
    $o = Invoke-ExplorerTool -Name 'net_query' -Args @{ command = 'Get-Date | Select-Object Year'; purpose = 'Year check!' } -Context $ctx
    $yr = (Get-Date).Year
    Assert-True ($o -match 'Raw output saved: raw/\d{8}-\d{6}-year-check\.txt \| exit code: 0' -and $o -match "$yr") "net_query local runs: $o"
    $rawFiles = @(Get-ChildItem -LiteralPath $rawDir -Filter '*year-check*')
    Assert-True ($rawFiles.Count -eq 1) 'net_query raw file created'
    if ($rawFiles.Count -eq 1) {
        $rt = [IO.File]::ReadAllText($rawFiles[0].FullName)
        Assert-True ($rt -match '# via: local' -and $rt -match 'Get-Date \| Select-Object Year' -and $rt -match "$yr") 'raw file has header and output'
    }
    $before = @(Get-ChildItem -LiteralPath $rawDir).Count
    $o = Invoke-ExplorerTool -Name 'net_query' -Args @{ command = 'Remove-Item C:\x'; purpose = 'bad' } -Context $ctx
    Assert-True ($o -match '^BLOCKED by read-only gate:') "net_query denied: $o"
    Assert-True (@(Get-ChildItem -LiteralPath $rawDir).Count -eq $before) 'denied net_query creates no raw file'
    $o = Invoke-ExplorerTool -Name 'net_query' -Args @{ command = 'Get-Date'; purpose = 'x'; via = 'winrm'; target = '10.20.30.5'; credential = 'vc' } -Context $ctx
    Assert-True ($o -match 'BLOCKED' -and $o -match 'scope') "net_query winrm without scope file blocked: $o"
    New-Item -ItemType Directory -Force (Join-Path $ws '.byob') | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $ws '.byob') 'scope.json'), '{"allow":["10.20.30.0/24"],"deny":[]}')
    $o = Invoke-ExplorerTool -Name 'net_query' -Args @{ command = 'Get-Date'; purpose = 'x'; via = 'winrm'; target = '10.20.30.5'; credential = 'vc' } -Context $ctx
    Assert-True ($o -match "kind 'vsphere'") "net_query winrm kind check: $o"
    $o = Invoke-ExplorerTool -Name 'net_query' -Args @{ command = "Get-Content '$dd/credentials.json'"; purpose = 'x' } -Context $ctx
    Assert-True ($o -match '^BLOCKED') 'net_query cannot read credential store'
    $o = Invoke-ExplorerTool -Name 'net_query' -Args @{ command = '1..3000 | ForEach-Object { "line $_ padding padding padding" }'; purpose = 'long output' } -Context $ctx
    Assert-True ($o -match 'truncated' -and $o.Length -lt 6600) "net_query truncates long output (len $($o.Length))"
    $lf = @(Get-ChildItem -LiteralPath $rawDir -Filter '*long-output*')
    if ($lf.Count -eq 1) {
        $rt = [IO.File]::ReadAllText($lf[0].FullName)
        Assert-True ($rt -match 'line 1 padding' -and $rt -match 'line 1500 padding' -and $rt -match 'line 3000 padding') 'raw file has the complete long output'
    } else { Assert-True $false 'long-output raw file missing' }
    $o = Invoke-ExplorerTool -Name 'net_query' -Args @{ command = 'Get-Date'; purpose = '' } -Context $ctx
    Assert-True ($o -match 'purpose') 'net_query requires purpose'

    # ssh_query refusal paths (no ssh server in the test runtime)
    $null = Set-StoredCredential -DataDir $dd -Name 'lnx' -Kind linux -Username 'root' -Secret 'pw'
    $o = Invoke-ExplorerTool -Name 'ssh_query' -Args @{ target = '10.20.30.9'; command = 'rm -rf /'; credential = 'lnx'; purpose = 'x' } -Context $ctx
    Assert-True ($o -match '^BLOCKED by read-only gate') "ssh_query denied: $o"
    $o = Invoke-ExplorerTool -Name 'ssh_query' -Args @{ target = '8.8.8.8'; command = 'uptime'; credential = 'lnx'; purpose = 'x' } -Context $ctx
    Assert-True ($o -match 'outside the allowed scope') "ssh_query scope: $o"
    $o = Invoke-ExplorerTool -Name 'ssh_query' -Args @{ target = '10.20.30.9'; command = 'ping -c 1 8.8.8.8'; credential = 'lnx'; purpose = 'x' } -Context $ctx
    Assert-True ($o -match 'outside the allowed scope') "ssh_query inner target scope: $o"
    $o = Invoke-ExplorerTool -Name 'ssh_query' -Args @{ target = '10.20.30.9'; command = 'uptime'; credential = 'vc'; purpose = 'x' } -Context $ctx
    Assert-True ($o -match "needs a 'linux' credential") "ssh_query kind: $o"
    $o = Invoke-ExplorerTool -Name 'ssh_query' -Args @{ target = '-oProxyCommand=x'; command = 'uptime'; credential = 'lnx'; purpose = 'x' } -Context $ctx
    Assert-True ($o -match 'not a valid host') 'ssh_query rejects option-like target'

    # Windows argument quoting
    Assert-True ((ConvertTo-ExplorerWinArg 'abc') -eq 'abc') 'quote plain'
    Assert-True ((ConvertTo-ExplorerWinArg 'a b') -eq '"a b"') 'quote space'
    Assert-True ((ConvertTo-ExplorerWinArg 'say "hi"') -eq '"say \"hi\""') 'quote embedded quotes'
    Assert-True ((ConvertTo-ExplorerWinArg 'C:\dir\ x\') -eq '"C:\dir\ x\\"') 'quote trailing backslash'
    Assert-True ((ConvertTo-ExplorerWinArg '') -eq '""') 'quote empty'

    # system prompt
    [IO.File]::WriteAllText((Join-Path (Join-Path $ws 'kb') '00-index.md'), "# Index`n- 20-network.md - subnets`n")
    $sp = Get-ExplorerSystemPrompt -Workspace $ws -CredentialNames @('vc', 'lnx')
    $words = @($sp -split '\s+' | Where-Object { $_ }).Count
    Assert-True ($sp -match 'BLOCKED' -and $sp -match 'INFERRED' -and $sp -match '20-network.md - subnets' -and $sp -match 'FRONTIER: 1 open' -and $sp -match 'vc, lnx') 'system prompt content'
    Assert-True ($words -lt 1000) "system prompt under ~900 words of instructions (got $words total)"

    # ------------------------------------------------------------ PluginHost
    Assert-True ((ConvertTo-PluginToolName 'Port-Check' 'Scan.TCP') -eq 'plg_port_check_scan_tcp') 'plugin tool name sanitised'
    $longName = ConvertTo-PluginToolName ('p' * 40) ('t' * 40)
    Assert-True ($longName.Length -eq 60 -and $longName.StartsWith('plg_ppp')) 'plugin tool name capped at 60'
    $appRoot = Join-Path $tmpRoot 'app'
    $pdir = Join-Path $appRoot 'plugins'
    function New-TestPlugin([string]$Dir, [string]$Manifest, [hashtable]$Files = @{}) {
        New-Item -ItemType Directory -Force $Dir | Out-Null
        if ($Manifest) { [IO.File]::WriteAllText((Join-Path $Dir 'byob-plugin.json'), $Manifest) }
        foreach ($k in $Files.Keys) { [IO.File]::WriteAllText((Join-Path $Dir $k), $Files[$k]) }
    }
    $goodManifest = '{"name":"good","description":"d","tools":[{"name":"check","description":"says hello","access":"read","params":{"type":"object","properties":{"who":{"type":"string"}}},"script":"check.ps1","timeout_sec":30}]}'
    New-TestPlugin (Join-Path $pdir 'good') $goodManifest @{ 'check.ps1' = 'param($ToolArgs) "hello $($ToolArgs.who) from $(Split-Path -Leaf $PluginRoot) in $(Split-Path -Leaf $WorkspaceRoot)"; return; "not reached"' }
    New-TestPlugin (Join-Path $pdir 'bad') '{ not json' @{}
    New-TestPlugin (Join-Path $pdir 'noscript') '{"name":"noscript","tools":[{"name":"x","access":"read","script":"missing.ps1"}]}' @{}
    New-TestPlugin (Join-Path $pdir 'badaccess') '{"name":"badaccess","tools":[{"name":"x","access":"root","script":"x.ps1"}]}' @{ 'x.ps1' = '1' }
    New-TestPlugin (Join-Path $pdir 'escape') '{"name":"escape","tools":[{"name":"x","access":"read","script":"../good/check.ps1"}]}' @{}
    New-TestPlugin (Join-Path $pdir 'notools') '{"name":"notools","tools":[]}' @{}
    New-TestPlugin (Join-Path $pdir 'nomanifest') $null @{ 'x.ps1' = '1' }
    $wsP = Join-Path (Join-Path (Join-Path $ws '.byob') 'plugins') 'dupe'
    New-TestPlugin $wsP $goodManifest @{ 'check.ps1' = '"dupe"' }
    New-TestPlugin (Join-Path (Join-Path (Join-Path $ws '.byob') 'plugins') 'wsplug') '{"name":"wsplug","tools":[{"name":"a","script":"a.ps1"},{"name":"b","access":"write","script":"a.ps1"}]}' @{ 'a.ps1' = '"ws plugin ran"' }
    $plugs = @(Get-ExplorerPlugins -AppRoot $appRoot -Workspace $ws -DataDir $dd)
    $byId = @{}; foreach ($pp in $plugs) { $byId[$pp.id] = $pp }
    Assert-True ($plugs.Count -eq 8 -and -not $byId.ContainsKey('app:nomanifest')) "plugin discovery count ($($plugs.Count): $(@($plugs | ForEach-Object { $_.id }) -join ', ')); folder without manifest ignored"
    Assert-True ($byId['app:good'].valid -and -not $byId['app:good'].trusted -and $byId['app:good'].tools[0].effectiveAccess -eq 'execute') 'new plugin is valid and untrusted (forced execute)'
    Assert-True (-not $byId['app:bad'].valid -and $byId['app:bad'].error -match 'JSON') "malformed manifest reported: $($byId['app:bad'].error)"
    Assert-True (-not $byId['app:noscript'].valid -and $byId['app:noscript'].error -match 'not found') 'missing script reported'
    Assert-True (-not $byId['app:badaccess'].valid -and $byId['app:badaccess'].error -match 'access') 'bad access reported'
    Assert-True (-not $byId['app:escape'].valid -and $byId['app:escape'].error -match 'relative') 'script path escape reported'
    Assert-True (-not $byId['app:notools'].valid) 'empty tools reported'
    Assert-True (-not $byId['workspace:dupe'].valid -and $byId['workspace:dupe'].error -match 'already used') 'duplicate tool name across plugins reported'
    Assert-True ($byId['workspace:wsplug'].valid -and $byId['workspace:wsplug'].tools[0].access -eq 'execute' -and $byId['workspace:wsplug'].tools[1].access -eq 'write') 'workspace plugin found; access defaults to execute'
    $defs = @(Get-PluginToolDefinitions -Plugins $plugs)
    Assert-True ($defs.Count -eq 3 -and @($defs | Where-Object { $_.confirm -and $_.access -eq 'execute' }).Count -eq 3) 'untrusted plugin tools: execute + confirm text'
    Assert-True (@($defs | Where-Object { $_.confirm -match "Plugin 'good' is new or has changed since you last trusted it. Read its code before allowing." }).Count -eq 1) 'confirm text wording'
    $h1 = Get-PluginFolderHash -Path (Join-Path $pdir 'good')
    Assert-True ($h1 -match '^[0-9a-f]{64}$' -and $h1 -eq (Get-PluginFolderHash -Path (Join-Path $pdir 'good'))) 'plugin hash stable'
    $threw = $false
    try { $null = Set-PluginTrustState -DataDir $dd -AppRoot $appRoot -Workspace $ws -Id 'app:good' -Action trust -ExpectedHash 'abc' } catch { $threw = $true }
    Assert-True $threw 'trust with stale expected hash refused'
    $threw = $false
    try { $null = Set-PluginTrustState -DataDir $dd -AppRoot $appRoot -Workspace $ws -Id 'app:bad' -Action trust } catch { $threw = $true }
    Assert-True $threw 'invalid plugin cannot be trusted'
    $null = Set-PluginTrustState -DataDir $dd -AppRoot $appRoot -Workspace $ws -Id 'app:good' -Action trust -ExpectedHash $h1
    $g = @(Get-ExplorerPlugins -AppRoot $appRoot -Workspace $ws -DataDir $dd | Where-Object { $_.id -eq 'app:good' })[0]
    $gd = @(Get-PluginToolDefinitions -Plugins @($g))[0]
    Assert-True ($g.trusted -and $gd.access -eq 'read' -and -not $gd.confirm -and $gd.name -eq 'plg_good_check') 'trusted plugin uses declared access, no confirm'
    Assert-True ((Read-PluginTrust -DataDir $dd)['app:good'] -eq $h1) 'trust file records the hash'
    [IO.File]::AppendAllText((Join-Path (Join-Path $pdir 'good') 'check.ps1'), "`n# edited")
    $g = @(Get-ExplorerPlugins -AppRoot $appRoot -Workspace $ws -DataDir $dd | Where-Object { $_.id -eq 'app:good' })[0]
    Assert-True (-not $g.trusted -and $g.changed -and $g.tools[0].effectiveAccess -eq 'execute') 'changed file invalidates trust'
    [IO.File]::WriteAllText((Join-Path (Join-Path $pdir 'good') 'extra.txt'), 'x')
    Assert-True ((Get-PluginFolderHash -Path (Join-Path $pdir 'good')) -ne $h1) 'added file changes the hash'
    $null = Set-PluginTrustState -DataDir $dd -AppRoot $appRoot -Workspace $ws -Id 'app:good' -Action trust
    Assert-True (@(Get-ExplorerPlugins -AppRoot $appRoot -Workspace $ws -DataDir $dd | Where-Object { $_.id -eq 'app:good' })[0].trusted) 're-trust after change'
    Assert-True (Set-PluginTrustState -DataDir $dd -Id 'app:good' -Action untrust) 'untrust returns true'
    Assert-True (-not @(Get-ExplorerPlugins -AppRoot $appRoot -Workspace $ws -DataDir $dd | Where-Object { $_.id -eq 'app:good' })[0].trusted) 'untrusted again'
    $pctx = @{ Workspace = $ws; DataDir = $dd; AppRoot = $appRoot }
    Assert-True ($null -eq (Invoke-PluginTool -Name 'read_file' -Args @{} -Context $pctx)) 'Invoke-PluginTool returns $null for non-plugin tools'
    Assert-True ((Invoke-PluginTool -Name 'plg_nope_x' -Args @{} -Context $pctx) -match 'Unknown plugin tool') 'unknown plugin tool message'
    $o = Invoke-PluginTool -Name 'plg_good_check' -Args @{ who = "bob's" } -Context $pctx
    Assert-True ($o -match "hello bob's from good in ws" -and $o -notmatch 'not reached' -and $o -match 'Raw output saved: raw/') "plugin tool runs in a child process with args and variables: $o"
    # sample plugin from the real app folder (scope in $ws allows 10.20.30.0/24; loopback is always in scope)
    $sctx = @{ Workspace = $ws; DataDir = $dd; AppRoot = $root }
    $sp = @(Get-ExplorerPlugins -AppRoot $root -Workspace '' -DataDir $dd | Where-Object { $_.id -eq 'app:sample-portscan' })[0]
    Assert-True ($sp.valid -and $sp.tools[0].exposed -eq 'plg_portscan_scan') 'sample plugin valid'
    $o = Invoke-PluginTool -Name 'plg_portscan_scan' -Args @{ target = '8.8.8.8'; ports = @(53) } -Context $sctx
    Assert-True ($o -match 'REFUSED' -and $o -match 'outside the workspace scope' -and $o -notmatch 'port 53:') "sample plugin refuses out-of-scope target: $o"
    $o = Invoke-PluginTool -Name 'plg_portscan_scan' -Args @{ target = '127.0.0.1'; ports = @(1..31) } -Context $sctx
    Assert-True ($o -match 'REFUSED' -and $o -match '1 to 30') 'sample plugin refuses more than 30 ports'
    $tl = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
    $tl.Start()
    try {
        $op = $tl.LocalEndpoint.Port
        $o = Invoke-PluginTool -Name 'plg_portscan_scan' -Args @{ target = '127.0.0.1'; ports = @($op) } -Context $sctx
        Assert-True ($o -match "port ${op}: open") "sample plugin scans an in-scope loopback port: $o"
    } finally { $tl.Stop() }

    # ------------------------------------------------------------ agent helpers
    $msgs = New-Object System.Collections.ArrayList
    [void]$msgs.Add(@{ role = 'user'; content = 'go' })
    for ($i = 0; $i -lt 8; $i++) {
        [void]$msgs.Add(@{ role = 'assistant'; content = ''; tool_calls = @(@{ id = "c$i"; type = 'function'; function = @{ name = 'kb_read'; arguments = '{}' } }) })
        [void]$msgs.Add(@{ role = 'tool'; tool_call_id = "c$i"; content = ("Raw output saved: raw/x$i.txt`n" + ('y' * 1000)) })
    }
    $before = Measure-ExplorerMessages -SystemPrompt 'sys' -Messages $msgs
    $n = Limit-ExplorerToolResults -Messages $msgs -KeepRecent 6 -HeadChars 400
    $toolMsgs = @($msgs | Where-Object { $_.role -eq 'tool' })
    Assert-True ($n -eq 2 -and $toolMsgs[0].content.EndsWith('[trimmed - full output is in the raw file named above]') -and $toolMsgs[0].content.StartsWith('Raw output saved: raw/x0.txt')) 'oldest tool results trimmed with marker'
    Assert-True ($toolMsgs[0].content.Length -eq (400 + $script:ExplorerTrimMarker.Length) -and $toolMsgs[2].content.Length -gt 1000) 'trim keeps 400 chars; recent 6 untouched'
    Assert-True ((Limit-ExplorerToolResults -Messages $msgs -KeepRecent 6 -HeadChars 400) -eq 0) 'trim is idempotent'
    Assert-True ((Measure-ExplorerMessages -SystemPrompt 'sys' -Messages $msgs) -lt $before) 'measure drops after trim'
    Assert-True ($msgs.Count -eq 17) 'trimming never removes messages (pairing kept)'
    Assert-True ((Get-ExplorerLoopKey 'net_query' @{ command = 'a' }) -eq (Get-ExplorerLoopKey 'net_query' @{ command = 'a' }) -and (Get-ExplorerLoopKey 'net_query' @{ command = 'a' }) -ne (Get-ExplorerLoopKey 'net_query' @{ command = 'b' })) 'loop key'
    Assert-True ((Test-ExplorerBadResult 'BLOCKED by read-only gate: x' 'done') -and (Test-ExplorerBadResult 'ok' 'error') -and -not (Test-ExplorerBadResult 'fine' 'done') -and (Test-ExplorerBadResult 'LOOP GUARD: x' 'blocked')) 'bad result classification'
    $tr = ConvertTo-ExplorerTranscript -Messages $msgs -MaxChars 3000
    Assert-True ($tr.Length -lt 3100 -and $tr -match 'USER: go' -and $tr -match 'omitted') 'transcript capped'
    $ei = Get-ExplorerExploreInstruction -Guidance 'focus on esx01' -Scope ([pscustomobject]@{ allow = @('10.1.0.0/24'); deny = @('10.1.0.1') }) -VsphereCredentials @('vc')
    Assert-True ($ei -match 'EXPLORE MODE' -and $ei -match '10\.1\.0\.0/24' -and $ei -match 'deny: 10\.1\.0\.1' -and $ei -match 'vc' -and $ei -match 'focus on esx01' -and $ei -match 'arp -a') 'explore instruction'
    $sysT = Get-ExplorerTurnSystemPrompt -Workspace $ws -DataDir $dd -CredentialNames @('vc') -ExtraInstructions 'be brief' -AppRoot $root
    Assert-True ($sysT -match 'PLUGINS' -and $sysT -match 'plg_<plugin>_<tool>' -and $sysT -match 'USER INSTRUCTIONS' -and $sysT -notmatch '(?i)outlook') 'turn system prompt'
    [IO.File]::WriteAllText((Join-Path $dd 'memory.md'), ('m' * 5000) + 'TAILMARK')
    $sysT = Get-ExplorerTurnSystemPrompt -Workspace $ws -DataDir $dd -AppRoot $root
    Assert-True ($sysT -match 'TAILMARK' -and $sysT -match 'GLOBAL MEMORY' -and $sysT.Length -lt 16000) 'memory capped at 4000 chars (newest kept)'
    $fcnt = Get-ExplorerFrontierCounts -Workspace $ws
    Assert-True ($fcnt.open -eq 1 -and $fcnt.done -eq 1 -and $fcnt.skipped -eq 1) 'frontier counts'
    $snapA = Get-ExplorerKbSnapshot -Workspace $ws
    Start-Sleep -Milliseconds 20
    $null = Invoke-ExplorerTool -Name 'kb_write' -Args @{ file = '30-services.md'; content = '# Services' } -Context $ctx
    $chg = Compare-ExplorerKbSnapshot -Before $snapA -After (Get-ExplorerKbSnapshot -Workspace $ws)
    Assert-True (@($chg).Count -eq 1 -and $chg[0] -eq 'kb/30-services.md') 'kb snapshot diff'

    # ------------------------------------------------------------ base tools
    $base = @(Get-ByobToolDefinitions -IncludeDelegate $true)
    $bn = @($base | ForEach-Object { $_.name })
    Assert-True ($bn.Count -eq 10 -and @($bn | Where-Object { $_ -match 'outlook' }).Count -eq 0 -and ($bn -join ',') -eq 'list_files,read_file,search_files,write_file,edit_file,run_command,create_artifact,update_plan,remember,delegate') "base tools: $($bn -join ',')"
    Assert-True (@($base | Where-Object { $_.name -eq 'run_command' })[0].access -eq 'execute') 'run_command access execute'
    $bctx = @{ Workspace = $ws; DataDir = $dd; UndoDir = (Join-Path $tmpRoot 'undo'); TurnId = 't1' }
    foreach ($bt in @(@{ n = 'read_file'; a = @{ path = (Join-Path $dd 'credentials.json') } }, @{ n = 'write_file'; a = @{ path = (Join-Path $dd 'plugin-trust.json'); content = '{}' } }, @{ n = 'list_files'; a = @{ path = $dd } }, @{ n = 'search_files'; a = @{ pattern = 'x'; path = $dd } })) {
        $threw = $false
        try { $null = Invoke-ByobTool -Name $bt.n -Args $bt.a -Context $bctx } catch { $threw = ($_.Exception.Message -match 'private data folder') }
        Assert-True $threw "$($bt.n) refuses the app data folder"
    }
    $o = Invoke-ByobTool -Name 'run_command' -Args @{ command = 'Write-Output ("rc-" + (2+3))' } -Context $bctx
    Assert-True ($o -match 'Exit code: 0' -and $o -match 'rc-5') "run_command runs: $o"
    $byobText = [IO.File]::ReadAllText((Join-Path $src 'ByobTools.ps1'))
    Assert-True ($byobText -notmatch '(?i)-ExecutionPolicy\s+Bypass') 'run_command does not pass -ExecutionPolicy Bypass'

    # ------------------------------------------------------------ LLM client conversions
    $conv2 = @(
        @{ role = 'user'; content = 'hi' },
        @{ role = 'assistant'; content = 'checking'; tool_calls = @(@{ id = 'a1'; type = 'function'; function = @{ name = 'kb_read'; arguments = '{"file":"x.md"}' } }, @{ id = 'a2'; type = 'function'; function = @{ name = 'frontier'; arguments = '{}' } }) },
        @{ role = 'tool'; tool_call_id = 'a1'; content = 'r1' },
        @{ role = 'tool'; tool_call_id = 'a2'; content = 'r2' },
        @{ role = 'user'; content = 'next' }
    )
    $am = ConvertTo-ByobAnthropicMessages -Messages $conv2
    Assert-True ($am.Count -eq 4 -and $am[1].role -eq 'assistant' -and @($am[1].content).Count -eq 3 -and $am[1].content[1].type -eq 'tool_use' -and $am[1].content[1].input.file -eq 'x.md') 'anthropic conversion: assistant tool_use blocks'
    Assert-True ($am[2].role -eq 'user' -and @($am[2].content).Count -eq 2 -and $am[2].content[0].tool_use_id -eq 'a1' -and $am[3].content -eq 'next') 'anthropic conversion: tool results merged into one user message'
    $tcl = ConvertTo-ByobToolCallList @(@{ id = 'x1'; name = 'kb_read'; args = [pscustomobject]@{ file = 'a.md' }; rawArgs = '' })
    Assert-True (@($tcl).Count -eq 1 -and $tcl[0].function.arguments -eq '{"file":"a.md"}' -and $tcl[0].type -eq 'function') 'tool call list normalised (fallback calls get arguments JSON)'
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- parse + PS 5.1 syntax scan
$files = @(Get-ChildItem -Path $root -Include '*.ps1', '*.psm1', '*.psd1' -Recurse)
foreach ($f in $files) {
    $tk = $null; $er = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$er)
    Assert-True (@($er).Count -eq 0) "parses cleanly: $($f.FullName) $(@($er | ForEach-Object { $_.Message }) -join '; ')"
}
$shipped = @(Get-ChildItem -Path $root -Include '*.ps1', '*.psm1', '*.psd1' -Recurse | Where-Object { $_.FullName -notmatch '[\\/](temp|data|dist|logs)[\\/]' })
Assert-True ($shipped.Count -ge 15) "found the shipped scripts ($($shipped.Count))"
foreach ($sf in $shipped) {
    $path = $sf.FullName
    $fn = $sf.FullName.Substring($root.Length + 1)
    $bytes = [IO.File]::ReadAllBytes($path)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
    Assert-True ($nonAscii -eq 0) "$fn is ASCII only"
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tk, [ref]$er)
    $ps7Nodes = @($ast.FindAll({ param($n) $n.GetType().Name -in @('TernaryExpressionAst', 'PipelineChainAst') }, $true))
    Assert-True ($ps7Nodes.Count -eq 0) "$fn has no ternary or && / || pipeline chains"
    $bad = @($tk | Where-Object { [string]$_.Kind -in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr') })
    Assert-True ($bad.Count -eq 0) "$fn has no ??, ?., && or || tokens: $(@($bad | ForEach-Object { $_.Text + '@' + $_.Extent.StartLineNumber }) -join ', ')"
    $text = [IO.File]::ReadAllText($path)
    if ($fn -match '(NetGate|CredStore|ExplorerTools|PluginHost|ExplorerAgent)\.ps1$') {
        Assert-True ($text -notmatch '::new\(') "$fn does not use ::new()"
        Assert-True ($text -notmatch '(?i)Add-Type') "$fn does not use Add-Type"
    }
    # Add-Type is allowed only for -AssemblyName (WinForms message box, zip) and in the .lnk bootstrap string.
    $addTypes = @([regex]::Matches($text, '(?im)^[^#\r\n]*\bAdd-Type\b(?![^\r\n]*-AssemblyName)[^\r\n]*$') | ForEach-Object { $_.Value.Trim() })
    $addTypes = @($addTypes | Where-Object { $fn -notmatch 'New-ToolShortcut\.ps1$' -and $fn -notmatch '^tests[\\/]' })
    Assert-True ($addTypes.Count -eq 0) "$fn has no Add-Type C# compile: $($addTypes -join ' | ')"
}

Write-Host ("Core tests: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
