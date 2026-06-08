<#
.SYNOPSIS
  Windows 11 rendszerbizonyíték és vendor diagnosztikai LOG gyűjtő modul.

.DESCRIPTION
  Nem javít rendszert. Strukturált, AI által elemezhető ZIP csomagot készít
  boot, setup, driver, update, crash és ismert gyártói diagnosztikai nyomokból.
  v1.2.1: lépésenként hibaszigetelt gyűjtés, gyökérszintű AI_README fájlok,
  részleges csomagkészítés hiba esetén is.
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
$ModuleVersion = '1.2.1'

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
    try { return [string]$Value } catch { return '<UnserializableValue>' }
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
            return $full.Substring($base.Length).TrimStart([char[]]@('\\','/'))
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
            Text = ConvertTo-SafeString -Value $InputObject
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
                Text = ConvertTo-SafeString -Value $item
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
        [Parameter(Mandatory)]$Errors,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Error,
        [string]$Target = '',
        [string]$Category = ''
    )
    $Errors.Add([PSCustomObject]@{
        SchemaVersion = 'diagframework.collector.error.v1'
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Step = $Step
        Target = $Target
        Category = $Category
        Error = $Error
    }) | Out-Null
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
- `InProgress`: a fájl a futás korai szakaszában készült, és később frissülhet.

## Adatvédelmi megjegyzés
A csomag gépnevet, felhasználónevet, eszköz- és driveradatokat, valamint útvonalakat tartalmazhat.
"@ | Out-File -FilePath (Join-Path $PackageRoot 'AI_README.md') -Encoding UTF8 -Force
}

function Convert-EventRecordFlat {
    param([Parameter(Mandatory)]$Event)
    $keywords = @()
    try { $keywords = @($Event.KeywordsDisplayNames | ForEach-Object { ConvertTo-SafeString -Value $_ }) } catch { $keywords = @() }
    [PSCustomObject]@{
        TimeCreated = try { if ($Event.TimeCreated) { ([datetime]$Event.TimeCreated).ToString('o') } else { $null } } catch { $null }
        ProviderName = try { ConvertTo-SafeString -Value $Event.ProviderName } catch { $null }
        LogName = try { ConvertTo-SafeString -Value $Event.LogName } catch { $null }
        Id = try { [int]$Event.Id } catch { $null }
        LevelDisplayName = try { ConvertTo-SafeString -Value $Event.LevelDisplayName } catch { $null }
        MachineName = try { ConvertTo-SafeString -Value $Event.MachineName } catch { $null }
        RecordId = try { [int64]$Event.RecordId } catch { $null }
        TaskDisplayName = try { ConvertTo-SafeString -Value $Event.TaskDisplayName } catch { $null }
        OpcodeDisplayName = try { ConvertTo-SafeString -Value $Event.OpcodeDisplayName } catch { $null }
        KeywordsDisplayNames = $keywords
        Message = try { ConvertTo-SafeString -Value $Event.Message } catch { '<MessageUnavailable>' }
    }
}

function Copy-IfExists {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [int64]$MaxBytes = 52428800,
        [int]$MaxFiles = 300
    )
    if (-not (Test-Path -LiteralPath $Source)) { return $null }
    New-DirectorySafe -Path $DestinationRoot
    $item = Get-Item -LiteralPath $Source -ErrorAction Stop
    if ($item.PSIsContainer) {
        $target = Join-Path $DestinationRoot $item.Name
        New-DirectorySafe -Path $target
        $copied = New-Object System.Collections.Generic.List[object]
        $count = 0
        Get-ChildItem -LiteralPath $item.FullName -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
            if ($count -ge $MaxFiles) { return }
            if ($_.Length -le $MaxBytes) {
                $relative = Get-RelativePathSafe -BasePath $item.FullName -FullPath $_.FullName
                $dest = Join-Path $target $relative
                New-DirectorySafe -Path (Split-Path -Parent $dest)
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                $copied.Add([PSCustomObject]@{ Source=$_.FullName; Destination=$dest; Length=$_.Length; LastWriteTime=$_.LastWriteTime.ToString('o') }) | Out-Null
                $count++
            }
            else {
                $copied.Add([PSCustomObject]@{ Source=$_.FullName; Skipped=$true; Reason='FileTooLarge'; Length=$_.Length }) | Out-Null
            }
        }
        return @($copied)
    }
    else {
        if ($item.Length -gt $MaxBytes) {
            return [PSCustomObject]@{ Source=$item.FullName; Skipped=$true; Reason='FileTooLarge'; Length=$item.Length }
        }
        $dest = Join-Path $DestinationRoot $item.Name
        Copy-Item -LiteralPath $item.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Source=$item.FullName; Destination=$dest; Length=$item.Length; LastWriteTime=$item.LastWriteTime.ToString('o') }
    }
}

