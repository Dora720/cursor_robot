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

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch {}
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
$chatName = [string]$data.conversation_title
if (-not $chatName) { $chatName = [string]$data.title }
if (-not $chatName -and $workspace) { $chatName = Split-Path -Path $workspace -Leaf }
$detail = [string]$data.command
if (-not $detail) { $detail = [string]$data.tool_name }
if (-not $detail) { $detail = "tool" }

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
try {
    $reqParsed = $reqOut | ConvertFrom-Json
    $confirmId = [string]$reqParsed.confirm_id
    if ($reqParsed.auto_allow -eq $true -or [string]$reqParsed.status -eq "allow") {
        $autoAllow = $true
    }
} catch {}

if ($autoAllow) {
    Write-Log "confirm auto_allow from server"
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
            "-TimeoutSec", "120"
        )
        try {
            Start-Process -FilePath "powershell.exe" -ArgumentList $arg -WindowStyle Hidden | Out-Null
            Write-Log ("started feishu watch confirm_id={0}" -f $confirmId)
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
