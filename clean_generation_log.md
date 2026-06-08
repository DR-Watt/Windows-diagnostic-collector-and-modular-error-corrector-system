# CLEAN Generation Log / Changelog

## Build metadata

- Project: DiagFramework Windows Update Repair MVP
- Version: v1.2.2-system-evidence-syntax-hotfix
- Generated at: 2026-06-08T08:47:30+00:00
- Generator purpose: Hotfix for SystemEvidenceCollector PowerShell parser error and pre-run syntax validation.

## Change summary

### Fixed

- Fixed `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1` parser error in `Convert-EventRecordFlat`.
- Removed direct `try { } catch { }` statements from `[PSCustomObject]@{ ... }` property values.
- Event record fields are now read into local variables before object creation.

### Added

- Added `validators/Validate-PowerShellSyntax.ps1`.
- Added automatic syntax validation call to `diagnostics/Initialize-DiagEnvironment.ps1`.

### Updated

- Updated `modules/SystemEvidenceCollector/manifest.json` to version `1.2.2`.
- Updated README with the v1.2.2 hotfix notes.

## Modified files

- `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
- `modules/SystemEvidenceCollector/manifest.json`
- `diagnostics/Initialize-DiagEnvironment.ps1`
- `validators/Validate-PowerShellSyntax.ps1`
- `README.md`
- `clean_generation_log.md`

## Runtime order

1. `install_and_run.bat`
2. `diagnostics/Initialize-DiagEnvironment.ps1`
3. `validators/Validate-Manifests.ps1`
4. `validators/Validate-UiResources.ps1`
5. `validators/Validate-PowerShellSyntax.ps1`
6. `Launcher.ps1`
7. GUI action: `SystemEvidenceCollector` / `Collect-SystemEvidence.ps1`

## Validation notes

- JSON files were parsed successfully during package generation.
- ZIP integrity was checked after package creation.
- PowerShell runtime parser validation cannot be executed inside this Linux container because `pwsh` is not available here; the included validator runs on the target Windows/PowerShell 7 environment before the GUI starts.

## Known limitations

- Some Windows Event Logs or vendor diagnostic paths may be inaccessible depending on permissions or installed hardware/vendor tooling. These cases are expected to be recorded in `errors/collector-errors.json`, not treated as fatal collector failures.
