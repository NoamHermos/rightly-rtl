@echo off
REM ============================================================================
REM Rightly - One-click uninstaller for Windows
REM ============================================================================

setlocal
cd /d "%~dp0"

echo.
echo ============================================================
echo   Rightly - Uninstaller
echo ============================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set EXITCODE=%ERRORLEVEL%

echo.
pause
exit /b %EXITCODE%
