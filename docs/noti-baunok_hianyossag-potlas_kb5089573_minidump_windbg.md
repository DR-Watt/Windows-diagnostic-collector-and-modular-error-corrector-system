# Hiányosság-pótlási jegyzet a fejlesztői szálhoz

**Téma:** NOTI-BAUNOK diagnosztikai ZIP tanulságai – KB5089573 frissítési hiba, CBS/DISM servicing store sérülés, minidump elemzés WinDbg/CDB automatizálással  
**Forráscsomag:** `20260608-203532-NOTI-BAUNOK-SystemEvidence.zip`  
**Cél:** a diagnosztikai rendszer hiányosságainak pótlása, hogy a következő gyűjtés és AI-elemzés pontosabban tudja elkülöníteni a Windows Update / CBS / DISM / driver-crash okokat.  
**Javasolt fejlesztési besorolás:** `v1.4.x P1 Normalizers + CrashDump Evidence Pack`  
**Kapcsolódó P1 normalizálók:** `WERNormalizer`, `CBSHResultNormalizer`, `WindowsUpdateErrorNormalizer`, `EventCorrelationNormalizer`, `DriverPnPProblemNormalizer`

---

## 1. Rövid vezetői összefoglaló

A NOTI-BAUNOK gépen a KB5089573 frissítés nem egyszerű letöltési vagy Windows Update klienshibának tűnik. Az eddigi evidencia alapján a fő gyanú:

```text
Component Store / WinSxS servicing sérülés
+
hiányzó vagy el nem érhető repair content
+
KB5089573 telepítési sikertelenség
```

A legfontosabb hibajelzések:

```text
KB5089573 install failure: 0x800F0845
DISM/CBS repair failure: 0x800F0915
Not able to find repair content anywhere
```

Fontos tanulság: az `sfc /verifyonly` vagy akár az `sfc /scannow` tiszta eredménye **nem zárja ki** a component store / CBS servicing sérülést. A NOTI-BAUNOK esetében a DISM/CBS oldal jelzi a problémát, nem elsődlegesen az SFC.

A ZIP tartalmazott minidumpokat is, de ezekből a jelenlegi collector még nem készít WinDbg/CDB alapú strukturált elemzést. Ez hiányosság, mert a dumpok eldönthetik, hogy a frissítési hiba mellett van-e párhuzamos kernel-driver crash ág, például Intel NPU/VPU, storage, PnP vagy egyéb kernel driver irányban.

---

## 2. Microsoft oldali KB-kontekstus

A KB5089573 hivatalos Microsoft Support oldala szerint ez egy **2026. május 26-i Windows 11 preview cumulative update**, amely az alábbi OS build célállapotokat érinti:

```text
OS Builds: 26200.8524 and 26100.8524
```

A Microsoft oldalon szerepel, hogy a frissítés tartalmazza a következő servicing stack frissítést is:

```text
Windows 11 servicing stack update: KB5092734 – 26100.8519
```

A Microsoft ugyanazon KB-oldalon jelenleg azt jelzi, hogy:

```text
Microsoft is not currently aware of any issues with this update.
```

Ezért a diagnosztikai rendszer ne azt tekintse alapértelmezettnek, hogy a KB5089573 globálisan hibás, hanem lokális gépállapotot vizsgáljon:

```text
CBS / WinSxS állapot
DISM repair source elérhetőség
SSU/LCU csomagállapot
pending reboot
rollback / package state transition
driver crash / minidump korreláció
```

**Hivatalos referencia:**  
<https://support.microsoft.com/en-us/topic/may-26-2026-kb5089573-os-builds-26200-8524-and-26100-8524-preview-f378c8ae-0170-47c9-a1e9-dfef978c8e17>

---

## 3. A NOTI-BAUNOK ZIP-ből levont fő diagnosztikai tanulságok

### 3.1. Hasznos, már meglévő evidencia

A ZIP első körös általános diagnosztikára hasznos, mert tartalmazta legalább az alábbiakat:

