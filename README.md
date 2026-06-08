# DiagFramework Windows Update Repair MVP v1.2.8 — Empty Array & UI Linebreak Hotfix

## Cél

PowerShell 7.x + WPF/XAML alapú Windows 11 diagnosztikai és javító keretrendszer. A v1.2.8 célja, hogy a rendszer LOG csomag akkor is elemezhető maradjon, ha egyes adatforrások — például registry pending reboot, driver snapshot vagy eseménynapló — futás közben hibát adnak.

## Fő változások v1.2.8-ben

- `SystemEvidenceCollector.ps1` runtime resilience hotfix.
- `SystemEvidenceCollector` verzió: `1.2.7`.
- Generikus `System.Collections.Generic.List[object]` használat eltávolítva a rendszer evidence gyűjtés kritikus útjából.
- A registry, driver és eseménynapló szakaszok natív PowerShell tömböket és laposított objektumokat használnak.
- A collector minden fő lépés után írja a `collector-progress.jsonl` állományt.
- Részleges hiba esetén `Partial` státuszú csomagot készít `ai_summary.json`, `AI_README.md` és `errors/collector-errors.json` fájlokkal.
- A GUI `ÖSSZEFOGLALÓ` és `JAVASOLT MŰVELET` szövegei részletesebb, lépésenként értelmezhető manifest szövegeket kaptak.
- A GUI most a célzott KB mezőt a `SystemEvidenceCollector` modulnak is átadja.

## Indítás

```powershell
Set-Location C:\git_wdcmac\Windows-diagnostic-collector-and-modular-error-corrector-system
.\install_and_run.bat
```

## Rendszer LOG csomag készítése

```powershell
.	ools\Collect-SystemEvidence.ps1 -DaysBack 30 -MaxEvents 1200 -TargetKB KB5089573
```

## Fontos fájlok a rendszer LOG csomagban

```text
AI_README.md
ai_summary.json
collector-progress.jsonl
errors\collector-errors.json
events\event-summary.json
registry
eboot-pending.json
drivers\pnp-signed-drivers.json
copied_logs\copied-files.json
commands
ative-command-results.json
manifest.json
```

## Elemzési javaslat AI számára

1. `AI_README.md`
2. `ai_summary.json`
3. `collector-progress.jsonl`
4. `errors/collector-errors.json`
5. `events/event-summary.json`
6. CBS/DISM/Panther/SetupAPI/WER és vendor logok.

## Korlát

A csomagot a build környezetben nem tudtam Windows 11 PowerShell 7.6.2 runtime alatt futtatni. A kliensen a környezeti validáció már lefutott; a v1.2.8 fő célja a `SystemEvidenceCollector` futásidejű hibatűrésének javítása.


## v1.2.8 hotfix

### Javítások

- A `SystemEvidenceCollector` üres hibalista (`@()`) esetén nem áll meg többé a `CurrentErrors` paraméter kötési hibájával.
- Az érintett gyűjtő helper függvények `AllowEmptyCollection` támogatást kaptak.
- A GUI most a `TargetKB` értéket a `SystemEvidenceCollector` modulnak is átadja.
- Az ÖSSZEFOGLALÓ és JAVASOLT MŰVELET panelek több soros, számozott lépésekkel tagolt szöveget kapnak.
- A `Launcher.ps1` régebbi egy soros manifest szövegek esetén is új sorba tördeli a `1)`, `2)`, `3)` lépéseket.

### Tesztelendő parancs

```powershell
Set-Location C:\git_wdcmac\Windows-diagnostic-collector-and-modular-error-corrector-system
.\diagnostics\Initialize-DiagEnvironment.ps1
.	ools\Collect-SystemEvidence.ps1 -DaysBack 30 -MaxEvents 1200 -TargetKB KB5089573
```
