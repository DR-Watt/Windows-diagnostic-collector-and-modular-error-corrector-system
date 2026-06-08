# CLEAN Generation Log — DiagFramework v1.3.2

## Build metadata

- Generated: 2026-06-08T17:27:08.981777+00:00
- Version: 1.3.2
- Build: System Evidence Truncated Fix + Progress UI
- Package type: PATCH_ONLY

## Trigger

The v1.3.1 SystemEvidenceCollector completed most of the package but failed at the end with:

```text
The property 'Truncated' cannot be found on this object. Verify that the property exists.
```

The GUI still displayed an older v1.2.9 title, and long evidence collection did not provide enough progress feedback.

## Root cause

`New-SummaryObject` assumed that every event summary row had a `Truncated` property. Warning rows such as `LogNotPresent` or `NoMatchingEvents` can omit this property, so strict property access caused a runtime failure at final summary generation.

## Changes

1. `SystemEvidenceCollector.ps1`
   - version bumped to 1.3.2
   - added `Get-ObjectPropertyValueSafe`
   - `TruncatedEventLogs` generation is property-safe

2. `config/app.json`
   - centralized product/version/build metadata

3. `Launcher.ps1`
   - reads title/version from `config/app.json`
   - adds progress UI helpers
   - shows progress status for diagnostics and collector button operations

4. `MainWindow.xaml`
   - status bar now contains `ProgressBar prgOperation`
   - added `txtProgressDetail`

5. `modules/SystemEvidenceCollector/manifest.json`
   - version bumped to 1.3.2
   - UI text updated for current P0 evidence scope

## Validation

- JSON files parsed successfully.
- ZIP integrity checked.
- PowerShell runtime validation was not executable in this Linux container.

## diagnostics_starter_pack

Run first:

```powershell
.\diagnostics\Initialize-DiagEnvironment.ps1
```
