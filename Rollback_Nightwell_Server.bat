@echo off
setlocal
chcp 65001 >nul
if "%~1"=="" (
    echo Перетащи папку резервной копии из backups на этот bat
    echo либо запусти: Rollback_Nightwell_Server.bat "C:\путь\к\backups\nightwell-server-update-..."
    pause
    exit /b 1
)
set "BACKUP=%~1"
for %%I in ("%BACKUP%\..\..") do set "TARGET=%%~fI"
if exist "%TARGET%\.venv\Scripts\python.exe" (
    "%TARGET%\.venv\Scripts\python.exe" "%~dp0server-updates\unified-install\install_all.py" --rollback "%BACKUP%"
) else (
    py -3 "%~dp0server-updates\unified-install\install_all.py" --rollback "%BACKUP%"
)
if errorlevel 1 echo Откат не выполнен. Если файлы менялись после установки, восстановление вручную.
pause
