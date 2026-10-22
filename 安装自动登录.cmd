@echo off
setlocal
cd /d "%~dp0"
echo Installing CUMT campus network auto-login...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-AutoLogin.ps1"
echo.
pause
