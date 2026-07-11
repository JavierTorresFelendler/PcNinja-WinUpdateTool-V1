# PcNinja WinUpdate Tool V1

PcNinja WinUpdate Tool is a Windows Update management utility for technicians, managed-service workflows, and advanced Windows maintenance.

It provides a desktop GUI, command-line modes, an MSI installer, a portable executable, scheduled update runs, driver audit support, deployment examples, and release hashes.

This repository is the V1 legacy release line. V2 lives separately at https://github.com/JavierTorresFelendler/PcNinja-WinUpdateTool-V2 (current V2 stable: V2.2.3). New installations should prefer the V2 line.

## Current Release

- Public version: `V1.1.2`
- Internal package version: `1.1.2.0`
- Release tag: `v1.1.2`
- Release status: unsigned unless signed separately

## Features

- GUI for Windows Update checks, update runs, scheduling, logs, and driver audit views.
- CLI modes for status checks, update runs, driver audits, log collection, and Windows Update reset workflows.
- MSI installer with interactive setup, silent deployment support, install-time options, and scheduled task configuration.
- Portable EXE for run-anywhere usage without a full installation.
- Deployment examples for command-line installs and managed deployment tools.
- SHA256 hashes for public release artifacts.

## Download

Use the GitHub Releases page for installable builds:

- `PcNinja-WinUpdateTool-V1.1.2-Setup-x64.msi`
- `PcNinja-WinUpdateTool-V1.1.2-Portable.exe`
- `PcNinja-WinUpdateTool-V1.1.2-PublicRelease.zip`

## Repository Layout

- `WinUpdateTool.ps1` - main GUI and workflow entry point.
- `WinUpdateCore.psm1` - shared Windows Update, scheduling, logging, and driver audit logic.
- `packaging/` - MSI, portable launcher, CLI host, and build scripts.
- `public-release/` - release notes, signing notes, hashes, and deployment examples.
- `assets/` - PcNinja icon and visual assets.

## Build From Source

Builds are intended for Windows.

Requirements:

- Windows PowerShell 5.1
- .NET Framework compiler at `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`
- WiX Toolset 6 with `WixToolset.UI.wixext`

Build command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Build-Packages.ps1
```

Unsigned builds are expected when no code-signing certificate is available.

## Safety Notes

This tool interacts with Windows Update, scheduled tasks, and administrative maintenance workflows. Test in a controlled environment before broad deployment.

Windows Update reset operations should be used carefully and only when the operator understands the impact.

## License

Copyright (c) 2026 Javier Torres Felendler.

All rights reserved. This repository is published for review, portfolio, and collaboration purposes. No permission is granted to copy, modify, redistribute, sublicense, or repackage this software without written permission from the owner.