```text
commands/dism-checkhealth.txt
commands/dism-packages-list.txt
commands/dism-packages-table.txt
copied_logs/CBS.log
copied_logs/dism.log
copied_logs/ReportingEvents.log
copied_logs/WindowsUpdate.log
copied_logs/setupapi.dev.log
copied_logs/Minidump/*.dmp
copied_logs/ReportArchive/**/Report.wer
```

Ezek alapján már azonosítható volt:

```text
1. KB5089573 telepítési sikertelenség
2. CBS/DISM servicing store javítható, de nem teljesen javított állapot
3. 0x800F0915 repair content hiány
4. WER WindowsServicingFailureInfo relevancia
5. minidumpok jelenléte
```

### 3.2. Kritikus hiányosság: CbsPersist logok nem kerültek be

A legnagyobb hiányosság, hogy a ZIP-ben az aktuális `CBS.log` benne van, de a releváns, rotált CBS persistent naplók nem kerültek be:

```text
C:\Windows\Logs\CBS\CbsPersist_*.log
C:\Windows\Logs\CBS\CbsPersist_*.cab
```

A Windows servicing hibák gyakran nem az aktuális `CBS.log` végén vannak, hanem korábbi `CbsPersist_*` fájlokban. A NOTI-BAUNOK esetében a WER riportok konkrétan CBS persist irányba mutattak, ezért ez P1 hiányosság.

**Fejlesztői követelmény:** a collector a következő verziótól mindig gyűjtse:

```text
C:\Windows\Logs\CBS\CBS.log
C:\Windows\Logs\CBS\CbsPersist*.log
C:\Windows\Logs\CBS\CbsPersist*.cab
C:\Windows\Logs\DISM\dism.log
C:\Windows\Logs\DISM\dism*.log
C:\Windows\SoftwareDistribution\ReportingEvents.log
```

**Megjegyzés:** CAB esetén vagy másoljuk nyersen, vagy opcionálisan bontsuk ki külön `ExtractedCbsPersist/` mappába.

---

## 4. Új modul: `MiniDumpWinDbgAnalyzer`

### 4.1. Miért kell?

A NOTI-BAUNOK ZIP több minidumpot tartalmazott:

```text
copied_logs/Minidump/060426-11593-01.dmp
copied_logs/Minidump/060526-10296-01.dmp
copied_logs/Minidump/060526-11031-01.dmp
copied_logs/Minidump/060526-11500-01.dmp
copied_logs/Minidump/060526-11703-01.dmp
```

Ezek jelenléte önmagában még nem bizonyít driverhibát, de a frissítési hiba környezetében kiemelten fontos lenne eldönteni:

```text
1. volt-e kernel crash a KB telepítésének vagy rollbackjének idején;
2. van-e visszatérő driver a crash stackben;
3. érintett-e storage / PnP / NPU / GPU / firmware komponens;
4. a crash összefügg-e update reboot ciklussal;
5. a dump tartalmaz-e blackbox információkat: BSD, PNP, NTFS, WINLOGON.
```

### 4.2. Miért CDB és nem GUI-s WinDbg?

Automatizált collector pipeline-ban a javasolt eszköz a Microsoft **CDB.exe** konzolos debugger, mert scriptből stabilabban hívható, mint a GUI-s WinDbg.

Hivatalos Microsoft dokumentáció alapján:

- a CDB `-z` kapcsolóval crash dump fájlt tud megnyitni;
- a `!analyze -v` automatikus verbose crash analysis kimenetet ad;
- a `-logo` / `-loga` kapcsolóval a debugger session logolható;
- small memory dump vizsgálatnál a Microsoft a `!analyze -show`, `!analyze -v`, és `lm N T` jellegű parancsokat is említi.

**Hivatalos referenciák:**

- CDB command-line options:  
  <https://learn.microsoft.com/windows-hardware/drivers/debugger/cdb-command-line-options>
