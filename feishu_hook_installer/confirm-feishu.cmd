@echo off
set LOG=%~dp0notify-feishu.log
echo [%date% %time%] cmd invoked event=confirm computer=%COMPUTERNAME% >> "%LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0confirm-feishu.ps1"
