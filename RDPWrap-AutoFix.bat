@echo off
chcp 65001 >nul
title RDP Wrapper AutoFix

rem --- 需要系統管理員權限，沒有就自動提權 ---
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0RDPWrap-AutoFix.ps1" %*
set RC=%ERRORLEVEL%

echo.
if not "%RC%"=="0" echo Exit code: %RC%
pause
