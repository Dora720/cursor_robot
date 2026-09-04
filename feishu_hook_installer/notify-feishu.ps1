# Notify Feishu when a local Cursor Agent turn stops.
# Logs to notify-feishu.log beside this script for troubleshooting.
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
    return [string]$raw
}

Write-Log "hook start pid=$PID computer=$env:COMPUTERNAME"
$raw = Read-HookInput
Write-Log ("stdin_len={0} preview={1}" -f $raw.Length, (($raw -replace "\s+", " ").Substring(0, [Math]::Min(300, $raw.Length))))

if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Log "empty stdin, skip"
    Write-Output "{}"
    exit 0
}

try {
    $data = $raw | ConvertFrom-Json
} catch {
    Write-Log ("json parse failed: {0}" -f $_.Exception.Message)
    Write-Output "{}"
    exit 0
}

$eventName = [string]$data.hook_event_name
if ($eventName -eq "sessionEnd") {
    Write-Log "skip sessionEnd (stop hook already notifies)"
    Write-Output "{}"
    exit 0
}
$status = [string]$data.status
if (-not $status) { $status = [string]$data.final_status }
if ($status -eq "aborted" -or $status -eq "window_close" -or $status -eq "user_close") {
    Write-Log ("skip status={0} event={1}" -f $status, $eventName)
    Write-Output "{}"
    exit 0
}
if (-not $status) { $status = "completed" }

$configPath = Join-Path $hookDir "notify.env"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Log "missing notify.env"
    Write-Output "{}"
    exit 0
}

$url = ""
$token = ""
Get-Content -LiteralPath $configPath -Encoding UTF8 | ForEach-Object {
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
    Write-Log ("bad notify.env url_len={0} token_len={1}" -f $url.Length, $token.Length)
    Write-Output "{}"
    exit 0
}

$workspace = ""
if ($data.workspace_roots) {
    $workspace = [string]@($data.workspace_roots)[0]
}

$model = [string]$data.model
$id = [string]$data.conversation_id
if (-not $id) { $id = [string]$data.session_id }
if (-not $id) { $id = "local-agent" }

# ASCII-only payload. Chinese text is composed on the server to avoid GBK mojibake.
$bodyObj = @{
    event     = "statusChange"
    id        = $id
    status    = $status
    machine   = $env:COMPUTERNAME
    workspace = $workspace
    model     = $model
}
$json = $bodyObj | ConvertTo-Json -Compress
Write-Log ("post {0} id={1} status={2}" -f $url, $id, $status)

$ok = $false
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($curl) {
    $tmp = Join-Path $env:TEMP "cursor-feishu-notify.json"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    $out = & curl.exe -sS -m 120 -w " HTTP:%{http_code}" -X POST $url `
        -H "Content-Type: application/json" -H "X-Notify-Token: $token" --data-binary "@$tmp" 2>&1
    Write-Log ("curl: {0}" -f $out)
    if ("$out" -match "HTTP:200" -or "$out" -match '"status":"sent"') { $ok = $true }
}

if (-not $ok) {
    try {
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $resp = Invoke-WebRequest -Uri $url -Method POST -Headers @{ "X-Notify-Token" = $token } `
            -ContentType "application/json; charset=utf-8" -Body $bodyBytes -TimeoutSec 120 -UseBasicParsing
        Write-Log ("iwr status={0} body={1}" -f $resp.StatusCode, $resp.Content)
        $ok = $true
    } catch {
        Write-Log ("iwr failed: {0}" -f $_.Exception.Message)
    }
}

Write-Log ("done ok={0}" -f $ok)
Write-Output "{}"
exit 0
