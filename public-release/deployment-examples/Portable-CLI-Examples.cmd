@echo off
setlocal
set "PORTABLE=%~dp0..\PcNinja-WinUpdateTool-Portable-1.1.3.0.exe"
"%PORTABLE%" /?
"%PORTABLE%" -Mode Status -Json
"%PORTABLE%" -Mode DriverAudit -Json
"%PORTABLE%" -Mode Configure -EnableSchedule -Frequency Monthly -MonthlyDay 15 -Time 03:00 -RunAtStartup -StartupDelayMinutes 5 -RunIfMissed -WakeToRun -RetryInitialDelayMinutes 5 -MinimumCooldownMinutes 5 -Json
"%PORTABLE%" -Mode ResetWindowsUpdate -ConfirmReset -Json
exit /b %ERRORLEVEL%
