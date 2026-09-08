# Peer confirm: Cursor Agent window AND Feishu are equal.
# 1) Send Feishu card
# 2) Immediately return permission=ask (Agent window can confirm now)
# 3) Detached watcher: if Feishu confirms first, click Agent Allow/Deny button
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$hookDir = $PSScriptRoot
if (-not $hookDir) { $hookDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$logPath = Join-Path $hookDir "notify-feishu.log"
$logRotatePs1 = Join-Path $hookDir "log-rotate.ps1"
if (Test-Path -LiteralPath $logRotatePs1) {
    try { . $logRotatePs1 } catch {}
}

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try {
        if (Get-Command Rotate-NotifyLog -ErrorAction SilentlyContinue) {
            Rotate-NotifyLog -LogFile $logPath
        }
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {}
}

function Read-HookInput {
    $raw = ""
    try {
        $stdin = [Console]::OpenStandardInput()
        $reader = New-Object System.IO.StreamReader($stdin, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
    } catch {}
    if ([string]::IsNullOrWhiteSpace($raw)) {
        try { $raw = [string]($input | Out-String) } catch {}
    }
    if ($null -eq $raw) { $raw = "" }
    return [string]$raw.TrimStart([char]0xFEFF)
}

function Write-Perm([string]$perm) {
    [Console]::Out.WriteLine(('{{"permission":"{0}","continue":true}}' -f $perm))
}

$raw = Read-HookInput
Write-Log ("confirm hook stdin_len={0}" -f $raw.Length)
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Perm "ask"
    exit 0
}

try {
    $data = $raw | ConvertFrom-Json
} catch {
    Write-Log ("confirm json failed: {0}" -f $_.Exception.Message)
    Write-Perm "ask"
    exit 0
}

$configPath = Join-Path $hookDir "notify.env"
$url = ""
$token = ""
Get-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
    $line = $_.Trim().TrimStart([char]0xFEFF)
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $i = $line.IndexOf("=")
        $k = $line.Substring(0, $i).Trim().TrimStart([char]0xFEFF)
        $v = $line.Substring($i + 1).Trim()
        if ($k -eq "NOTIFY_URL") { $url = $v }
        if ($k -eq "NOTIFY_TOKEN") { $token = $v }
    }
}
if (-not $url -or -not $token) {
    Write-Log "confirm missing notify.env -> Agent window ask only"
    Write-Perm "ask"
    exit 0
}

$id = [string]$data.conversation_id
if (-not $id) { $id = [string]$data.session_id }
if (-not $id) { $id = "local-agent" }
$workspace = ""
if ($data.workspace_roots) { $workspace = [string]@($data.workspace_roots)[0] }
# Agents Window labels chats by workspace folder (e.g. cursor_robot), not composer auto-title.
$chatName = ""
if ($workspace) { $chatName = Split-Path -Path $workspace -Leaf }
if (-not $chatName) {
    $py = Join-Path $hookDir "resolve-chat-name.py"
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($python -and (Test-Path -LiteralPath $py)) {
        try {
            $prevPyEnc = $env:PYTHONIOENCODING
            $env:PYTHONIOENCODING = "utf-8"
            $out = & $python.Source -X utf8 $py $id 2>$null
            if ($prevPyEnc) { $env:PYTHONIOENCODING = $prevPyEnc } else { Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue }
            if ($out) { $chatName = ([string]$out).Trim() }
        } catch {}
    }
}
if (-not $chatName) { $chatName = [string]$data.conversation_title }
if (-not $chatName) { $chatName = [string]$data.title }
Write-Log ("confirm chat_name={0}" -f $chatName)

$detail = [string]$data.command
if (-not $detail) { $detail = [string]$data.tool_name }
if (-not $detail) { $detail = [string]$data.tool }
if (-not $detail) { $detail = "tool" }
Write-Log ("confirm detail={0}" -f $detail)

function Get-AlwaysRunCommands([string]$flagPath) {
    $list = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $flagPath)) { return $list }
    try {
        $raw = [System.IO.File]::ReadAllText($flagPath, [System.Text.Encoding]::UTF8).Trim()
        if (-not $raw) { return $list }
        try {
            $obj = $raw | ConvertFrom-Json
            foreach ($c in @($obj.commands)) {
                if ($c) { [void]$list.Add([string]$c) }
            }
        } catch {
            # Legacy plain conversation-id file: treat as session-wide allow-all marker.
            if ($raw -eq $id) { [void]$list.Add("*") }
        }
    } catch {}
    return $list
}

function Get-CmdFingerprint([string]$cmd) {
    if (-not $cmd) { return "" }
    $s = ($cmd -replace "\s+", " ").Trim()
    return $s
}

