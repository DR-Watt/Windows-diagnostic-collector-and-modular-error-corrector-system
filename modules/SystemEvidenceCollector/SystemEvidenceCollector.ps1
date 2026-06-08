<#
.SYNOPSIS
  Windows 11 rendszerbizonyíték és vendor diagnosztikai LOG gyűjtő modul.

.DESCRIPTION
  Nem javít rendszert. Strukturált, AI által elemezhető ZIP csomagot készít
  boot, setup, driver, update, crash és ismert gyártói diagnosztikai nyomokból.
  v1.2.8: empty-array binding hotfix. A gyűjtő lépések explicit üres
  tömb támogatást kaptak, ezért a legelső hiba esetén is létrejön a részleges
  csomag, AI_README, ai_summary.json és collector-errors.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Get-Metadata','Test-Condition','Invoke-Fix','Invoke-Rollback')][string]$Action,
    [switch]$WhatIf,
    [string]$LogRoot = (Join-Path $PSScriptRoot '..\..\logs'),
    [string]$TargetKB = '',
    [int]$DaysBack = 30,
    [int]$MaxEvents = 1200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ModuleId = 'SystemEvidenceCollector'
$ModuleVersion = '1.2.8'

function Get-Metadata {
    [PSCustomObject]@{
        Id = $ModuleId
        Name = 'Rendszer LOG bizonyítékgyűjtő'
        Version = $ModuleVersion
        Risk = 'Low'
        Summary = 'Windows boot, setup, update, driver, crash és vendor diagnosztikai LOG gyűjtés.'
    }
}

function New-DirectorySafe {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function ConvertTo-SafeString {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [array]) {
            return (@($Value) | ForEach-Object { ConvertTo-SafeString -Value $_ }) -join '; '
        }
        return [string]$Value
    }
    catch { return '<UnserializableValue>' }
}

function Get-RelativePathSafe {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$FullPath
    )
    try {
        return [System.IO.Path]::GetRelativePath([string]$BasePath, [string]$FullPath)
    }
    catch {
        $base = [string]$BasePath
        $full = [string]$FullPath
        if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $full.Substring($base.Length).TrimStart([char[]]@('\','/'))
        }
        return Split-Path -Path $full -Leaf
    }
}

function Write-JsonSafe {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 10
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { New-DirectorySafe -Path $parent }
    try {
        $InputObject | ConvertTo-Json -Depth $Depth -ErrorAction Stop | Out-File -FilePath $Path -Encoding UTF8 -Force
    }
    catch {
        $fallback = [PSCustomObject]@{
            SchemaVersion = 'diagframework.jsonfallback.v1'
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            JsonSerializationFailed = $true
            Error = $_.Exception.Message
            ObjectType = if ($null -ne $InputObject) { $InputObject.GetType().FullName } else { $null }
            Text = ConvertTo-SafeString -Value ($InputObject | Out-String)
        }
        $fallback | ConvertTo-Json -Depth 6 | Out-File -FilePath $Path -Encoding UTF8 -Force
    }
}

function Write-JsonLinesSafe {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { New-DirectorySafe -Path $parent }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
    foreach ($item in @($InputObject)) {
        try {
            $item | ConvertTo-Json -Depth 8 -Compress -ErrorAction Stop | Out-File -FilePath $Path -Encoding UTF8 -Append
        }
        catch {
            [PSCustomObject]@{
                SchemaVersion = 'diagframework.jsonl.fallback.v1'
                TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
                Error = $_.Exception.Message
                ObjectType = if ($null -ne $item) { $item.GetType().FullName } else { $null }
                Text = ConvertTo-SafeString -Value ($item | Out-String)
            } | ConvertTo-Json -Depth 6 -Compress | Out-File -FilePath $Path -Encoding UTF8 -Append
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType File -Force | Out-Null }
}

function Add-ProgressEvent {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$Step,
        [string]$Status = 'OK',
        [string]$Message = ''
    )
    try {
        $entry = [PSCustomObject]@{
            SchemaVersion = 'diagframework.collector.progress.v1'
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            Step = $Step
            Status = $Status
            Message = $Message
        }
        $entry | ConvertTo-Json -Depth 6 -Compress | Out-File -FilePath (Join-Path $PackageRoot 'collector-progress.jsonl') -Encoding UTF8 -Append
    }
    catch { }
}

