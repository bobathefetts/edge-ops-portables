# BYOB Plugin Backend for Outlook Classic (Windows PowerShell 5.1, STA). ASCII only.
# Speaks BYOB's newline-delimited JSON protocol v1 over stdin/stdout.
$ErrorActionPreference = 'Stop'

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

. (Join-Path $PSScriptRoot 'outlook_com.ps1')

$script:Settings = @{}
$script:DefaultDaysBack = 14
$script:AllowSensitive = $false
$script:CachedInbox = $null
$script:CachedStatus = $null

function Send-ByobMsg {
    param([Parameter(Mandatory)]$Obj)
    $json = ($Obj | ConvertTo-Json -Depth 12 -Compress)
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Send-ByobReply {
    param($Id, $Result)
    Send-ByobMsg @{ type = 'reply'; id = $Id; result = $Result }
}

function Send-ByobError {
    param($Id, [string]$Message)
    Send-ByobMsg @{ type = 'reply'; id = $Id; error = $Message }
}

function Get-ChipView {
    try {
        if (-not $script:CachedStatus) {
            $script:CachedStatus = Invoke-OutlookStatus
        }
        if ($script:CachedStatus.connected) {
            return @{
                type = 'chip'
                text = "Outlook: $($script:CachedStatus.inboxUnread) unread"
                tone = 'accent'
            }
        }
        return @{
            type = 'chip'
            text = 'Outlook: unavailable'
            tone = 'dim'
        }
    } catch {
        return @{ type = 'chip'; text = 'Outlook: offline'; tone = 'dim' }
    }
}

function Get-InboxPaneView {
    $children = New-Object System.Collections.Generic.List[object]
    $children.Add(@{
        type = 'row'
        children = @(
            @{ type = 'button'; label = 'Refresh Inbox'; action = 'refresh'; primary = $true },
            @{ type = 'text'; text = 'Classic Outlook COM'; style = 'small'; tone = 'dim' }
        )
    })

    if (-not $script:CachedStatus) {
        $script:CachedStatus = Invoke-OutlookStatus
    }
    if (-not $script:CachedStatus.connected) {
        $msg = if ($script:CachedStatus.message) { [string]$script:CachedStatus.message } else { 'Classic Outlook is not connected.' }
        $children.Add(@{
            type = 'card'
            title = 'Classic Outlook not connected'
            children = @(
                @{ type = 'text'; text = $msg; tone = 'dim' }
            )
        })
        return @{ type = 'column'; children = $children.ToArray() }
    }

    if (-not $script:CachedInbox) {
        try {
            $script:CachedInbox = Invoke-OutlookSearch -Folder 'Inbox' -DaysBack $script:DefaultDaysBack -Limit 15 -AllowSensitive $script:AllowSensitive
        } catch {
            $children.Add(@{ type = 'text'; text = $_.Exception.Message; tone = 'dim' })
            return @{ type = 'column'; children = $children.ToArray() }
        }
    }

    $children.Add(@{
        type = 'text'
        text = "$($script:CachedStatus.userEmail) - $($script:CachedStatus.inboxUnread) unread / $($script:CachedStatus.inboxTotal) total"
        style = 'small'
        tone = 'dim'
    })

    $emails = @($script:CachedInbox.emails)
    if ($emails.Count -eq 0) {
        $children.Add(@{ type = 'text'; text = 'No recent emails found in Inbox.'; tone = 'dim' })
    } else {
        $idx = 0
        foreach ($em in $emails) {
            $idx++
            $chips = New-Object System.Collections.Generic.List[object]
            if ($em.unread) { $chips.Add(@{ type = 'chip'; text = 'unread'; tone = 'accent' }) }
            if ($em.appearsReplied) { $chips.Add(@{ type = 'chip'; text = 'replied'; tone = 'success' }) }
            if ($em.isSensitive) { $chips.Add(@{ type = 'chip'; text = 'sensitive'; tone = 'warning' }) }

            $cardChildren = New-Object System.Collections.Generic.List[object]
            if ($chips.Count -gt 0) {
                $cardChildren.Add(@{ type = 'row'; children = $chips.ToArray() })
            }
            $cardChildren.Add(@{ type = 'text'; text = "$($em.fromName) ($($em.received))"; style = 'small'; tone = 'dim' })
            $cardChildren.Add(@{ type = 'text'; text = [string]$em.preview; style = 'small' })
            $cardChildren.Add(@{
                type = 'row'
                children = @(
                    @{ type = 'button'; label = 'Open in Outlook'; action = "open:$idx" }
                )
            })
            $subjTitle = if ([string]::IsNullOrWhiteSpace($em.subject)) { '(no subject)' } else { [string]$em.subject }
            $children.Add(@{
                type = 'card'
                key = "mail-$idx"
                title = $subjTitle
                children = $cardChildren.ToArray()
            })
        }
    }
    return @{ type = 'column'; children = $children.ToArray() }
}

function Invoke-ToolRequest {
    param([string]$Name, $Args)

    $a = if ($Args) { $Args } else { [pscustomobject]@{} }
    function ArgVal($Key, $Default = $null) {
        if ($a.PSObject.Properties.Name -contains $Key) { return $a.$Key }
        return $Default
    }

    switch ($Name) {
        'outlook_status' {
            $res = Invoke-OutlookStatus
            $script:CachedStatus = $res
            return ($res | ConvertTo-Json -Depth 6)
        }
        'outlook_folders' {
            $res = Invoke-OutlookFolders
            return ($res | ConvertTo-Json -Depth 6)
        }
        'outlook_search' {
            $folder = [string](ArgVal 'folder' 'Inbox')
            $from = [string](ArgVal 'from' '')
            $to = [string](ArgVal 'to' '')
            $subj = [string](ArgVal 'subject' '')
            $txt = [string](ArgVal 'text' '')
            $unread = ArgVal 'unread' $null
            $daysRaw = ArgVal 'days_back' $null
            $days = if ($null -ne $daysRaw) { [int]$daysRaw } else { $script:DefaultDaysBack }
            $limRaw = ArgVal 'limit' 20
            $lim = if ($null -ne $limRaw) { [int]$limRaw } else { 20 }
            $res = Invoke-OutlookSearch -Folder $folder -From $from -To $to -Subject $subj -Text $txt -Unread $unread -DaysBack $days -Limit $lim -AllowSensitive $script:AllowSensitive
            return ($res | ConvertTo-Json -Depth 8)
        }
        'outlook_read' {
            $eid = [string](ArgVal 'entry_id' '')
            if (-not $eid) { throw 'entry_id is required.' }
            $start = [int](ArgVal 'start' 0)
            $maxC = [int](ArgVal 'max_chars' 12000)
            $res = Invoke-OutlookRead -EntryID $eid -Start $start -MaxChars $maxC -AllowSensitive $script:AllowSensitive
            return ($res | ConvertTo-Json -Depth 6)
        }
        'outlook_thread' {
            $eid = [string](ArgVal 'entry_id' '')
            if (-not $eid) { throw 'entry_id is required.' }
            $lim = [int](ArgVal 'limit' 15)
            $res = Invoke-OutlookThread -EntryID $eid -Limit $lim -AllowSensitive $script:AllowSensitive
            return ($res | ConvertTo-Json -Depth 8)
        }
        'outlook_open' {
            $eid = [string](ArgVal 'entry_id' '')
            if (-not $eid) { throw 'entry_id is required.' }
            $res = Invoke-OutlookOpen -EntryID $eid
            return ($res | ConvertTo-Json -Depth 4)
        }
        'outlook_draft_reply' {
            $eid = [string](ArgVal 'entry_id' '')
            $body = [string](ArgVal 'body' '')
            $replyAll = [bool](ArgVal 'reply_all' $false)
            $subj = [string](ArgVal 'subject' '')
            $openWin = [bool](ArgVal 'open_window' $false)
            $res = Invoke-OutlookDraftReply -EntryID $eid -Body $body -ReplyAll $replyAll -Subject $subj -OpenWindow $openWin
            return ($res | ConvertTo-Json -Depth 4)
        }
        'outlook_draft_new' {
            $to = [string](ArgVal 'to' '')
            $cc = [string](ArgVal 'cc' '')
            $bcc = [string](ArgVal 'bcc' '')
            $subj = [string](ArgVal 'subject' '')
            $body = [string](ArgVal 'body' '')
            $openWin = [bool](ArgVal 'open_window' $false)
            $res = Invoke-OutlookDraftNew -To $to -Cc $cc -Bcc $bcc -Subject $subj -Body $body -OpenWindow $openWin
            return ($res | ConvertTo-Json -Depth 4)
        }
        'outlook_mark' {
            $eids = @(ArgVal 'entry_ids' @() | ForEach-Object { [string]$_ })
            $act = [string](ArgVal 'action' '')
            $val = [string](ArgVal 'value' '')
            $res = Invoke-OutlookMark -EntryIDs $eids -Action $act -Value $val
            return ($res | ConvertTo-Json -Depth 4)
        }
        'outlook_send' {
            $res = Invoke-OutlookSend `
                -To ([string](ArgVal 'to' '')) `
                -Cc ([string](ArgVal 'cc' '')) `
                -Bcc ([string](ArgVal 'bcc' '')) `
                -Subject ([string](ArgVal 'subject' '')) `
                -Body ([string](ArgVal 'body' '')) `
                -DraftEntryID ([string](ArgVal 'draft_entry_id' '')) `
                -InReplyTo ([string](ArgVal 'in_reply_to' ''))
            return ($res | ConvertTo-Json -Depth 4)
        }
        default {
            throw "Unknown tool '$Name'."
        }
    }
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $msg = $null
    try {
        $msg = $line | ConvertFrom-Json
    } catch {
        [Console]::Error.WriteLine("outlook-classic: bad JSON from byob: $($_.Exception.Message)")
        continue
    }

    switch ($msg.type) {
        'init' {
            if ($msg.settings) {
                $script:Settings = $msg.settings
                if ($msg.settings.PSObject.Properties.Name -contains 'DEFAULT_DAYS_BACK') {
                    try { $script:DefaultDaysBack = [int]$msg.settings.DEFAULT_DAYS_BACK } catch { }
                }
                if ($msg.settings.PSObject.Properties.Name -contains 'ALLOW_SENSITIVE_BODY') {
                    $v = [string]$msg.settings.ALLOW_SENSITIVE_BODY
                    $script:AllowSensitive = ($v -eq 'true' -or $v -eq '1' -or $v -eq 'True')
                }
            }
        }
        'shutdown' {
            break
        }
        'request' {
            $reqId = $msg.id
            try {
                if ($msg.method -eq 'tool') {
                    $text = Invoke-ToolRequest -Name ([string]$msg.params.name) -Args $msg.params.args
                    Send-ByobReply -Id $reqId -Result $text
                } elseif ($msg.method -eq 'view') {
                    $vid = [string]$msg.params.view
                    if ($vid -eq 'chip') {
                        Send-ByobReply -Id $reqId -Result @{ view = (Get-ChipView) }
                    } else {
                        Send-ByobReply -Id $reqId -Result @{ view = (Get-InboxPaneView) }
                    }
                } else {
                    Send-ByobError -Id $reqId -Message "Unsupported method '$($msg.method)'."
                }
            } catch {
                Send-ByobError -Id $reqId -Message $_.Exception.Message
            }
        }
        'event' {
            if ($msg.event -eq 'view') {
                $action = [string]$msg.action
                try {
                    if ($action -eq 'refresh') {
                        $script:CachedStatus = Invoke-OutlookStatus
                        $script:CachedInbox = $null
                    } elseif ($action -match '^open:(\d+)$') {
                        $idx = [int]$Matches[1] - 1
                        $emails = if ($script:CachedInbox) { @($script:CachedInbox.emails) } else { @() }
                        if ($idx -ge 0 -and $idx -lt $emails.Count) {
                            [void](Invoke-OutlookOpen -EntryID ([string]$emails[$idx].entryId))
                        }
                    }
                    Send-ByobMsg @{ type = 'view'; id = 'inbox'; key = ''; view = (Get-InboxPaneView) }
                    Send-ByobMsg @{ type = 'view'; id = 'chip'; key = ''; view = (Get-ChipView) }
                } catch {
                    Send-ByobMsg @{ type = 'notice'; level = 'error'; text = $_.Exception.Message }
                }
            }
        }
    }
}
