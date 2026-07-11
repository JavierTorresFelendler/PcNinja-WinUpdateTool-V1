@echo off
setlocal
set "MSI=%~dp0..\PcNinja-WinUpdateTool-Setup-1.1.3.0-x64.msi"
msiexec /i "%MSI%" /qn /norestart
exit /b %ERRORLEVEL%
