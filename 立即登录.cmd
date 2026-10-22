@echo off
setlocal
cd /d "%~dp0"
echo Connecting to CUMT campus network (one-shot)...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Connect-CampusNet.ps1" -VerboseLog
echo.
pause
