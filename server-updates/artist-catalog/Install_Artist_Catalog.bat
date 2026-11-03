@echo off
setlocal
set "SERVER=C:\Nightwell Music\nightwell-music"
if not "%~1"=="" set "SERVER=%~1"
echo Установка каталога исполнителей Nightwell Music в "%SERVER%"
py -3 "%~dp0install_artist_catalog.py" --target "%SERVER%"
if errorlevel 1 (
  echo Установка прервана, ничего не развёрнуто. Проверь текст ошибки.
  pause
  exit /b 1
)
echo Обновление установлено. Перезапусти существующий сервер.
pause
