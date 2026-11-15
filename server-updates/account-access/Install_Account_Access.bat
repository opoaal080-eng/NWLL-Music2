@echo off
chcp 65001 >nul
setlocal
if "%~1"=="" goto usage
if "%~2"=="" goto usage
py -3 "%~dp0install_account_access.py" --target "%~1" --adapter "%~2"
exit /b %errorlevel%
:usage
echo Usage: Install_Account_Access.bat "C:\Nightwell\Server" "C:\Nightwell\account_access_host.py"
exit /b 2
