# CLEAN Generation Log — v1.4.2 P0 Evidence Bridge Syntax Hotfix

## Build metadata

- Timestamp: `2026-06-09T07:10:26.488527+00:00`
- Package: `DiagFramework_v1_4_2_p0_evidence_bridge_syntax_hotfix_PATCH_ONLY`
- Scope: P0 evidence bridge syntax hotfix
- Compatible P1 normalizer version: `1.4.0`

## Trigger

A kliens oldali `Initialize-DiagEnvironment.ps1` PowerShell szintaxisvalidációs hibát jelzett: hibás fájlok száma 1. A hiba a v1.4.1 P0 evidence bridge csomag alkalmazása után jelent meg.

## Root cause

A v1.4.1 `SystemEvidenceCollector.ps1` több `[PSCustomObject]@{ ... }` hashtable literalban közvetlen command invocation formát használt property értékként. Ezeket zárójelezett kifejezésekké alakítottam.

## Modified files

1. `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
2. `modules/SystemEvidenceCollector/manifest.json`
3. `config/app.json`
4. `docs/p0_evidence_bridge_syntax_hotfix_v1_4_2.md`
5. `clean_generation_log.md`

## Validation

- ZIP integrity checked.
- JSON files parsed successfully.
- PowerShell runtime parser not available in this Linux container; client-side validation required.

## diagnostics_starter_pack

A futtatási sorrend változatlan:

```powershell
.\diagnostics\Initialize-DiagEnvironment.ps1
.\install_and_run.bat
```
