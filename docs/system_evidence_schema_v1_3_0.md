# System Evidence Schema v1.3.0

## Új P0 evidence outputok

| Mappa/fájl | Jelentés |
|---|---|
| `events/raw/*.evtx` | Nyers eseménynapló export `wevtutil epl` alapján. |
| `events/event-export-metadata.json` | Count, MaxEvents, Truncated, oldest/newest timestamp, raw export status. |
| `windows_update/WindowsUpdate.generated.log` | `Get-WindowsUpdateLog` által generált olvasható Windows Update log. |
| `servicing/dism-scanhealth.txt` | `DISM /Online /Cleanup-Image /ScanHealth /English` kimenet. |
| `servicing/sfc-verifyonly.txt` | `sfc.exe /verifyonly` read-only ellenőrzés kimenet. |
| `servicing/cbs-hresult-summary.json` | CBS HRESULT aggregáció. |
| `storage/*.json` | Disk/PhysicalDisk/Volume/Partition/CIM mapping és reliability counterek. |
| `storage/disk-event-map.json` | Disk Event ID 153 események DiskNumber best-effort mapje. |
| `wer/wer-summary.json` | WER reportok deduplikált összefoglalója. |
| `vendor_logs/vendor-log-policy.json` | Vendor log whitelist/blacklist policy. |
| `manifest.json` | v2 manifest SHA-256 hash mezővel. |

## Státuszmodell

- `OK`: nincs error és warning.
- `OKWithWarnings`: minden fő csomag elkészült, csak nem blokkoló warningok vannak.
- `Partial`: legalább egy elvárt adatforrás hibázott, de a ZIP elemezhető.
- `Failed`: alapvető csomagkészítés nem sikerült.
