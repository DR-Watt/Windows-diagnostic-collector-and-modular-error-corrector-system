# Collector acceptance tests v1.3.4

## Kötelező ellenőrzések

1. `ai_summary.json` SchemaVersion = `diagframework.systemevidence.summary.v3.4`.
2. `storage/detected-storage-topology.json` létezik.
3. `storage/storage-hint-validation.json` létezik.
4. `storage/raid-volume-map.json` létezik.
5. `storage/physical-disk-candidate-map.json` létezik.
6. `analysis/target-kb-correlation.json` létezik.
7. Ha hint JBOD, de detektált disk FriendlyName Intel Raid 0/1 Volume, akkor `StorageHintMismatch` vagy `StorageHintSizeMismatch` jelenjen meg.
8. A Disk 153 summary továbbra is tartalmazza DiskNumber, PDO és LBA mezőket.

## Elfogadható warning

Opcionális event log csatornák hiánya továbbra is `OKWithWarnings`, nem `Failed`.
