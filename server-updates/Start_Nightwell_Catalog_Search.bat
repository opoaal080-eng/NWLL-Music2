@echo off
setlocal
cd /d "%~dp0"
py -3 catalog_search_service.py --db "%~dp0nightwell_catalog.sqlite" --port 8099
if errorlevel 1 pause
