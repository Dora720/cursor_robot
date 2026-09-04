# Run on the other machine to verify network + token without waiting for an Agent.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\test-notify.ps1
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$hookDir = $PSScriptRoot
$configPath = Join-Path $hookDir "notify.env"
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
if (-not $url -or -not $token) { throw "notify.env missing NOTIFY_URL or NOTIFY_TOKEN" }

$payload = @{
    event = "statusChange"
    id = "hook-self-test"
    status = "completed"
    summary = "另一台电脑 hook 自测"
    machine = $env:COMPUTERNAME
    workspace = $hookDir
} | ConvertTo-Json -Compress

Write-Host "POST $url"
$tmp = Join-Path $env:TEMP "cursor-feishu-selftest.json"
[System.IO.File]::WriteAllText($tmp, $payload, [System.Text.UTF8Encoding]::new($false))
& curl.exe -sS -m 120 -w "`nHTTP:%{http_code}`n" -X POST $url -H "Content-Type: application/json" -H "X-Notify-Token: $token" --data-binary "@$tmp"
