@echo off
rem ===================================================================
rem  SNNU campus network auto-login - one click install
rem  Double-click this file. No PowerShell knowledge needed.
rem  (This file is kept ASCII-only on purpose so it displays correctly
rem   under any console code page. All Chinese UI comes from the .ps1.)
rem ===================================================================
title SNNU Auto Login - Install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-wizard.ps1" -Mode Install
echo.
echo ============================================================
echo  Done. Press any key to close this window.
echo ============================================================
pause >nul
