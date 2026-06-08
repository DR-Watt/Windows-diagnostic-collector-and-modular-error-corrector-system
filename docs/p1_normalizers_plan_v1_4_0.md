# P1 Normalizálók — v1.4.0 tervezett csomag

A v1.3.4 után a fókusz a P1 normalizálókon legyen, nem újabb nagy P0 adatgyűjtésen.

## Tervezett normalizálók

1. `WERNormalizer`
   - WER Report.wer mezők normalizálása: EventType, AppName, FaultModule, BucketId, CabId, time.

2. `SetupAPINormalizer`
   - setupapi.dev.log / setupapi.setup.log hibaszakaszok, device install failures, INF mapping.

3. `CBSHResultNormalizer`
   - CBS.log HRESULT, package identity, component store corruption minták.

4. `DriverPnPProblemNormalizer`
   - Get-PnpDevice problem code, missing / not present / failed device mapping.

5. `EventCorrelationNormalizer`
   - Disk 153, Kernel-Power, Setup, WindowsUpdateClient és reboot időablakok közös idősora.

6. `WindowsUpdateErrorNormalizer`
   - WindowsUpdate.generated.log hibakódok, target KB scan result és retry mintázatok.

## Elvárt outputok

- `analysis/normalized-wer.json`
- `analysis/normalized-setupapi.json`
- `analysis/normalized-cbs-hresults.json`
- `analysis/normalized-pnp-problems.json`
- `analysis/normalized-event-correlation.json`
- `analysis/normalized-windowsupdate-errors.json`
- `analysis/p1-findings.json`
