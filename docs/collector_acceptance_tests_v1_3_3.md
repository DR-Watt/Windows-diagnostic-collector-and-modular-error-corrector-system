# Collector acceptance tests v1.3.3

## Kötelező ellenőrzések

1. `ai_summary.json` SchemaVersion: `diagframework.systemevidence.summary.v3.3`.
2. `ModuleVersion`: `1.3.3`.
3. `storage/storage-hints.json` létezik és tartalmazza Disk 2/3 Intel RAID JBOD kontextust.
4. `storage/disk153-timeline.json` létezik.
5. `storage/disk153-device-correlation.json` létezik.
6. `storage/controller-driver-map.json` létezik.
7. `storage/storage-driver-snapshot.json` létezik.
8. `storage/storage-risk-summary.json` létezik.
9. `analysis/top-findings.json` létezik.
10. `ai_summary.json` tartalmazza: `TopFindings`, `RiskIndicators`, `SuggestedNextEvidence`.

## Elfogadott állapot

- `OK` vagy `OKWithWarnings` elfogadott.
- Opcionális event log csatorna hiánya warning, nem failure.
- Ha nincs Disk 153 esemény, a storage risk summary `NoSignal` állapotú lehet.