function Test-CmdAllowlisted([string]$cmd, $commands) {
    if (-not $cmd -or -not $commands -or $commands.Count -eq 0) { return $false }
    $cmd = Get-CmdFingerprint $cmd
    $cmdFirst = ($cmd -split " ", 2)[0]
    foreach ($c in $commands) {
        if (-not $c) { continue }
        if ($c -eq "*") { return $true }
        $c = Get-CmdFingerprint $c
        if ($cmd -eq $c) { return $true }
        if ($cmd.StartsWith($c) -or $c.StartsWith($cmd)) { return $true }
        $cFirst = ($c -split " ", 2)[0]
        # Same executable / tool name (e.g. git / python / Shell)
        if ($cmdFirst -and $cFirst -and ($cmdFirst -ieq $cFirst)) { return $true }
    }
    return $false
}

function Save-AlwaysRunCommands([string]$flagPath, $commands) {
    $dir = Split-Path -Parent $flagPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $uniq = @()
    foreach ($c in @($commands)) {
        if ($c -and ($uniq -notcontains $c)) { $uniq += [string]$c }
    }
    $json = (@{ commands = $uniq } | ConvertTo-Json -Compress)
    [System.IO.File]::WriteAllText($flagPath, $json, [System.Text.UTF8Encoding]::new($false))
}

# Local Always Run allowlist (per command) — persists across Agent turns until Skip.
$alwaysDir = Join-Path $hookDir "always-run"
$alwaysSafe = ($id -replace "[^\w\-]", "_")
$alwaysFlag = Join-Path $alwaysDir $alwaysSafe
$localCmds = Get-AlwaysRunCommands $alwaysFlag
if ($id -and (Test-CmdAllowlisted $detail $localCmds)) {
    Write-Log ("confirm local always-run match detail={0}" -f $detail)
    Write-Perm "allow"
    exit 0
}

$reqUrl = $url -replace "/local-notify$", "/local-confirm/request"
$reqObj = @{
    id              = $id
    conversation_id = $id
    workspace       = $workspace
    chat_name       = $chatName
    machine         = $env:COMPUTERNAME
    detail          = $detail
}
$reqJson = $reqObj | ConvertTo-Json -Compress
$tmp = Join-Path $env:TEMP "cursor-feishu-confirm-req.json"
[System.IO.File]::WriteAllText($tmp, $reqJson, [System.Text.UTF8Encoding]::new($false))
$reqOut = & curl.exe -sS -m 30 -X POST $reqUrl -H "Content-Type: application/json" -H "X-Notify-Token: $token" --data-binary "@$tmp" 2>&1
Write-Log ("confirm request: {0}" -f $reqOut)

$confirmId = ""
$autoAllow = $false
$messageId = ""
try {
    $reqParsed = $reqOut | ConvertFrom-Json
    $confirmId = [string]$reqParsed.confirm_id
    $messageId = [string]$reqParsed.message_id
    if ($reqParsed.auto_allow -eq $true -or [string]$reqParsed.status -eq "allow" -or [string]$reqParsed.status -eq "always") {
        $autoAllow = $true
    }
} catch {}

if ($autoAllow) {
    Write-Log "confirm auto_allow from server"
    try {
        $cmds = @()
        if ($reqParsed.allowlist) { $cmds = @($reqParsed.allowlist) }
        if ($reqParsed.matched) { $cmds += [string]$reqParsed.matched }
        if (-not $cmds -and $detail) { $cmds = @($detail) }
        if ($cmds.Count -gt 0) {
            Save-AlwaysRunCommands $alwaysFlag $cmds
            Write-Log ("synced local always-run allowlist conv={0} n={1}" -f $id, $cmds.Count)
        }
    } catch {}
    Write-Perm "allow"
    exit 0
}

# Always open Agent-window confirm immediately (peer with Feishu).
if ($confirmId) {
    $statusUrl = ($url -replace "/local-notify$", "/local-confirm/status/") + $confirmId
    $decideUrl = $url -replace "/local-notify$", "/local-confirm/decide"
    $watchPs1 = Join-Path $hookDir "confirm-feishu-watch.ps1"
    if (Test-Path -LiteralPath $watchPs1) {
        $arg = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $watchPs1,
            "-ConfirmId", $confirmId,
            "-StatusUrl", $statusUrl,
            "-Token", $token,
            "-DecideUrl", $decideUrl,
            "-LogPath", $logPath,
            "-ConversationId", $id,
            "-TimeoutSec", "120"
        )
        if ($messageId) {
            $arg += @("-MessageId", $messageId)
        }
        try {
            Start-Process -FilePath "powershell.exe" -ArgumentList $arg -WindowStyle Hidden | Out-Null
            Write-Log ("started feishu watch confirm_id={0} message_id={1} conv={2}" -f $confirmId, $messageId, $id)
        } catch {
            Write-Log ("start watch failed: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-Log "watch script missing; Feishu cannot auto-click Agent button"
    }
} else {
    Write-Log "confirm_id missing; Agent window ask only"
}

Write-Perm "ask"
exit 0
