@echo off
setlocal
chcp 65001 >nul
set "SERVER=C:\Nightwell Music\nightwell-music"
if not "%~1"=="" set "SERVER=%~1"
echo.
echo Nightwell Music - безопасное обновление сервера
echo Папка: "%SERVER%"
echo.
if exist "%SERVER%\.venv\Scripts\python.exe" (
    "%SERVER%\.venv\Scripts\python.exe" "%~dp0server-updates\unified-install\install_all.py" --target "%SERVER%"
) else (
    py -3 "%~dp0server-updates\unified-install\install_all.py" --target "%SERVER%"
)
if errorlevel 1 (
    echo.
    echo Установка отменена. Проверь сообщение об ошибке, исходный сервер должен остаться без изменений.
    pause
    exit /b 1
)
echo.
echo Перезапусти свой существующий сервер штатным батником.
pause
