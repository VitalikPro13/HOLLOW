@echo off
echo === Launching 6 Hollow instances ===
echo.

set "INSTANCES_DIR=%~dp0"

for %%i in (1 2 3 4 5 6) do (
    if not exist "%INSTANCES_DIR%instance_%%i\hollow.exe" (
        echo ERROR: Instance %%i not found. Run setup.bat first.
        pause
        exit /b 1
    )
)

echo Starting instance 1...
set "HOLLOW_DATA_DIR=%INSTANCES_DIR%data_1\hollow"
set "APPDATA=%INSTANCES_DIR%data_1"
start "" "%INSTANCES_DIR%instance_1\hollow.exe"
timeout /t 2 /nobreak >nul

echo Starting instance 2...
set "HOLLOW_DATA_DIR=%INSTANCES_DIR%data_2\hollow"
set "APPDATA=%INSTANCES_DIR%data_2"
start "" "%INSTANCES_DIR%instance_2\hollow.exe"
timeout /t 2 /nobreak >nul

echo Starting instance 3...
set "HOLLOW_DATA_DIR=%INSTANCES_DIR%data_3\hollow"
set "APPDATA=%INSTANCES_DIR%data_3"
start "" "%INSTANCES_DIR%instance_3\hollow.exe"
timeout /t 2 /nobreak >nul

echo Starting instance 4...
set "HOLLOW_DATA_DIR=%INSTANCES_DIR%data_4\hollow"
set "APPDATA=%INSTANCES_DIR%data_4"
start "" "%INSTANCES_DIR%instance_4\hollow.exe"
timeout /t 2 /nobreak >nul

echo Starting instance 5...
set "HOLLOW_DATA_DIR=%INSTANCES_DIR%data_5\hollow"
set "APPDATA=%INSTANCES_DIR%data_5"
start "" "%INSTANCES_DIR%instance_5\hollow.exe"
timeout /t 2 /nobreak >nul

echo Starting instance 6...
set "HOLLOW_DATA_DIR=%INSTANCES_DIR%data_6\hollow"
set "APPDATA=%INSTANCES_DIR%data_6"
start "" "%INSTANCES_DIR%instance_6\hollow.exe"

echo.
echo === All 6 instances launched! ===
echo Each has its own identity and data directory.
echo Use "kill_all.bat" to stop them all.
echo.
pause
