@echo off
echo === Hollow Multi-Instance Test Setup ===
echo.

set "RELEASE_DIR=%~dp0..\build\windows\x64\runner\Release"
set "INSTANCES_DIR=%~dp0"

if not exist "%RELEASE_DIR%\hollow.exe" (
    echo ERROR: Release build not found at %RELEASE_DIR%
    echo Run "flutter build windows" first.
    pause
    exit /b 1
)

echo Copying Release build to 6 instance folders...

for %%i in (1 2 3 4 5 6) do (
    if not exist "%INSTANCES_DIR%instance_%%i" (
        echo Creating instance_%%i...
        xcopy "%RELEASE_DIR%" "%INSTANCES_DIR%instance_%%i\" /E /I /Q >nul
    ) else (
        echo Updating instance_%%i...
        xcopy "%RELEASE_DIR%" "%INSTANCES_DIR%instance_%%i\" /E /I /Q /Y >nul
    )
)

echo.
echo Creating data directories...
for %%i in (1 2 3 4 5 6) do (
    if not exist "%INSTANCES_DIR%data_%%i" mkdir "%INSTANCES_DIR%data_%%i"
)

echo.
echo === Setup complete! ===
echo.
echo Use "launch_all.bat" to start all 6 instances.
echo Use "launch_one.bat N" to start instance N (1-6).
echo Use "kill_all.bat" to stop all instances.
echo.
pause
