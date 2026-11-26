@echo off
rem Smart Downloads Organiser - made by Sparsh
title Smart Downloads Organiser - by Sparsh
setlocal DisableDelayedExpansion
if not exist "%~dp0Organiser.ps1" (
  echo Organiser.ps1 was not found. Right-click the ZIP, choose "Extract All", then try again.
  pause
  exit /b 1
)
rem "-ExecutionPolicy Bypass" applies to this one run only. No system setting is changed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Organiser.ps1" -Undo %*
if errorlevel 1 pause
