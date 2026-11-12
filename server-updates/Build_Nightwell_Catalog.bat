@echo off
setlocal
cd /d "%~dp0"
echo Nightwell Music - Audius metadata index
echo No audio files will be downloaded.
py -3 catalog_metadata_index.py index --sources audius --db "%~dp0nightwell_catalog.sqlite" --max-tracks 50000 --max-pages 300
if errorlevel 1 (
  echo Catalog indexing stopped with an error. Run again to resume.
  pause
  exit /b 1
)
py -3 catalog_metadata_index.py stats --db "%~dp0nightwell_catalog.sqlite"
echo Done. Run Start_Nightwell_Catalog_Search.bat for local lookup.
pause
