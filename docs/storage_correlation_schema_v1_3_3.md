# Storage Correlation Schema v1.3.3

## Cél

A v1.3.3 Storage Correlation Pack a Disk Event ID 153 eseményeket konkrét Windows storage objektumokhoz és a felhasználó által megadott topológiához köti.

## Felhasználói topológia

- Disk 2 és Disk 3: alaplapi Intel RAID controllerre csatolt 2x8TB SATA HDD.
- RAID mód: JBOD.

## Új fájlok

```text
config/storage_hints.json
storage/storage-hints.json
storage/controller-driver-map.json
storage/storage-driver-snapshot.json
storage/pnp-storage-devices.json
storage/disk153-timeline.json
storage/disk153-device-correlation.json
storage/disk153-update-setup-correlation.json
storage/storage-risk-summary.json
analysis/top-findings.json
analysis/risk-indicators.json
analysis/suggested-next-evidence.json
analysis/suggested-next-actions.json
```

## ai_summary.json új mezők

```json
{
  "SchemaVersion": "diagframework.systemevidence.summary.v3.3",
  "TopFindings": [],
  "RiskIndicators": [],
  "SuggestedNextEvidence": []
}
```

## Értelmezési szabály

A Disk Event ID 153 nem bizonyít önmagában fizikai lemezhibát. Intel RAID JBOD SATA HDD topológiában a storage útvonal teljes láncát kell vizsgálni: HDD SMART, SATA kábel/port, tápellátás, Intel RST/RAID driver, chipset/firmware és Windows Update/Setup időbeli korreláció.