function Add-CollectorError {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$CurrentErrors = @(),
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Error,
        [AllowEmptyString()][string]$Target = '',
        [AllowEmptyString()][string]$Category = '',
        [AllowEmptyString()][string]$ScriptStackTrace = ''
    )

    $existing = @()
    if ($null -ne $CurrentErrors) { $existing = @($CurrentErrors) }

    return @($existing + [PSCustomObject]@{
        SchemaVersion = 'diagframework.collector.error.v1'
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Step = $Step
        Target = $Target
        Category = $Category
        Error = $Error
        ScriptStackTrace = $ScriptStackTrace
    })
}

function Write-CollectorErrorsSafe {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Errors = @()
    )
    Write-JsonSafe -InputObject @($Errors) -Path (Join-Path $PackageRoot 'errors/collector-errors.json') -Depth 8
}

function Write-LogRootReadmes {
    param(
        [Parameter(Mandatory)][string]$LogRootPath,
        [string]$TargetKB = ''
    )
    New-DirectorySafe -Path $LogRootPath
    $evidenceRoot = Join-Path $LogRootPath 'evidence_packages'
    $aiPackageRoot = Join-Path $LogRootPath 'ai_packages'
    foreach ($dir in @($evidenceRoot, $aiPackageRoot, (Join-Path $LogRootPath 'jsonl'), (Join-Path $LogRootPath 'state'))) {
        New-DirectorySafe -Path $dir
    }

    $now = (Get-Date).ToString('o')
    @"
# DiagFramework LOG Root — AI elemzési útmutató

Generated/Updated: $now
Module: $ModuleId $ModuleVersion
TargetKB context: $TargetKB

## Cél
Ez a könyvtár tartalmazza a DiagFramework futási, rendszerdiagnosztikai és AI-elemzésre előkészített LOG állományait.

## Fontos könyvtárak

| Könyvtár | Tartalom | AI elemzési prioritás |
|---|---|---|
| `ai_packages/` | Célzott KB / Windows Update hibaelemző csomagok | Magas, ha konkrét frissítés hibázik |
| `evidence_packages/` | Általános rendszerbizonyíték-csomagok boot/setup/driver/update/crash vizsgálathoz | Magas, ha rollback, BSOD, driver vagy boot anomália van |
| `jsonl/` | DiagFramework futási események JSONL formátumban | Közepes; a program saját futását magyarázza |
| `state/` | Javítási/rollback állapotfájlok, ha egy modul használja | Magas javítás után |

## AI-nak javasolt sorrend
1. Olvasd el az adott ZIP-ben vagy mappában lévő `AI_README.md` fájlt.
2. Nézd meg az `ai_summary.json` fájlt.
3. Nézd meg a `collector-progress.jsonl` és `errors/collector-errors.json` fájlokat.
4. Ezután elemezd az eseménynaplókat, CBS/DISM/Panther/SetupAPI/WER adatokat.

## Biztonsági megjegyzés
A LOG csomagok érzékeny gépnevet, felhasználónevet, driverlistát, eszközazonosítókat és részleges útvonalakat tartalmazhatnak. Külső megosztás előtt célszerű anonimizálni.
"@ | Out-File -FilePath (Join-Path $LogRootPath 'AI_README.md') -Encoding UTF8 -Force

    @"
# System Evidence Packages — AI elemzési útmutató

Generated/Updated: $now
Module: $ModuleId $ModuleVersion

## Cél
Ez a könyvtár a `SystemEvidenceCollector` által létrehozott általános Windows 11 rendszerbizonyíték-csomagokat tartalmazza.

## Tipikus használat
- Windows Update rollback vagy többszöri újraindítás után sikertelen telepítés.
- Driver-összeférhetetlenség gyanúja.
- Boot / setup / device setup / WER / minidump vizsgálat.
- Gyártói diagnosztikai program futtatása utáni logok strukturált gyűjtése.

## Egy csomag várható szerkezete

| Elem | Jelentés |
|---|---|
| `AI_README.md` | Az adott csomag emberi/AI olvasási útmutatója |
| `ai_summary.json` | Gép, időablak, hiba- és csomagösszefoglaló |
| `manifest.json` | Fájlindex relatív útvonalakkal és méretekkel |
| `collector-progress.jsonl` | Gyűjtési lépések időrendben |
| `errors/collector-errors.json` | Sikertelen részlépések; részleges csomag esetén elsőként olvasandó |
| `events/*.jsonl` | Laposított Windows eseménynapló rekordok |
| `copied_logs/` | CBS, DISM, Panther, SetupAPI, WER, minidump és egyéb fájlok |
| `vendor_logs/` | Ismert gyártói diagnosztikai könyvtárakból másolt releváns fájlok |

## Elemzési szabály
A csomag részleges állapotban is értékes. Ha `Status=Partial`, akkor először az `errors/collector-errors.json` alapján kell eldönteni, melyik adatforrás hiányzik.
"@ | Out-File -FilePath (Join-Path $evidenceRoot 'AI_README.md') -Encoding UTF8 -Force
}

