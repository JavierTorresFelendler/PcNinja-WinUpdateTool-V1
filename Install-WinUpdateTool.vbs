Option Explicit

Dim shell
Dim fso
Dim scriptDir
Dim installScript
Dim arguments

Set shell = CreateObject("Shell.Application")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
installScript = fso.BuildPath(scriptDir, "Install-WinUpdateTool.ps1")
arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & installScript & Chr(34) & " -RunAfterInstall"

shell.ShellExecute "powershell.exe", arguments, scriptDir, "runas", 0
