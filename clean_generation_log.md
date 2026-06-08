# CLEAN Generation Log / Changelog

## Build

- Project: DiagFramework Windows Update Repair MVP
- Version: v1.2.7-system-evidence-resilience-ui-details
- Generated: 2026-06-08T09:34:42.504380+00:00
- Format: Markdown

## Trigger

A validáció végre lefutott, de a `SystemEvidenceCollector` rendszer LOG csomag futás közben ismét hibába futott. A feltöltött `collector-progress.jsonl` szerint a `RegistryPendingReboot`, `DriverSnapshot` és `EventLogs` lépések `Argument types do not match` hibát adtak. A felhasználó kérte, hogy az `ÖSSZEFOGLALÓ` és `JAVASOLT MŰVELET` panelek részletesebb, lépésmagyarázó szöveget kapjanak.

## Root cause inference

A hiba nem PowerShell szintaxisprobléma: a `environment-20260608-112419.log` szerint a manifest, UI resource és PowerShell szintaxisvalidáció sikeresen lefutott. A futásidejű hiba a rendszer evidence collector belső adatgyűjtő/JSON-szerializáló útvonalán jelent meg. A v1.2.7 ezért eltávolítja a kritikus útból a generikus `System.Collections.Generic.List[object]` szerkezeteket, laposabb objektumokat használ, és részleges hiba esetén is csomagot készít.

## Modified files

- `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
- `modules/SystemEvidenceCollector/manifest.json`
- `modules/AILogCollector/manifest.json`
- `modules/ComponentStoreRepair/manifest.json`
- `modules/PSWindowsUpdateManager/manifest.json`
- `modules/WUCacheReset/manifest.json`
- `modules/WUServiceHealth/manifest.json`
- `Launcher.ps1`
- `README.md`
- `clean_generation_log.md`

## Functional changes

### SystemEvidenceCollector

- Version bumped to `1.2.7`.
- Native PowerShell arrays are used instead of generic .NET list objects in the critical collection path.
- `Get-RebootPendingSnapshot`, `Get-DriverSnapshot`, `Collect-Events`, `Copy-IfExists`, and package manifest generation were hardened.
- A top-level collector body catch path creates `collector-errors.json` and `ai_summary.json` instead of allowing the GUI call to fail unhandled.
- `TargetKB` is propagated into the system evidence package path and README context.

### GUI detail text

- Manifest `Ui.Summary` and `Ui.RecommendedAction` fields were expanded into detailed, scroll-friendly explanation blocks.
- These texts explain what each module checks, when to run it, and how to interpret next steps.

### Launcher

- `TargetKB` is now passed to `SystemEvidenceCollector` during diagnostics and actual collection.

## Expected runtime behavior

If registry, driver or event collection fails, the package should continue and mark the result as `Partial` instead of failing the whole operation. The main evidence package should still contain:

- `AI_README.md`
- `ai_summary.json`
- `collector-progress.jsonl`
- `errors/collector-errors.json`

## Validation

- JSON manifests: generated and parsed successfully in build environment.
- ZIP packaging: generated successfully in build environment.
- PowerShell runtime validation: not executable in this Linux container; client-side PowerShell 7.6.2 validation is required.

## Run order

1. Apply patch over the repository root.
2. Run `./diagnostics/Initialize-DiagEnvironment.ps1`.
3. Run `./install_and_run.bat` or `./tools/Collect-SystemEvidence.ps1 -DaysBack 30 -MaxEvents 1200 -TargetKB KB5089573`.
4. Inspect `logs/evidence_packages/<package>/collector-progress.jsonl` and `errors/collector-errors.json`.
