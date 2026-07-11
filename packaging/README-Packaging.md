# PcNinja WinUpdate Tool Packaging

V1.1.3-RC1 produces two product deliverables from the same app files:

- `PcNinja-WinUpdateTool-Setup-1.1.3.0-x64.msi`
- `PcNinja-WinUpdateTool-Portable-1.1.3.0.exe`

Build command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Build-Packages.ps1
```

The MSI uses WiX Toolset 6. If WiX is missing:

```powershell
dotnet tool install wix --version 6.* --tool-path ..\..\.build-tools-wix6
```

The MSI installs `PcNinja.WinUpdateTool.exe`, a branded host that runs the PowerShell UI in-process, plus `PcNinja.WinUpdateTool.Cli.exe` for command-line use.

Normal interactive MSI installs show a wizard with license, install-folder, schedule/options, progress, and finish pages.

The MSI can be deployed silently with `msiexec /qn` and can apply post-install configuration through public `PCNINJA_*` MSI properties.

JSON-based MSI deployment is not included in V1.1.3-RC1.

The portable EXE is a small .NET Framework launcher with the app payload embedded as a zip resource. It always extracts under `%LOCALAPPDATA%\PcNinja\WinUpdateTool\Portable\1.1.3.0`. With no arguments it launches `PcNinja.WinUpdateTool.exe`; with arguments it forwards them to `PcNinja.WinUpdateTool.Cli.exe`.

Deployment examples are generated under `dist\deployment-examples`.











