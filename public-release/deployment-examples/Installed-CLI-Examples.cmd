@echo off
setlocal
set "CLI=%ProgramFiles%\PcNinja\WinUpdateTool\PcNinja.WinUpdateTool.Cli.exe"
"%CLI%" /?
"%CLI%" -Mode Status -Json
"%CLI%" -Mode Configure -EnableSchedule -Frequency Monthly -MonthlyDay 15 -Time 03:00 -RunAtStartup -StartupDelayMinutes 5 -RunIfMissed -WakeToRun -RetryInitialDelayMinutes 5 -MinimumCooldownMinutes 5 -Json
"%CLI%" -Mode RunUpdates -Silent -RunType Manual -Json
"%CLI%" -Mode ResetWindowsUpdate -ConfirmReset -Json
exit /b %ERRORLEVEL%
