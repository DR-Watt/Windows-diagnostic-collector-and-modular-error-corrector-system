# CLEAN Generation Log / Changelog — v1.3.0 P0 Evidence Quality Pack

## Build metadata

- Timestamp: `2026-06-08T15:40:58.806348+00:00`
- Version: `1.3.0`
- Scope: `SystemEvidenceCollector` P0 evidence quality
- Source roadmap: `docs/20260608-160353-HAL-SystemEvidence-deep-analysis-roadmap.md`

## Módosított / új fájlok

- `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
- `modules/SystemEvidenceCollector/manifest.json`
- `docs/system_evidence_schema_v1_3_0.md`
- `docs/collector_acceptance_tests.md`
- `docs/20260608-160353-HAL-SystemEvidence-deep-analysis-roadmap.md`
- `validators/Validate-SystemEvidencePackage.ps1`
- `README_v1.3.0.md`

## Fő implementált P0 elemek

1. EVTX export.
2. WindowsUpdate.generated.log.
3. DISM ScanHealth.
4. SFC verifyonly.
5. Storage mapping és Disk 153 map.
6. Warning/error státuszmodell.
7. Vendor whitelist/blacklist.
8. Manifest SHA-256.
9. Event truncation metadata.

## Validáció

- JSON manifest validálva Python parserrel.
- ZIP integritás ellenőrizve.
- PowerShell runtime teszt nem futott ebben a Linux konténerben.

## diagnostics_starter_pack

A build a Windows 11 PowerShell diagnosztikai sablonra épít; futtatás előtt továbbra is javasolt az `Initialize-DiagEnvironment.ps1` indítása.
