# Storage Topology Truth Schema v1.3.4

## Cél

A v1.3.4 elkülöníti a felhasználói storage kontextust (`storage_hints.json`) és a Windows által detektált storage topológiát.

## Új fájlok

- `storage/detected-storage-topology.json` — detektált Disk/RAID/PhysicalDisk/PnP/controller kép.
- `storage/storage-hint-validation.json` — UserProvidedTopology és DetectedTopology összevetése.
- `storage/raid-volume-map.json` — RAID volume jellegű disk objektumok.
- `storage/physical-disk-candidate-map.json` — fizikai HDD/SSD jelöltek, Get-PhysicalDisk és PnP alapján.
- `analysis/target-kb-correlation.json` — célzott KB direkt szöveges egyezése Disk 153 korrelációs ablakokban.

## Értelmezési szabály

A `storage_hints.json` értékes kontextus, de nem erősebb bizonyíték, mint a Windows storage stackből gyűjtött tényadat. Ha a hint JBOD-t mond, de a Windows Intel Raid 0/1 Volume objektumokat mutat, akkor a csomag `StorageHintMismatch` jelzést ad.

## Javító modulokra vonatkozó szabály

A Windows Update javítási műveletek előtt a storage topológiát igazolni kell Intel RST/VMD kezelőfelület, SMART/gyártói diagnosztika és fizikai SATA útvonal ellenőrzéssel.
