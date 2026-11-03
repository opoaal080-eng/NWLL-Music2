@echo off
setlocal
chcp 65001 >nul
set "TARGET=C:\Nightwell Music\nightwell-music"
if not "%~1"=="" set "TARGET=%~1"
if exist "%TARGET%\.venv\Scripts\python.exe" (
  "%TARGET%\.venv\Scripts\python.exe" "%~dp0installer.py" --check --target "%TARGET%"
) else (
  py -3 "%~dp0installer.py" --check --target "%TARGET%"
)
pause
