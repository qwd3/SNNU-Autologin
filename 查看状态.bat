@echo off
rem SNNU Auto Login - check status.  Double-click to run.
title SNNU Auto Login - Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-wizard.ps1" -Mode Status
echo.
echo ============================================================
echo  Press any key to close this window.
echo ============================================================
pause >nul
