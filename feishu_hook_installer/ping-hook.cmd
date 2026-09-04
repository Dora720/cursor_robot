@echo off
set LOG=%~dp0notify-feishu.log
echo [%date% %time%] cmd invoked event=sessionStart computer=%COMPUTERNAME% user=%USERNAME% >> "%LOG%"
