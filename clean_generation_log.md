# CLEAN Generation Log — DiagFramework v1.3.3 Storage Correlation Pack

## Build metadata

- Timestamp: `2026-06-08T17:58:09.508735+00:00`
- Version: `1.3.3`
- Build type: patch-only
- Main module: `SystemEvidenceCollector`

## User-provided diagnostic context

Disk 2 and Disk 3 are two 8TB SATA HDDs attached to the onboard Intel RAID controller. RAID mode is JBOD.

## Implemented items

1. Disk 2 / Disk 3 → Get-Disk / PhysicalDisk / Win32_DiskDrive mapping.
2. PDO object name → storage controller / driver snapshot context.
3. Event ID 153 timeline.
4. Disk 153 event correlation with Windows Update / Setup / Kernel-Boot / Kernel-PnP time windows.
5. Dedicated storage risk summary.
6. ai_summary.json TopFindings / RiskIndicators / SuggestedNextEvidence fields.

## Changed files

- `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
- `modules/SystemEvidenceCollector/manifest.json`
- `config/app.json`
- `config/storage_hints.json`
- `docs/storage_correlation_schema_v1_3_3.md`
- `docs/collector_acceptance_tests_v1_3_3.md`
- `clean_generation_log.md`

## Runtime validation

Not executed in this Linux container. ZIP and JSON syntax were validated during generation.
