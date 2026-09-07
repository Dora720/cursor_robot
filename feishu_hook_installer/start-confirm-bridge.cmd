@echo off
REM Start bridge if not already running (called from sessionStart / install).
set LOCK=%TEMP%\cursor-feishu-confirm-bridge.lock
if exist "%LOCK%" (
  exit /b 0
)
start "" /B powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0confirm-bridge.ps1"
exit /b 0
