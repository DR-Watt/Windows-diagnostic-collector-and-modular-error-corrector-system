# P0 → P1 handoff schema v1.4.1

## Cél

A v1.4.1 P0 Evidence Bridge célja, hogy a P1 normalizáló ág aktuális `1.4.0` verziójához stabil bemenetet adjon.

## Új P0 outputok

```text
analysis/servicing/cbs-log-inventory.json
analysis/servicing/cbs-persist-collection-summary.json
analysis/windbg/cdb-discovery.json
analysis/windbg/normalized/minidump-summary.json
analysis/windbg/normalized/suspect-drivers.json
analysis/windbg/normalized/crash-timeline.json
analysis/windbg/normalized/crash-blackbox-summary.json
analysis/repair-source-advisor.json
analysis/kb-context-handoff.json
```

## Normalizáló átadás

| P1 normalizáló | P0 bemenet | Megjegyzés |
|---|---|---|
| WERNormalizer | `wer/*.json`, `analysis/windbg/normalized/minidump-summary.json` | WER és crash összekötés |
| CBSHResultNormalizer | `servicing/cbs-hresult-summary.json`, `analysis/servicing/cbs-log-inventory.json`, `copied_logs/CBS/*` | 0x800F0915 / 0x800F0845 |
| WindowsUpdateErrorNormalizer | `windows_update/windowsupdate-signal-summary.json`, `analysis/kb-context-handoff.json` | KB-szintű hibakód csoportosítás |
| EventCorrelationNormalizer | EVTX/JSONL események, KB handoff, crash timeline | KB/CBS/DISM/reboot/crash idővonal |
| DriverPnPProblemNormalizer | PnP/driver snapshot + suspect-drivers | driverjelöltek, nem gyökérok |
| SetupAPINormalizer | setupapi.dev/setup logs | driver install lifecycle |

## Alapelv

A P0 ág tényt és bizonyítékot gyűjt. A P1 ág normalizál, kategorizál és következtet.
