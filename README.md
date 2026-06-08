# DiagFramework Windows Update Repair MVP v1.1.0 — AI LOG Pack

## Cél

PowerShell 7.x + WPF/XAML alapú Windows 11 diagnosztikai és javító keretrendszer, amely a Windows Update telepítési hibáit vizsgálja, opcionális javításokat kínál, és **AI által elemezhető strukturált LOG csomagot** készít.

A v1.1.0 fejlesztés elsődleges célja: olyan bizonyítékcsomag létrehozása, amely egy külső AI vagy szakértő számára is értelmezhető, különösen többszöri rollback és újraindítás után sikertelenül települő kumulatív frissítéseknél, például: `KB5089573`.

## Követelmények

- Windows 11
- PowerShell 7.x (`pwsh.exe`)
- Admin jogosultság
- WPF futtatási környezet Windows alatt
- Execution Policy: `RemoteSigned` vagy a mellékelt indítón keresztül `Bypass`

## Indítás GUI-val

```powershell
Set-Location C:\DIAG\DiagFramework_WURepair_MVP_v1_1_0_ai_logs
.\install_and_run.bat
```

Vagy közvetlenül:

```powershell
Set-Location C:\DIAG\DiagFramework_WURepair_MVP_v1_1_0_ai_logs
.\diagnostics\Initialize-DiagEnvironment.ps1
.\Launcher.ps1
```

## Gyors célzott AI LOG gyűjtés KB5089573-hoz

Admin PowerShell 7-ből:

```powershell
Set-Location C:\DIAG\DiagFramework_WURepair_MVP_v1_1_0_ai_logs
.\tools\Collect-AIPackage.ps1 -TargetKB KB5089573 -DaysBack 30
```

Vagy:

```bat
collect_ai_logs_for_kb5089573.bat
```

A csomag helye:

```text
logs\ai_packages\YYYYMMDD-HHMMSS-COMPUTER-KB5089573.zip
```

## Új v1.1.0 funkciók

### 1. AI LOG csomag gyűjtő modul

Új modul:

```text
modules\AILogCollector\AILogCollector.ps1
```

Feladata:

- célzott KB azonosító kezelése, alapértelmezés: `KB5089573`,
- Windows Update history gyűjtése COM API alapján,
- WindowsUpdate ETL logok olvasható `WindowsUpdate.log` formátumba konvertálása,
- eseménynaplók gyűjtése JSONL formátumban,
- CBS/DISM/Panther/MoSetup/ReportingEvents logok másolása,
- registry reboot/pending állapotok gyűjtése,
- DISM CheckHealth és csomaglista mentése,
- hibakódok (`0x........`) kinyerése,
- `ai_summary.json` létrehozása,
- ZIP csomag készítése.

### 2. GUI bővítés

Új mezők és gombok:

- `Célzott KB` mező, alapértelmezés: `KB5089573`,
- `Napok` mező, alapértelmezés: `30`,
- `AI LOG csomag készítése` gomb,
- `Logs mappa` gomb.

Az AI LOG csomag készítése **nem javít rendszert**, csak diagnosztikai adatokat gyűjt és tömörít.

### 3. Strukturált JSONL naplózás

A core naplózás bővült:

```text
logs\jsonl\diag-YYYYMMDD.jsonl
```

Minden logbejegyzés tartalmazza:

- `SchemaVersion`,
- `TimestampUtc`,
- `TimestampLocal`,
- `RunId`,
- `CorrelationId`,
- `Severity`,
- `Computer`,
- `User`,
- `Module`,
- `Action`,
- `Host`,
- `Data`.

### 4. AI csomag szerkezete

Példa:

```text
ai_summary.json
manifest.json
AI_README.md
meta\system-info.json
updates\update-history.json
updates\target-KB5089573-history.json
updates\get-hotfix.json
updates\get-windowsupdatelog-result.json
events\event-summary.json
events\*.jsonl
registry\reboot-pending.json
commands\native-command-results.json
copied_logs\CBS.log
copied_logs\dism.log
copied_logs\WindowsUpdate.log
copied_logs\ReportingEvents.log
etl_metadata\etl-files.json
errors\error-codes.json
```

## Célzott KB5089573 elemzési irány

A KB5089573 a Microsoft dokumentáció szerint 2026. május 26-i preview cumulative update Windows 11 25H2 és 24H2 rendszerekhez, OS build: `26200.8524` és `26100.8524`.

Többszöri rollback és újraindítás után az első lépés nem agresszív reset, hanem bizonyítékgyűjtés:

1. AI LOG csomag készítése.
2. `ai_summary.json` ellenőrzése.
3. `updates\target-KB5089573-history.json` HResult és ResultText mezőinek vizsgálata.
4. `events\event-summary.json` alapján érintett log kiválasztása.
5. `errors\error-codes.json` alapján hibakód-csoportosítás.
6. `copied_logs\CBS.log`, `dism.log`, `WindowsUpdate.log`, Panther/MoSetup logok összevetése.
7. Csak ezután cache reset, DISM/SFC vagy célzott javítás.

## AI csomag validálása

```powershell
.\validators\Validate-AIPackage.ps1 -PackagePath .\logs\ai_packages\<csomag>.zip
```

## Biztonsági megjegyzés

Az AI LOG csomag tartalmazhat:

- gépnevet,
- felhasználónevet,
- telepítési útvonalakat,
- event log üzeneteket,
- update history adatokat,
- registry policy részleteket.

Külső AI-nak vagy harmadik félnek küldés előtt szükség esetén anonimizáld.

## Modulok

- `AILogCollector` — AI LOG csomag gyűjtés, nem javít.
- `WUServiceHealth` — Windows Update szolgáltatások ellenőrzése/javítása.
- `WUCacheReset` — SoftwareDistribution/catroot2 rollback-barát átnevezése.
- `ComponentStoreRepair` — DISM/SFC javítás.
- `PSWindowsUpdateManager` — PSWindowsUpdate integráció.

## Validációs sorrend

1. `diagnostics\Initialize-DiagEnvironment.ps1`
2. `validators\Validate-Manifests.ps1`
3. `Launcher.ps1` vagy `tools\Collect-AIPackage.ps1`
4. AI csomag készülése után: `validators\Validate-AIPackage.ps1`



## v1.1.1 AI LOG Collector hotfix

Javítások:

- `AILogCollector.ps1: Argument types do not match` hiba javítása platformbiztos relatívútvonal-képzéssel.
- `.TrimStart('\')` típusérzékeny művelet kiváltása `[System.IO.Path]::GetRelativePath()` alapú megoldással.
- Windows eseménynapló objektumok egyszerűsítése AI-barát, sekély JSON/JSONL struktúrára.
- `ConvertTo-Json` mélységi figyelmeztetések csökkentése/szüntetése `-WarningAction SilentlyContinue` és laposított objektumok használatával.
- `collector-progress.jsonl` és `collector-errors.json` fájlok létrehozása, hogy részleges gyűjtés esetén is látható legyen, melyik fázis bukott el.
- A LOG csomag részleges hiba esetén is ZIP-be kerül, ha a package könyvtár létrejött. Ilyenkor a visszatérési eredmény: `CompletedWithWarnings`.
