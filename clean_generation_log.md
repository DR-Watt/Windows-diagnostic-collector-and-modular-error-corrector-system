# CLEAN Generation Log — DiagFramework v1.2.0

## Build metadata

- **Project:** DiagFramework Windows Update Repair MVP
- **Version:** 1.2.0
- **Generated at:** 2026-06-08T07:45:34+00:00
- **Generator log schema:** clean-generation-log.md/v1
- **Purpose:** UI/manifest/log architecture refactor according to the updated project instructions.

## Development changelog

### Added

- `config/ui.hu-HU.json` structured UI resource file for labels, button text, tooltips and main user messages.
- `modules/SystemEvidenceCollector/` read-only evidence collector module for Windows boot/setup/update/driver/crash/vendor diagnostic evidence.
- `tools/Collect-SystemEvidence.ps1` CLI wrapper.
- `collect_system_evidence.bat` quick launcher.
- `validators/Validate-UiResources.ps1` validator for localized UI resources.
- Manifest `Ui` blocks for module-level Summary, RecommendedAction, ToolTip, ExpectedOutput and Impact metadata.

### Changed

- `MainWindow.xaml`: summary/action text removed from the main module table and moved into two dedicated scrollable right-side panels.
- `Launcher.ps1`: loads UI strings from `config/ui.hu-HU.json`, applies tooltips, reads module explanatory text from each manifest, and exposes the new System Evidence package button.
- `validators/Validate-Manifests.ps1`: validates module UI metadata, not just script references.
- `diagnostics/Initialize-DiagEnvironment.ps1`: runs both manifest and UI resource validators.
- `README.md`: updated to v1.2.0 structure and usage.

### Removed

- `clean_generation_log.txt`; CLEAN generation logs now use Markdown format as the build/changelog document.

## GitHub input used

The build design used the following GitHub repositories as architectural input:

- DR-Watt/Windows-diagnostic-collector-and-modular-error-corrector-system
- DR-Watt/WindowsRescue
- DR-Watt/Windows-Repair-Tool
- DR-Watt/Windows-Maintenance-Tool
- DR-Watt/WindowsMaintenance

The external repositories were used as design references, not as direct code imports.

## Generated / modified files

- `DiagFramework.psm1`
- `Launcher.ps1`
- `MainWindow.xaml`
- `README.md`
- `collect_ai_logs_for_kb5089573.bat`
- `collect_system_evidence.bat`
- `config/ui.hu-HU.json`
- `diagnostics/Initialize-DiagEnvironment.ps1`
- `hotfix_001_fix_lastexitcode.ps1`
- `hotfix_002_ai_log_collector_notes.ps1`
- `install_and_run.bat`
- `modules/AILogCollector/AILogCollector.ps1`
- `modules/AILogCollector/manifest.json`
- `modules/ComponentStoreRepair/ComponentStoreRepair.ps1`
- `modules/ComponentStoreRepair/manifest.json`
- `modules/PSWindowsUpdateManager/PSWindowsUpdateManager.ps1`
- `modules/PSWindowsUpdateManager/manifest.json`
- `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
- `modules/SystemEvidenceCollector/manifest.json`
- `modules/WUCacheReset/WUCacheReset.ps1`
- `modules/WUCacheReset/manifest.json`
- `modules/WUServiceHealth/WUServiceHealth.ps1`
- `modules/WUServiceHealth/manifest.json`
- `tools/Collect-AIPackage.ps1`
- `tools/Collect-SystemEvidence.ps1`
- `validators/Validate-AIPackage.ps1`
- `validators/Validate-Manifests.ps1`
- `validators/Validate-UiResources.ps1`
- `workspace.code-workspace`

## Execution order

1. `install_and_run.bat`
2. `diagnostics/Initialize-DiagEnvironment.ps1`
3. `validators/Validate-Manifests.ps1`
4. `validators/Validate-UiResources.ps1`
5. `Launcher.ps1`
6. User-selected GUI actions:
   - diagnostics: module `Test-Condition`
   - selected repair: module `Invoke-Fix`
   - rollback: module `Invoke-Rollback`
   - KB evidence: `modules/AILogCollector/AILogCollector.ps1`
   - general system evidence: `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`

## Validation log

- JSON syntax validation: completed for all manifest files and `config/ui.hu-HU.json`.
- Structural validation target: manifest `Ui` block present for every module.
- Runtime validation caveat: Windows 11 / PowerShell 7 / WPF execution cannot be performed inside this Linux container.

## Known limitations

- `SystemEvidenceCollector` uses broad known vendor folders under `%ProgramData%`; missing vendor folders are treated as non-errors.
- Large copied files are skipped above the module default size threshold.
- Some Windows Event Log channels may be unavailable depending on edition, policy, or logging configuration.
- `Get-WindowsUpdateLog` may emit ETL schema warnings; these are preserved as diagnostic context.

## Documentation check summary

- DISM/SFC flow follows Microsoft documented servicing and system file repair concepts.
- Windows Update ETL conversion follows Microsoft `Get-WindowsUpdateLog` documentation.
- Windows Update component reset remains rename/backup-oriented rather than destructive deletion.

## CLEAN result

- Full package ZIP generated separately.
- Patch-only ZIP generated separately.
- This Markdown file is the authoritative CLEAN build/changelog log for v1.2.0.
