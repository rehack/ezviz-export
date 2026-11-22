@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-export.ps1" %*
set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" (
    echo Startup failed. Read the message above.
    echo Press any key to close this window.
    pause >nul
    exit /b %RESULT%
)
echo Task is running in the background.
echo Press any key to close this window.
pause >nul
exit /b 0
