Option Explicit

Dim shell
Dim fso
Dim scriptDir
Dim appScript
Dim hostExe
Dim arguments

Set shell = CreateObject("Shell.Application")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
hostExe = fso.BuildPath(scriptDir, "PcNinja.WinUpdateTool.exe")
appScript = fso.BuildPath(scriptDir, "WinUpdateTool.ps1")
arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & appScript & Chr(34) & " -Mode UI"

If fso.FileExists(hostExe) Then
    shell.ShellExecute hostExe, "", scriptDir, "open", 1
Else
    shell.ShellExecute "powershell.exe", arguments, scriptDir, "runas", 0
End If
