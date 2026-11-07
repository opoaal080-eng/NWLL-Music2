@echo off
setlocal
chcp 65001 >nul
set "PYTHONUTF8=1"
set "NW_AUDIUS_TARGET=C:\Nightwell Music\nightwell-music"
if not "%~1"=="" set "NW_AUDIUS_TARGET=%~1"
if not exist "%NW_AUDIUS_TARGET%\app.py" goto missing
if exist "%NW_AUDIUS_TARGET%\.venv\Scripts\python.exe" goto venv
where py >nul 2>nul
if not errorlevel 1 goto launcher
python "%~dp0install_audius.py" --target "%NW_AUDIUS_TARGET%"
set "NW_AUDIUS_RESULT=%ERRORLEVEL%"
goto finished
:venv
"%NW_AUDIUS_TARGET%\.venv\Scripts\python.exe" "%~dp0install_audius.py" --target "%NW_AUDIUS_TARGET%"
set "NW_AUDIUS_RESULT=%ERRORLEVEL%"
goto finished
:launcher
py -3 "%~dp0install_audius.py" --target "%NW_AUDIUS_TARGET%"
set "NW_AUDIUS_RESULT=%ERRORLEVEL%"
goto finished
:missing
echo Не найден app.py в папке "%NW_AUDIUS_TARGET%".
echo Запусти этот батник с путём к папке сервера первым аргументом.
set "NW_AUDIUS_RESULT=1"
:finished
echo.
pause
exit /b %NW_AUDIUS_RESULT%
