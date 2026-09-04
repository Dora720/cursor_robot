# Confirm via Feishu (wait) OR Cursor Agent window (ask after timeout / if Feishu unreachable).
# No OS popup. Feishu allow => permission allow. Timeout => permission ask (Agent window).
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
$waitSeconds = 90
Get-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
    $line = $_.Trim().TrimStart([char]0xFEFF)
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $i = $line.IndexOf("=")
        $k = $line.Substring(0, $i).Trim().TrimStart([char]0xFEFF)
        $v = $line.Substring($i + 1).Trim()
        if ($k -eq "NOTIFY_URL") { $url = $v }
        if ($k -eq "NOTIFY_TOKEN") { $token = $v }
        if ($k -eq "CONFIRM_WAIT_SECONDS") {
            $n = 0
            if ([int]::TryParse($v, [ref]$n) -and $n -ge 0) { $waitSeconds = $n }
        }
    }
}
if (-not $url -or -not $token) {
    Write-Log "confirm missing notify.env -> Agent window ask"
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
if (-not $confirmId) {
    Write-Log "confirm_id missing -> Agent window ask"
    Write-Perm "ask"
    exit 0
}

# waitSeconds=0 => skip Feishu wait, use Agent window only (card still sent).
if ($waitSeconds -le 0) {
    Write-Log "CONFIRM_WAIT_SECONDS=0 -> Agent window ask"
    Write-Perm "ask"
    exit 0
}

$statusUrl = ($url -replace "/local-notify$", "/local-confirm/status/") + $confirmId
$deadline = (Get-Date).AddSeconds($waitSeconds)
$decision = "pending"
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 1
    $stOut = & curl.exe -sS -m 8 -H "X-Notify-Token: $token" $statusUrl 2>&1
    try {
        $st = $stOut | ConvertFrom-Json
        $decision = [string]$st.status
    } catch { $decision = "pending" }
    if ($decision -and $decision -ne "pending" -and $decision -ne "unknown") { break }
}
Write-Log ("confirm decision={0} id={1} waited={2}s" -f $decision, $confirmId, $waitSeconds)

if ($decision -eq "allow") { Write-Perm "allow"; exit 0 }
if ($decision -eq "deny") { Write-Perm "deny"; exit 0 }

# Feishu not answered: hand off to Cursor Agent window confirm.
try {
    $pushUrl = $url -replace "/local-notify$", "/local-confirm/decide"
    $pushObj = @{ confirm_id = $confirmId; decision = "cursor" } | ConvertTo-Json -Compress
    $pushTmp = Join-Path $env:TEMP "cursor-feishu-confirm-cursor.json"
    [System.IO.File]::WriteAllText($pushTmp, $pushObj, [System.Text.UTF8Encoding]::new($false))
    $null = & curl.exe -sS -m 8 -X POST $pushUrl -H "Content-Type: application/json" -H "X-Notify-Token: $token" --data-binary "@$pushTmp" 2>&1
} catch {}

Write-Perm "ask"
exit 0
