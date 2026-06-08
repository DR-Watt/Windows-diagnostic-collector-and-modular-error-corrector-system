# Collector acceptance tests v1.3.1

## Kötelező ellenőrzések futás után

```powershell
.\tools\Collect-SystemEvidence.ps1 -DaysBack 30 -MaxEvents 1200
```

## Elvárt fájlok

```text
ai_summary.json
errors\collector-issues.json
events\event-export-metadata.json
storage\disk-event-map.json
storage\disk-event-153-aggregate.json
wer\wer-summary.json
wer\wer-reports.json
copied_logs\skipped-files.json
copied_logs\system-log-copy-policy.json
copied_logs\setup-log-copy-policy.json
manifest.json
```

## Sikerkritériumok

1. A collector státusza `OK`, `OKWithWarnings` vagy indokolt esetben `Partial`, de ne fusson kezeletlen hibába.
2. Magyar disk Event ID 153 üzenet esetén `DiskNumberFromMessage` ne legyen `null`, ha a message tartalmazza a `2 jelű lemez` vagy hasonló mintát.
3. `PdoObjectName` töltődjön, ha a message tartalmaz `\Device\...` értéket.
4. `LogicalBlockAddress` töltődjön, ha a message tartalmaz `0x... logikai blokkcím` mintát.
5. Ha a manifestben `Report.wer` fájlok vannak, a `wer-summary.json` `ReportCount` értéke ne legyen 0.
6. A Panther / Rollback bináris fájlok ne kerüljenek tömegesen a `copied_logs` csomagba; a kihagyások `skipped-files.json` alatt látszódjanak.
7. Ha JSONL event log limitbe fut, az `ai_summary.json` jelezze a `TruncatedEventLogs` mezőben, és az EVTX export legyen elérhető.
