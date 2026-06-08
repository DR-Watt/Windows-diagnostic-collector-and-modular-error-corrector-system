# CLEAN Generation Log — DiagFramework v1.2.1 SystemEvidence Hotfix

- **GeneratedAt:** 2026-06-08T10:36:19.306686+02:00
- **Project:** Windows diagnostic collector and modular error corrector system
- **Version:** 1.2.1
- **Change type:** Hotfix / robustness hardening
- **Scope:** CLEAN kódgenerálási LOG, nem futó szoftver által generált rendszer LOG

## Cél

A `SystemEvidenceCollector` modul `Argument types do not match` hibájának megelőzése és a rendszer LOG csomag AI-elemzésének javítása.

## Hibakép

A felhasználói futás szerint a GUI logban a rendszer LOG csomag készítése az alábbi hibával állt meg:

```text
SystemEvidenceCollector csomag hiba: Argument types do not match
```

A feltöltött `collector-progress.jsonl` alapján a futás a `DriverSnapshot` után állt meg. Ez a v1.2.0 kód alapján az eseménynapló-gyűjtés, logmásolás vagy manifest/ZIP szakasz környékére szűkíthető.

## Módosított fájlok

| Fájl | Művelet | Megjegyzés |
|---|---|---|
| `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1` | módosítva | v1.2.1 hibaszigetelt gyűjtés, root AI_README generálás, részleges csomag |
| `modules/SystemEvidenceCollector/manifest.json` | módosítva | verzió és UI magyarázat frissítve |
| `tools/Collect-SystemEvidence.ps1` | módosítva | `MaxEvents` és opcionális `TargetKB` támogatás |
| `collect_system_evidence.bat` | módosítva | CLI paraméterek bővítése |
| `config/ui.hu-HU.json` | módosítva | v1.2.1 szövegek és tooltip |
| `validators/Validate-SystemEvidencePackage.ps1` | új | SystemEvidence ZIP/mappa szerkezeti validátor |
| `logs/AI_README.md` | új | LOG gyökér AI útmutató |
| `logs/evidence_packages/AI_README.md` | új | SystemEvidence gyökér AI útmutató |
| `logs/ai_packages/AI_README.md` | új | célzott AI csomagok gyökér útmutató |
| `README.md` | módosítva | v1.2.1 használati leírás |
| `clean_generation_log.md` | módosítva | Markdown changelog/build log |

## Technikai javítások

1. A rendszer LOG gyűjtés már nem egyetlen törékeny folyamatlánc.
2. Minden fő lépés saját hibakezelést és `collector-progress.jsonl` bejegyzést kap.
3. A `Get-WinEvent` kimenet laposított, serializálható objektummá alakul.
4. A registry értékek mély .NET objektumok helyett név/érték párokká alakulnak.
5. A relatív útvonal-képzés típusbiztos wrapperbe került.
6. A ZIP-manifest készítés hibája nem akadályozza meg az addig létrejött csomag elemzését.
7. A `logs` és `logs/evidence_packages` gyökér is kap AI_README fájlt.

## Futtatási sorrend

```powershell
Set-Location C:\DIAG\DiagFramework_WURepair_MVP_v1_2_1_system_evidence_hotfix
.\install_and_run.bat
```

CLI rendszer LOG gyűjtés:

```powershell
.\tools\Collect-SystemEvidence.ps1 -DaysBack 30 -MaxEvents 1200 -TargetKB KB5089573
```

Validálás:

```powershell
.\validators\Validate-SystemEvidencePackage.ps1 -PackagePath .\logs\evidence_packages\<package>.zip
```

## Ismert korlátok

- Windows runtime tesztet ebben a környezetben nem lehetett futtatni.
- Egyes eseménynaplók hiányozhatnak vagy jogosultság miatt nem olvashatók; ez `errors/collector-errors.json` alatt jelenik meg.
- A vendor loggyűjtés fájlszám- és méretkorláttal dolgozik.

## Validáció

- JSON fájlok szintaxisa ellenőrizve.
- ZIP integritás ellenőrizve.
- Patch ZIP integritás ellenőrizve.

