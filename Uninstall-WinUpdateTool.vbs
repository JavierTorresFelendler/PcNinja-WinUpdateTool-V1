Option Explicit

Dim shell
Dim fso
Dim scriptDir
Dim uninstallScript
Dim arguments

Set shell = CreateObject("Shell.Application")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
uninstallScript = fso.BuildPath(scriptDir, "Uninstall-WinUpdateTool.ps1")
arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & uninstallScript & Chr(34)

shell.ShellExecute "powershell.exe", arguments, scriptDir, "runas", 0