function Write-PackageReadme {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [string]$TargetKB = '',
        [string]$Status = 'InProgress'
    )
    @"
# System Evidence Package — AI_README

Generated/Updated: $((Get-Date).ToString('o'))
Computer: $env:COMPUTERNAME
Module: $ModuleId $ModuleVersion
Status: $Status
TargetKB context: $TargetKB

## Cél
Ez a csomag Windows 11 boot, setup, update, driver, crash és gyártói diagnosztikai bizonyítékokat tartalmaz AI vagy szakértői elemzéshez.

## Fontos
A csomagot egy olvasó jellegű gyűjtőmodul készíti. Nem futtat javítást, nem reseteli a Windows Update komponenst, és nem módosít rendszerbeállítást.

## AI elemzési sorrend
1. `ai_summary.json`
2. `collector-progress.jsonl`
3. `errors/collector-errors.json`
4. `events/event-summary.json`
5. `registry/reboot-pending.json`
6. `drivers/pnp-signed-drivers.json`
7. `copied_logs/` és `vendor_logs/` tartalma
8. `commands/native-command-results.json`

## Állapotértelmezés
- `Complete`: a fő csomagképzés lefutott.
- `Partial`: egy vagy több adatforrás hibázott, de a csomag elemzésre alkalmas.
- `FatalPartial`: végzetes részhiba történt, de a modul megpróbált csomagot és hibaösszefoglalót készíteni.
- `InProgress`: a fájl a futás korai szakaszában készült, és később frissülhet.

## Adatvédelmi megjegyzés
A csomag gépnevet, felhasználónevet, eszköz- és driveradatokat, valamint útvonalakat tartalmazhat.
"@ | Out-File -FilePath (Join-Path $PackageRoot 'AI_README.md') -Encoding UTF8 -Force
}

function Convert-EventRecordFlat {
    param([Parameter(Mandatory)]$Event)

    $timeCreated = $null
    $providerName = $null
    $logName = $null
    $eventId = $null
    $levelDisplayName = $null
    $machineName = $null
    $recordId = $null
    $taskDisplayName = $null
    $opcodeDisplayName = $null
    $keywords = ''
    $message = '<MessageUnavailable>'

    try { if ($null -ne $Event.TimeCreated) { $timeCreated = ([datetime]$Event.TimeCreated).ToString('o') } } catch { }
    try { $providerName = ConvertTo-SafeString -Value $Event.ProviderName } catch { }
    try { $logName = ConvertTo-SafeString -Value $Event.LogName } catch { }
    try { if ($null -ne $Event.Id) { $eventId = [int]$Event.Id } } catch { }
    try { $levelDisplayName = ConvertTo-SafeString -Value $Event.LevelDisplayName } catch { }
    try { $machineName = ConvertTo-SafeString -Value $Event.MachineName } catch { }
    try { if ($null -ne $Event.RecordId) { $recordId = [int64]$Event.RecordId } } catch { }
    try { $taskDisplayName = ConvertTo-SafeString -Value $Event.TaskDisplayName } catch { }
    try { $opcodeDisplayName = ConvertTo-SafeString -Value $Event.OpcodeDisplayName } catch { }
    try { $keywords = ConvertTo-SafeString -Value $Event.KeywordsDisplayNames } catch { }
    try { $message = ConvertTo-SafeString -Value $Event.Message } catch { }

    [PSCustomObject]@{
        TimeCreated = $timeCreated
        ProviderName = $providerName
        LogName = $logName
        Id = $eventId
        LevelDisplayName = $levelDisplayName
        MachineName = $machineName
        RecordId = $recordId
        TaskDisplayName = $taskDisplayName
        OpcodeDisplayName = $opcodeDisplayName
        KeywordsDisplayNames = $keywords
        Message = $message
    }
}

