@echo off
set LOG=%~dp0notify-feishu.log
echo [%date% %time%] cmd invoked event=confirm computer=%COMPUTERNAME% >> "%LOG%"
rem -STA is required for WinForms Allow/Deny dialog
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0confirm-feishu.ps1"