- Using the `!analyze` extension:  
  <https://learn.microsoft.com/windows-hardware/drivers/debugger/using-the--analyze-extension>
- How to read a small memory dump:  
  <https://learn.microsoft.com/troubleshoot/windows-client/performance/read-small-memory-dump-file>
- Tools included in Debugging Tools for Windows:  
  <https://learn.microsoft.com/windows-hardware/drivers/debugger/extra-tools>

---

## 5. Javasolt output-struktúra a WinDbg/CDB elemzéshez

A collector a nyers dumpokat változatlanul őrizze meg, és mellé generáljon elemzési outputokat:

```text
SystemEvidence/
  copied_logs/
    Minidump/
      *.dmp

  analysis/
    windbg/
      raw/
        060426-11593-01.windbg.txt
        060526-10296-01.windbg.txt
        060526-11031-01.windbg.txt
        060526-11500-01.windbg.txt
        060526-11703-01.windbg.txt
      xml/
        060426-11593-01.analyze.xml
        060526-10296-01.analyze.xml
      normalized/
        minidump-summary.json
        suspect-drivers.json
        crash-timeline.json
        crash-update-correlation.json
        crash-blackbox-summary.json
```

### 5.1. `minidump-summary.json` javasolt séma

```json
[
  {
    "dumpFile": "copied_logs/Minidump/060526-11031-01.dmp",
    "dumpTimestampLocal": "2026-06-05T10:45:00",
    "analysisStatus": "Success",
    "bugCheckCode": "0x00000000",
    "bugCheckName": null,
    "bugCheckParameters": [],
    "probablyCausedBy": null,
    "moduleName": null,
    "imageName": null,
    "failureBucketId": null,
    "processName": null,
    "stackTextExtracted": true,
    "loadedModulesExtracted": true,
    "hasBlackboxBSD": false,
    "hasBlackboxPNP": false,
    "hasBlackboxNTFS": false,
    "hasBlackboxWinlogon": false,
    "rawLogPath": "analysis/windbg/raw/060526-11031-01.windbg.txt",
    "xmlPath": "analysis/windbg/xml/060526-11031-01.analyze.xml",
    "confidence": "NeedsManualReview",
    "notes": []
  }
]
```

### 5.2. `suspect-drivers.json` javasolt séma

```json
[
  {
    "driverName": "npu_kmd.sys",
    "moduleName": "npu_kmd",
    "occurrences": 3,
    "firstSeen": "2026-06-04T14:56:00",
    "lastSeen": "2026-06-05T12:29:00",
    "evidenceSources": [
      "analysis/windbg/raw/060426-11593-01.windbg.txt",
      "analysis/windbg/raw/060526-11500-01.windbg.txt"
    ],
    "role": "Kernel driver candidate, not confirmed root cause",
    "confidence": "CandidateOnly"
  }
]
```

**Fontos szabály:** a `Probably caused by` mezőt a rendszer ne tekintse automatikusan végleges gyökérokbizonyítéknak. Ez csak elsődleges hibakeresési jelölt. A UI-ban és az AI összefoglalóban is így kell megjeleníteni.

---

## 6. Javasolt PowerShell vázlat: CDB batch elemzés