function Copy-IfExists {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [int64]$MaxBytes = 52428800,
        [int]$MaxFiles = 300
    )
    if (-not (Test-Path -LiteralPath $Source)) { return @() }
    New-DirectorySafe -Path $DestinationRoot
    $item = Get-Item -LiteralPath $Source -ErrorAction Stop

    if ($item.PSIsContainer) {
        $target = Join-Path $DestinationRoot $item.Name
        New-DirectorySafe -Path $target
        $count = 0
        $results = @()
        $children = @(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        foreach ($child in $children) {
            if ($count -ge $MaxFiles) { break }
            if ($child.Length -le $MaxBytes) {
                $relative = Get-RelativePathSafe -BasePath $item.FullName -FullPath $child.FullName
                $dest = Join-Path $target $relative
                New-DirectorySafe -Path (Split-Path -Parent $dest)
                Copy-Item -LiteralPath $child.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                $results += [PSCustomObject]@{ Source=$child.FullName; Destination=$dest; Length=$child.Length; LastWriteTime=$child.LastWriteTime.ToString('o') }
                $count++
            }
            else {
                $results += [PSCustomObject]@{ Source=$child.FullName; Skipped=$true; Reason='FileTooLarge'; Length=$child.Length }
            }
        }
        return $results
    }

    if ($item.Length -gt $MaxBytes) {
        return @([PSCustomObject]@{ Source=$item.FullName; Skipped=$true; Reason='FileTooLarge'; Length=$item.Length })
    }
    $dest = Join-Path $DestinationRoot $item.Name
    Copy-Item -LiteralPath $item.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
    return @([PSCustomObject]@{ Source=$item.FullName; Destination=$dest; Length=$item.Length; LastWriteTime=$item.LastWriteTime.ToString('o') })
}

function Get-RegistryValuesFlat {
    param([Parameter(Mandatory)][string]$Path)
    $values = @()
    try {
        $props = Get-ItemProperty -Path $Path -ErrorAction Stop
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $values += [PSCustomObject]@{ Name=$p.Name; Value=(ConvertTo-SafeString -Value $p.Value) }
        }
    }
    catch {
        $values += [PSCustomObject]@{ Name='__ERROR__'; Value=$_.Exception.Message }
    }
    return $values
}

function Get-RebootPendingSnapshot {
    $checks = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )
    $result = @()
    foreach ($path in $checks) {
        $exists = $false
        try { $exists = [bool](Test-Path -LiteralPath $path) } catch { $exists = $false }
        $values = @()
        if ($exists) { $values = @(Get-RegistryValuesFlat -Path $path) }
        $result += [PSCustomObject]@{ Path=$path; Exists=$exists; Values=$values }
    }
    return $result
}

function Get-SystemSnapshot {
    $os = $null; $cs = $null; $bios = $null
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop } catch { }
    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        UserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        PowerShell = [PSCustomObject]@{
            Version = $PSVersionTable.PSVersion.ToString()
            Edition = $PSVersionTable.PSEdition
            Platform = if ($PSVersionTable.ContainsKey('Platform')) { $PSVersionTable.Platform } else { $null }
        }
        OS = if ($os) { [PSCustomObject]@{ Caption=$os.Caption; Version=$os.Version; BuildNumber=$os.BuildNumber; Architecture=$os.OSArchitecture; InstallDate=if ($os.InstallDate) { ([datetime]$os.InstallDate).ToString('o') } else { $null }; LastBootUpTime=if ($os.LastBootUpTime) { ([datetime]$os.LastBootUpTime).ToString('o') } else { $null } } } else { $null }
        ComputerSystem = if ($cs) { [PSCustomObject]@{ Manufacturer=$cs.Manufacturer; Model=$cs.Model; SystemType=$cs.SystemType; TotalPhysicalMemory=$cs.TotalPhysicalMemory } } else { $null }
        BIOS = if ($bios) { [PSCustomObject]@{ Manufacturer=$bios.Manufacturer; SMBIOSBIOSVersion=$bios.SMBIOSBIOSVersion; ReleaseDate=if ($bios.ReleaseDate) { ([datetime]$bios.ReleaseDate).ToString('o') } else { $null } } } else { $null }
    }
}

function Get-DriverSnapshot {
    $items = @()
    try {
        $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)
        foreach ($d in $drivers) {
            $items += [PSCustomObject]@{
                DeviceName = ConvertTo-SafeString -Value $d.DeviceName
                Manufacturer = ConvertTo-SafeString -Value $d.Manufacturer
                DriverProviderName = ConvertTo-SafeString -Value $d.DriverProviderName
                DriverVersion = ConvertTo-SafeString -Value $d.DriverVersion
                DriverDate = ConvertTo-SafeString -Value $d.DriverDate
                InfName = ConvertTo-SafeString -Value $d.InfName
                DeviceClass = ConvertTo-SafeString -Value $d.DeviceClass
                IsSigned = ConvertTo-SafeString -Value $d.IsSigned
                Signer = ConvertTo-SafeString -Value $d.Signer
            }
        }
    }
    catch {
        $items += [PSCustomObject]@{ Error = $_.Exception.Message }
    }
    return $items
}