function Get-RegistryValuesFlat {
    param([Parameter(Mandatory)][string]$Path)
    $values = New-Object System.Collections.Generic.List[object]
    try {
        $props = Get-ItemProperty -Path $Path -ErrorAction Stop
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $raw = $p.Value
            $text = if ($raw -is [array]) { (@($raw) | ForEach-Object { ConvertTo-SafeString -Value $_ }) -join '; ' } else { ConvertTo-SafeString -Value $raw }
            $values.Add([PSCustomObject]@{ Name=$p.Name; Value=$text }) | Out-Null
        }
    }
    catch {
        $values.Add([PSCustomObject]@{ Name='__ERROR__'; Value=$_.Exception.Message }) | Out-Null
    }
    return @($values)
}

function Get-RebootPendingSnapshot {
    $checks = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($path in $checks) {
        $exists = Test-Path $path
        $result.Add([PSCustomObject]@{ Path=$path; Exists=$exists; Values=if ($exists) { Get-RegistryValuesFlat -Path $path } else { @() } }) | Out-Null
    }
    return @($result)
}

function Get-SystemSnapshot {
    $os = $null; $cs = $null; $bios = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop } catch { }
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
    $items = New-Object System.Collections.Generic.List[object]
    try {
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | ForEach-Object {
            $items.Add([PSCustomObject]@{
                DeviceName = ConvertTo-SafeString -Value $_.DeviceName
                Manufacturer = ConvertTo-SafeString -Value $_.Manufacturer
                DriverProviderName = ConvertTo-SafeString -Value $_.DriverProviderName
                DriverVersion = ConvertTo-SafeString -Value $_.DriverVersion
                DriverDate = ConvertTo-SafeString -Value $_.DriverDate
                InfName = ConvertTo-SafeString -Value $_.InfName
                DeviceClass = ConvertTo-SafeString -Value $_.DeviceClass
                IsSigned = $_.IsSigned
                Signer = ConvertTo-SafeString -Value $_.Signer
            }) | Out-Null
        }
    }
    catch {
        $items.Add([PSCustomObject]@{ Error = $_.Exception.Message }) | Out-Null
    }
    return @($items)
}

function Collect-Events {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][datetime]$StartTime,
        [Parameter(Mandatory)]$Errors,
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
    $summary = New-Object System.Collections.Generic.List[object]
    foreach ($log in $logs) {
        $safe = ($log -replace '[\\/\:\*\?"\<\>\|]', '_')
        $outPath = Join-Path $eventRoot ($safe + '.jsonl')
        try {
            $rawEvents = @(Get-WinEvent -FilterHashtable @{ LogName=$log; StartTime=$StartTime } -MaxEvents $MaxEvents -ErrorAction Stop)
            $flat = New-Object System.Collections.Generic.List[object]
            foreach ($ev in $rawEvents) {
                try { $flat.Add((Convert-EventRecordFlat -Event $ev)) | Out-Null }
                catch { Add-CollectorError -Errors $Errors -Step 'EventFlatten' -Target $log -Error $_.Exception.Message -Category 'EventRecord' }
            }
            Write-JsonLinesSafe -InputObject @($flat) -Path $outPath
            $summary.Add([PSCustomObject]@{ LogName=$log; Status='OK'; Count=$flat.Count; OutputFile=('events/' + $safe + '.jsonl') }) | Out-Null
        }
        catch {
            Write-JsonLinesSafe -InputObject @() -Path $outPath
            $summary.Add([PSCustomObject]@{ LogName=$log; Status='Error'; Count=0; Error=$_.Exception.Message; OutputFile=('events/' + $safe + '.jsonl') }) | Out-Null
            Add-CollectorError -Errors $Errors -Step 'EventLog' -Target $log -Error $_.Exception.Message -Category 'Get-WinEvent'
        }
    }
    Write-JsonSafe -InputObject @($summary) -Path (Join-Path $eventRoot 'event-summary.json') -Depth 6
    return @($summary)
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
        [PSCustomObject]@{ Name=$Name; ExitCode=$p.ExitCode; StdOut=$outFile; StdErr=$errFile; Args=$Args }
    }
    catch {
        [PSCustomObject]@{ Name=$Name; Error=$_.Exception.Message; Args=$Args }
    }
}

