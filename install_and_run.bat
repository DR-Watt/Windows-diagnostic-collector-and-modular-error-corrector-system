@echo off
setlocal
set SCRIPT_DIR=%~dp0
where pwsh >nul 2>&1
if errorlevel 1 (
  echo PowerShell 7.x / pwsh.exe nem talalhato. Telepitsd a PowerShell 7-et, majd futtasd ujra.
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%diagnostics\Initialize-DiagEnvironment.ps1"
if errorlevel 1 (
  echo Kornyezeti diagnosztika hibat jelzett.
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT_DIR%Launcher.ps1"
endlocal
