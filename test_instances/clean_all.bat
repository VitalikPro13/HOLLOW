@echo off
echo === WARNING: This will delete ALL instance data (identities, messages, settings) ===
echo Press Ctrl+C to cancel, or...
pause

set "INSTANCES_DIR=%~dp0"

echo Cleaning data directories...
for %%i in (1 2 3 4 5 6) do (
    if exist "%INSTANCES_DIR%data_%%i" (
        rmdir /s /q "%INSTANCES_DIR%data_%%i"
        mkdir "%INSTANCES_DIR%data_%%i"
        echo Cleaned data_%%i
    )
)

echo.
echo All instance data wiped. Each will generate a fresh identity on next launch.
pause
