# Run on the PC that does NOT send Feishu notify.
# powershell -NoProfile -ExecutionPolicy Bypass -File .\diagnose.ps1
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$hookDir = Join-Path $env:USERPROFILE ".cursor\hooks"
$hooksJson = Join-Path $env:USERPROFILE ".cursor\hooks.json"
$envPath = Join-Path $hookDir "notify.env"
$logPath = Join-Path $hookDir "notify-feishu.log"
$notifyPs1 = Join-Path $hookDir "notify-feishu.ps1"

Write-Host "==== cursor_robot hook diagnose ===="
Write-Host ("computer : {0}" -f $env:COMPUTERNAME)
Write-Host ("user     : {0}" -f $env:USERNAME)
Write-Host ("hookDir  : {0}" -f $hookDir)
Write-Host ""

function Ok($b, $msg) {
    if ($b) { Write-Host "[OK] $msg" -ForegroundColor Green }
    else { Write-Host "[FAIL] $msg" -ForegroundColor Red }
}

Ok (Test-Path $hooksJson) "hooks.json exists"
Ok (Test-Path $notifyPs1) "notify-feishu.ps1 installed"
Ok (Test-Path $envPath) "notify.env exists"

$url = ""; $token = ""
if (Test-Path $envPath) {
    Get-Content -LiteralPath $envPath -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim().TrimStart([char]0xFEFF)
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $i = $line.IndexOf("=")
            $k = $line.Substring(0, $i).Trim()
            $v = $line.Substring($i + 1).Trim()
            if ($k -eq "NOTIFY_URL") { $url = $v }
            if ($k -eq "NOTIFY_TOKEN") { $token = $v }
        }
    }
    Ok ($url -like "https://*/local-notify") "NOTIFY_URL=$url"
    Ok ($token.Length -ge 16) ("NOTIFY_TOKEN length={0}" -f $token.Length)
}

if (Test-Path $hooksJson) {
    $raw = Get-Content -LiteralPath $hooksJson -Raw -Encoding UTF8
    Ok ($raw -match "notify-feishu") "hooks.json references notify-feishu"
    Ok ($raw -match "stop") "hooks.json has stop hook"
    Write-Host "----- hooks.json -----"
    Write-Host $raw
}

Write-Host ""
Write-Host "----- health -----"
$health = & curl.exe -sS -m 90 "https://cursor-robot.onrender.com/health" 2>&1
Write-Host $health
Ok (($health -as [string]) -match '"status"\s*:\s*"ok"') "Render /health ok"

if ($url -and $token) {
    Write-Host ""
    Write-Host "----- post test card -----"
    $payload = @{
        event = "statusChange"
        id = "diagnose-" + $env:COMPUTERNAME
        status = "completed"
        machine = $env:COMPUTERNAME
        workspace = "diagnose"
        model = "diagnose"
        chat_name = ("diagnose " + $env:COMPUTERNAME)
    } | ConvertTo-Json -Compress
    $tmp = Join-Path $env:TEMP "cursor-feishu-diagnose.json"
    [System.IO.File]::WriteAllText($tmp, $payload, [System.Text.UTF8Encoding]::new($false))
    $out = & curl.exe -sS -m 90 -w " HTTP:%{http_code}" -X POST $url `
        -H "Content-Type: application/json" -H "X-Notify-Token: $token" --data-binary "@$tmp" 2>&1
    Write-Host "result: $out"
    Ok (($out -as [string]) -match '"status"\s*:\s*"sent"' -or ($out -as [string]) -match "HTTP:200") "local-notify accepted"
}

Write-Host ""
Write-Host "----- recent log (last 30 lines) -----"
if (Test-Path $logPath) {
    Get-Content -LiteralPath $logPath -Tail 30 -Encoding UTF8
} else {
    Write-Host "(no notify-feishu.log — stop hook may never have run)"
}

Write-Host ""
Write-Host "Next:"
Write-Host "  1. If any [FAIL] above: copy latest feishu_hook_installer, fill notify.env, run install.cmd"
Write-Host "  2. Fully quit Cursor (tray too), reopen"
Write-Host "  3. Cursor Settings -> search Hooks -> ensure enabled"
Write-Host "  4. Run one local Agent; then re-check notify-feishu.log for 'hook start'"
