@echo off
rem Opens the CorePilot window. conhost --headless runs PowerShell without any console window,
rem so nothing stays open behind the app. Nothing is changed until you press Apply and confirm.
start "" "%SystemRoot%\System32\conhost.exe" --headless powershell.exe -NoProfile -STA -File "%~dp0CorePilot.ps1" -Gui
