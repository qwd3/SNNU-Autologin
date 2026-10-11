@echo off
rem SNNU Auto Login - uninstall (stop daemon + remove autostart task).
title SNNU Auto Login - Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-wizard.ps1" -Mode Uninstall
echo.
echo ============================================================
echo  Press any key to close this window.
echo ============================================================
pause >nul
