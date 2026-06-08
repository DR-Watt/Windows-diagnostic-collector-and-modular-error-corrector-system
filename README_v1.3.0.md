# DiagFramework v1.3.0 — System Evidence P0 Quality Pack

Ez a patch a `SystemEvidenceCollector` P0 bizonyítékminőségi fejlesztéseit tartalmazza.

## Új elemek

- EVTX export `wevtutil epl` használatával.
- `Get-WindowsUpdateLog` alapú `WindowsUpdate.generated.log`.
- DISM ScanHealth és SFC verifyonly read-only servicing evidence.
- Storage mapping: disk, physical disk, volume, partition, CIM association és storage reliability counter.
- Disk Event ID 153 best-effort map.
- Vendor log whitelist/blacklist.
- Manifest v2 SHA-256 hash mezőkkel.
- `OKWithWarnings` státuszmodell.

## Futtatás

```powershell
Set-Location C:\git_wdcmac\Windows-diagnostic-collector-and-modular-error-corrector-system
.\diagnostics\Initialize-DiagEnvironment.ps1
.	ools\Collect-SystemEvidence.ps1 -DaysBack 30 -MaxEvents 1200
```

## Megjegyzés

A modul továbbra is read-only jellegű. A `DISM /ScanHealth` és `sfc /verifyonly` nem javít, de hosszabb ideig futhat.
