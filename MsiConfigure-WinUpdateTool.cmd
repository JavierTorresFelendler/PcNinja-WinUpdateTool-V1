@echo off
setlocal

set "SCRIPT=%~dp0MsiConfigure-WinUpdateTool.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%


