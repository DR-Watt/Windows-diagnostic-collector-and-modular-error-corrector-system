# CLEAN generation log — DiagFramework v1.3.4 Storage Topology Truth Pack

## Build

- Timestamp: `2026-06-08T18:41:20.905440+00:00`
- Version: `1.3.4`
- Type: PATCH_ONLY

## Változtatás oka

A v1.3.3 futás igazolta, hogy a Disk 153 korreláció működik, de a `storage_hints.json` túl erősen tényként jelent meg. A Windows mapping Intel Raid 0 / Intel Raid 1 volume objektumokat mutatott, ezért a UserProvidedTopology és DetectedTopology szétválasztása szükséges.

## Módosított fájlok

- `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
- `modules/SystemEvidenceCollector/manifest.json`
- `config/app.json`
- `config/storage_hints.json`
- `docs/storage_topology_truth_schema_v1_3_4.md`
- `docs/collector_acceptance_tests_v1_3_4.md`
- `docs/p1_normalizers_plan_v1_4_0.md`
- `clean_generation_log.md`

## Új outputok

- `storage/detected-storage-topology.json`
- `storage/storage-hint-validation.json`
- `storage/raid-volume-map.json`
- `storage/physical-disk-candidate-map.json`
- `analysis/target-kb-correlation.json`

## Következő fejlesztési lépcső

A v1.3.4 után a következő csomag a P1 normalizálók csomagja legyen: WER, SetupAPI, CBS, Driver/PnP, WindowsUpdate error és event-correlation normalizálás.
