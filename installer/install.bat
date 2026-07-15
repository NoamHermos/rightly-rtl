@echo off
setlocal
cd /d "%~dp0"

echo.
echo ============================================================
echo   Rightly - RTL for GPT + Claude
echo ============================================================
echo.

where node.exe >nul 2>&1
if errorlevel 1 (
    echo [!] Node.js is not installed.
    echo     Install Node.js LTS from https://nodejs.org/ and run this again.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set EXITCODE=%ERRORLEVEL%

echo.
if %EXITCODE% NEQ 0 (
    echo [X] Installation failed with exit code %EXITCODE%.
) else (
    echo [+] Installation completed.
)
echo.
pause
exit /b %EXITCODE%
