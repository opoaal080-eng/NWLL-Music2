@echo off
setlocal
chcp 65001 >nul
set "TARGET=C:\Nightwell Music\nightwell-music"
if not "%~1"=="" set "TARGET=%~1"
echo Nightwell Music: последние изменения исполнителей и качества SoundCloud
echo Проверка папки: "%TARGET%"
if exist "%TARGET%\.venv\Scripts\python.exe" (
    "%TARGET%\.venv\Scripts\python.exe" "%~dp0installer.py" --check --target "%TARGET%"
) else (
    py -3 "%~dp0installer.py" --check --target "%TARGET%"
)
if errorlevel 1 (
    echo Установка отменена: версия сервера несовместима или файлы отсутствуют.
    pause
    exit /b 1
)
echo.
choice /C YN /M "Ты остановил сервер? Установить обновление"
if errorlevel 2 exit /b 1
if exist "%TARGET%\.venv\Scripts\python.exe" (
    "%TARGET%\.venv\Scripts\python.exe" "%~dp0installer.py" --target "%TARGET%"
) else (
    py -3 "%~dp0installer.py" --target "%TARGET%"
)
if errorlevel 1 (
    echo Установка остановлена, исходники проверены на совместимость.
    pause
    exit /b 1
)
echo Перезапусти Nightwell Music прежним батником.
pause