function Collect-Events {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][datetime]$StartTime,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Errors = @(),
        [int]$MaxEvents = 1200
    )
    $eventRoot = Join-Path $PackageRoot 'events'
    New-DirectorySafe -Path $eventRoot
    $logs = @(
        'System',
        'Application',
        'Setup',
        'Microsoft-Windows-WindowsUpdateClient/Operational',
        'Microsoft-Windows-DeviceSetupManager/Admin',
        'Microsoft-Windows-DeviceSetupManager/Operational',
        'Microsoft-Windows-Kernel-Boot/Operational',
        'Microsoft-Windows-Kernel-PnP/Configuration',
        'Microsoft-Windows-DriverFrameworks-UserMode/Operational',
        'Microsoft-Windows-WHEA-Logger/Operational',
        'Microsoft-Windows-WER-SystemErrorReporting/Operational'
    )
    $summary = @()
    $localErrors = if ($null -ne $Errors) { @($Errors) } else { @() }
    foreach ($log in $logs) {
        $safe = ($log -replace '[\\/\:\*\?"\<\>\|]', '_')
        $outPath = Join-Path $eventRoot ($safe + '.jsonl')
        try {
            $rawEvents = @(Get-WinEvent -FilterHashtable @{ LogName=$log; StartTime=$StartTime } -MaxEvents $MaxEvents -ErrorAction Stop)
            $flat = @()
            foreach ($ev in $rawEvents) {
                try { $flat += (Convert-EventRecordFlat -Event $ev) }
                catch { $localErrors = @(Add-CollectorError -CurrentErrors $localErrors -Step 'EventFlatten' -Target $log -Error $_.Exception.Message -Category 'EventRecord' -ScriptStackTrace $_.ScriptStackTrace) }
            }
            Write-JsonLinesSafe -InputObject $flat -Path $outPath
            $summary += [PSCustomObject]@{ LogName=$log; Status='OK'; Count=$flat.Count; OutputFile=('events/' + $safe + '.jsonl') }
        }
        catch {
            Write-JsonLinesSafe -InputObject @() -Path $outPath
            $summary += [PSCustomObject]@{ LogName=$log; Status='Error'; Count=0; Error=$_.Exception.Message; OutputFile=('events/' + $safe + '.jsonl') }
            $localErrors = @(Add-CollectorError -CurrentErrors $localErrors -Step 'EventLog' -Target $log -Error $_.Exception.Message -Category 'Get-WinEvent' -ScriptStackTrace $_.ScriptStackTrace)
        }
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $eventRoot 'event-summary.json') -Depth 6
    [PSCustomObject]@{ Summary=$summary; Errors=$localErrors }
}

function Invoke-NativeCommandSafe {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$File,
        [string[]]$Args = @()
    )
    try {
        $outFile = Join-Path $PackageRoot ('commands/' + $Name + '.txt')
        $errFile = Join-Path $PackageRoot ('commands/' + $Name + '.err.txt')
        $p = Start-Process -FilePath $File -ArgumentList ([string[]]$Args) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
        [PSCustomObject]@{ Name=$Name; ExitCode=$p.ExitCode; StdOut=$outFile; StdErr=$errFile; Args=(ConvertTo-SafeString -Value $Args) }
    }
    catch {
        [PSCustomObject]@{ Name=$Name; Error=$_.Exception.Message; Args=(ConvertTo-SafeString -Value $Args) }
    }
}

function New-PackageManifestSafe {
    param([Parameter(Mandatory)][string]$PackageRoot)
    $files = @()
    $children = @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        try {
            $files += [PSCustomObject]@{
                RelativePath = Get-RelativePathSafe -BasePath $PackageRoot -FullPath $child.FullName
                Length = $child.Length
                LastWriteTime = $child.LastWriteTime.ToString('o')
            }
        }
        catch { }
    }
    [PSCustomObject]@{
        SchemaVersion='diagframework.package.manifest.v1'
        PackageType='SystemEvidence'
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        ModuleId=$ModuleId
        ModuleVersion=$ModuleVersion
        ComputerName=$env:COMPUTERNAME
        Files=$files
    }
}

