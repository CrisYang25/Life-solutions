@echo off
setlocal
set "LOG=%LOCALAPPDATA%\CUMTNet\campusnet.log"
if exist "%LOG%" (
    start "" notepad "%LOG%"
) else (
    echo Log file not found:
    echo %LOG%
    echo.
    echo Run "Connect-CampusNet.ps1" or "Install-AutoLogin.ps1" first.
    pause
)
