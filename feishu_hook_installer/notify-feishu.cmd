@echo off
set LOG=%~dp0notify-feishu.log
echo [%date% %time%] cmd invoked event=stop computer=%COMPUTERNAME% user=%USERNAME% >> "%LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0notify-feishu.ps1"
echo [%date% %time%] cmd finished exit=%ERRORLEVEL% >> "%LOG%"
