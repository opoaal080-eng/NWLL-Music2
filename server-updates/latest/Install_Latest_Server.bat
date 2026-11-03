@echo off
setlocal DisableDelayedExpansion
set "SCRIPT=%~dp0Run-Latest-Server.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: Run-Latest-Server.ps1 is missing. Extract the ZIP first.
    pause
    exit /b 1
)
if "%~1"=="" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Install
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Install -Target "%~1"
)
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" echo Installation/check failed. See the error above.
pause
exit /b %RESULT%
