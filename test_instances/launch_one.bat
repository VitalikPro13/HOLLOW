@echo off
if "%1"=="" (
    echo Usage: launch_one.bat [1-6]
    exit /b 1
)

set "INSTANCES_DIR=%~dp0"
set "NUM=%1"

if not exist "%INSTANCES_DIR%instance_%NUM%\hollow.exe" (
    echo ERROR: Instance %NUM% not found. Run setup.bat first.
    exit /b 1
)

echo Launching Hollow instance %NUM%...
set "HOLLOW_DATA_DIR=%INSTANCES_DIR%data_%NUM%\hollow"
set "APPDATA=%INSTANCES_DIR%data_%NUM%"
start "" "%INSTANCES_DIR%instance_%NUM%\hollow.exe"
echo Instance %NUM% started (data: %HOLLOW_DATA_DIR%)
