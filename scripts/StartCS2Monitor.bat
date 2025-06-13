@echo off
chcp 437 > nul
setlocal enabledelayedexpansion

REM Set console title
title CS2 Server Monitor System

REM ========== Configuration ==========
REM Set your CS2 server path here (with quotes if path contains spaces)
set "CS2_SERVER_PATH=D:\CS2 Servers\MultiGames\steamapps\common\Counter-Strike Global Offensive\game\bin\win64"
REM ==================================

REM Get current directory and script path
set "CURRENT_DIR=%~dp0"
set "SCRIPT_PATH=%CURRENT_DIR%cs2_monitor_master.ps1"

REM Convert backslashes to forward slashes in paths
set "CS2_SERVER_PATH=%CS2_SERVER_PATH:\=/%"
set "SCRIPT_PATH=%SCRIPT_PATH:\=/%"

echo ========================================
echo         CS2 Server Monitor System        
echo          By: DearCrazyLeaf
echo ========================================
echo.

echo Current server path: "%CS2_SERVER_PATH%"
echo.

REM Validate the path
if not exist "%CS2_SERVER_PATH%" (
    echo ERROR: Server path not found: "%CS2_SERVER_PATH%"
    echo Please check the path in the script
    pause
    exit /b 1
)

echo Starting monitor...
echo.

REM Use escaped quotes and forward slashes for PowerShell
powershell -NoExit -ExecutionPolicy Bypass -Command ^
    "& '%SCRIPT_PATH%' -CS2Path '%CS2_SERVER_PATH%'"

pause