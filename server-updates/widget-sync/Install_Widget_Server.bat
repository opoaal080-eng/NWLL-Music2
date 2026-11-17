@echo off
chcp 65001 >nul
cd /d "%~dp0"
set "TARGET=C:\Nightwell Music\nightwell-music"
if not "%~1"=="" set "TARGET=%~1"
py -3 install_widget_sync.py --target "%TARGET%"
echo.
echo Перезапусти Nightwell Music Server штатным способом.
pause