```powershell
param(
    [Parameter(Mandatory = $true)]
    [string]$DumpRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutRoot,

    [string]$CdbPath = ""
)

$ErrorActionPreference = "Stop"

if (-not $CdbPath) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe",
        "${env:ProgramFiles}\Windows Kits\10\Debuggers\x64\cdb.exe"
    )
    $CdbPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $CdbPath) {
    throw "cdb.exe nem található. Telepíteni kell a Microsoft Debugging Tools for Windows csomagot."
}

New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null

$symbolCache = Join-Path $OutRoot "symbols"
New-Item -ItemType Directory -Path $symbolCache -Force | Out-Null

$symbolPath = "srv*$symbolCache*https://msdl.microsoft.com/download/symbols"

$results = foreach ($dump in Get-ChildItem -Path $DumpRoot -Filter "*.dmp" -Recurse) {
    $safeName = [IO.Path]::GetFileNameWithoutExtension($dump.Name)
    $rawDir = Join-Path $OutRoot "raw"
    $xmlDir = Join-Path $OutRoot "xml"
    New-Item -ItemType Directory -Path $rawDir -Force | Out-Null
    New-Item -ItemType Directory -Path $xmlDir -Force | Out-Null

    $logPath = Join-Path $rawDir "$safeName.windbg.txt"
    $xmlPath = Join-Path $xmlDir "$safeName.analyze.xml"

    $commands = @(
        ".sympath $symbolPath",
        ".reload",
        "vertarget",
        "!analyze -show",
        "!analyze -v",
        "!analyze -v -xml -xmf `"$xmlPath`"",
        ".bugcheck",
        "kv",
        "lm N T",
        "!blackboxbsd",
        "!blackboxpnp",
        "!blackboxntfs",
        "!blackboxwinlogon",
        "q"
    ) -join "; "

    & $CdbPath -z $dump.FullName -c $commands -logo $logPath | Out-Null

    $text = Get-Content -Path $logPath -Raw -ErrorAction SilentlyContinue

    [pscustomobject]@{
        dumpFile         = $dump.FullName
        rawLogPath       = $logPath
        xmlPath          = $xmlPath
        bugCheckCode     = ([regex]::Match($text, '(?im)^BugCheck\s+([0-9A-Fa-f]+),')).Groups[1].Value
        probablyCausedBy = ([regex]::Match($text, '(?im)^Probably caused by\s*:\s*(.+)$')).Groups[1].Value.Trim()
        moduleName       = ([regex]::Match($text, '(?im)^\s*MODULE_NAME:\s*(.+)$')).Groups[1].Value.Trim()
        imageName        = ([regex]::Match($text, '(?im)^\s*IMAGE_NAME:\s*(.+)$')).Groups[1].Value.Trim()
        failureBucketId  = ([regex]::Match($text, '(?im)^\s*FAILURE_BUCKET_ID:\s*(.+)$')).Groups[1].Value.Trim()
        processName      = ([regex]::Match($text, '(?im)^\s*PROCESS_NAME:\s*(.+)$')).Groups[1].Value.Trim()
        hasBlackboxBSD   = $text -match '(?i)BLACKBOXBSD|BlackBoxBSD'
        hasBlackboxPNP   = $text -match '(?i)BLACKBOXPNP|BlackBoxPNP'
        hasBlackboxNTFS  = $text -match '(?i)BLACKBOXNTFS|BlackBoxNTFS'
        confidence       = "NeedsManualReview"
    }
}

$normalizedDir = Join-Path $OutRoot "normalized"
New-Item -ItemType Directory -Path $normalizedDir -Force | Out-Null

$results |
    ConvertTo-Json -Depth 8 |
    Set-Content -Path (Join-Path $normalizedDir "minidump-summary.json") -Encoding UTF8
