@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Uninstalling Cursor Feishu hook...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-hooks.ps1"
echo.
pause