function New-PackageManifestSafe {
    param([Parameter(Mandatory)][string]$PackageRoot)
    $files = New-Object System.Collections.Generic.List[object]
    Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $files.Add([PSCustomObject]@{
                RelativePath = Get-RelativePathSafe -BasePath $PackageRoot -FullPath $_.FullName
                Length = $_.Length
                LastWriteTime = $_.LastWriteTime.ToString('o')
            }) | Out-Null
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
        Files=@($files)
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

    $errors = New-Object System.Collections.Generic.List[object]
    $eventSummary = @()
    $copied = New-Object System.Collections.Generic.List[object]
    $nativeResults = New-Object System.Collections.Generic.List[object]

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

    $startTime = (Get-Date).AddDays(-1 * [Math]::Abs($DaysBack))

    try { Write-JsonSafe -InputObject (Get-SystemSnapshot) -Path (Join-Path $packageRoot 'meta/system-info.json') -Depth 8; Add-ProgressEvent -PackageRoot $packageRoot -Step 'SystemSnapshot' } catch { Add-CollectorError -Errors $errors -Step 'SystemSnapshot' -Error $_.Exception.Message; Add-ProgressEvent -PackageRoot $packageRoot -Step 'SystemSnapshot' -Status 'Error' -Message $_.Exception.Message }
    try { Write-JsonSafe -InputObject (Get-RebootPendingSnapshot) -Path (Join-Path $packageRoot 'registry/reboot-pending.json') -Depth 10; Add-ProgressEvent -PackageRoot $packageRoot -Step 'RegistryPendingReboot' } catch { Add-CollectorError -Errors $errors -Step 'RegistryPendingReboot' -Error $_.Exception.Message; Add-ProgressEvent -PackageRoot $packageRoot -Step 'RegistryPendingReboot' -Status 'Error' -Message $_.Exception.Message }
    try { Write-JsonSafe -InputObject (Get-DriverSnapshot) -Path (Join-Path $packageRoot 'drivers/pnp-signed-drivers.json') -Depth 8; Add-ProgressEvent -PackageRoot $packageRoot -Step 'DriverSnapshot' } catch { Add-CollectorError -Errors $errors -Step 'DriverSnapshot' -Error $_.Exception.Message; Add-ProgressEvent -PackageRoot $packageRoot -Step 'DriverSnapshot' -Status 'Error' -Message $_.Exception.Message }
    try { $eventSummary = Collect-Events -PackageRoot $packageRoot -StartTime $startTime -MaxEvents $MaxEvents -Errors $errors; Add-ProgressEvent -PackageRoot $packageRoot -Step 'EventLogs' -Message "Logs=$(@($eventSummary).Count)" } catch { Add-CollectorError -Errors $errors -Step 'EventLogs' -Error $_.Exception.Message; Add-ProgressEvent -PackageRoot $packageRoot -Step 'EventLogs' -Status 'Error' -Message $_.Exception.Message; $eventSummary=@() }

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
            $result = Copy-IfExists -Source $target -DestinationRoot $destRoot
            if ($null -ne $result) { foreach ($r in @($result)) { $copied.Add($r) | Out-Null } }
        }
        catch { Add-CollectorError -Errors $errors -Step 'CopyTarget' -Target $target -Error $_.Exception.Message }
    }
    Write-JsonSafe -InputObject @($copied) -Path (Join-Path $packageRoot 'copied_logs/copied-files.json') -Depth 8
    Add-ProgressEvent -PackageRoot $packageRoot -Step 'CopyLogs' -Message "CopiedRecords=$($copied.Count)"

    $commands = @(
        @{ Name='reagentc-info'; File='reagentc.exe'; Args=@('/info') },
        @{ Name='bcdedit-enum-all'; File='bcdedit.exe'; Args=@('/enum','all') },
        @{ Name='dism-packages'; File='dism.exe'; Args=@('/Online','/Get-Packages','/Format:Table') },
        @{ Name='dism-checkhealth'; File='dism.exe'; Args=@('/Online','/Cleanup-Image','/CheckHealth') }
    )
    foreach ($cmd in $commands) {
        $nr = Invoke-NativeCommandSafe -PackageRoot $packageRoot -Name ([string]$cmd.Name) -File ([string]$cmd.File) -Args ([string[]]$cmd.Args)
        $nativeResults.Add($nr) | Out-Null
    }
    Write-JsonSafe -InputObject @($nativeResults) -Path (Join-Path $packageRoot 'commands/native-command-results.json') -Depth 6
    Add-ProgressEvent -PackageRoot $packageRoot -Step 'NativeCommands' -Message "Commands=$($nativeResults.Count)"

    Write-JsonSafe -InputObject @($errors) -Path (Join-Path $packageRoot 'errors/collector-errors.json') -Depth 8

    $status = if ($errors.Count -gt 0) { 'Partial' } else { 'Complete' }
    $summary = [PSCustomObject]@{
        SchemaVersion = 'diagframework.systemevidence.summary.v1'
        ModuleId = $ModuleId
        ModuleVersion = $ModuleVersion
        Status = $status
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName = $env:COMPUTERNAME
        TargetKB = $TargetKB
        DaysBack = $DaysBack
        MaxEvents = $MaxEvents
        PackageRoot = $packageRoot
        ZipPath = $zipPath
        EventLogCount = @($eventSummary).Count
        CopiedRecordCount = $copied.Count
        NativeCommandCount = $nativeResults.Count
        ErrorCount = $errors.Count
        Purpose = 'AI/szakértő által elemezhető Windows 11 rendszerbizonyíték-csomag boot, setup, driver, update, crash és vendor diagnosztikai hibákhoz.'
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $packageRoot 'ai_summary.json') -Depth 8
    Write-PackageReadme -PackageRoot $packageRoot -TargetKB $TargetKB -Status $status

    try {
        $manifest = New-PackageManifestSafe -PackageRoot $packageRoot
        Write-JsonSafe -InputObject $manifest -Path (Join-Path $packageRoot 'manifest.json') -Depth 10
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'Manifest' -Message "Files=$($manifest.Files.Count)"
    }
    catch {
        Add-CollectorError -Errors $errors -Step 'Manifest' -Error $_.Exception.Message
        Write-JsonSafe -InputObject @($errors) -Path (Join-Path $packageRoot 'errors/collector-errors.json') -Depth 8
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'Manifest' -Status 'Error' -Message $_.Exception.Message
    }

    try {
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
        Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -Force -ErrorAction Stop
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'Zip' -Message $zipPath
    }
    catch {
        Add-CollectorError -Errors $errors -Step 'Zip' -Error $_.Exception.Message
        Write-JsonSafe -InputObject @($errors) -Path (Join-Path $packageRoot 'errors/collector-errors.json') -Depth 8
        Add-ProgressEvent -PackageRoot $packageRoot -Step 'Zip' -Status 'Error' -Message $_.Exception.Message
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
            Summary = 'Rendszerbizonyíték-csomag készíthető boot, setup, driver, update és vendor diagnosztikai elemzéshez.'
            RecommendedAction = 'Hibás frissítés, rollback, driver-összeférhetetlenség vagy gyártói diagnosztika után készíts LOG csomagot AI-elemzéshez.'
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
