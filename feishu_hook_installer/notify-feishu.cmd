@echo off
set LOG=%~dp0notify-feishu.log
if exist "%~dp0log-rotate.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0log-rotate.ps1" -Path "%LOG%" >nul 2>&1
)
echo [%date% %time%] cmd invoked event=stop computer=%COMPUTERNAME% user=%USERNAME% >> "%LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0notify-feishu.ps1"
if exist "%~dp0log-rotate.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0log-rotate.ps1" -Path "%LOG%" >nul 2>&1
)
echo [%date% %time%] cmd finished exit=%ERRORLEVEL% >> "%LOG%"
