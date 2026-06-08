# CLEAN generation log — DiagFramework v1.2.8

## Build metadata

- Timestamp: `2026-06-08T10:53:52.521757+00:00`
- Version: `1.2.8`
- Build type: hotfix / patch
- Purpose: `SystemEvidenceCollector empty-array binding fix + UI detail linebreaks`

## Hiba oka

A SystemEvidenceCollector a futás elején üres hibalistával indult. Az `Add-CollectorError` helper `CurrentErrors` paramétere kötelező `object[]` paraméterként volt deklarálva, ezért PowerShell üres tömb esetén paraméterkötési hibát adott:

```text
Cannot bind argument to parameter 'CurrentErrors' because it is an empty array.
```

## Módosított fájlok

1. `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
   - verzió: `1.2.8`
   - `Add-CollectorError` üres tömb kompatibilis lett
   - `Write-CollectorErrorsSafe`, `Collect-Events`, `Invoke-CollectorStep`, `New-SummaryObject` paraméterei üres kollekciót is elfogadnak
   - null-safe hibalista kezelés

2. `Launcher.ps1`
   - `SystemEvidenceCollector` is megkapja a `TargetKB` paramétert
   - új `Format-DetailTextForPane` helper a részletes panelek sortöréséhez

3. `modules/*/manifest.json`
   - részletesebb `Ui.Summary`
   - részletesebb, számozott, több soros `Ui.RecommendedAction`
   - `SystemEvidenceCollector` manifest verzió: `1.2.8`

4. `README.md`
   - v1.2.8 hotfix dokumentálása

## Futtatási sorrend

1. Patch kicsomagolása a repo gyökerébe.
2. `.diagnostics\Initialize-DiagEnvironment.ps1` futtatása.
3. `.tools\Collect-SystemEvidence.ps1 -DaysBack 30 -MaxEvents 1200 -TargetKB KB5089573` futtatása.
4. GUI ellenőrzés: ÖSSZEFOGLALÓ és JAVASOLT MŰVELET panelek.

## Validáció

- JSON manifestek szintaktikailag ellenőrizve Python `json` parserrel.
- ZIP integritás ellenőrizve `unzip -t` paranccsal.
- PowerShell runtime teszt nem futott ebben a konténerben, mert `pwsh` nem érhető el.

## Ismert korlát

Windows 11 PowerShell 7.6.2 runtime teszt továbbra is kliens oldalon szükséges.
