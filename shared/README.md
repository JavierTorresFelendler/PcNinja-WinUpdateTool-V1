# Shared PcNinja components

Files in this folder are shared by every PcNinja Windows tool:

- Windows Upgrade Tool
- WinUpdate Tool V1 and V2
- Smart Office Installer
- the planned unified PcNinja tool

**Keep them byte-identical in every repository.** Change them in one place,
then copy the same file to the other repositories in the same change set. They
are written in C# 5 so that every build path can compile them unchanged:
.NET 8 SDK projects, .NET Framework 4.8 projects, legacy `csc.exe` v4 and
PowerShell 5.1 `Add-Type`.

## PcNinjaSingleInstance.cs

This file makes each GUI single-instance per Windows logon session. If the app
is launched while it is already open, no second copy starts. The running
window is restored if minimized and brought to the front.

| Call | Where it goes |
| --- | --- |
| `TryActivateExisting(appId)` | An unelevated launcher, just before it self-elevates. If this returns `true`, exit with code 0. This avoids a UAC prompt for an app that is already open. |
| `Acquire(appId)` | The GUI process, after elevation and before any window or file extraction. If this returns `null`, exit with code 0. Otherwise keep the returned holder alive until the app closes (`using`). |

Rules:

- **GUI only.** CLI and automation modes (BigFix, scheduled tasks, `-Mode Status`)
  must not be blocked by an open window. Protect shared machine operations
  with their own operation locks (for example the Windows Upgrade Tool's
  `AppOperationGate`).
- **Fixed app ids.** Changing an app id breaks detection between old and new
  builds, so never derive one from a version.

  | App id | Product |
  | --- | --- |
  | `WinUpgradeTool` | Windows Upgrade Tool |
  | `WinUpdateTool` | WinUpdate Tool V1 and V2. They share the id because they are the same tool with the same scheduled tasks and machine state. |
  | `SmartOfficeInstaller` | Smart Office Installer |

- **Fails open.** If the guard cannot be created, the app starts normally.
- **Self-update is unaffected.** The update helpers start the new GUI only after
  the old process has exited, and the kernel releases the guard when the old
  process exits or crashes.
- **Nested entry is handled.** An EXE host that runs the PowerShell UI
  in-process sets `PCNINJA_SINGLE_INSTANCE_HELD=<appId>|<pid>`. A second
  `Acquire` call in the same process then succeeds without creating a new
  guard. Child processes do not match, because the marker includes the
  process id.

### How it works

1. **The guard is a named event, one per app and session.** Its name is
   `Local\PcNinja.<AppId>.SingleInstance.v1`. The first GUI process creates
   it and keeps it open for its whole lifetime.
2. **A later launch signals that event.** Before signalling, it calls
   `AllowSetForegroundWindow` so that Windows lets the running instance take
   the foreground.
3. **The running instance activates its own window.** It restores and focuses
   its main window, or the modal dialog that window owns. If Windows refuses
   the focus change, it flashes the taskbar button. Because the instance only
   activates itself, it avoids UIPI restrictions between elevated and
   standard processes.
4. **Unelevated launches can signal an elevated instance.** The event's DACL
   lets interactive users wait on it and signal it. Its integrity label is
   Medium, so a standard-rights process may signal it, while an elevated app
   still owns it.

### Unified tool

The unified tool should compile this same file and call `Acquire` once in
its GUI entry point with a new fixed id (for example `PcNinjaToolkit`).

The open question is whether the unified tool may run next to the
standalone tools:

- **No.** At startup it also probes the legacy ids (`WinUpgradeTool`,
  `WinUpdateTool`, `SmartOfficeInstaller`) with `TryActivateExisting`.
- **Yes.** No change is needed.

Decide this when the unified tool's design is closed.
