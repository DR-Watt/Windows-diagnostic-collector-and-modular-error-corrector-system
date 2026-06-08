# System Evidence Schema v1.3.1 — Quality Fix Pack

## Cél

A v1.3.1 a v1.3.0 P0 evidence collector normalizálási hibáit javítja. A fő cél nem új javítási művelet, hanem az AI/szakértői elemzéshez szükséges adatok pontosabb és tisztább előkészítése.

## Új / módosított elemek

### `storage/disk-event-map.json`

Új mezők az Event ID 153 rekordokban:

```json
{
  "DiskNumber": 2,
  "DiskNumberFromMessage": 2,
  "PdoObjectName": "\\Device\\0000005f",
  "LogicalBlockAddress": "0x8000",
  "Parser": "HungarianDiskNumber",
  "MatchedDisk": { }
}
```

A parser kezeli a magyar lokalizációt is: `2 jelű lemez`, `PDO objektum neve`, `logikai blokkcím`.

### `storage/disk-event-153-aggregate.json`

Összesítő az Event ID 153 eseményekhez:

```json
{
  "EventCount": 34,
  "ByDiskNumber": [],
  "ByPdoObjectName": [],
  "ByLogicalBlockAddress": []
}
```

### `wer/wer-summary.json`

A WER summary most a következő forrásokat vizsgálja:

```text
copied_logs\ReportArchive\**\Report.wer
copied_logs\ReportQueue\**\Report.wer
vendor_logs\**\*.wer
```

Új aggregációk:

- `ByEventType`
- `BySig0`
- `ByAppName`
- `OldestReportTime`
- `NewestReportTime`

### `copied_logs/skipped-files.json`

A copied_logs gyűjtés már nem másolja vakon a teljes Panther / Rollback bináris fájlkészletet. A kihagyott fájlokról külön manifest készül.

### `copied_logs/system-log-copy-policy.json` és `copied_logs/setup-log-copy-policy.json`

Külön policy választja szét az általános rendszerlog és Panther/setup log gyűjtési szabályokat.

### `ai_summary.json`

Sémaverzió: `diagframework.systemevidence.summary.v3`.

Új összefoglaló mezők:

- `TruncatedEventLogCount`
- `TruncatedEventLogs`
- `WarningsByCode`
- bővített `P0Evidence`

## Elemzési javaslat

1. `ai_summary.json`
2. `errors/collector-issues.json`
3. `events/event-export-metadata.json`
4. `storage/disk-event-153-aggregate.json`
5. `storage/disk-event-map.json`
6. `wer/wer-summary.json`
7. `copied_logs/skipped-files.json`
8. `manifest.json`
