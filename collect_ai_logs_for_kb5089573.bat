@echo off
setlocal
set ROOT=%~dp0
set TARGETKB=KB5089573
set DAYSBACK=30

where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 / pwsh.exe nem talalhato.
  pause
  exit /b 1
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\Collect-AIPackage.ps1" -TargetKB %TARGETKB% -DaysBack %DAYSBACK%
if errorlevel 1 (
  echo AI LOG csomag keszitese hibat jelzett.
  pause
  exit /b 1
)

echo.
echo AI LOG csomag kesz. Ellenorizd: %ROOT%logs\ai_packages
pause
