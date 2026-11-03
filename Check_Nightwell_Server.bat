@echo off
setlocal
chcp 65001 >nul
set "SERVER=C:\Nightwell Music\nightwell-music"
if not "%~1"=="" set "SERVER=%~1"
if exist "%SERVER%\.venv\Scripts\python.exe" (
    "%SERVER%\.venv\Scripts\python.exe" "%~dp0server-updates\unified-install\install_all.py" --check --target "%SERVER%"
) else (
    py -3 "%~dp0server-updates\unified-install\install_all.py" --check --target "%SERVER%"
)
pause
