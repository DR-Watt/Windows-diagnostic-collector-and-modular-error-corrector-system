# CLEAN Generation Log — DiagFramework v1.3.1 System Evidence Quality Fix Pack

## Build metadata

- Project: Windows diagnostic collector and modular error corrector system
- Version: v1.3.1
- Build type: SystemEvidenceCollector quality fix
- Timestamp: 2026-06-08T18:30:00+02:00
- Output format: Markdown changelog

## Input evidence

A v1.3.0 futás `OKWithWarnings` állapotot adott, `ErrorCount=0`, `WarningCount=3`. A minőségi elemzés három fejlesztendő pontot azonosított:

1. `disk-event-map.json`: a magyar Event ID 153 üzenetekből a disk szám nem töltődött (`DiskNumber=null`).
2. `wer-summary.json`: `ReportCount=0`, miközben a manifest sok `Report.wer` fájlt tartalmazott.
3. `copied_logs`: Panther / Rollback alatt túl sok bináris és nem log jellegű fájl került be.

## Módosított fájlok

- `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
- `docs/system_evidence_schema_v1_3_1.md`
- `docs/collector_acceptance_tests_v1_3_1.md`
- `clean_generation_log.md`

## Implementált javítások

### Disk Event ID 153 parser

Új függvények:

- `Parse-Disk153Message`
- `New-Disk153Aggregate`

Kezelt minták:

- magyar: `2 jelű lemez`
- magyar: `PDO objektum neve: \Device\...`
- magyar: `0x8000 logikai blokkcím`
- angol fallback: `disk 2`, `PDO name`, `logical block address`

### WER summary útvonaljavítás

Új függvények:

- `Read-WerReportFile`
- `Get-WerValueSafe`

Források:

- `copied_logs\ReportArchive`
- `copied_logs\ReportQueue`
- `vendor_logs`

### copied_logs policy

Új policy függvények:

- `Get-SystemLogCopyPolicy`
- `Get-SetupLogCopyPolicy`

Új outputok:

- `copied_logs/skipped-files.json`
- `copied_logs/system-log-copy-policy.json`
- `copied_logs/setup-log-copy-policy.json`

### ai_summary v3

Új mezők:

- `TruncatedEventLogCount`
- `TruncatedEventLogs`
- `WarningsByCode`

## Validáció

- JSON dokumentumok: szintaktikailag ellenőrizve.
- ZIP integritás: ellenőrizve.
- PowerShell runtime teszt: nem futtatható ebben a konténerben, kliensoldali PowerShell 7.6.2 validáció szükséges.

## Runtime sorrend

1. Patch kicsomagolása a repo gyökerébe.
2. `./diagnostics/Initialize-DiagEnvironment.ps1`
3. `./tools/Collect-SystemEvidence.ps1 -DaysBack 30 -MaxEvents 1200`
4. `ai_summary.json`, `storage/disk-event-153-aggregate.json`, `wer/wer-summary.json`, `copied_logs/skipped-files.json` ellenőrzése.
