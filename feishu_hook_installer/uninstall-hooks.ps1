# Uninstall Cursor Feishu hooks on this Windows PC.
# Double-click uninstall.cmd, or run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall-hooks.ps1
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$cursorDir = Join-Path $env:USERPROFILE ".cursor"
$hookDir = Join-Path $cursorDir "hooks"
$hooksJson = Join-Path $cursorDir "hooks.json"
$logPath = Join-Path $hookDir "notify-feishu.log"

Write-Host "Uninstalling Cursor Feishu hook..."
Write-Host "  computer : $env:COMPUTERNAME"
Write-Host "  user     : $env:USERNAME"
Write-Host ""

# Stop confirm-bridge
$lockPath = Join-Path $env:TEMP "cursor-feishu-confirm-bridge.lock"
try {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and ($_.CommandLine -like "*confirm-bridge.ps1*") } |
        ForEach-Object {
            Write-Host ("Stopping bridge pid={0}" -f $_.ProcessId)
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
} catch {}
Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue

# Remove Startup shortcut created by install
$startupCmd = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\cursor-feishu-confirm-bridge.cmd"
if (Test-Path -LiteralPath $startupCmd) {
    Remove-Item -LiteralPath $startupCmd -Force -ErrorAction SilentlyContinue
    Write-Host "Removed Startup shortcut"
}

# Our install overwrites hooks.json; remove it (backup first).
if (Test-Path -LiteralPath $hooksJson) {
    $bak = Join-Path $cursorDir ("hooks.json.bak-uninstall-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    try {
        Copy-Item -LiteralPath $hooksJson -Destination $bak -Force
        Write-Host "Backed up hooks.json -> $bak"
    } catch {}
    Remove-Item -LiteralPath $hooksJson -Force -ErrorAction SilentlyContinue
    Write-Host "Removed hooks.json"
}

$files = @(
    "notify-feishu.ps1", "notify-feishu.cmd",
    "ping-hook.cmd",
    "confirm-feishu.ps1", "confirm-feishu.cmd", "confirm-feishu-watch.ps1",
    "confirm-bridge.ps1", "confirm-bridge.cmd", "start-confirm-bridge.cmd",
    "resolve-chat-name.py",
    "diagnose.ps1",
    "manage-allowlist.ps1", "manage-allowlist.cmd",
    "notify-feishu.log",
    "notify.env"
)
$removed = 0
foreach ($name in $files) {
    $path = Join-Path $hookDir $name
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        $removed++
    }
}
# Temp watch locks
Get-ChildItem -Path $env:TEMP -Filter "cursor-confirm-watch-*.lock" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:TEMP -Filter "cursor-feishu-*.json" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Uninstall OK"
Write-Host "  removed hook files : $removed"
Write-Host "  note: always-run\shared.json kept (edit/delete manually if needed)"
Write-Host "  hooks dir          : $hookDir (kept if other files remain)"
Write-Host ""
Write-Host "Next:"
Write-Host "  1. Fully quit Cursor (tray icon too) and reopen."
Write-Host "  2. Settings -> Hooks should no longer list Feishu notify/confirm."
Write-Host ""
