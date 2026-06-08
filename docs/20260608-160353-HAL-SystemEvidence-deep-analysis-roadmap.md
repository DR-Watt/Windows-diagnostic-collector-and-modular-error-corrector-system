# Részletes fejlesztői elemzés és implementációs roadmap — `20260608-160353-HAL-SystemEvidence.zip`

**Célközönség:** fejlesztő AI / implementáló fejlesztő.  
**Cél:** a jelenlegi `SystemEvidenceCollector` kimenetének mély diagnosztikai értékelése, hiányosságok azonosítása, majd implementálható roadmap készítése a Windows 11 hibakereső és javító rendszer továbbfejlesztéséhez.  
**Elemzett csomag:** `/mnt/data/20260608-160353-HAL-SystemEvidence.zip`  
**Elemzés dátuma:** 2026-06-08 15:24:59  
**SHA-256:** `35a02f09df3c71d4642dc70c9f69e6d6381ef2acaf97bad45ff56199a5e0dca2`

---

## 0. Rövid végkövetkeztetés

A ZIP már **valódi Windows evidence-csomag**, nem pusztán keretrendszer-dokumentáció. A struktúra érdemi elemzésre alkalmas: tartalmaz rendszer-metaadatot, eseménynapló-kivonatokat, registry pending reboot állapotot, natív parancskimeneteket, CBS/DISM/SetupAPI/ReportingEvents logokat, WER-anyagokat, minidumpot és vendor logokat.

A csomag diagnosztikai értéke jelen állapotban **jó, de nem teljes**. A legfontosabb fejlesztési irány nem újabb javítómodul azonnali írása, hanem az evidence gyűjtés bővítése: **nyers `.evtx` export**, **konvertált WindowsUpdate.log**, **DISM ScanHealth/RestoreHealth + SFC lánc**, **storage mapping**, **WinDbg dump summary**, **részletes PnP snapshot**, valamint **vendor log zajszűrés**.

A jelenlegi evidence alapján a legfontosabb hibairányok:

1. **DISM / Component Store:** `CheckHealth` szerint a component store repairable állapotú.
2. **Storage / I/O:** több `disk` Event ID 153 jelzi, hogy a rendszer újrapróbált I/O műveleteket a `Disk 2` eszközön.
3. **Váratlan leállás:** `Kernel-Power 41` és `EventLog 6008` szerepel a System logban.
4. **WHEA:** egy korrigált PCI Express Root Port hardverhiba látható.
5. **Hyper-V / vSwitch / HNS:** visszatérő `ROOT\VMS_VSMP\0000` PnP start failure.
6. **Driver Store:** `SetupAPI.dev.log` alapján több driver package manifest hiányzik vagy nem ellenőrizhető.
7. **WER mintázat:** sok Intel Graphics Software, Armoury Crate, LiveKernelEvent és AutoHotkey/VirtualDesktopAccessor esemény.
8. **Windows Update:** aktív WU hibát az Operational log nem bizonyít, de a fő `WindowsUpdate.log` csak stub, ezért a WU evidence nem teljes.

---

## 1. Elemzési módszertan és korlátok

### 1.1. Mit vizsgáltam ténylegesen?

A ZIP-et rekurzívan olvastam. Ellenőriztem:

- gyökérszintű JSON/MD fájlokat,
- `manifest.json`, `ai_summary.json`, `collector-progress.jsonl`,
- `events/*.jsonl`,
- `commands/native-command-catalog.json`, `commands/native-command-results.json`,
- natív parancsok stdout/stderr fájljait,
- `copied_logs/CBS.log`, `copied_logs/dism.log`, `copied_logs/setupapi.dev.log`, `copied_logs/WindowsUpdate.log`, `copied_logs/ReportingEvents.log`,
- `drivers/pnp-signed-drivers.json`,
- `registry/reboot-pending.json`,
- WER `Report.wer` fájlokat,
- dump fájlok meglétét és inventory jellegét,
- vendor log mappa összetételét.

### 1.2. Mit nem végeztem el?

Nem futtattam WinDbg `!analyze -v` elemzést a dumpokon. A dumpfájlok jelenléte és WER-metaadataik alapján tudok következtetni, de kernel/user dump root cause attribúcióhoz külön WinDbg vagy CDB futtatás szükséges.

Nem futtattam élő Windows parancsot a HAL gépen. Minden megállapítás a ZIP-ben lévő evidence alapján készült.

---

## 2. Csomag-inventár

| Mutató | Érték |
|---|---:|
| ZIP méret | 428,912,905 bájt |
| ZIP bejegyzések száma | 1487 |
| Fájlbejegyzések száma | 1463 |
| Könyvtárbejegyzések száma | 24 |
| Manifestben szereplő fájlok száma | 1462 |
| Manifest önmagát tartalmazza? | Nem; a `manifest.json` a ZIP-ben van, de a manifest fájllistájában nincs benne. |
| Collector státusz | `Partial` |
| Modul | `SystemEvidenceCollector` |
| Modulverzió | `1.2.11` |
| Gépnév | `HAL` |
| DaysBack | 30 |
| MaxEvents | 1200 |
| EventLogCount | 11 |
| CopiedRecordCount | 1436 |
| NativeCommandCount | 9 |
| ErrorCount | 3 |
| FatalError | `` |

### 2.1. Top-level tartalom

| Top-level elem | Fájlszám |
|---|---:|
| `AI_README.md` | 1 |
| `ai_summary.json` | 1 |
| `collector-progress.jsonl` | 1 |
| `commands` | 21 |
| `copied_logs` | 822 |
| `drivers` | 1 |
| `errors` | 1 |
| `events` | 12 |
| `manifest.json` | 1 |
| `meta` | 1 |
| `registry` | 1 |
| `vendor_logs` | 600 |

---

## 3. Rendszerkontextus

Forrás: `meta/system-info.json`.

| Terület | Érték |
|---|---|
| ComputerName | `HAL` |
| UserName | `HAL\pinte` |
| TimestampUtc | `2026-06-08T14:03:54.0107916Z` |
| PowerShell | `7.6.2 Core` |
| OS | `Microsoft Windows 11 Pro` |
| OS Version | `10.0.26200` |
| OS BuildNumber | `26200` |
| Architecture | `64 bites` |
| InstallDate | `11/23/2024 19:43:03` |
| LastBootUpTime | `06/06/2026 08:16:39` |
| Manufacturer | `ASUS` |
| Model | `System Product Name` |
| TotalPhysicalMemory | `67974778880` bájt |
| BIOS | `American Megatrends Inc. 3811` |
| BIOS ReleaseDate | `10/22/2025 02:00:00` |

### Értékelés

A `meta/system-info.json` jó minimumszintet ad, de még nem elég teljes. Hiányzik például:

- Secure Boot állapot,
- TPM állapot,
- BitLocker állapot,
- BIOS mode / UEFI állapot,
- Hyper-V feature státusz,
- WSL / Docker / Windows Sandbox / HNS státusz,
- GPU-k pontos listája driververziókkal,
- storage topológia,
- power plan,
- memória XMP/EXPO jellegű állapot, ha WHEA vagy instabilitás a vizsgálati cél.

---

## 4. Collector futási állapot

Forrás: `collector-progress.jsonl`, `errors/collector-errors.json`, `ai_summary.json`.

A collector lépései mind `OK` státusszal zártak:

```text
Start → SystemSnapshot → RegistryPendingReboot → DriverSnapshot → EventLogs → CopyLogs → NativeCommands → Manifest
```

A `Start` üzenet fontos:

```text
DaysBack=30 MaxEvents=1200 TargetKB= WhatIf=False
```

Ez helyes, mert evidence gyűjtésnél a `WhatIf` mód kerülendő: a parancsoknak ténylegesen le kell futniuk ahhoz, hogy bizonyítékot adjanak. A korábbi argumentumhiányos probléma ebben a csomagban már javítottnak látszik.

### 4.1. Hibák értelmezése

`errors/collector-errors.json` három hibát tartalmaz:

| Target | Category | Jelleg | Értékelés |
|---|---|---|---|
| `Microsoft-Windows-DriverFrameworks-UserMode/Operational` | `Get-WinEvent` | Nem volt megfelelő esemény | Ne legyen `Error`; inkább `NoMatchingEvents`. |
| `Microsoft-Windows-WHEA-Logger/Operational` | `Get-WinEvent` | Nincs ilyen log | Ne legyen `Error`; inkább `LogNotPresent`. A WHEA események System logban szerepelhetnek. |
| `Microsoft-Windows-WER-SystemErrorReporting/Operational` | `Get-WinEvent` | Nincs ilyen log | Ne legyen `Error`; inkább `LogNotPresent`. |

### 4.2. Javasolt státuszmodell

A jelenlegi `Partial` túl durva. Javasolt új státuszok:

```json
{
  "Status": "OKWithWarnings",
  "FatalError": "",
  "ErrorCount": 0,
  "WarningCount": 3,
  "Warnings": [
    { "Code": "NoMatchingEvents", "Target": "Microsoft-Windows-DriverFrameworks-UserMode/Operational" },
    { "Code": "LogNotPresent", "Target": "Microsoft-Windows-WHEA-Logger/Operational" },
    { "Code": "LogNotPresent", "Target": "Microsoft-Windows-WER-SystemErrorReporting/Operational" }
  ]
}
```

Implementációs szabály:

- `Fatal`: a csomag nem készült el vagy alapvető fájlok hiányoznak.
- `Error`: egy elvárt és létező adatforrás gyűjtése kivétellel elbukott.
- `Warning`: adatforrás nem létezik, nincs esemény, hozzáférés nem kritikus, vagy opcionális adat hiányzik.
- `OK`: nincs hiba és nincs figyelmeztetés.
- `OKWithWarnings`: minden fő evidence elkészült, de van nem blokkoló figyelmeztetés.

---

## 5. Event log lefedettség

