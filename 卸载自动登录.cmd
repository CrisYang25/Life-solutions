@echo off
setlocal
cd /d "%~dp0"
echo Uninstalling CUMT campus network auto-login...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-AutoLogin.ps1" -Uninstall
echo.
pause
