# One-click install for a Windows PC.
# Double-click install.cmd, or run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-hooks.ps1
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$srcDir = $PSScriptRoot
$cursorDir = Join-Path $env:USERPROFILE ".cursor"
$hookDir = Join-Path $cursorDir "hooks"
New-Item -ItemType Directory -Force -Path $hookDir | Out-Null

foreach ($name in @("notify-feishu.ps1", "notify-feishu.cmd", "ping-hook.cmd", "confirm-feishu.ps1", "confirm-feishu.cmd", "confirm-feishu-watch.ps1")) {
    $from = Join-Path $srcDir $name
    if (-not (Test-Path -LiteralPath $from)) {
        throw "Missing $from"
    }
    Copy-Item -LiteralPath $from -Destination (Join-Path $hookDir $name) -Force
}

$envDst = Join-Path $hookDir "notify.env"
$envSrc = Join-Path $srcDir "notify.env"
$envExample = Join-Path $srcDir "notify.env.example"
if (Test-Path -LiteralPath $envSrc) {
    Copy-Item -LiteralPath $envSrc -Destination $envDst -Force
} elseif (-not (Test-Path -LiteralPath $envDst)) {
    if (-not (Test-Path -LiteralPath $envExample)) {
        throw "Missing notify.env and notify.env.example"
    }
    Copy-Item -LiteralPath $envExample -Destination $envDst -Force
    Write-Host "Created notify.env from example. Fill NOTIFY_TOKEN before testing."
}

$ping = Join-Path $hookDir "ping-hook.cmd"
$notify = Join-Path $hookDir "notify-feishu.cmd"
$confirm = Join-Path $hookDir "confirm-feishu.cmd"
$hooksJson = Join-Path $cursorDir "hooks.json"
$config = @{
    version = 1
    hooks = @{
        sessionStart = @(
            @{ command = "cmd.exe /c `"$ping`""; timeout = 15 }
        )
        stop = @(
            @{ command = "cmd.exe /c `"$notify`""; timeout = 120 }
        )
        beforeShellExecution = @(
            @{ command = "cmd.exe /c `"$confirm`""; timeout = 120 }
        )
        preToolUse = @(
            @{ command = "cmd.exe /c `"$confirm`""; matcher = "Task"; timeout = 120 }
        )
    }
}
[System.IO.File]::WriteAllText(
    $hooksJson,
    ($config | ConvertTo-Json -Depth 6),
    [System.Text.UTF8Encoding]::new($false)
)

$logPath = Join-Path $hookDir "notify-feishu.log"
if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }
$probe = "[{0}] install probe computer={1} user={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $env:COMPUTERNAME, $env:USERNAME
Add-Content -LiteralPath $logPath -Value $probe -Encoding UTF8

Write-Host ""
Write-Host "Installed OK"
Write-Host "  computer   : $env:COMPUTERNAME"
Write-Host "  user       : $env:USERNAME"
Write-Host "  hooks.json : $hooksJson"
Write-Host "  scripts    : $hookDir"
Write-Host "  log        : $logPath"
Write-Host ""

$url = ""
$token = ""
Get-Content -LiteralPath $envDst -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim().TrimStart([char]0xFEFF)
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $i = $line.IndexOf("=")
        $k = $line.Substring(0, $i).Trim().TrimStart([char]0xFEFF)
        $v = $line.Substring($i + 1).Trim()
        if ($k -eq "NOTIFY_URL") { $url = $v }
        if ($k -eq "NOTIFY_TOKEN") { $token = $v }
    }
}
if ($url -and $token) {
    $payload = @{
        event = "statusChange"
        id = "install-self-test"
        status = "completed"
        machine = $env:COMPUTERNAME
        workspace = $env:USERNAME
        model = "install-test"
    } | ConvertTo-Json -Compress
    $tmp = Join-Path $env:TEMP "cursor-feishu-install-test.json"
    [System.IO.File]::WriteAllText($tmp, $payload, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Sending Feishu test from $env:COMPUTERNAME ..."
    $out = & curl.exe -sS -m 90 -w " HTTP:%{http_code}" -X POST $url `
        -H "Content-Type: application/json" -H "X-Notify-Token: $token" --data-binary "@$tmp" 2>&1
    Write-Host "test result: $out"
    Add-Content -LiteralPath $logPath -Value ("[{0}] install test {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $out) -Encoding UTF8
} else {
    Write-Host "WARNING: notify.env missing URL/token, skipped Feishu test"
}

# Do NOT add a broad terminalAllowlist here: peer confirm needs Agent ask UI to appear.
$perm = @{
    autoRun = @{
        allow_instructions = @()
        block_instructions = @()
    }
}
try {
    # Keep existing allowlists if user already customized them; only ensure file exists.
    if (Test-Path -LiteralPath $permPath) {
        Write-Host "Kept existing permissions.json : $permPath"
    } else {
        [System.IO.File]::WriteAllText(
            $permPath,
            ($perm | ConvertTo-Json -Depth 6),
            [System.Text.UTF8Encoding]::new($false)
        )
        Write-Host "Created permissions.json : $permPath"
    }
} catch {
    Write-Host ("WARNING: could not write permissions.json: {0}" -f $_.Exception.Message)
}

Write-Host ""
Write-Host "Next:"
Write-Host "  1. Fully quit Cursor (tray icon too), reopen."
Write-Host "  2. Confirm is peer: Feishu button OR Cursor Agent window — either works."
Write-Host "  3. Keep a Run Mode that still shows Agent approval UI when hook returns ask."