| LogName | Status | Count | OutputFile | Valószínű truncation |
|---|---:|---:|---|---|
| `System` | OK | 1200 | `events/System.jsonl` | igen |
| `Application` | OK | 1200 | `events/Application.jsonl` | igen |
| `Setup` | OK | 1200 | `events/Setup.jsonl` | igen |
| `Microsoft-Windows-WindowsUpdateClient/Operational` | OK | 839 | `events/Microsoft-Windows-WindowsUpdateClient_Operational.jsonl` | nem/valószínűleg nem |
| `Microsoft-Windows-DeviceSetupManager/Admin` | OK | 950 | `events/Microsoft-Windows-DeviceSetupManager_Admin.jsonl` | nem/valószínűleg nem |
| `Microsoft-Windows-DeviceSetupManager/Operational` | OK | 10 | `events/Microsoft-Windows-DeviceSetupManager_Operational.jsonl` | nem/valószínűleg nem |
| `Microsoft-Windows-Kernel-Boot/Operational` | OK | 149 | `events/Microsoft-Windows-Kernel-Boot_Operational.jsonl` | nem/valószínűleg nem |
| `Microsoft-Windows-Kernel-PnP/Configuration` | OK | 266 | `events/Microsoft-Windows-Kernel-PnP_Configuration.jsonl` | nem/valószínűleg nem |
| `Microsoft-Windows-DriverFrameworks-UserMode/Operational` | Error | 0 | `events/Microsoft-Windows-DriverFrameworks-UserMode_Operational.jsonl` | nem/valószínűleg nem |
| `Microsoft-Windows-WHEA-Logger/Operational` | Error | 0 | `events/Microsoft-Windows-WHEA-Logger_Operational.jsonl` | nem/valószínűleg nem |
| `Microsoft-Windows-WER-SystemErrorReporting/Operational` | Error | 0 | `events/Microsoft-Windows-WER-SystemErrorReporting_Operational.jsonl` | nem/valószínűleg nem |

### Értékelés

A JSONL export jól használható AI-elemzéshez, mert egyszerűen feldolgozható. Ugyanakkor a `System`, `Application` és `Setup` pontosan 1200 rekordot tartalmaz, ami megegyezik a `MaxEvents` limittel. Ezeket a collectorban `Truncated=true` jelöléssel kellene ellátni.

Javasolt minden event exporthoz külön metaadat:

```json
{
  "LogName": "System",
  "Status": "OK",
  "Count": 1200,
  "MaxEvents": 1200,
  "Truncated": true,
  "OldestTimeCreated": "2026-06-04T05:45:27.0450883+02:00",
  "NewestTimeCreated": "2026-06-08T14:19:54.6646742+02:00",
  "OutputJsonl": "events/System.jsonl",
  "OutputEvtx": "events/System.evtx"
}
```

### Kötelező fejlesztés: nyers `.evtx` export

A JSONL nem helyettesíti a nyers `.evtx` fájlt. A fejlesztői roadmapben a nyers export magas prioritású, mert:

- a JSONL-ben elveszhetnek provider-specifikus XML mezők,
- Event Viewerrel és külső eszközökkel visszaolvasható,
- Microsoft és vendor support felé bizonyítékként jobban használható,
- később strukturált újraelemzéshez nem kell újragyűjteni a gépről.

Hivatalos Microsoft által dokumentált exportút: `wevtutil epl <log> <exportfile>`. A `wevtutil` Microsoft dokumentációja szerint az `epl/export-log` eseményeket exportál eseménynaplóból vagy logfájlból megadott fájlba.

Javasolt output:

```text
events/raw/System.evtx
events/raw/Application.evtx
events/raw/Setup.evtx
events/raw/Microsoft-Windows-WindowsUpdateClient_Operational.evtx
events/raw/Microsoft-Windows-Kernel-PnP_Configuration.evtx
events/raw/Microsoft-Windows-DeviceSetupManager_Admin.evtx
events/raw/Microsoft-Windows-Kernel-Boot_Operational.evtx
```

---

## 6. System log — fő hibacsoportok

Forrás: `events/System.jsonl`.