function Invoke-CollectorStep {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Errors = @()
    )
    try {
        $result = & $ScriptBlock
        Add-ProgressEvent -PackageRoot $PackageRoot -Step $Step -Status 'OK'
        [PSCustomObject]@{ Result=$result; Errors=$Errors }
    }
    catch {
        $newErrors = @(Add-CollectorError -CurrentErrors $Errors -Step $Step -Error $_.Exception.Message -Category $_.CategoryInfo.ToString() -ScriptStackTrace $_.ScriptStackTrace)
        Add-ProgressEvent -PackageRoot $PackageRoot -Step $Step -Status 'Error' -Message $_.Exception.Message
        [PSCustomObject]@{ Result=$null; Errors=$newErrors }
    }
}

function New-SummaryObject {
    param(
        [string]$Status,
        [string]$PackageRoot,
        [string]$ZipPath,
        [string]$TargetKB,
        [int]$DaysBack,
        [int]$MaxEvents,
        [AllowNull()][AllowEmptyCollection()][object[]]$EventSummary = @(),
        [AllowNull()][AllowEmptyCollection()][object[]]$Copied = @(),
        [AllowNull()][AllowEmptyCollection()][object[]]$NativeResults = @(),
        [AllowNull()][AllowEmptyCollection()][object[]]$Errors = @(),
        [string]$FatalError = ''
    )
    [PSCustomObject]@{
        SchemaVersion = 'diagframework.systemevidence.summary.v1'
        ModuleId = $ModuleId
        ModuleVersion = $ModuleVersion
        Status = $Status
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName = $env:COMPUTERNAME
        TargetKB = $TargetKB
        DaysBack = $DaysBack
        MaxEvents = $MaxEvents
        PackageRoot = $PackageRoot
        ZipPath = $ZipPath
        EventLogCount = @($EventSummary).Count
        CopiedRecordCount = @($Copied).Count
        NativeCommandCount = @($NativeResults).Count
        ErrorCount = @($Errors).Count
        FatalError = $FatalError
        Purpose = 'AI/szakértő által elemezhető Windows 11 rendszerbizonyíték-csomag boot, setup, driver, update, crash és vendor diagnosztikai hibákhoz.'
    }
}

