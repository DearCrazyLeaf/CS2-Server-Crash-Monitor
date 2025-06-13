@echo off
chcp 437 > nul
setlocal enabledelayedexpansion

REM Set console title
title CS2 Server Monitor System

REM ========== Configuration ==========
REM Set your CS2 server path here (with quotes if path contains spaces)
set "CS2_SERVER_PATH=D:\CS2 Servers\MultiGames\steamapps\common\Counter-Strike Global Offensive\game\bin\win64"

REM Set your Animation DLL path here (leave empty to disable DLL monitoring)
set "ANIMATION_DLL_PATH="
REM ==================================

REM Get current directory and script path
set "CURRENT_DIR=%~dp0"
set "SCRIPT_PATH=%CURRENT_DIR%cs2_monitor_master.ps1"

echo ========================================
echo         CS2 Server Monitor System        
echo          By: DearCrazyLeaf
echo ========================================
echo.

REM Verify script exists
if not exist "%SCRIPT_PATH%" (
    echo ERROR: Cannot find cs2_monitor_master.ps1
    pause
    exit /b 1
)

REM Validate CS2 path
if not exist "%CS2_SERVER_PATH%" (
    echo ERROR: CS2 Server path not found: "%CS2_SERVER_PATH%"
    echo Please check the path in the script configuration
    pause
    exit /b 1
)

REM Convert backslashes to forward slashes
set "CS2_SERVER_PATH=%CS2_SERVER_PATH:\=/%"
set "SCRIPT_PATH=%SCRIPT_PATH:\=/%"

echo Server path: "%CS2_SERVER_PATH%"
if defined ANIMATION_DLL_PATH (
    echo Animation DLL path: "%ANIMATION_DLL_PATH%"
) else (
    echo Animation DLL monitoring: Disabled
)
echo.

echo Starting monitor...
echo.

REM Launch PowerShell script
if defined ANIMATION_DLL_PATH (
    set "ANIMATION_DLL_PATH=%ANIMATION_DLL_PATH:\=/%"
    powershell -NoExit -ExecutionPolicy Bypass -Command ^
        "& '%SCRIPT_PATH%' -CS2Path '%CS2_SERVER_PATH%' -AnimationDllPath '%ANIMATION_DLL_PATH%'"
) else (
    powershell -NoExit -ExecutionPolicy Bypass -Command ^
        "& '%SCRIPT_PATH%' -CS2Path '%CS2_SERVER_PATH%'"
)

pause