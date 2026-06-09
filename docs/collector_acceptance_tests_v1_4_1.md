# Collector acceptance tests v1.4.1

## Kötelező ellenőrzések

- [ ] `SystemEvidenceCollector` verzió: `1.4.1`.
- [ ] `ai_summary.json` SchemaVersion: `diagframework.systemevidence.summary.v4.1`.
- [ ] `ai_summary.json` tartalmazza: `CompatibleP1Version = 1.4.0`.
- [ ] `analysis/servicing/cbs-log-inventory.json` létrejön.
- [ ] `CbsPersist*.log` és `CbsPersist*.cab` másolása bekerül az inventoryba, ha vannak.
- [ ] CDB hiány esetén nincs collector failure, csak warning/summary: `CdbNotFound`.
- [ ] CDB jelenlét esetén minden minidumphoz raw TXT és normalizált JSON készül.
- [ ] `analysis/repair-source-advisor.json` létrejön.
- [ ] `analysis/kb-context-handoff.json` létrejön.
- [ ] P1 handoff mezők megjelennek az `ai_summary.json` fájlban.

## NOTI-BAUNOK specifikus elvárás

- [ ] 0x800F0915 / repair content jel esetén a repair-source advisor `RepairSourceIssueCandidate` státuszt ad.
- [ ] Minidump jelenléte esetén a rendszer nem állít végleges driver gyökérokot WinDbg/CDB elemzés nélkül.
