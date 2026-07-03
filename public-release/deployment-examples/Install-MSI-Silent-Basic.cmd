@echo off
setlocal
set "MSI=%~dp0..\PcNinja-WinUpdateTool-V1.1.2-Setup-x64.msi"
msiexec /i "%MSI%" /qn /norestart
exit /b %ERRORLEVEL%

