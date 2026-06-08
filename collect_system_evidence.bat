@echo off
setlocal
set ROOT=%~dp0
set DAYSBACK=30
set MAXEVENTS=1200
set TARGETKB=KB5089573

where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 / pwsh.exe nem talalhato.
  pause
  exit /b 1
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\Collect-SystemEvidence.ps1" -DaysBack %DAYSBACK% -MaxEvents %MAXEVENTS% -TargetKB %TARGETKB%
if errorlevel 1 (
  echo Rendszer LOG csomag keszitese hibat jelzett.
  pause
  exit /b 1
)

echo.
echo Rendszer LOG csomag kesz. Ellenorizd: %ROOT%logs\evidence_packages
pause