```

---

## 7. Új modul: `CbsPersistCollector`

### 7.1. Feladat

A CBS rotált és tömörített logok teljes gyűjtése, mert az aktuális `CBS.log` nem elég a servicing hibákhoz.

### 7.2. Gyűjtendő fájlok

```text
C:\Windows\Logs\CBS\CBS.log
C:\Windows\Logs\CBS\CbsPersist*.log
C:\Windows\Logs\CBS\CbsPersist*.cab
C:\Windows\Logs\DISM\dism.log
C:\Windows\Logs\DISM\dism*.log
```

### 7.3. Kimenet

```text
copied_logs/CBS.log
copied_logs/CBS/CbsPersist_*.log
copied_logs/CBS/CbsPersist_*.cab
copied_logs/CBS/extracted/*.log
copied_logs/DISM/dism.log
copied_logs/DISM/dism*.log
analysis/servicing/cbs-log-inventory.json
```

### 7.4. `cbs-log-inventory.json` séma

```json
[
  {
    "path": "copied_logs/CBS/CbsPersist_20260605094537.log",
    "sourcePath": "C:\\Windows\\Logs\\CBS\\CbsPersist_20260605094537.log",
    "sizeBytes": 1234567,
    "lastWriteTime": "2026-06-05T09:45:37",
    "isCab": false,
    "copied": true,
    "extracted": false,
    "errors": []
  }
]
```

---

## 8. Új normalizáló: `CBSHResultNormalizer`

### 8.1. Feladat

A CBS, DISM, WER és Windows Update naplókban található HRESULT / CBS hibakódokat egységesen kell normalizálni.

### 8.2. Kiemelt kódok a NOTI-BAUNOK ügyből

```text
0x800F0845 - KB5089573 telepítési hiba / servicing failure candidate
0x800F0915 - repair content nem található
0x80240438 - Windows Update service/transient error candidate
0x8024001E - Windows Update operation stopped / driver search failure candidate
0x8024000B - update manifest / operation failure candidate
0x800704cf - network location / connectivity / AAD/WAM candidate
```

### 8.3. Output séma

```json
[
  {
    "code": "0x800F0915",
    "source": "WER WindowsServicingFailureInfo",
    "category": "ServicingRepairSourceMissing",
    "severity": "High",
    "summaryHu": "A CBS/DISM javítás nem talált megfelelő repair content forrást.",
    "suggestedActionHu": "Futtasson DISM RestoreHealth műveletet megfelelő Windows repair source megadásával, majd ismételje meg a KB telepítését.",
    "evidenceFiles": [
      "copied_logs/ReportArchive/**/Report.wer",
      "copied_logs/CBS.log",
      "copied_logs/DISM/dism.log"
    ],
    "confidence": "High"
  }
]
```

---

## 9. Új normalizáló: `WindowsUpdateKBContextNormalizer`

### 9.1. Feladat

A cél KB-hoz tartozó eseményeket külön kell csoportosítani:

```text
KB azonosító
cél build
aktuális build
package state transition
telepítési próbálkozások
hibakódok
rollback / Absent állapot
pending reboot összefüggés
SSU/LCU összefüggés
```

### 9.2. NOTI-BAUNOK esetben szükséges értelmezés

A KB5089573 esetén a rendszernek ezt a következtetést kellene kiadnia:

```text
A KB5089573 telepítése nem maradt fenn. A package state transition alapján a csomag Staged/Installed irányba elmozdult, majd Absent állapotba került. Ez rollback vagy sikertelen servicing művelet irányába mutat.
```

### 9.3. Output séma

```json
{
  "targetKb": "KB5089573",
  "targetBuild": "26200.8524",
  "currentBuildAtCollection": "26200.8457",
  "installAttempts": 3,
  "lastFailureCode": "0x800F0845",
  "finalPackageState": "Absent",
  "requiresRebootObserved": true,
  "pendingRebootAtCollection": false,
  "servicingStackContext": {
    "includedSsuKb": "KB5092734",
    "includedSsuVersion": "26100.8519"
  },
  "assessment": "FailedInstallWithServicingStoreCorruptionCandidate",
  "confidence": "High"
}
```

---

## 10. Új modul: `RepairSourceAdvisor`

### 10.1. Feladat

Ha a DISM/CBS/WER alapján `0x800F0915`, `source files could not be found`, vagy `Not able to find repair content anywhere` jellegű hiba látszik, a rendszer ne általános WU-resetet javasoljon első helyen, hanem repair source fókuszú javítást.

### 10.2. Hivatalos Microsoft alap

A Microsoft dokumentáció szerint a DISM képes online Windows image javítására, és a `/RestoreHealth` mellett a `/Source` paraméterrel megadható javítási forrás. A `/LimitAccess` megakadályozza, hogy a DISM Windows Update-et használjon javítási forrásként.

**Hivatalos referenciák:**

- Repair a Windows Image:  
  <https://learn.microsoft.com/windows-hardware/manufacture/desktop/repair-a-windows-image?view=windows-11>
- Fix Windows Update corruptions and installation failures:  
  <https://learn.microsoft.com/troubleshoot/windows-server/installing-updates-features-roles/fix-windows-update-errors#using-dism-to-repair-windows-update-corruptions>
- PowerShell `Repair-WindowsImage`:  
  <https://learn.microsoft.com/powershell/module/dism/repair-windowsimage?view=windowsserver2025-ps>

### 10.3. Javasolt műveleti sorrend

```cmd
DISM /Online /Cleanup-Image /CheckHealth
DISM /Online /Cleanup-Image /ScanHealth
DISM /Online /Cleanup-Image /RestoreHealth
sfc /scannow
```

Ha a `RestoreHealth` repair content hibát ad:

```cmd
DISM /Online /Cleanup-Image /RestoreHealth /Source:C:\RepairSource\Windows /LimitAccess
sfc /scannow
```

**Fontos:** a collector modul alapértelmezetten csak diagnosztizáljon. Automatikus javítás csak explicit `RepairMode` / `ApplyFixes` kapcsolóval történhet.

---

## 11. Event correlation fejlesztés

### 11.1. Korrelációs ablakok

A következő eseményeket idővonalban kell összekötni:

```text
KB5089573 Windows Update install attempt
CBS package state transition
DISM corruption / repair result
WER WindowsServicingFailureInfo
System crash / bugcheck / minidump keletkezés
reboot / shutdown / startup esemény
DeviceSetupManager / driver update hiba
SetupAPI driver install esemény
```

### 11.2. Javasolt korrelációs fájl

```text
analysis/correlation/kb5089573-event-correlation.json
```

### 11.3. Séma

```json
[
  {
    "timestamp": "2026-06-05T13:22:04",
    "eventType": "PackageStateChange",
    "source": "Setup/CBS",
    "kb": "KB5089573",
    "stateFrom": "Staged",
    "stateTo": "Absent",
    "relatedErrors": ["0x800F0845", "0x800F0915"],
    "nearbyCrashDump": "copied_logs/Minidump/060526-11500-01.dmp",
    "correlationConfidence": "Medium",
    "notes": [
      "Crash proximity alone does not prove causality. Requires WinDbg output."
    ]
  }
]
```

---

## 12. UI / manifest követelmények

### 12.1. Modul manifest

Az új modulok információs szövegei és tooltipjei kerüljenek modul manifestbe, ne legyenek szétszórva a kódban.

Példa:

```json
{
  "moduleId": "MiniDumpWinDbgAnalyzer",
  "displayNameHu": "Minidump elemzés WinDbg/CDB segítségével",
  "summaryHu": "A Windows kernel dump fájlokból strukturált crash elemzést készít.",
  "tooltipHu": "A modul Microsoft CDB.exe segítségével futtatja a !analyze -v elemzést. A 'Probably caused by' mező csak hibakeresési jelölt, nem végleges gyökérok.",
  "requiresAdmin": false,
  "requiresExternalMicrosoftTool": true,
  "toolName": "Debugging Tools for Windows",
  "readOnlyByDefault": true
}
```

### 12.2. UI oszlopelrendezés

Az `ÖSSZEFOGLALÓ` és `JAVASOLT MŰVELET` mezők ne a modulok táblázatában legyenek hosszú szövegként. Külön, lefelé scrollozható oszlopokban jelenjenek meg:

```text
Bal oldal: modulok / státusz / súlyosság / confidence
Jobb oldal 1: ÖSSZEFOGLALÓ
Jobb oldal 2: JAVASOLT MŰVELET
```

Ez különösen fontos a CBS/DISM/WinDbg jellegű eredményeknél, mert ezekhez hosszabb magyarázó szöveg tartozik.

---

## 13. Javítandó collector-hiba

A NOTI-BAUNOK csomag alapján javítandó egy storage summary hiba is:

```text
StorageEvidenceFailed
New-StorageRiskSummary
The property 'TimeCreated' cannot be found on this object.
```

### 13.1. Elvárt javítás

Minden olyan objektumnál, ahol `TimeCreated` mezőt használunk, kell null/property existence védelem:

```powershell
if ($event.PSObject.Properties.Name -contains 'TimeCreated' -and $null -ne $event.TimeCreated) {
    $time = $event.TimeCreated
} else {
    $time = $null
}
```

### 13.2. Elfogadási kritérium

```text
1. A storage summary modul ne álljon le hiányzó TimeCreated mező miatt.
2. A hibás vagy hiányos események külön warnings tömbbe kerüljenek.
3. A teljes evidence ZIP generálása folytatódjon.
4. A clean_generation_log / collector log jelezze a részleges adatminőségi problémát.
```

---

## 14. Elfogadási kritériumok a következő fejlesztési csomaghoz

### 14.1. Collector

```text
[ ] Gyűjti a CBS.log mellett az összes CbsPersist*.log fájlt.
[ ] Gyűjti a CbsPersist*.cab fájlokat.
[ ] Opcionálisan kibontja a CBS CAB fájlokat.
[ ] Gyűjti a DISM logokat teljesebb mintával.
[ ] Megőrzi a minidumpokat nyersen.
[ ] WinDbg/CDB jelenlétet detektál.
[ ] Ha CDB nincs telepítve, nem bukik el, hanem warningot ad.
[ ] Ha CDB elérhető, minden dumpból raw TXT + XML + JSON elemzést készít.
```

### 14.2. Normalizálók

```text
[ ] WERNormalizer felismeri a WindowsServicingFailureInfo riportokat.
[ ] CBSHResultNormalizer kiemeli a 0x800F0915 és 0x800F0845 kódokat.
[ ] WindowsUpdateErrorNormalizer KB-szinten csoportosítja a hibákat.
[ ] EventCorrelationNormalizer összeköti a KB, CBS, DISM, WER, reboot és dump idővonalat.
[ ] DriverPnPProblemNormalizer beemeli a dumpban és SetupAPI-ban visszatérő driverjelölteket.
```

### 14.3. AI-output

```text
[ ] Ne állítson végleges driver gyökérokot WinDbg elemzés nélkül.
[ ] Különítse el a bizonyított tényt, a valószínű következtetést és a vizsgálandó jelöltet.
[ ] KB5089573 esetben a servicing store hibát magas prioritással emelje ki.
[ ] Ha repair source hiány látszik, ne WU-reset legyen az első javaslat, hanem DISM repair source alapú javítás.
```

---

## 15. Prioritási javaslat

```text
P1. CbsPersistCollector
P1. WERNormalizer WindowsServicingFailureInfo bővítés
P1. CBSHResultNormalizer 0x800F0915 / 0x800F0845 kezelés
P1. WindowsUpdateKBContextNormalizer
P1. MiniDumpWinDbgAnalyzer CDB batch elemzéssel
P2. CrashDumpNormalizer
P2. Driver suspect aggregation
P2. KB-update-crash correlation timeline
P2. RepairSourceAdvisor
P3. UI manifest/tooltips finomítás
```

---

## 16. Dokumentáció ellenőrzés

| Elem | Státusz | Hivatalos Microsoft hivatkozás |
|---|---:|---|
| KB5089573 hivatalos KB-oldal | ✅ | <https://support.microsoft.com/en-us/topic/may-26-2026-kb5089573-os-builds-26200-8524-and-26100-8524-preview-f378c8ae-0170-47c9-a1e9-dfef978c8e17> |
| KB5089573 SSU tartalom: KB5092734 / 26100.8519 | ✅ | Ugyanazon Microsoft Support KB-oldal |
| CDB `-z` dumpnyitás | ✅ | <https://learn.microsoft.com/windows-hardware/drivers/debugger/cdb-command-line-options> |
| `!analyze -v` használat | ✅ | <https://learn.microsoft.com/windows-hardware/drivers/debugger/using-the--analyze-extension> |
| Small memory dump elemzési parancsok | ✅ | <https://learn.microsoft.com/troubleshoot/windows-client/performance/read-small-memory-dump-file> |
| Debugging Tools for Windows | ✅ | <https://learn.microsoft.com/windows-hardware/drivers/debugger/extra-tools> |
| DISM Windows image repair | ✅ | <https://learn.microsoft.com/windows-hardware/manufacture/desktop/repair-a-windows-image?view=windows-11> |
| Windows Update corruption repair DISM-mel | ✅ | <https://learn.microsoft.com/troubleshoot/windows-server/installing-updates-features-roles/fix-windows-update-errors#using-dism-to-repair-windows-update-corruptions> |
| PowerShell `Repair-WindowsImage` | ✅ | <https://learn.microsoft.com/powershell/module/dism/repair-windowsimage?view=windowsserver2025-ps> |

---

## 17. Validációs log

```text
SELF-CHECK / Háromszűrős ellenőrzés

