# DiagFramework Windows Update Repair MVP v1.2.2 — Structured AI UI & System Evidence Hotfix

## v1.2.2 hotfix összefoglaló

Ez a build a `SystemEvidenceCollector` hibaszigetelését javítja. A rendszer LOG csomag most már részleges adatforrás-hiba esetén is megpróbál `ai_summary.json`, `collector-progress.jsonl`, `errors/collector-errors.json`, `manifest.json`, `AI_README.md` és ZIP csomagot készíteni.

Új gyökérszintű AI útmutatók:

```text
logs\AI_README.md
logs\evidence_packages\AI_README.md
logs\ai_packages\AI_README.md
```

A gyűjtőmodul továbbra sem végez javítást, csak bizonyítékot gyűjt.


## Cél

PowerShell 7.x + WPF/XAML alapú Windows 11 diagnosztikai és javító keretrendszer, amely:

- Windows Update telepítési hibákat vizsgál,
- opcionális javításokat kínál felhasználói jóváhagyással,
- célzott KB-frissítésekhez AI által elemezhető LOG csomagot készít,
- általános boot/setup/driver/crash/vendor diagnosztikai bizonyítékcsomagot készít,
- a GUI feliratait, tooltipjeit és fő üzeneteit külön strukturált JSON fájlban tartja,
- a modulok magyarázó szövegeit a modul saját `manifest.json` fájljában tárolja.

## v1.2.0 fő változások

### 1. Strukturált UI erőforrásfájl

Új fájl:

```text
config\ui.hu-HU.json
```

Ez tartalmazza:

- ablakcímet,
- gombfeliratokat,
- címkéket,
- tooltip szövegeket,
- fő üzeneteket,
- használati megjegyzést.

### 2. Manifest-vezérelt modulmagyarázatok

Minden modul manifestje tartalmazza az új `Ui` blokkot:

```json
{
  "Ui": {
    "Summary": "...",
    "RecommendedAction": "...",
    "ToolTip": "...",
    "ExpectedOutput": "...",
    "Impact": "..."
  }
}
```

A GUI ezeket használja az ÖSSZEFOGLALÓ és JAVASOLT MŰVELET panel feltöltéséhez.

### 3. GUI elrendezés módosítása

A modulok listája külön bal oldali táblában jelenik meg. Az ÖSSZEFOGLALÓ és JAVASOLT MŰVELET nem hosszú GridView oszlopként szerepel, hanem két külön, függőlegesen görgethető jobb oldali panelben.

Ez hosszabb magyarázó szövegeknél kezelhetőbb.

### 4. Új SystemEvidenceCollector modul

Új modul:

```text
modules\SystemEvidenceCollector\SystemEvidenceCollector.ps1
```

Feladata:

- System/Application/Setup eseménynaplók gyűjtése,
- WindowsUpdateClient események gyűjtése,
- Kernel-Boot, Kernel-PnP, DeviceSetupManager, DriverFrameworks események gyűjtése,
- CBS/DISM/Panther/SetupAPI/WER/Minidump adatok másolása,
- ismert gyártói diagnosztikai loghelyek gyűjtése: Dell, HP, Lenovo, Intel, NVIDIA, AMD,
- driver snapshot mentése,
- pending reboot registry állapot mentése,
- `ai_summary.json`, `manifest.json`, `AI_README.md` és ZIP csomag készítése.

A modul nem javít rendszert.

### 5. Markdown CLEAN generálási log

A CLEAN kódgenerálási log a továbbiakban Markdown formátumú:

```text
clean_generation_log.md
```

Ez egyben build log és fejlesztői changelog.

## Követelmények

- Windows 11
- PowerShell 7.x (`pwsh.exe`)
- Admin jogosultság
- WPF futtatási környezet Windows alatt
- Execution Policy: `RemoteSigned`, vagy a mellékelt `.bat` indítón keresztül `Bypass`

## Indítás GUI-val

```powershell
Set-Location C:\DIAG\DiagFramework_WURepair_MVP_v1_2_0_structured_ai_ui
.\install_and_run.bat
```

Vagy közvetlenül:

```powershell
Set-Location C:\DIAG\DiagFramework_WURepair_MVP_v1_2_0_structured_ai_ui
.\diagnostics\Initialize-DiagEnvironment.ps1
.\Launcher.ps1
```

## Célzott AI LOG gyűjtés KB5089573-hoz

Admin PowerShell 7-ből:

```powershell
Set-Location C:\DIAG\DiagFramework_WURepair_MVP_v1_2_0_structured_ai_ui
.\tools\Collect-AIPackage.ps1 -TargetKB KB5089573 -DaysBack 30
```

Vagy:

```bat
collect_ai_logs_for_kb5089573.bat
```

Csomag helye:

```text
logs\ai_packages\YYYYMMDD-HHMMSS-COMPUTER-KB5089573.zip
```

## Általános rendszer LOG / evidence csomag

Admin PowerShell 7-ből:

```powershell
Set-Location C:\DIAG\DiagFramework_WURepair_MVP_v1_2_0_structured_ai_ui
.\tools\Collect-SystemEvidence.ps1 -DaysBack 30
```

Vagy:

```bat
collect_system_evidence.bat
```

Csomag helye:

```text
logs\evidence_packages\YYYYMMDD-HHMMSS-COMPUTER-SystemEvidence.zip
```

## Validátorok

Manifest validáció:

```powershell
.\validators\Validate-Manifests.ps1
```

UI resource validáció:

```powershell
.\validators\Validate-UiResources.ps1
```

AI LOG csomag validáció:

```powershell
.\validators\Validate-AIPackage.ps1 -PackagePath .\logs\ai_packages\<package>.zip
```

## Biztonsági alapelv

- A LOG gyűjtő modulok nem javítanak rendszert.
- A Windows Update cache reset törlés helyett átnevezést használ.
- Javító műveleteket először WhatIf módban célszerű futtatni.
- DISM/SFC hosszú ideig futhat, és újraindítást igényelhet.

## GitHub inputok

A v1.2.0 átdolgozás tervezésénél figyelembe vett GitHub repók:

- `DR-Watt/Windows-diagnostic-collector-and-modular-error-corrector-system`
- `DR-Watt/WindowsRescue`
- `DR-Watt/Windows-Repair-Tool`
- `DR-Watt/Windows-Maintenance-Tool`
- `DR-Watt/WindowsMaintenance`

A külső repók nem lettek egy az egyben átmásolva; tervezési mintaként használtam őket: biztonságos mentés, interaktív javítás, DISM/SFC sorrend, GUI tooltip/preview szemlélet, opcionális agresszív műveletek.


## v1.2.2 hotfix

### Javítás

A `SystemEvidenceCollector.ps1` modulban a `Convert-EventRecordFlat` függvény PowerShell parser-hibát okozhatott, mert a `[PSCustomObject]@{ ... }` objektumliterál értékei között közvetlen `try { } catch { }` szerkezet szerepelt.

A v1.2.2-ben a védett eseménymező-kiolvasások a hashtable-literal előtt, külön változókba kerülnek, majd ezekből készül az objektum. Ez megszünteti a következő típusú hibát:

```text
Missing closing '}' in statement block or type definition.
Unexpected token 'ProviderName' in expression or statement.
```

### Új validátor

Új fájl:

```text
validators\Validate-PowerShellSyntax.ps1
```

A környezeti diagnosztika most már indításkor lefuttatja a PowerShell parser-alapú szintaxisellenőrzést a `.ps1` és `.psm1` fájlokon, így hasonló parse-hiba nem csak a GUI-gomb megnyomásakor derül ki.
