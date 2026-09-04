# Install user-level Cursor hooks with absolute Windows paths.
# Run this ON the machine that should send Feishu notifications:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-hooks.ps1
$ErrorActionPreference = "Stop"

$srcDir = $PSScriptRoot
$cursorDir = Join-Path $env:USERPROFILE ".cursor"
$hookDir = Join-Path $cursorDir "hooks"
New-Item -ItemType Directory -Force -Path $hookDir | Out-Null

$files = @(
    "notify-feishu.ps1",
    "notify-feishu.cmd",
    "ping-hook.cmd",
    "notify.env.example"
)
foreach ($name in $files) {
    $from = Join-Path $srcDir $name
    if (Test-Path -LiteralPath $from) {
        Copy-Item -LiteralPath $from -Destination (Join-Path $hookDir $name) -Force
    }
}

$envSrc = Join-Path $srcDir "notify.env"
$envDst = Join-Path $hookDir "notify.env"
if ((Test-Path -LiteralPath $envSrc) -and -not (Test-Path -LiteralPath $envDst)) {
    Copy-Item -LiteralPath $envSrc -Destination $envDst -Force
}

if (-not (Test-Path -LiteralPath $envDst)) {
    Write-Host "WARNING: $envDst is missing. Copy notify.env from the other PC."
}

$ping = Join-Path $hookDir "ping-hook.cmd"
$notify = Join-Path $hookDir "notify-feishu.cmd"
$hooksJson = Join-Path $cursorDir "hooks.json"

# Absolute cmd.exe paths so Cursor does not depend on cwd or ./hooks/...
$config = @{
    version = 1
    hooks = @{
        sessionStart = @(
            @{
                command = "cmd.exe /c `"$ping`""
                timeout = 15
            }
        )
        stop = @(
            @{
                command = "cmd.exe /c `"$notify`""
                timeout = 120
            }
        )
    }
}

$json = $config | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($hooksJson, $json, [System.Text.UTF8Encoding]::new($false))

$logPath = Join-Path $hookDir "notify-feishu.log"
if (Test-Path -LiteralPath $logPath) {
    Remove-Item -LiteralPath $logPath -Force
}
$probe = "[{0}] install probe computer={1} user={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $env:COMPUTERNAME, $env:USERNAME
Add-Content -LiteralPath $logPath -Value $probe -Encoding UTF8

Write-Host ""
Write-Host "Installed."
Write-Host "  hooks.json : $hooksJson"
Write-Host "  scripts    : $hookDir"
Write-Host "  computer   : $env:COMPUTERNAME"
Write-Host "  user       : $env:USERNAME"
Write-Host ""
Write-Host "Next:"
Write-Host "  1. Confirm notify.env exists in $hookDir"
Write-Host "  2. Fully quit Cursor (tray icon too) and reopen"
Write-Host "  3. Cursor Settings -> search Hooks -> confirm sessionStart and stop are listed"
Write-Host "  4. After Cursor starts, $logPath should get a sessionStart line"
Write-Host ""
Write-Host "hooks.json content:"
Get-Content -LiteralPath $hooksJson -Raw
