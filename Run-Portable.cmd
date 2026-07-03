@echo off
if exist "%~dp0PcNinja.WinUpdateTool.exe" (
  "%~dp0PcNinja.WinUpdateTool.exe"
) else (
  wscript.exe "%~dp0Launch-WinUpdateTool.vbs"
)


