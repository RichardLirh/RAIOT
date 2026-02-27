@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "OLD_CP="

for /f "tokens=2 delims=:" %%I in ('chcp') do set "OLD_CP=%%I"
for /f "tokens=* delims= " %%I in ("%OLD_CP%") do set "OLD_CP=%%I"
chcp 65001 >nul

for %%A in (%*) do (
    if /I "%%~A"=="-h" goto usage
    if /I "%%~A"=="--help" goto usage
    if "%%~A"=="/?" goto usage
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%start-all.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
if defined OLD_CP chcp %OLD_CP% >nul

endlocal & exit /b %EXIT_CODE%

:usage
echo Usage:
echo   start-all.cmd [-BackendProfile dev^|test^|prod] [-RestartAiServer] [-LogRoot path] [-EnvFile path] [-SkipPortCleanup] [-SkipEsp32HintWindow]
echo.
echo Notes:
echo   - Runs all services in the current CMD window with merged prefixed logs.
echo   - Default env file is ".env.raiot" in repository root.
echo   - Before startup, script ensures backend MySQL database exists.
echo   - By default, startup cleans occupied service ports before launching.
echo   - After services start, script syncs sys_params LAN IP values.
echo   - By default, startup syncs Richard-esp32/sdkconfig OTA URL and then opens a second ESP32 tip CMD window (prefer ESP-IDF 5.5 environment).
echo   - Press Ctrl+C once to stop all child processes.
if defined OLD_CP chcp %OLD_CP% >nul
endlocal & exit /b 0
