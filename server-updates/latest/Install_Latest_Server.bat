@echo off
setlocal
chcp 65001 >nul
set "TARGET=C:\Nightwell Music\nightwell-music"
if not "%~1"=="" set "TARGET=%~1"
set "PY=py -3"
if exist "%TARGET%\.venv\Scripts\python.exe" set "PY=%TARGET%\.venv\Scripts\python.exe"
echo Nightwell Music: последние обновления исполнителей и качества звука
echo Проверяем папку: "%TARGET%"
%PY% "%~dp0installer.py" --check --target "%TARGET%"
if errorlevel 1 (
  echo Установка отменена. Исходные файлы не изменены.
  pause
  exit /b 1
)
echo.
choice /C YN /M "Остановлен ли текущий сервер? Установить обновления"
if errorlevel 2 exit /b 1
%PY% "%~dp0installer.py" --target "%TARGET%"
if errorlevel 1 (
  echo Установка остановлена, проверь сообщение.
  pause
  exit /b 1
)
echo Перезапусти сервер СВОИМ прежним батником.
pause