1. Hivatalos dokumentáció
   ✅ A WinDbg/CDB, !analyze, small dump elemzés, DISM RestoreHealth és Repair-WindowsImage hivatkozások Microsoft dokumentáción alapulnak.
   ✅ A KB5089573 kontextus Microsoft Support oldalon ellenőrizhető.

2. Gyakorlati validálás
   ✅ A javasolt collector-bővítések olvasási/gyűjtési jellegűek.
   ✅ A WinDbg/CDB elemzés dump fájlokat olvas, nem módosítja a rendszert.
   ✅ A DISM javítási javaslat külön RepairMode/ApplyFixes kapcsoló mögé teendő, nem automatikus collector művelet.

3. Figyelmeztetés
   ⚠️ A minidump korlátozott információt tartalmazhat; teljes kernel dump nélkül nem minden stack és memóriaállapot rekonstruálható.
   ⚠️ A WinDbg `Probably caused by` mező nem végleges gyökérok, hanem hibakeresési jelölt.
   ⚠️ Hiányos szimbólumok esetén a stack részben félrevezető lehet.
   ⚠️ A KB5089573 hiba lokális servicing store problémának tűnik, de a végleges következtetéshez CbsPersist logok és WinDbg output szükséges.
```

---

## 18. Záró fejlesztői következtetés

A NOTI-BAUNOK eset tanulsága, hogy a jelenlegi általános diagnosztika már jó irányba mutat, de Windows Update servicing hibáknál még nem elég mély. A következő fejlesztési csomagban a fő hiánypótlás:

```text
1. CBS persistens naplók teljes gyűjtése
2. WER WindowsServicingFailureInfo célzott normalizálása
3. DISM/CBS HRESULT kódok egységes kezelése
4. KB-szintű Windows Update package lifecycle elemzés
5. Minidumpok WinDbg/CDB batch elemzése
6. Crash + KB + CBS + DISM idővonal korreláció
7. Repair source hiány felismerése és célzott javaslat generálása
```

Ezzel a rendszer a következő hasonló esetben már nemcsak azt fogja látni, hogy „a Windows Update hibázott”, hanem képes lesz elkülöníteni:

```text
- servicing store sérülés,
- repair content hiány,
- KB telepítési rollback,
- driver/crash mellékszál,
- PnP / storage / NPU jelölt,
- ténylegesen hiányzó további evidencia.
```

**diagnostics_starter_pack megjegyzés:** a fenti fejlesztés illeszkedik a Windows 11 diagnosztikai starter pack logikához: hivatalos Microsoft eszközökre épül, read-only collector módban biztonságos, javítási műveleteket csak külön kapcsolóval végez, és minden elemzési eredményt reprodukálható TXT/JSON/XML formában ment.
