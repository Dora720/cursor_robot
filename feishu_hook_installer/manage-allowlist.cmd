@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0manage-allowlist.ps1" %*
