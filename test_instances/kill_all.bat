@echo off
echo Stopping all Hollow instances...
taskkill /f /im hollow.exe 2>nul
echo Done.
pause
