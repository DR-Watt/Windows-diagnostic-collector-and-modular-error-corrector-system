# CLEAN Generation Log / Changelog

## Build metadata

- Project: DiagFramework Windows Update Repair MVP
- Version: v1.2.4 Bootstrap Output Hotfix
- Generated: 2026-06-08T11:08:00+02:00
- Target: Windows 11, PowerShell 7.x, WPF/XAML

## Change summary

### Fixed

- Javítva a környezeti diagnosztika validátor-wrapper hibája.
- A `Write-EnvLog` már nem használ `Tee-Object`-et, mert az a success output streamre is továbbít.
- A validátorok JSON summary objektumait kötelező mezőellenőrzés védi.

### Modified files

- `diagnostics/Initialize-DiagEnvironment.ps1`
- `README.md`
- `clean_generation_log.md`

## Runtime order

1. `install_and_run.bat`
2. `diagnostics/Initialize-DiagEnvironment.ps1`
3. Manifest validátor
4. UI resource validátor
5. PowerShell szintaxisvalidátor
6. `Launcher.ps1`

## Known limitation

A build PowerShell runtime validálását ebben a környezetben nem lehetett tényleges Windows PowerShell 7.6.2 hoston futtatni.
