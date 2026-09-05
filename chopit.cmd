@echo off
setlocal
set "CHOPIT_SCRIPT=%~dp0chopit.ps1"

where.exe pwsh.exe >nul 2>nul
if not errorlevel 1 goto use_pwsh

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CHOPIT_SCRIPT%" %*
exit /b %errorlevel%

:use_pwsh
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%CHOPIT_SCRIPT%" %*
exit /b %errorlevel%
