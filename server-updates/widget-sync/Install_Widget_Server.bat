@echo off
setlocal DisableDelayedExpansion
set "SCRIPT=%~dp0install_widget_sync.py"
if not exist "%SCRIPT%" (
  echo ERROR: install_widget_sync.py not found. Extract the entire ZIP first.
  goto end
)
set "TARGET=%~1"
:choose_target
if not defined TARGET (
  if exist "C:\Nightwell Music\nightwell-music\app.py" (
    set "TARGET=C:\Nightwell Music\nightwell-music"
  ) else (
    echo Server directory was not found automatically.
    echo Open the folder that contains the running server's app.py.
    set /p "TARGET=Paste full path to that folder: "
  )
)
set "TARGET=%TARGET:"=%"
if not exist "%TARGET%\app.py" (
  echo.
  echo ERROR: app.py was not found in "%TARGET%".
  echo Please choose the folder containing your active server app.py.
  set "TARGET="
  goto choose_target
)
echo.
echo INSTALLATION for "%TARGET%"
echo.
where py >nul 2>nul
if not errorlevel 1 (
  py -3 --version >nul 2>nul
  if not errorlevel 1 goto use_launcher
)
where python >nul 2>nul
if errorlevel 1 (
  echo ERROR: Python 3 not found. Install Python or add it to PATH.
  goto end
)
python "%SCRIPT%" --target "%TARGET%"
goto finished
:use_launcher
py -3 "%SCRIPT%" --target "%TARGET%"
:finished
if errorlevel 1 (
  echo.
  echo ERROR: INSTALLATION failed. See the message above.
) else (
  echo.
  echo INSTALLATION finished successfully.
)
:end
echo.
pause
endlocal
