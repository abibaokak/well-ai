@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 (
  echo.
  echo Installation failed. See the window above for details.
  pause
)
