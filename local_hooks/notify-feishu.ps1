# Notify Feishu when a local Cursor Agent turn stops.
# Reads NOTIFY_URL / NOTIFY_TOKEN from notify.env next to this script.
$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Output "{}"
    exit 0
}

try {
    $data = $raw | ConvertFrom-Json
} catch {
    Write-Output "{}"
    exit 0
}

$status = [string]$data.status
if ($status -eq "aborted") {
    Write-Output "{}"
    exit 0
}

$configPath = Join-Path $PSScriptRoot "notify.env"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Output "{}"
    exit 0
}

$url = ""
$token = ""
Get-Content -LiteralPath $configPath -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $i = $line.IndexOf("=")
        $k = $line.Substring(0, $i).Trim()
        $v = $line.Substring($i + 1).Trim()
        if ($k -eq "NOTIFY_URL") { $url = $v }
        if ($k -eq "NOTIFY_TOKEN") { $token = $v }
    }
}

if (-not $url -or -not $token) {
    Write-Output "{}"
    exit 0
}

$workspace = ""
if ($data.workspace_roots) {
    $workspace = [string]@($data.workspace_roots)[0]
}

$model = [string]$data.model
$summary = "本地 Cursor Agent 执行完成"
if ($model) { $summary = "本地 Cursor Agent 执行完成 ($model)" }

$bodyObj = @{
    event            = "statusChange"
    id               = [string]$data.conversation_id
    status           = $status
    summary          = $summary
    machine          = $env:COMPUTERNAME
    workspace        = $workspace
    workspace_roots  = @($data.workspace_roots)
    model            = $model
}
$json = $bodyObj | ConvertTo-Json -Compress
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

try {
    Invoke-WebRequest -Uri $url -Method POST -Headers @{ "X-Notify-Token" = $token } `
        -ContentType "application/json; charset=utf-8" -Body $bodyBytes -TimeoutSec 120 -UseBasicParsing | Out-Null
} catch {
    # Fail open so a notify outage does not block the agent.
}

Write-Output "{}"
exit 0
