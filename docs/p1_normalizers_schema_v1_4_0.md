# P1 Normalizers schema v1.4.0

## Cél

A P1 normalizálók a P0/P1 evidence csomag nyers és félig strukturált fájljaiból AI-barát, deduplikált, rangsorolt JSON réteget készítenek.

## Outputok

| Fájl | Normalizáló | Tartalom |
|---|---|---|
| `analysis/normalized-wer.json` | WERNormalizer | Report.wer / wer-reports aggregáció, ByEventType, ByAppName, ByFaultModule. |
| `analysis/normalized-setupapi.json` | SetupAPINormalizer | setupapi.dev.log/setupapi.setup.log hibasorok, HRESULT-ek. |
| `analysis/normalized-cbs-hresults.json` | CBSHResultNormalizer | CBS/DISM/SFC HRESULT és servicing minták. |
| `analysis/normalized-pnp-problems.json` | DriverPnPProblemNormalizer | PnP problem/stale eszközök, Kernel-PnP és DeviceSetup warningok. |
| `analysis/normalized-event-correlation.json` | EventCorrelationNormalizer | Disk153/update/setup/power/hyperv korrelációs összegzés. |
| `analysis/normalized-windowsupdate-errors.json` | WindowsUpdateErrorNormalizer | WindowsUpdate.generated.log, ReportingEvents.log, WU event hibák, KB/HRESULT minták. |
| `analysis/p1-findings.json` | Aggregátor | Emberi/AI döntési top findingok. |
| `analysis/p1-normalization-summary.json` | Aggregátor | Státusz, darabszámok, output lista, issue lista. |

## Státuszmodell

- `OK`: minden normalizáló lefutott.
- `OKWithWarnings`: nem blokkoló input-hiány vagy részleges adat.
- `Partial`: legalább egy normalizáló hibázott, de a többi output elkészült.

## Read-only policy

A modul nem javít rendszert, nem futtat DISM RestoreHealth vagy SFC /scannow parancsot, nem módosít registryt és drivert. Csak `analysis/*.json` fájlokat hoz létre és az `ai_summary.json`-t bővíti P1Normalization blokkal.
