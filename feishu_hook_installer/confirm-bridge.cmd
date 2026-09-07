@echo off
REM Keep a single peer-confirm bridge running for local Agent UI (incl. Remote SSH).
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0confirm-bridge.ps1"