| Level | Provider | Event ID | Darab | Idősáv | Mintaüzenet |
|---|---|---:|---:|---|---|
| Kritikus | `Microsoft-Windows-Kernel-Power` | `41` | 1 | 2026-06-06T08:16:45.1975701+02:00 → 2026-06-06T08:16:45.1975701+02:00 | A rendszer úgy indult újra, hogy előtte nem állt le megfelelően. Ez a hiba azért fordulhatott elő, mert a rendszer nem válaszolt, összeomlott vagy váratlanul megszűnt az energia... |
| Hiba | `Service Control Manager` | `7009` | 3 | 2026-06-06T06:55:10.6563433+02:00 → 2026-06-06T08:17:01.8017444+02:00 | Letelt egy időkorlát (45000 ms) a(z) Intel(R) Platform License Manager Service szolgáltatás kapcsolódására való várakozás közben. |
| Hiba | `Microsoft-Windows-DistributedCOM` | `10010` | 2 | 2026-06-05T07:54:59.2012094+02:00 → 2026-06-05T07:54:59.4372966+02:00 | {00000000-0000-0000-0000-000000000000} kiszolgáló nem regisztrálta magát a DCOM-ban a megadott határidő lejárta előtt. |
| Hiba | `BTHUSB` | `16` | 1 | 2026-06-06T11:20:25.7245687+02:00 → 2026-06-06T11:20:25.7245687+02:00 | Nem sikerült a kölcsönös hitelesítés a helyi Bluetooth-adapter és a(z) (c4:77:64:81:bb:35) című Bluetooth-adapter között. |
| Hiba | `EventLog` | `6008` | 1 | 2026-06-06T08:17:01.5380419+02:00 → 2026-06-06T08:17:01.5380419+02:00 | Az előző rendszerleállítás (‎2026. ‎06. ‎06. - 7:35:10) váratlan volt. |
| Hiba | `Service Control Manager` | `7000` | 1 | 2026-06-06T06:55:54.9186619+02:00 → 2026-06-06T06:55:54.9186619+02:00 | A szolgáltatás (Steam Client Service) a következő hiba következtében leállt: A szolgáltatás nem válaszolt megfelelő időben az indítási vagy vezérlési kérésre. |
| Hiba | `BTHUSB` | `17` | 1 | 2026-06-06T06:55:18.8136173+02:00 → 2026-06-06T06:55:18.8136173+02:00 | A helyi Bluetooth-adapter hiba miatt meghatározhatatlan módon leállt, ezért nem fogja használni a rendszer. Az illesztőprogram már nincs a memóriában. |
| Hiba | `Service Control Manager` | `7043` | 1 | 2026-06-05T07:55:40.6085475+02:00 → 2026-06-05T07:55:40.6085475+02:00 | A(z) Windows biztonság szolgáltatás szolgáltatás nem állt le megfelelően egy leállítás előtti esemény fogadását követően. |
| Hiba | `Volsnap` | `36` | 1 | 2026-06-04T09:17:43.1433540+02:00 → 2026-06-04T09:17:43.1433540+02:00 | A(z) C: kötet árnyékmásolatait a program megszüntette, mert az árnyékmásolatok tárolására szolgáló lemezterületet egy felhasználó által beállított korlát miatt nem sikerült megn... |
| Figyelmeztetés | `Microsoft-Windows-Kernel-PnP` | `225` | 51 | 2026-06-04T05:46:51.6835429+02:00 → 2026-06-08T12:38:18.1622918+02:00 | The application \Device\HarddiskVolume11\Program Files\LGHUB\lghub_agent.exe with process id 29720 stopped the removal or ejection for the device USB\VID_046D&PID_C06B\DB5C44250... |
| Figyelmeztetés | `Microsoft-Windows-DistributedCOM` | `10016` | 43 | 2026-06-04T05:45:57.0051654+02:00 → 2026-06-08T13:13:45.0214127+02:00 | A(z) alkalmazásspecifikus engedélybeállítások nem biztosítanak a(z) Helyi számára Aktiválás engedélyt a COM-kiszolgálóalkalmazáshoz. CLSID: {00000000-0000-0000-0000-000000000000... |
| Figyelmeztetés | `Microsoft-Windows-Hyper-V-VmSwitch` | `22` | 8 | 2026-06-04T09:34:35.4695233+02:00 → 2026-06-08T12:03:36.4866060+02:00 | Media disconnected on NIC /DEVICE/{87A92187-88D1-461B-B7E5-AF99FC586852} (Friendly Name: Realtek Gaming 2.5GbE Family Controller). |
| Figyelmeztetés | `disk` | `153` | 7 | 2026-06-04T15:48:35.0192663+02:00 → 2026-06-08T12:35:25.4685476+02:00 | A rendszer ismét megpróbálta végrehajtani a(z) 2 jelű lemez (PDO objektum neve: \Device\0000005f) 0x8000 logikai blokkcímét érintő I/O-műveletet. |
| Figyelmeztetés | `Microsoft-Windows-DNS-Client` | `1014` | 2 | 2026-06-05T07:53:58.7517173+02:00 → 2026-06-08T12:35:12.8023077+02:00 | A(z) steamconnecttest.com név feloldása során időtúllépés történt, miután a beállított DNS-kiszolgálók egyike sem válaszolt. Ügyfél-folyamatazonosító48592. |
| Figyelmeztetés | `Tcpip` | `4266` | 2 | 2026-06-04T15:58:46.6739199+02:00 → 2026-06-07T13:51:52.4542613+02:00 | Sikertelen volt a globális UDP porttérből rövid élettartamú portszámot lefoglaló kérés, mivel az összes ilyen port használatban van. |
| Figyelmeztetés | `Microsoft-Windows-Kernel-PnP` | `219` | 2 | 2026-06-06T06:54:59.7567805+02:00 → 2026-06-06T08:16:45.1816702+02:00 | The driver \Driver\WUDFRd failed to load. Device: ROOT\DISPLAY\0000 Status: 0xC0000365 |
| Figyelmeztetés | `Microsoft-Windows-Hyper-V-Hypervisor` | `167` | 2 | 2026-06-06T06:54:55.0060312+02:00 → 2026-06-06T08:16:40.0101639+02:00 | A hipervizor nem engedélyezte a kockázatcsökkentéseket a mellékcsatorna biztonsági réseinek esetében virtuális gépekhez, mert a HyperThreading engedélyezve van. A virtuális gépe... |
| Figyelmeztetés | `BTHUSB` | `3` | 2 | 2026-06-06T06:55:13.8146340+02:00 → 2026-06-06T06:55:18.8136173+02:00 | Letelt egy, az adapternek küldött parancs időkorlátja. Az adapter nem válaszolt. |
| Figyelmeztetés | `Microsoft-Windows-Time-Service` | `134` | 1 | 2026-06-08T06:11:19.2457490+02:00 → 2026-06-08T06:11:19.2457490+02:00 | NtpClient was unable to set a manual peer to use as a time source because of DNS resolution error on 'time.kfki.hu,0x9'. NtpClient will try again in 15 minutes and double the re... |
| Figyelmeztetés | `Tcpip` | `4231` | 1 | 2026-06-07T16:13:59.5927010+02:00 → 2026-06-07T16:13:59.5927010+02:00 | Sikertelen volt a globális TCP porttérből rövid élettartamú portszámot lefoglaló kérés, mivel az összes ilyen port használatban van. |
| Figyelmeztetés | `Microsoft-Windows-WHEA-Logger` | `17` | 1 | 2026-06-06T08:17:01.9010097+02:00 → 2026-06-06T08:17:01.9010097+02:00 | Javított hardverhiba történt. Összetevő: PCI Express Root Port Hibaforrás: Advanced Error Reporting (PCI Express) Elsődleges busz:eszköz:funkció: 0x0:0x1C:0x2 Másodlagos busz:es... |
| Figyelmeztetés | `winsrvext` | `100` | 1 | 2026-06-05T07:55:02.9420776+02:00 → 2026-06-05T07:55:02.9420776+02:00 | A(z) C:\Windows\System32\SecurityHealthSystray.exe folyamat 5016 ezredmásodperc után késlelteti a rendszer leállítását. |

### 6.1. Kernel-Power 41 és EventLog 6008

A `Kernel-Power 41` és `EventLog 6008` együtt váratlan vagy nem szabályos leállást jelez. Ez nem root cause, hanem tünet. A következő adatokat kell mellé gyűjteni:

- az esemény előtti és utáni 30 perc eseményei,
- bugcheck eventek,
- minidump inventory,
- WER kernel reportok,
- WHEA események,
- storage I/O események,
- GPU/display LiveKernelEvent reportok,
- power transition / sleep / resume események.

Implementációs javaslat: minden `Kernel-Power 41`, `EventLog 6008`, `BugCheck 1001` köré automatikusan készítsen a collector egy időablakot:

```json
{
  "AnchorEvent": { "Provider": "Microsoft-Windows-Kernel-Power", "Id": 41, "TimeCreated": "..." },
  "WindowBeforeMinutes": 30,
  "WindowAfterMinutes": 30,
  "Output": "events/correlated/unexpected-shutdown-<timestamp>.json"
}
```

### 6.2. WHEA-Logger 17

A System log tartalmaz egy `Microsoft-Windows-WHEA-Logger` Event ID 17 figyelmeztetést:

```text
Javított hardverhiba történt.
Összetevő: PCI Express Root Port
Hibaforrás: Advanced Error Reporting (PCI Express)
Elsődleges busz:eszköz:funkció: 0x0:0x1C:0x2
Elsődleges eszköz neve: PCI\VEN_8086&DEV_7ABA&SUBSYS_86941043&REV_11
```

Ez nem feltétlenül kritikus önmagában, mert korrigált hardverhibáról van szó. Viszont a `Kernel-Power 41`, a disk retry események, a LiveKernelEvent reportok és a PCIe Root Port jelzés együtt már indokolja, hogy a következő collector verzió bővítse a hardver-topológiai mappinget.

Javasolt extra output:

```text
hardware/pci-devices.json
hardware/pci-error-map.json
hardware/whea-system-events.json
hardware/pnp-pci-join.json
```

---

## 7. Storage / I/O diagnosztika

Forrás: `events/System.jsonl`.

A System logban több `disk` Event ID 153 esemény szerepel:

```text
A rendszer ismét megpróbálta végrehajtani a(z) 2 jelű lemez (PDO objektum neve: \Device\0000005f) 0x8000 logikai blokkcímét érintő I/O-műveletet.
```

Darabszám: **7**.

### Értékelés

Ez az egyik legfontosabb jelzés. Az Event ID 153 azt mutatja, hogy az I/O műveletet újra kellett próbálni. Ez lehet:

- fizikai lemezhiba vagy firmware-probléma,
- NVMe/SATA controller driver probléma,
- USB storage / külső eszköz késlekedése,
- power management / sleep-resume utáni storage timeout,
- kábel/tápellátási gond, ha SATA/HDD érintett,
- PCIe/NVMe link stabilitási probléma,
- storage stack driver-probléma.

A csomagból **nem derül ki**, hogy a `Disk 2` pontosan melyik fizikai eszköz, volume, serial number vagy interface. Ez jelentős hiányosság.

### Kötelező fejlesztés: Disk 2 mapping

A collector következő verziója készítsen explicit mappinget:

```text
storage/disks.json
storage/physical-disks.json
storage/volumes.json
storage/partitions.json
storage/diskdrive-cim.json
storage/disk-to-partition-map.json
storage/logicaldisk-to-partition-map.json
storage/storage-reliability-counters.json
storage/chkdsk-scan-results.txt
storage/disk-event-map.json
```

Javasolt mezők:

```json
{
  "DiskNumber": 2,
  "FriendlyName": "...",
  "SerialNumber": "...",
  "FirmwareVersion": "...",
  "BusType": "NVMe/SATA/USB/RAID/Virtual",
  "HealthStatus": "...",
  "OperationalStatus": ["..."],
  "SizeBytes": 0,
  "IsBoot": false,
  "IsSystem": false,
  "Volumes": ["C:", "D:"],
  "PnpDeviceId": "...",
  "RelatedEvents": [
    { "Provider": "disk", "Id": 153, "Count": 7 }
  ]
}
```

### Javasolt read-only parancsok / cmdletek

A Microsoft Storage modul alapján a `Get-StorageReliabilityCounter` storage reliability countereket ad vissza például device temperature, error jellegű számlálók és használati idő kapcsán. A collectorban read-only módon használható:

```powershell
Get-Disk | ConvertTo-Json -Depth 5
Get-PhysicalDisk | ConvertTo-Json -Depth 5
Get-Volume | ConvertTo-Json -Depth 5
Get-CimInstance Win32_DiskDrive | ConvertTo-Json -Depth 5
Get-CimInstance Win32_DiskPartition | ConvertTo-Json -Depth 5
Get-CimInstance Win32_LogicalDisk | ConvertTo-Json -Depth 5
Get-CimInstance Win32_DiskDriveToDiskPartition | ConvertTo-Json -Depth 5
Get-CimInstance Win32_LogicalDiskToPartition | ConvertTo-Json -Depth 5
Get-PhysicalDisk | Get-StorageReliabilityCounter | ConvertTo-Json -Depth 5
```

A `chkdsk /scan` dokumentált online vizsgálati kapcsoló. Javítást ne végezzen automatikusan, csak külön javítómodulban és felhasználói jóváhagyással.

```powershell
chkdsk C: /scan
```

---

## 8. DISM / CBS / Component Store

### 8.1. Natív DISM CheckHealth eredmény

Forrás: `commands/dism-checkhealth.txt`.

```text
Deployment Image Servicing and Management tool
Version: 10.0.26100.8521

Image Version: 10.0.26200.8524

The component store is repairable.
The operation completed successfully.
```

Kulcsmegállapítás:

```text
The component store is repairable.
```

Ez azt jelenti, hogy a komponens-tár javítandó állapotként van megjelölve. A `CheckHealth` nem mély vizsgálat és nem javítás. A következő lánc szükséges:

1. `CheckHealth` — gyors állapotjelzés.
2. `ScanHealth` — mélyebb vizsgálat.
3. `RestoreHealth` — javítás.
4. `sfc /scannow` — rendszerfájl-ellenőrzés.
5. CBS `[SR]` sorok szűrése.

### 8.2. CBS log mintázat

Forrás: `copied_logs/CBS.log`.

Leggyakoribb HRESULT minták:

| HRESULT / jelzés | Darab |
|---|---:|
| `0x800f0805 - CBS_E_INVALID_PACKAGE` | 66 |
| `0x800f0805` | 22 |
| `0x2c75b538` | 6 |
| `0x20a769df` | 4 |
| `0x1d30f03c` | 4 |
| `0x1d166f04` | 4 |
| `0x255da6d4` | 4 |
| `0x28d10d1f` | 4 |
| `0x15daa735` | 4 |
| `0x19b16c0f` | 2 |
| `0x19b16bb8` | 2 |
| `0x2920557e` | 2 |

Fontos minta:

```text
InternalOpenPackage failed for Package_for_KB3025096~31bf3856ad364e35~amd64~~6.4.1.0 [HRESULT = 0x800f0805 - CBS_E_INVALID_PACKAGE]
```

A CBS logban többször látszik `CBS_E_INVALID_PACKAGE`. Ez nem feltétlenül az aktuális hiba közvetlen oka, de a `CheckHealth repairable` eredménnyel együtt a servicing/component store irányt magas prioritásúvá teszi.

### 8.3. Kötelező collector-bővítés

Készüljenek külön output fájlok:

```text
servicing/dism-checkhealth.txt
servicing/dism-scanhealth.txt
servicing/dism-restorehealth-readiness.txt
servicing/sfc-verifyonly.txt
servicing/sfc-scannow.txt      # csak javító workflow-ban, nem baseline collectorban
servicing/cbs-sr-lines.txt
servicing/cbs-hresult-summary.json
servicing/cbs-package-errors.json
servicing/sessions.xml
```

### 8.4. Javítási policy

A collector **ne javítson automatikusan**. Javítómodul csak a bizonyítékmentés után fusson.

Ajánlott folyamat:

```text
Evidence Collector → Read-only diagnosis → Risk scoring → User approval → Repair module → Post-repair evidence package
```

DISM javítómodul előtt kötelező:

- teljes evidence csomag,
- restore point / backup policy ellenőrzése,
- pending reboot ellenőrzés,
- Windows Update / servicing szolgáltatásállapot,
- elegendő szabad tárhely,
- opcionális helyi source megadása, ha `RestoreHealth` forrást igényel.

---

## 9. Windows Update értékelés

Források:

- `events/Microsoft-Windows-WindowsUpdateClient_Operational.jsonl`,
- `copied_logs/WindowsUpdate.log`,
- `copied_logs/ReportingEvents.log`,
- `commands/dism-packages-*`.

### 9.1. Operational log

A `WindowsUpdateClient/Operational` 839 eseményt tartalmaz. Mind információs szintű:

- Event ID 26: update keresés eredménye,
- Event ID 41: update metadata / agent jellegű események.

Nem látszik aktív Windows Update error ebben az exportban.

### 9.2. WindowsUpdate.log probléma

A `copied_logs/WindowsUpdate.log` mindössze 276 bájt. Ez modern Windows 10/11 rendszereken várható lehet, mert a Windows Update naplózás ETW/ETL alapú, a klasszikus `WindowsUpdate.log` nem közvetlenül keletkezik.

Kötelező fejlesztés:

```powershell
Get-WindowsUpdateLog -IncludeAllLogs -LogPath "$PackageRoot\windows_update\WindowsUpdate.generated.log"
```

A Microsoft dokumentáció szerint a `Get-WindowsUpdateLog` a Windows Update `.etl` fájlokat egyesíti és olvasható `WindowsUpdate.log` fájllá konvertálja. Emiatt a jelenlegi `WindowsUpdate.log` stub nem tekinthető teljes WU evidence-nek.

### 9.3. Windows Update evidence output javaslat

```text
windows_update/WindowsUpdate.generated.log
windows_update/Get-WindowsUpdateLog.stdout.txt
windows_update/Get-WindowsUpdateLog.stderr.txt
windows_update/WindowsUpdateClient_Operational.evtx
windows_update/WindowsUpdateClient_Operational.jsonl
windows_update/ReportingEvents.log
windows_update/usoshared-logs/
windows_update/policies.json
windows_update/wsus-policy.json
windows_update/winhttp-proxy.json
windows_update/delivery-optimization.json
windows_update/update-history.json
windows_update/pending-reboot.json
```

### 9.4. StoreAgent / AppX update jelzések

A WER-ben sok `StoreAgentInstallFailure1` és `StoreAgentScanForUpdatesFailure0` látszik, például:

- `80073d02`,
- `80244022`,
- `8024001e`.

Ezek inkább Microsoft Store / AppX update irányú problémák, nem feltétlenül klasszikus Windows Update kumulatív frissítési hiba. Külön `appx_store_update` modul javasolt.

---

## 10. Driver / PnP / SetupAPI elemzés

### 10.1. Driver inventory

Forrás: `drivers/pnp-signed-drivers.json`.

| Mutató | Érték |
|---|---:|
| PnP signed driver rekordok | 337 |

Ez jó alap, de hiányzik több kulcsmező:

- `InstanceId`,
- `Status`,
- `Problem`,
- `ConfigManagerErrorCode`,
- `ClassGuid`,
- `Service`,
- `PDO`,
- `PresentOnly` jelzés,
- driver package path,
- device ↔ driver join.

A Microsoft `Get-PnpDevice` cmdlet alap PnP információkat ad, és támogatja többek között az `-PresentOnly` és `-Status` szerinti lekérdezést. Ez a jelenlegi driver snapshotot jól egészítené ki.

### 10.2. Kernel-PnP Configuration hibák

Forrás: `events/Microsoft-Windows-Kernel-PnP_Configuration.jsonl`.

| Level | Event ID | Darab | Idősáv | Minta |
|---|---:|---:|---|---|
| Hiba | `411` | 28 | 2026-05-10T15:13:14.2661416+02:00 → 2026-06-06T08:17:11.6903285+02:00 | Device ROOT\VMS_VSMP\0000 had a problem starting. |
| Hiba | `411` | 3 | 2026-05-13T11:08:17.0253936+02:00 → 2026-05-29T10:11:08.3013187+02:00 | Device ROOT\VMS_VSMP\0002 had a problem starting. |
| Figyelmeztetés | `442` | 3 | 2026-05-16T14:33:46.5478201+02:00 → 2026-05-27T07:04:03.9187238+02:00 | Device settings for HDAUDIO\FUNC_01&VEN_10DE&DEV_00AA&SUBSYS_10DE0000&REV_1001\5&d3dced&0&0001 were not migrated from previous OS installation due to partial or ambiguous device... |
| Figyelmeztetés | `442` | 1 | 2026-06-07T07:12:22.2921308+02:00 → 2026-06-07T07:12:22.2921308+02:00 | Device settings for SWD\MMDEVAPI\{0.0.1.00000000}.{2216c728-4350-4082-9ff7-04a4777f86e0} were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-06-07T07:12:22.1643829+02:00 → 2026-06-07T07:12:22.1643829+02:00 | Device settings for SWD\MMDEVAPI\{0.0.0.00000000}.{5d23c006-3ce2-4a1c-b3dd-3dc0beb6501b} were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-06-06T08:30:34.8071943+02:00 → 2026-06-06T08:30:34.8071943+02:00 | Device settings for BTHHFENUM\BthHFPAudio\8&24f341c6&0&97 were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-06-06T08:30:34.7672526+02:00 → 2026-06-06T08:30:34.7672526+02:00 | Device settings for BTHENUM\{0000111f-0000-1000-8000-00805f9b34fb}_VID&00010075_PID&0100\7&4816060&0&C4776481BB35_C00000000 were not migrated from previous OS installation due t... |
| Figyelmeztetés | `442` | 1 | 2026-06-06T08:30:34.6159235+02:00 → 2026-06-06T08:30:34.6159235+02:00 | Device settings for BTHENUM\{0000110a-0000-1000-8000-00805f9b34fb}_VID&00010075_PID&0100\7&4816060&0&C4776481BB35_C00000000 were not migrated from previous OS installation due t... |
| Figyelmeztetés | `442` | 1 | 2026-06-04T07:32:03.9253489+02:00 → 2026-06-04T07:32:03.9253489+02:00 | Device settings for DISPLAY\Default_Monitor\5&221900ff&0&UID4353 were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-05-30T13:17:04.0678522+02:00 → 2026-05-30T13:17:04.0678522+02:00 | Device settings for SWD\MMDEVAPI\{0.0.0.00000000}.{efde7cc0-2518-44fa-88c7-8bc0be211359} were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-05-28T16:56:58.2817856+02:00 → 2026-05-28T16:56:58.2817856+02:00 | Device settings for SWD\MMDEVAPI\{0.0.0.00000000}.{6f8150b7-23b9-4fa8-a80e-ddb515910dba} were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-05-27T07:02:10.0334616+02:00 → 2026-05-27T07:02:10.0334616+02:00 | Device settings for SWD\MMDEVAPI\{0.0.0.00000000}.{58034a08-3bd8-40ba-a46e-f45835977477} were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-05-27T06:59:34.4913907+02:00 → 2026-05-27T06:59:34.4913907+02:00 | Device settings for DISPLAY\SAM72E9\1&8713bca&0&UID0 were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-05-17T11:13:21.9629490+02:00 → 2026-05-17T11:13:21.9629490+02:00 | Device settings for SWD\MMDEVAPI\{0.0.0.00000000}.{5768fdf9-3ed2-4258-944d-f78b9d2e6a7f} were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-05-17T08:07:46.4851327+02:00 → 2026-05-17T08:07:46.4851327+02:00 | Device settings for SWD\WPDBUSENUM\{c49b962d-4172-11f1-afec-010101010000}#0000000000100000 were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-05-16T14:34:04.1204744+02:00 → 2026-05-16T14:34:04.1204744+02:00 | Device settings for SWD\MMDEVAPI\{0.0.0.00000000}.{22b3bcec-a310-4f0a-a04f-5d6c427a16cc} were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-05-16T14:32:19.9826405+02:00 → 2026-05-16T14:32:19.9826405+02:00 | Device settings for DISPLAY\Default_Monitor\1&8713bca&0&UID0 were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-05-15T17:35:29.0030852+02:00 → 2026-05-15T17:35:29.0030852+02:00 | Device settings for DISPLAY\MS_0001\4&2ce9aed6&2&UID4161 were not migrated from previous OS installation due to partial or ambiguous device match. |
| Figyelmeztetés | `442` | 1 | 2026-05-15T09:54:13.7919623+02:00 → 2026-05-15T09:54:13.7919623+02:00 | Device settings for USB\VID_046D&PID_0A5C\00000000 were not migrated from previous OS installation due to partial or ambiguous device match. |

Legfontosabb ismétlődő hiba:

```text
Device ROOT\VMS_VSMP\0000 had a problem starting.
Driver Name: wvms_mp_windows.inf
Service: VMSMP
Problem: 0xA
Problem Status: 0xC0000001
```

Ez Hyper-V virtual switch / HNS / virtual network stack irányba mutat. Releváns komponensek:

- Hyper-V,
- WSL2,
- Docker Desktop,
- Windows Sandbox,
- HNS,
- virtual switch,
- bridge/VPN adapterek,
- Realtek 2.5GbE adapter virtual switch binding.

Külön modul javasolt: `HyperVNetworkEvidenceCollector`.

### 10.3. DeviceSetupManager hibák

Forrás: `events/Microsoft-Windows-DeviceSetupManager_Admin.jsonl`.

| Time | Level | Event ID | Üzenet |
|---|---|---:|---|
| 2026-05-29T10:11:02.7651021+02:00 | Figyelmeztetés | `202` | A Hálózatlistázó jelenti, hogy nem képes kapcsolódni az internetre. |
| 2026-05-29T10:10:14.4792986+02:00 | Hiba | `121` | Nem sikerült telepíteni az illesztőprogram-frissítés(eke)t a(z) SWD\DRIVERENUM\{96bedf2c-18cb-4a15-b821-5e95ed0fea61}#VocaEffectPack&1&38cf50d&0 eszközre, hiba: 0x8024000B. |
| 2026-05-29T10:10:07.5811769+02:00 | Figyelmeztetés | `202` | A Hálózatlistázó jelenti, hogy nem képes kapcsolódni az internetre. |
| 2026-05-29T10:09:17.9974009+02:00 | Hiba | `121` | Nem sikerült telepíteni az illesztőprogram-frissítés(eke)t a(z) SWD\DRIVERENUM\{96bedf2c-18cb-4a15-b821-5e95ed0fea61}#VocaEffectPack&1&38cf50d&0 eszközre, hiba: 0x8024000B. |

A `0x8024000B` driver update hiba a `VocaEffectPack` eszközhöz kötődik. Ez nem tűnik core Windows-stabilitási hibának, de a driver/update pipeline jellegű hiányosságok közé tartozik.

### 10.4. SetupAPI.dev.log — Driver Store integrity problémák

Forrás: `copied_logs/setupapi.dev.log`.

Hiányzó OEM INF-ek:

| INF | Előfordulás |
|---|---:|
| `oem21.inf` | 10 |
| `oem45.inf` | 10 |
| `oem27.inf` | 10 |
| `oem56.inf` | 10 |
| `oem124.inf` | 10 |
| `oem115.inf` | 10 |
| `oem155.inf` | 10 |

Driver package manifest hiány / integrity ellenőrzési hiba:

| Driver package | Előfordulás |
|---|---:|
| `alderlakedmasecextension.inf_amd64_f0d7eea44ed4e421` | 10 |
| `alderlakepch-ssystem.inf_amd64_2d3c87d4553e8e1f` | 10 |
| `alderlakesystem.inf_amd64_0565e3956cec3231` | 10 |
| `hanvonugeemfilter.inf_amd64_5e728e9b55a6391e` | 10 |
| `hdx_asusext_rtk.inf_amd64_dfd51385129afd73` | 10 |
| `heci.inf_amd64_6b6e8cc42a3d1f09` | 10 |
| `iastorvd.inf_amd64_d0ba3dc7378fedf6` | 10 |
| `lgbusenum.inf_amd64_b85dc68b0a47ef81` | 10 |
| `lgsfmouhid.inf_amd64_7704a84ec2ea5556` | 10 |
| `lgvirhid.inf_amd64_1d45129410e6b111` | 10 |
| `oculus_vigembus.inf_amd64_0fc887be65ce6549` | 10 |
| `prime-z690-p-d4-asus-1620.inf_amd64_2257ef56fb7ebbb4` | 10 |
| `riftsensor.inf_amd64_e3211a841e2dbf6f` | 10 |
| `riftsusb.inf_amd64_6f12f427c4b2bc0e` | 10 |
| `steamxbox.inf_amd64_63e8d56deab53bb8` | 10 |
| `xppentablet.inf_amd64_0047901d9177278c` | 10 |
| `bcbus.inf_amd64_cc76433ce211e506` | 10 |
| `bertreader.inf_amd64_35957fe211381ec1` | 10 |
| `hdxasus.inf_amd64_e7e477c598e7d249` | 10 |
| `hpcm127128.inf_amd64_44371ae144db2616` | 10 |
| `iclsclient.inf_amd64_fc84dfa25a6a7727` | 10 |
| `igcc_dch.inf_amd64_4b7ed4943df328f7` | 10 |
| `lgaudio.inf_amd64_2c12e9bd731d3023` | 10 |
| `lgpbtdd.inf_amd64_67f46fed141433dd` | 10 |
| `mewmiprov.inf_amd64_d51901c26227fb29` | 10 |
| `netrtwlanu6.inf_amd64_90c9239878785bd7` | 10 |
| `netrtwlanufb.inf_amd64_61fb51de5225e251` | 10 |
| `ntprint.inf_x86_0234ee61ba44613e` | 10 |
| `ntprint.inf_x86_daf845dcc8506dcf` | 10 |
| `nvvad.inf_amd64_35079c3b2e98dd66` | 10 |
| `oculus119b.inf_amd64_8ebf10315eedf749` | 10 |
| `oculusud.inf_amd64_f0761a2ffdf542fc` | 10 |
| `ocusbvid.inf_amd64_401adf6c09b1f80f` | 10 |
| `realtekapo.inf_amd64_cafde37b477c6720` | 10 |
| `realtekasio.inf_amd64_d8d14eba3c3bec87` | 10 |
| `realtekhsa.inf_amd64_1dd27a91fc59a9d8` | 10 |
| `realtekservice.inf_amd64_31adae5d99f8cd09` | 10 |
| `riftdisplay.inf_amd64_bf1a8d0051740dc0` | 10 |
| `riftssensor.inf_amd64_fc5a5e75fcd40072` | 10 |
| `rt25cx21x64.inf_amd64_bda91607087ccd13` | 10 |
| `rtkfilter.inf_amd64_545527481b8c6f0f` | 10 |
| `steamstreamingmicrophone.inf_amd64_788589b826cf93ce` | 10 |
| `steamstreamingspeakers.inf_amd64_78513697685d0fe1` | 10 |

### Értékelés

Ez jelentős jel. A `SetupAPI.dev.log` alapján több driver package manifest nem nyitható meg, illetve több OEM INF eltávolítás hibázik. A Microsoft dokumentáció szerint a `SetupAPI.dev.log` a device installation és drivertelepítési problémák elsődleges naplója, és a `%SystemRoot%\inf` alatt található.

Ezt nem szabad automatikusan „takarítani”. Először inventory és mapping kell:

```text
drivers/driver-store-inventory.json
drivers/pnputil-enum-drivers.txt
drivers/windows-driver-online.json
drivers/pnp-devices-all.json
drivers/pnp-devices-problem.json
drivers/setupapi-error-summary.json
drivers/setupapi-missing-manifests.json
drivers/setupapi-failed-oem-inf-removals.json
```

Javasolt read-only parancsok:

```powershell
Get-PnpDevice | ConvertTo-Json -Depth 5
Get-PnpDevice -PresentOnly -Status ERROR,DEGRADED,UNKNOWN | ConvertTo-Json -Depth 5
Get-CimInstance Win32_PnPSignedDriver | ConvertTo-Json -Depth 5
Get-WindowsDriver -Online -All | ConvertTo-Json -Depth 5
pnputil /enum-drivers
pnputil /enum-devices /problem
```

A `pnputil /delete-driver` vagy driver eltávolítás ne legyen collector funkció. Az javítómodul, külön jóváhagyással.

---

## 11. WER / Crash / LiveKernelEvent / Dump elemzés

### 11.1. WER összesítés

Forrás: `copied_logs/ReportArchive/**/Report.wer`, `copied_logs/ReportQueue/**/Report.wer`.

| Mutató | Érték |
|---|---:|
| `Report.wer` fájlok száma | 349 |

Leggyakoribb WER minták:

| Darab | EventType | FriendlyEventName | Sig0 | Sig1 | Sig2 | Sig3 |
|---:|---|---|---|---|---|---|
| 79 | `APPCRASH` | `Működésképtelenné vált` | `IntelGraphicsSoftware.Service.exe` | `25.30.1705.2` | `68260000` | `KERNELBASE.dll` |
| 44 | `CLR20r3` | `Működésképtelenné vált` | `ArmouryCrate.UserSessionHelper` | `6.4.2.0` | `69438597` | `NAudio.Wasapi` |
| 21 | `LiveKernelEvent` | `Hardverhiba` | `1b8` | `a` | `0` | `0` |
| 18 | `APPCRASH` | `Működésképtelenné vált` | `AutoHotkey64.exe` | `2.0.26.0` | `69f7ffb2` | `VirtualDesktopAccessor.dll` |
| 15 | `CLR20r3` | `Működésképtelenné vált` | `ArmouryCrate.Service.exe` | `6.4.3.0` | `6943859b` | `NAudio.Wasapi` |
| 12 | `LiveKernelEvent` | `Hardverhiba` | `1a8` | `a` | `0` | `0` |
| 7 | `StoreAgentInstallFailure1` | `StoreAgentInstallFailure1` | `Update;MoUpdateOrchestratorUserScan-MoUsoCoreWorker-SearchForAllUpdatesWithUpdateOptionsAsync` | `80073d02` | `26200` | `7922` |
| 6 | `APPCRASH` | `Működésképtelenné vált` | `Aac3572MbHal_x86.exe` | `1.6.1.9` | `699eafcf` | `combase.dll` |
| 6 | `APPCRASH` | `Működésképtelenné vált` | `LightingService.exe` | `3.10.6.0` | `697316a9` | `ntdll.dll` |
| 5 | `StoreAgentInstallFailure1` | `StoreAgentInstallFailure1` | `Update;MoUpdateOrchestratorUserScan-MoUsoCoreWorker-SearchForAllUpdatesWithUpdateOptionsAsync` | `80073d02` | `26200` | `7462` |
| 4 | `APPCRASH` | `Működésképtelenné vált` | `Aac3572MbHal_x86.exe` | `1.6.1.5` | `69290196` | `combase.dll` |
| 4 | `BEX64` | `Működésképtelenné vált` | `ArmouryCrate.UserSessionHelper.exe` | `6.3.8.0` | `69254184` | `ArmouryCrate.AuraPlugin.dll_unloaded` |
| 4 | `StoreAgentInstallFailure1` | `StoreAgentInstallFailure1` | `Update;MoUpdateOrchestratorUserScan-MoUsoCoreWorker-SearchForAllUpdatesWithUpdateOptionsAsync` | `80073d02` | `26200` | `8039` |
| 3 | `APPCRASH` | `Működésképtelenné vált` | `atkexComSvc.exe` | `4.0.7.3` | `690aae49` | `atkexComSvc.exe` |
| 3 | `BEX64` | `Működésképtelenné vált` | `AUDIODG.EXE` | `10.0.26100.7705` | `24c4d397` | `oculusvadapo.dll` |
| 3 | `APPCRASH` | `Működésképtelenné vált` | `IntelGraphicsSoftware.exe` | `25.40.1953.2` | `68260000` | `combase.dll` |
| 3 | `APPCRASH` | `Működésképtelenné vált` | `LightingService.exe` | `3.8.60.0` | `691e78e6` | `ntdll.dll` |
| 3 | `MoAppCrash` | `Működésképtelenné vált` | `Microsoft.YourPhone_1.26042.95.0_x64__8wekyb3d8bbwe` | `praid:App` | `1.26042.95.0` | `69f20000` |
| 3 | `APPCRASH` | `Működésképtelenné vált` | `PresentMonService.exe` | `1.0.2.0` | `67c5e553` | `nvml.dll` |
| 3 | `StoreAgentScanForUpdatesFailure0` | `StoreAgentScanForUpdatesFailure0` | `Update;` | `80244022` | `26200` | `7705` |

### 11.2. Értelmezés

#### Intel Graphics Software

Sok `IntelGraphicsSoftware.Service.exe` APPCRASH látszik `KERNELBASE.dll` és `e0434352` kivételkóddal. Ez általában .NET/alkalmazásszintű hiba irány, nem feltétlen kernel crash. Viszont a LiveKernelEvent mintákkal együtt GPU/display stack monitoring szempontból releváns.

#### Armoury Crate / ASUS stack

Sok Armoury Crate, `Aac3572MbHal_x86.exe`, `LightingService.exe`, `atkexComSvc.exe` crash látható. Ez OEM utility stack instabilitást jelez. A javító rendszer ne módosítsa automatikusan, de külön modul javasolt:

```text
VendorAsusEvidenceCollector
VendorAsusCleanupRecommendation
```

A cleanup csak ajánlás legyen, nem automatikus eltávolítás.

#### AutoHotkey + VirtualDesktopAccessor.dll

A legaktuálisabb Application log hibák között több `AutoHotkey64.exe` crash/hang van, hibás modul: `VirtualDesktopAccessor.dll`, kivételkód: `0xc0000005`. Ez izolált user-mode alkalmazáshiba, nem tekinthető Windows rendszerhiba root cause-nak.

#### LiveKernelEvent

Több `LiveKernelEvent` WER riport szerepel:

- `1b8`,
- `1a8`,
- `193`,
- korábban `117` jellegű watchdog riportok is vannak a ReportQueue-ban.

Ez hardver/display/driver irányba mutathat, de dump elemzés nélkül nem lehet pontos okozót kijelölni.

### 11.3. Kötelező fejlesztés: WinDbg summary modul

A Microsoft WinDbg dokumentáció szerint a `!analyze` extension az aktuális exception vagy bug check információit jeleníti meg; kernel dump fájlok WinDbg-vel elemezhetők. A collector következő verziójában opcionális, külön kapcsolható `DumpAnalyzer` modul készüljön:

```text
crash/dump-inventory.json
crash/minidump-list.json
crash/livekernel-dump-list.json
crash/windbg-analysis/*.txt
crash/windbg-analysis/*.xml
crash/windbg-summary.json
```

Javasolt mezők:

```json
{
  "DumpPath": "copied_logs/Minidump/022325-10250-01.dmp",
  "DumpType": "KernelMiniDump|LiveKernelDump|UserDump",
  "SizeBytes": 6131056,
  "CreatedTime": "...",
  "BugCheckCode": "...",
  "ProbablyCausedBy": "...",
  "FailureBucketId": "...",
  "ImageName": "...",
  "ModuleName": "...",
  "AnalysisStatus": "Completed|Skipped|ToolMissing|Failed"
}
```

A dump elemzés legyen opcionális, mert:

- WinDbg telepítést igényelhet,
- symbol letöltést igényelhet,
- futási ideje hosszabb,
- érzékeny adatokat tartalmazhat.

---

## 12. Application log értékelés

| Level | Provider | Event ID | Darab | Idősáv | Mintaüzenet |
|---|---|---:|---:|---|---|
| Hiba | `Application Error` | `1000` | 8 | 2026-06-07T17:30:55.9961404+02:00 → 2026-06-07T18:22:51.4181563+02:00 | Hibás alkalmazás neve: AutoHotkey64.exe, verzió: 2.0.26.0, időbélyeg: 0x69f7ffb2 Hibás modul neve: VirtualDesktopAccessor.dll, verzió: 0.0.0.0, időbélyeg: 0x675f5f29 Kivételkód: 0xc0000005 Hibás eltolás: 0x00000000000... |
| Hiba | `Application Hang` | `1002` | 4 | 2026-06-07T17:33:15.4402532+02:00 → 2026-06-07T18:07:00.8214115+02:00 | A 2.0.26.0 verziójú AutoHotkey64.exe program nem kommunikál a Windows rendszerrel, ezért a program bezárult. Ha tudni szeretné, hogy elérhető-e további információ a problémáról, tekintse meg a probléma előzményeit a B... |
| Figyelmeztetés | `Microsoft-Windows-CertificateServicesClient-AutoEnrollment` | `64` | 1 | 2026-06-08T08:17:11.7632394+02:00 → 2026-06-08T08:17:11.7632394+02:00 | A(z) helyi rendszer tanúsítványa a(z) 84 9c ab 86 4f 1b 39 3d ac f6 09 0b 2c fc 4f 74 d8 b5 f1 76 ujjlenyomattal lejárt vagy nemsokára lejár. |

### Értékelés

Az Application log dominánsan WER eseményekkel van tele. Az aktuális, gyakori hiba az AutoHotkey/VirtualDesktopAccessor köré csoportosul. Ezt a fő Windows diagnosztikában **alacsonyabb prioritásra** kell tenni, mert nem Windows core komponens, és nem bizonyítja a rendszer újraindulásának okát.

Viszont a WER-mennyiség miatt szükséges egy WER normalizáló modul, mert a nyers ReportArchive/ReportQueue struktúra AI-nak is zajos.

Javasolt kimenet:

```text
wer/wer-summary.json
wer/wer-by-eventtype.json
wer/wer-by-application.json
wer/wer-by-module.json
wer/wer-by-exception-code.json
wer/wer-critical-recent.json
```

---

## 13. Registry / Pending reboot

Forrás: `registry/reboot-pending.json`.

| Ellenőrzés | Eredmény |
|---|---|
| CBS `RebootPending` | nem létezik |
| Windows Update `RebootRequired` | nem létezik |
| Session Manager | létezik |
| `PendingFileRenameOperations` | létezik, főként Microsoft Edge / EdgeUpdate temp elemekkel |

### Értékelés

A klasszikus CBS/WU pending reboot állapot nem látszik. A `PendingFileRenameOperations` jelenléte önmagában nem kritikus, mert jellemzően alkalmazásfrissítési takarítás is lehet. A collectorban külön osztályozni kell:

```json
{
  "PendingReboot": false,
  "Signals": {
    "CBSRebootPending": false,
    "WindowsUpdateRebootRequired": false,
    "PendingFileRenameOperations": true
  },
  "Risk": "Low",
  "Explanation": "Only Edge/EdgeUpdate temp cleanup pending rename entries were detected."
}
```

---

## 14. Native command collector értékelés

A natív parancsok most már jól futottak: argumentumok megvannak, `ExitCode=0`, nincs help-output fallback, nincs hiányzó argumentum.

| Name | CommandLine | ExitCode | stdout bytes | stderr bytes | InformationValue | missing args | help detected | Preview |
|---|---|---:|---:|---:|---|---|---|---|
| `reagentc-info` | `reagentc.exe /info` | 0 | 535 | 0 | Captured | false | false | Windows Recovery Environment (Windows RE) and system reset configuration / Information: |
| `bcdedit-enum-all-v` | `bcdedit.exe /enum all /v` | 0 | 5309 | 0 | Captured | false | false | Firmware Boot Manager / --------------------- |
| `dism-packages-table` | `dism.exe /Online /Get-Packages /Format:Table /English` | 0 | 54686 | 0 | Captured | false | false | Deployment Image Servicing and Management tool / Version: 10.0.26100.8521 |
| `dism-packages-list` | `dism.exe /Online /Get-Packages /Format:List /English` | 0 | 67519 | 0 | Captured | false | false | Deployment Image Servicing and Management tool / Version: 10.0.26100.8521 |
| `dism-checkhealth` | `dism.exe /Online /Cleanup-Image /CheckHealth /English` | 0 | 187 | 0 | Captured | false | false | Deployment Image Servicing and Management tool / Version: 10.0.26100.8521 |
| `sc-query-wuauserv` | `sc.exe query wuauserv` | 0 | 257 | 0 | Captured | false | false | SERVICE_NAME: wuauserv  /         TYPE               : 30  WIN32   |
| `sc-query-bits` | `sc.exe query BITS` | 0 | 333 | 0 | Captured | false | false | SERVICE_NAME: BITS  /         TYPE               : 30  WIN32   |
| `sc-query-cryptsvc` | `sc.exe query cryptsvc` | 0 | 346 | 0 | Captured | false | false | SERVICE_NAME: cryptsvc  /         TYPE               : 10  WIN32_OWN_PROCESS   |
| `sc-query-trustedinstaller` | `sc.exe query TrustedInstaller` | 0 | 357 | 0 | Captured | false | false | SERVICE_NAME: TrustedInstaller  /         TYPE               : 10  WIN32_OWN_PROCESS   |

### Pozitívumok

- A korábbi argumentumhiányos probléma javult.
- A `CommandLine`, `ArgumentList`, `ArgumentString`, stdout/stderr path, preview és exit code mind szerepel.
- A `WhatIf=False` helyes evidence gyűjtésnél.
- A `HelpOutputDetected` és `RequiredArgumentsMissing` mezők jó minőségbiztosítási elemek.

### Hiányosságok

A `sc.exe query` csak futási állapotot ad. Kell mellé:

```powershell
sc.exe qc wuauserv
sc.exe qc BITS
sc.exe qc cryptsvc
sc.exe qc TrustedInstaller
Get-CimInstance Win32_Service | Where-Object Name -in @('wuauserv','BITS','cryptsvc','TrustedInstaller') | ConvertTo-Json -Depth 5
```

A szolgáltatásdiagnosztika javasolt mezői:

```json
{
  "Name": "wuauserv",
  "DisplayName": "Windows Update",
  "State": "Stopped",
  "StartMode": "Manual",
  "StartName": "LocalSystem",
  "PathName": "...",
  "ExitCode": 0,
  "ServiceSpecificExitCode": 0,
  "Dependencies": [],
  "DependentServices": []
}
```

---

## 15. Vendor logok és adatvédelmi kockázat

A `vendor_logs` mappa 615 fájlbejegyzést tartalmaz. Több esetben nem klasszikus logok, hanem NVIDIA App / UpdateFramework / OTA artifact / DLL / EXE / bináris komponensek kerültek be.

### Probléma

- Növeli a ZIP méretét.
- Zajos AI-elemzést eredményez.
- Adatvédelmi és licencelési kockázatot növel.
- Vendor binárisok elemzésére a diagnosztikai rendszernek nincs szüksége.

### Javasolt whitelist

```text
*.log
*.txt
*.json
*.xml
*.etl
*.evtx
*.wer
*.mdmp
*.dmp   # csak crash/dump policy alapján
```

### Javasolt blacklist

```text
*.exe
*.dll
*.sys
*.bin
*.cab   # kivétel: Panther / setup diagnostic, ha indokolt
*.msi
*.msix
*.appx
OTA artifact könyvtárak
installer cache könyvtárak
package payload könyvtárak
```

### Javasolt vendor log manifest

```json
{
  "Vendor": "NVIDIA",
  "Product": "NVIDIA App",
  "CollectedFiles": 12,
  "SkippedFiles": 391,
  "SkippedByExtension": { ".dll": 120, ".exe": 31, ".bin": 44 },
  "Reason": "Binary payload excluded by evidence policy"
}
```

---

## 16. Hiányzó diagnosztikai komponensek összefoglalója

| Hiány | Prioritás | Miért fontos? | Javasolt output |
|---|---:|---|---|
| Nyers `.evtx` export | P0 | A JSONL elveszíthet provider-specifikus XML mezőket. | `events/raw/*.evtx` |
| Konvertált Windows Update log | P0 | A jelenlegi `WindowsUpdate.log` stub. | `windows_update/WindowsUpdate.generated.log` |
| DISM ScanHealth | P0 | `CheckHealth` repairable állapotot jelez, mély vizsgálat kell. | `servicing/dism-scanhealth.txt` |
| DISM RestoreHealth eredmény | P0/P1 | Javítási eredmény és forráshiba kimutatása. | `servicing/dism-restorehealth.txt` |
| SFC output | P0/P1 | Rendszerfájl-sérülések ellenőrzése. | `servicing/sfc-scannow.txt` |
| Storage mapping | P0 | `Disk 2` nem azonosítható. | `storage/disk-event-map.json` |
| Storage reliability | P0 | Disk 153 miatt fizikai/logikai storage állapot kell. | `storage/storage-reliability-counters.json` |
| Dump analysis | P1 | LiveKernelEvent és minidump root cause csak így értelmezhető. | `crash/windbg-summary.json` |
| PnP problem snapshot | P1 | VMS_VSMP és driverhibák pontos device-mappingje hiányzik. | `drivers/pnp-devices-problem.json` |
| Driver store inventory | P1 | SetupAPI manifest hiányok miatt kell. | `drivers/driver-store-inventory.json` |
| WER normalizálás | P1 | Sok WER-fájl zajos, AI-nak aggregátum kell. | `wer/wer-summary.json` |
| Hyper-V/HNS snapshot | P1 | VMSMP PnP hiba visszatérő. | `hyperv/hns-networks.json` |
| Network/TCP port snapshot | P2 | TCP/UDP ephemeral port exhaustion figyelmeztetés látszik. | `network/tcpip-dynamic-port-state.json` |
| Power diagnostics | P2 | Kernel-Power / sleep-resume korrelációhoz kell. | `power/powercfg-*.txt` |
| Security baseline | P2 | TPM/SecureBoot/BitLocker hiányzik. | `security/*.json` |

---

## 17. Implementációs roadmap

### Fázis 0 — Stabilizálás és evidence-minőség

**Cél:** a jelenlegi collector státuszlogikájának és manifestjének megbízhatóvá tétele.

Feladatok:

1. `Partial` helyett finomabb státuszmodell: `OK`, `OKWithWarnings`, `Partial`, `Failed`.
2. `NoMatchingEvents` és `LogNotPresent` ne növelje a valódi `ErrorCount` értéket.
3. Minden export mellé `metadata.json` készüljön: count, max, truncated, oldest/newest timestamp, duration, command, exit code.
4. `manifest.json` tartalmazzon SHA-256 hash-t minden fájlhoz.
5. `manifest.json` tartalmazzon `CollectorPolicy` blokkot: include/exclude szabályok, privacy policy, max file size.
6. `collector-progress.jsonl` maradjon append-only jellegű.

Acceptance criteria:

```text
- FatalError üres, ha a csomag elkészült.
- Nem létező opcionális event log Warning, nem Error.
- Minden 1200 rekordos export Truncated=true jelölést kap.
- Minden fájlhoz van length + lastwrite + sha256.
```

### Fázis 1 — Event és Windows Update evidence teljessé tétele

**Cél:** eseménynaplók és Windows Update logok bizonyítóerejének növelése.

Feladatok:

1. `wevtutil epl` alapú `.evtx` export.
2. JSONL mellett XML-normalizált event export, legalább kritikus provider-csoportokra.
3. `Get-WindowsUpdateLog -IncludeAllLogs` futtatása.
4. USO / UX / ReportingEvents / policy snapshot gyűjtése.
5. Windows Update result code és KB-k szerinti aggregáció.

Javasolt mappa:

```text
events/raw/
events/jsonl/
events/correlated/
windows_update/
```

Acceptance criteria:

```text
- System/Application/Setup EVTX benne van a ZIP-ben.
- WindowsUpdate.generated.log nem stub és > 1 KB.
- WU eventek KB, result code és idő szerint aggregálva vannak.
```

### Fázis 2 — Servicing / DISM / SFC modul

**Cél:** a repairable component store állapot pontosítása.

Feladatok:

1. `DISM /CheckHealth` maradjon baseline.
2. `DISM /ScanHealth` fusson külön hosszabb timeouttal.
3. `DISM /RestoreHealth` csak javító workflow-ban fusson, approval után.
4. `SFC /verifyonly` baseline collectorban.
5. `SFC /scannow` javító workflow-ban.
6. CBS parser: HRESULT, package identity, corruption marker, `[SR]` sorok.
7. `Sessions.xml` mentése.

Acceptance criteria:

```text
- DISM CheckHealth repairable esetén automatikus "ServicingRepairRecommended" flag készül.
- Javítás előtt és után külön evidence package készül.
- CBS_E_INVALID_PACKAGE aggregáció külön JSON-ban szerepel.
```

### Fázis 3 — Storage / Hardware correlation

**Cél:** Disk 153 és WHEA 17 eseményekhez eszközszintű mapping.

Feladatok:

1. Disk/PhysicalDisk/Volume/Partition snapshot.
2. CIM mapping: diskdrive → partition → logical disk.
3. PnP device mapping storage controllerre és diskre.
4. Storage reliability counters.
5. `chkdsk /scan` read-only output minden fix volume-ra.
6. Disk/System event correlator.
7. WHEA event parser + PCI mapping.

Acceptance criteria:

```text
- A System logban szereplő Disk 2 konkrét eszközre visszavezethető.
- Disk 153 események száma, LBA, PDO és idő szerint aggregálva vannak.
- WHEA PCI device ID és PnP/CIM mapping készül.
```

### Fázis 4 — Driver / PnP / SetupAPI mélyítés

**Cél:** driver store integrity és PnP hibák érdemi elemzése.

Feladatok:

1. `Get-PnpDevice` teljes export.
2. `Get-PnpDevice -PresentOnly -Status ERROR,DEGRADED,UNKNOWN` export.
3. `Get-CimInstance Win32_PnPSignedDriver` bővítés InstanceId mezőkkel.
4. `Get-WindowsDriver -Online -All` export.
5. `pnputil /enum-drivers` és `pnputil /enum-devices /problem` output.
6. SetupAPI parser: missing INF, missing manifest, failed remove, failed configure, device install failure.
7. Hyper-V VMSMP külön almodul.

Acceptance criteria:

```text
- ROOT\VMS_VSMP\0000 konkrét service, driver package és feature state szerint értékelhető.
- Missing driver package manifest lista külön JSON-ban szerepel.
- Driver removal/corruption javítás csak ajánlásként jelenik meg, automatikus törlés nélkül.
```

### Fázis 5 — Crash / WER / Dump pipeline

**Cél:** WER és dump anyagok AI-kompatibilis normalizálása.

Feladatok:

1. WER parser EventType, app, module, exception code, bucket, report id alapján.
2. WER deduplikálás.
3. Dump inventory.
4. WinDbg/CDB opcionális elemző.
5. LiveKernelEvent osztályozás.
6. Kernel-Power 41 körüli event-korreláció.

Acceptance criteria:

```text
- 349 WER fájlból tömör wer-summary.json készül.
- LiveKernelEvent kódok száma és kapcsolódó dumpfájlok listája szerepel.
- WinDbg hiányában AnalysisStatus=ToolMissing, nem Error.
```

### Fázis 6 — Vendor log szűrés és adatvédelmi policy

**Cél:** a ZIP méret és zaj csökkentése, privacy javítása.

Feladatok:

1. Extension whitelist/blacklist.
2. Max file size limit.
3. Vendor-specific collectors: NVIDIA, ASUS, Intel, Realtek.
4. Binary payload exclusion.
5. PII sanitization opció.
6. `vendor_logs_manifest.json`.

Acceptance criteria:

```text
- NVIDIA OTA binary payloadok nem kerülnek vendor_logs alá.
- A ZIP méret jelentősen csökken.
- Minden skipped fájl szerepel manifestben okkal, de nem kerül becsomagolásra.
```

### Fázis 7 — UI és manifest-szövegstruktúra

**Cél:** a diagnosztikai UI kezelhetősége és AI által olvasható manifest tartalma javuljon.

Feladatok:

1. A felső hint (`txtTopHint`) külön, diszkrét színű `DockPanel`-be kerüljön, ne legyen egyvonalban a LOG gombokkal.
2. A modul saját szakmai leírása, tooltipje, kockázati szintje, evidence outputjai a modul `manifest.json` fájljába kerüljenek.
3. A központi UI string fájlban csak általános UI feliratok maradjanak.
4. Az `ÖSSZEFOGLALÓ` és `JAVASOLT MŰVELET` oszlopok külön, lefelé scrollozható táblázati/nézeti oszlopként jelenjenek meg, ne a modulok oszloppal egy zsúfolt táblában.
5. Minden UI objektumnak legyen tooltipje.
6. Minden modulnál legyen `SummaryTemplate` és `RecommendedActionTemplate`.

Javasolt manifest részlet:

```json
{
  "ModuleId": "SystemEvidenceCollector",
  "DisplayName": "System Evidence Collector",
  "RiskLevel": "ReadOnly",
  "RequiresElevation": true,
  "SupportsWhatIf": false,
  "Tooltip": "Windows rendszerbizonyítékokat gyűjt elemzéshez; nem végez javítást.",
  "SummaryTemplate": "Összegyűjti a rendszer-, esemény-, driver-, registry- és logbizonyítékokat.",
  "RecommendedActionTemplate": "A csomag elemzése után futtatható javítómodulok csak külön jóváhagyással induljanak.",
  "ExpectedOutputs": [
    "meta/system-info.json",
    "events/event-summary.json",
    "commands/native-command-results.json"
  ],
  "OfficialDocs": [
    { "Name": "Get-WindowsUpdateLog", "Url": "https://learn.microsoft.com/powershell/module/windowsupdate/get-windowsupdatelog" }
  ]
}
```

---

## 18. Risk scoring javaslat

Javasolt diagnosztikai pontozás:

```json
{
  "RiskScores": {
    "Servicing": 85,
    "Storage": 80,
    "CrashReboot": 75,
    "DriverStore": 70,
    "HyperVNetwork": 60,
    "WindowsUpdate": 35,
    "UserModeApplications": 45,
    "VendorUtilities": 50
  },
  "PrimaryInvestigationPath": [
    "Servicing",
    "Storage",
    "CrashReboot",
    "DriverStore"
  ]
}
```

Értelmezés:

- `Servicing` magas, mert DISM repairable.
- `Storage` magas, mert disk 153 ismétlődik és nincs mapping.
- `CrashReboot` magas, mert Kernel-Power 41 / EventLog 6008 látszik.
- `DriverStore` magas, mert SetupAPI driver package manifest hibák vannak.
- `WindowsUpdate` közepes/alacsony, mert Operational logban nincs aktív hiba, de a WU log hiányos.
- `UserModeApplications` külön ág, mert AutoHotkey és Armoury Crate nem core Windows root cause.

---

## 19. Javítási sorrend — operatív ajánlás

A javításokat csak teljes evidence mentés után indítsa a rendszer.

### 19.1. Első kör: read-only bővített collector

1. EVTX export.
2. Generated WindowsUpdate.log.
3. DISM ScanHealth.
4. SFC verifyonly.
5. Storage mapping.
6. WER summary.
7. Dump inventory.
8. SetupAPI parser.

### 19.2. Második kör: célzott diagnosztika

1. Ha Disk 2 rendszerlemez vagy fontos NVMe: storage health, firmware, driver, event korreláció.
2. Ha WHEA ugyanarra a PCIe root portra mutat: PCIe mapping, BIOS/chipset/firmware irány.
3. Ha DISM ScanHealth hibát erősít: RestoreHealth előkészítés.
4. Ha VMSMP hiba aktív: Hyper-V/HNS/VSwitch snapshot.

### 19.3. Harmadik kör: javítómodulok

1. Component Store repair modul.
2. SFC repair modul.
3. Windows Update reset modul — csak WU evidence alapján, nem első lépésként.
4. Driver Store repair/cleanup ajánló modul — automatikus törlés nélkül.
5. Hyper-V virtual switch rebuild modul — csak explicit user approval után.
6. Vendor utility cleanup ajánlás — OEM support és visszaállítási pont mellett.

---

## 20. Dokumentáció ellenőrzés

A javaslatoknál csak hivatalos Microsoft dokumentációra támaszkodó Windows/PowerShell parancsokat vettem alapul.

| Terület | Hivatalos dokumentációs alap | Státusz | Megjegyzés |
|---|---|---|---|
| Windows Update log konverzió | `Get-WindowsUpdateLog` Microsoft Learn | ✅ | ETL fájlokat egyesít és olvasható loggá konvertál. |
| DISM / image repair | `Repair-WindowsImage`, DISM Repair a Windows Image | ✅ | CheckHealth/ScanHealth/RestoreHealth lánc. |
| SetupAPI.dev.log | SetupAPI Device Installation Log Entries | ✅ | Device/driver install hibák elsődleges logja. |
| Event log export | `wevtutil epl/export-log` | ✅ | Nyers `.evtx` exporthoz alkalmas. |
| PnP snapshot | `Get-PnpDevice` | ✅ | PnP eszközök alapinformációi, `-PresentOnly`, `-Status`. |
| Storage reliability | `Get-StorageReliabilityCounter` | ✅ | Storage reliability counterek. |
| Driver export/inventory | `Export-WindowsDriver`, Microsoft driver inventory irány | ✅ | Third-party driver export/inventory. |
| CHKDSK online scan | `chkdsk /scan` | ✅ | Read-only/online vizsgálati irányban használható; javítás külön modul. |
| Dump analysis | WinDbg `!analyze`, kernel dump analysis | ✅ | Opcionális elemzőmodulhoz. |

---

## 21. Validációs log

### 21.1. Háromszűrős ellenőrzés

| Szűrő | Eredmény | Megjegyzés |
|---|---|---|
| Hivatalos dokumentáció | ✅ | Microsoft Learn dokumentációval ellenőrzött parancsok/cmdletek kerültek roadmapbe. |
| Gyakorlati validálás a ZIP alapján | ✅ | A megállapítások a ZIP tényleges fájljaiból és rekordjaiból származnak. |
| Figyelmeztetés | ⚠️ | Dump root cause elemzés nem készült, mert WinDbg nem futott. Storage Disk 2 mapping nem áll rendelkezésre. |

### 21.2. SELF-CHECK jellegű következtetések

- A natív parancsok argumentumai ebben a csomagban már nem maradtak le.
- A `WhatIf=False` helyes a gyűjtőmodulnál.
- A három collector error nem valódi hibának, hanem figyelmeztetésnek minősítendő.
- A `System`, `Application`, `Setup` event export truncation-jelölést igényel.
- A vendor log gyűjtés túl széles, whitelist/blacklist szükséges.
- A javítási modulok előtt kötelező a bővített read-only evidence csomag.

---

## 22. diagnostics_starter_pack integrációs hivatkozás

A következő implementációs iteráció végén a projekt `diagnostics_starter_pack` hivatkozását a generált dokumentáció és CLEAN log végére is be kell illeszteni. A csomag a legfrissebb PowerShell és Python önfejlesztő diagnosztikai sablonokat használja Windows 11 környezetben, és a diagnosztika minden projekt előtt lefut a környezet ellenőrzésére és javítására.

Javasolt roadmap-output fájlok:

```text
clean_generation_log.txt
implementation_roadmap.md
schema_changes.md
module_manifest_contract.md
collector_acceptance_tests.md
```

---

## 23. Fejlesztő AI-nak szánt végső implementációs utasítás

A következő fejlesztési iterációban **ne javítómodult írj elsőként**. Először a `SystemEvidenceCollector` minőségét kell P0 szinten javítani:

```text
1. EVTX export
2. Get-WindowsUpdateLog -IncludeAllLogs
3. DISM ScanHealth + SFC verifyonly
4. Storage mapping DiskNumber → PhysicalDisk → Volume → PnP
5. WER summary parser
6. SetupAPI parser
7. Státuszmodell javítása: NoEvents/LogNotPresent ≠ Error
8. Vendor log whitelist/blacklist
9. Manifest hash + truncation metadata
10. UI manifest-alapú tooltip/summary/recommended action mezők
```

Csak ezután következzenek a javítómodulok. A javítómodulok minden esetben készítsenek **pre-repair** és **post-repair** evidence csomagot.

---

## 24. Hivatalos Microsoft Learn hivatkozások

A fejlesztő AI az alábbi Microsoft Learn oldalak alapján validálja a parancsokat és cmdleteket implementáció előtt:

| Terület | URL |
|---|---|
| Get-WindowsUpdateLog | https://learn.microsoft.com/powershell/module/windowsupdate/get-windowsupdatelog |
| Windows Update logs | https://learn.microsoft.com/windows/deployment/update/windows-update-logs |
| Repair a Windows Image | https://learn.microsoft.com/windows-hardware/manufacture/desktop/repair-a-windows-image?view=windows-11 |
| Repair-WindowsImage | https://learn.microsoft.com/powershell/module/dism/repair-windowsimage |
| SetupAPI Device Installation Log Entries | https://learn.microsoft.com/windows-hardware/drivers/install/setupapi-device-installation-log-entries |
| SetupAPI Text Logs | https://learn.microsoft.com/windows-hardware/drivers/install/setupapi-text-logs |
| wevtutil | https://learn.microsoft.com/windows-server/administration/windows-commands/wevtutil |
| Get-PnpDevice | https://learn.microsoft.com/powershell/module/pnpdevice/get-pnpdevice |
| Get-StorageReliabilityCounter | https://learn.microsoft.com/powershell/module/storage/get-storagereliabilitycounter |
| Export-WindowsDriver | https://learn.microsoft.com/powershell/module/dism/export-windowsdriver |
| chkdsk | https://learn.microsoft.com/windows-server/administration/windows-commands/chkdsk |
| WinDbg !analyze | https://learn.microsoft.com/windows-hardware/drivers/debuggercmds/-analyze |
| Kernel dump analysis with WinDbg | https://learn.microsoft.com/windows-hardware/drivers/debugger/analyzing-a-kernel-mode-dump-file-with-windbg |