function Invoke-EvidenceCollection {
    param([int]$DaysBack = 30, [int]$MaxEvents = 1200, [switch]$WhatIf, [string]$TargetKB = '')

    Write-LogRootReadmes -LogRootPath $LogRoot -TargetKB $TargetKB

    $evidenceRoot = Join-Path $LogRoot 'evidence_packages'
    New-DirectorySafe -Path $evidenceRoot
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $suffix = if ([string]::IsNullOrWhiteSpace($TargetKB)) { 'SystemEvidence' } else { ('SystemEvidence-' + $TargetKB) }
    $packageRoot = Join-Path $evidenceRoot ("$timestamp-$env:COMPUTERNAME-$suffix")
    $zipPath = "$packageRoot.zip"
    New-DirectorySafe -Path $packageRoot
    foreach ($sub in 'meta','events','registry','copied_logs','drivers','commands','errors','vendor_logs') { New-DirectorySafe -Path (Join-Path $packageRoot $sub) }
    Write-PackageReadme -PackageRoot $packageRoot -TargetKB $TargetKB -Status 'InProgress'

    $errors = @()
    $eventSummary = @()
    $copied = @()
    $nativeResults = @()

    Add-ProgressEvent -PackageRoot $packageRoot -Step 'Start' -Message "DaysBack=$DaysBack MaxEvents=$MaxEvents TargetKB=$TargetKB WhatIf=$($WhatIf.IsPresent)"

    if ($WhatIf) {
        $summary = [PSCustomObject]@{
            SchemaVersion='diagframework.systemevidence.summary.v1'
            ModuleId=$ModuleId
            ModuleVersion=$ModuleVersion
            WhatIf=$true
            Status='WhatIf'
            Summary='WhatIf mód: a modul nem gyűjtött fájlokat, csak jelezte a tervezett evidence package műveletet.'
            PlannedPackageRoot=$packageRoot
            PlannedZipPath=$zipPath
        }
        Write-JsonSafe -InputObject $summary -Path (Join-Path $packageRoot 'ai_summary.json') -Depth 8
        Write-PackageReadme -PackageRoot $packageRoot -TargetKB $TargetKB -Status 'WhatIf'
        return $summary
    }

    try {
        $startTime = (Get-Date).AddDays(-1 * [Math]::Abs($DaysBack))

        $step = Invoke-CollectorStep -Step 'SystemSnapshot' -PackageRoot $packageRoot -Errors $errors -ScriptBlock {
            $obj = Get-SystemSnapshot
            Write-JsonSafe -InputObject $obj -Path (Join-Path $packageRoot 'meta/system-info.json') -Depth 8
            $obj
        }
        $errors = if ($null -ne $step.Errors) { @($step.Errors) } else { @() }

        $step = Invoke-CollectorStep -Step 'RegistryPendingReboot' -PackageRoot $packageRoot -Errors $errors -ScriptBlock {
            $obj = @(Get-RebootPendingSnapshot)
            Write-JsonSafe -InputObject $obj -Path (Join-Path $packageRoot 'registry/reboot-pending.json') -Depth 10
            $obj
        }
        $errors = if ($null -ne $step.Errors) { @($step.Errors) } else { @() }

        $step = Invoke-CollectorStep -Step 'DriverSnapshot' -PackageRoot $packageRoot -Errors $errors -ScriptBlock {
            $obj = @(Get-DriverSnapshot)
            Write-JsonSafe -InputObject $obj -Path (Join-Path $packageRoot 'drivers/pnp-signed-drivers.json') -Depth 8
            $obj
        }
        $errors = if ($null -ne $step.Errors) { @($step.Errors) } else { @() }

        try {
            $eventResult = Collect-Events -PackageRoot $packageRoot -StartTime $startTime -MaxEvents $MaxEvents -Errors $errors
            $eventSummary = @($eventResult.Summary)
            $errors = if ($null -ne $eventResult.Errors) { @($eventResult.Errors) } else { @() }
            Add-ProgressEvent -PackageRoot $packageRoot -Step 'EventLogs' -Status 'OK' -Message "Logs=$($eventSummary.Count)"
        }
        catch {
            $errors = @(Add-CollectorError -CurrentErrors $errors -Step 'EventLogs' -Error $_.Exception.Message -Category $_.CategoryInfo.ToString() -ScriptStackTrace $_.ScriptStackTrace)
            Add-ProgressEvent -PackageRoot $packageRoot -Step 'EventLogs' -Status 'Error' -Message $_.Exception.Message
            $eventSummary = @()
        }

        $copyTargets = @(
            "$env:SystemRoot\Logs\CBS\CBS.log",
            "$env:SystemRoot\Logs\DISM\dism.log",
            "$env:SystemRoot\WindowsUpdate.log",
            "$env:SystemRoot\SoftwareDistribution\ReportingEvents.log",
            "$env:SystemRoot\Panther",
            "$env:SystemRoot\INF\setupapi.dev.log",
            "$env:SystemRoot\INF\setupapi.setup.log",
            "$env:SystemRoot\Minidump",
            "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
            "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
            "$env:ProgramData\Dell",
            "$env:ProgramData\HP",
            "$env:ProgramData\Lenovo",
            "$env:ProgramData\Intel",
            "$env:ProgramData\NVIDIA Corporation",
            "$env:ProgramData\AMD"
        )
        foreach ($target in $copyTargets) {
            try {
                $destRoot = if ($target -match 'ProgramData\\(Dell|HP|Lenovo|Intel|NVIDIA Corporation|AMD)') { Join-Path $packageRoot 'vendor_logs' } else { Join-Path $packageRoot 'copied_logs' }
                $result = @(Copy-IfExists -Source $target -DestinationRoot $destRoot)
                if ($result.Count -gt 0) { $copied += $result }
            }
            catch {
                $errors = @(Add-CollectorError -CurrentErrors $errors -Step 'CopyTarget' -Target $target -Error $_.Exception.Message -Category $_.CategoryInfo.ToString() -ScriptStackTrace $_.ScriptStackTrace)
            }
        }
        Write-JsonSafe -InputObject $copied -Path (Join-Path $packageRoot 'copied_logs/copied-files.json') -Depth 8
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'CopyLogs' -Message "CopiedRecords=$($copied.Count)"

        $commands = @(
            @{ Name='reagentc-info'; File='reagentc.exe'; Args=@('/info') },
            @{ Name='bcdedit-enum-all'; File='bcdedit.exe'; Args=@('/enum','all') },
            @{ Name='dism-packages'; File='dism.exe'; Args=@('/Online','/Get-Packages','/Format:Table') },
            @{ Name='dism-checkhealth'; File='dism.exe'; Args=@('/Online','/Cleanup-Image','/CheckHealth') }
        )
        foreach ($cmd in $commands) {
            $nativeResults += (Invoke-NativeCommandSafe -PackageRoot $packageRoot -Name ([string]$cmd.Name) -File ([string]$cmd.File) -Args ([string[]]$cmd.Args))
        }
        Write-JsonSafe -InputObject $nativeResults -Path (Join-Path $packageRoot 'commands/native-command-results.json') -Depth 6
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'NativeCommands' -Message "Commands=$($nativeResults.Count)"
    }
    catch {
        $errors = @(Add-CollectorError -CurrentErrors $errors -Step 'FatalCollectorBody' -Error $_.Exception.Message -Category $_.CategoryInfo.ToString() -ScriptStackTrace $_.ScriptStackTrace)
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'FatalCollectorBody' -Status 'Error' -Message $_.Exception.Message
    }

    Write-CollectorErrorsSafe -PackageRoot $packageRoot -Errors $errors

    $status = if (@($errors).Count -gt 0) { 'Partial' } else { 'Complete' }
    $summary = New-SummaryObject -Status $status -PackageRoot $packageRoot -ZipPath $zipPath -TargetKB $TargetKB -DaysBack $DaysBack -MaxEvents $MaxEvents -EventSummary $eventSummary -Copied $copied -NativeResults $nativeResults -Errors $errors
    Write-JsonSafe -InputObject $summary -Path (Join-Path $packageRoot 'ai_summary.json') -Depth 8
    Write-PackageReadme -PackageRoot $packageRoot -TargetKB $TargetKB -Status $status

    try {
        $manifest = New-PackageManifestSafe -PackageRoot $packageRoot
        Write-JsonSafe -InputObject $manifest -Path (Join-Path $packageRoot 'manifest.json') -Depth 10
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'Manifest' -Message "Files=$($manifest.Files.Count)"
    }
    catch {
        $errors = @(Add-CollectorError -CurrentErrors $errors -Step 'Manifest' -Error $_.Exception.Message -Category $_.CategoryInfo.ToString() -ScriptStackTrace $_.ScriptStackTrace)
        Write-CollectorErrorsSafe -PackageRoot $packageRoot -Errors $errors
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'Manifest' -Status 'Error' -Message $_.Exception.Message
    }

    try {
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
        Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -Force -ErrorAction Stop
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'Zip' -Message $zipPath
    }
    catch {
        $errors = @(Add-CollectorError -CurrentErrors $errors -Step 'Zip' -Error $_.Exception.Message -Category $_.CategoryInfo.ToString() -ScriptStackTrace $_.ScriptStackTrace)
        Write-CollectorErrorsSafe -PackageRoot $packageRoot -Errors $errors
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'Zip' -Status 'Error' -Message $_.Exception.Message
    }

    if (@($errors).Count -gt 0 -and $summary.Status -ne 'Partial') {
        $summary = New-SummaryObject -Status 'Partial' -PackageRoot $packageRoot -ZipPath $zipPath -TargetKB $TargetKB -DaysBack $DaysBack -MaxEvents $MaxEvents -EventSummary $eventSummary -Copied $copied -NativeResults $nativeResults -Errors $errors
        Write-JsonSafe -InputObject $summary -Path (Join-Path $packageRoot 'ai_summary.json') -Depth 8
    }

    return $summary
}

