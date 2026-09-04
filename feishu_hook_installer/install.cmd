@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Installing Cursor Feishu hook...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-hooks.ps1"
echo.
pause
