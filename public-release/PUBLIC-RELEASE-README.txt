PcNinja WinUpdate Tool V1.1.2 Public Release

Files:
- PcNinja-WinUpdateTool-V1.1.2-Setup-x64.msi
- PcNinja-WinUpdateTool-V1.1.2-Portable.exe
- deployment-examples\

Main install options:
- Interactive MSI: double-click the MSI.
- Silent MSI: msiexec /i "PcNinja-WinUpdateTool-V1.1.2-Setup-x64.msi" /qn /norestart
- Portable GUI: run "PcNinja-WinUpdateTool-V1.1.2-Portable.exe".
- Portable help: run "PcNinja-WinUpdateTool-V1.1.2-Portable.exe" /?

Windows Update reset:
- GUI: Dashboard > Reset Windows Update.
- CLI: PcNinja.WinUpdateTool.Cli.exe -Mode ResetWindowsUpdate -ConfirmReset -Json
- Portable CLI: PcNinja-WinUpdateTool-V1.1.2-Portable.exe -Mode ResetWindowsUpdate -ConfirmReset -Json

Reset behavior:
- Uses the same Snooz-style service stop path before doing the reset.
- Stops Windows Update related services.
- Deletes and recreates C:\Windows\SoftwareDistribution.
- Starts the update services again.
- Reports cache status and service status in JSON when -Json is used.

V1.1.2 hotfix:
- Fixes a false reset failure after the cache was already deleted/recreated.
- Root cause: reset service-status reporting used a .NET generic object list that PowerShell could not safely enumerate/serialize in this path.

Notes:
- This build is unsigned because no code-signing certificate is installed on this machine.
- Keep SHA256SUMS.txt beside the release files for download verification.