switch ($Action) {
    'Get-Metadata' { Get-Metadata }
    'Test-Condition' {
        [PSCustomObject]@{
            IssueDetected = $true
            FixAvailable = $true
            Severity = 'Info'
            Summary = 'Rendszerbizonyíték-csomag készíthető boot, setup, driver, Windows Update, WER és gyártói diagnosztikai elemzéshez. A modul olvasási jellegű: célja a tényanyag összegyűjtése, nem a rendszer módosítása.'
            RecommendedAction = 'Sikertelen KB telepítés, rollback, ismeretlen restart, drivergyanú vagy vendor diagnosztika után futtasd. Először hagyd bekapcsolva a WhatIf módot a GUI-ban, majd éles gyűjtésnél készíts ZIP-et. A kész csomagban elsőként az AI_README.md, ai_summary.json, collector-progress.jsonl és errors/collector-errors.json fájlokat kell olvasni.'
        }
    }
    'Invoke-Fix' { Invoke-EvidenceCollection -DaysBack $DaysBack -MaxEvents $MaxEvents -WhatIf:$WhatIf -TargetKB $TargetKB }
    'Invoke-Rollback' {
        [PSCustomObject]@{
            RollbackSupported = $false
            Summary = 'A SystemEvidenceCollector nem módosít rendszert, ezért rollback nem szükséges.'
        }
    }
}
