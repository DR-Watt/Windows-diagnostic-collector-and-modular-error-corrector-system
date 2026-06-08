<#
.SYNOPSIS
  Windows 11 rendszerbizonyíték és vendor diagnosztikai LOG gyűjtő modul.
.DESCRIPTION
  v1.3.3 Storage Correlation Pack.
  Read-only evidence gyűjtés + storage korreláció: Disk 2 / Disk 3 → Get-Disk,
  PhysicalDisk, Win32_DiskDrive mapping; PDO/controller/driver snapshot; Event ID 153
  idővonal; Windows Update / Setup / Kernel-Boot korreláció; TopFindings és risk summary.
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

$ErrorActionPreference = 'Stop'
$ModuleId = 'SystemEvidenceCollector'
$ModuleVersion = '1.3.3'

function Get-Metadata {
    [PSCustomObject]@{
        Id = $ModuleId
        Name = 'Rendszer LOG bizonyítékgyűjtő'
        Version = $ModuleVersion
        Risk = 'Low'
        Summary = 'Windows 11 P0 read-only evidence + storage correlation: Disk 2/3 Intel RAID JBOD HDD mapping, Event ID 153 timeline, controller/driver context és top findings.'
    }
}

function New-DirectorySafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
}

function ConvertTo-SafeString {
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [array]) { return (@($Value) | ForEach-Object { ConvertTo-SafeString $_ }) -join '; ' }
        return [string]$Value
    }
    catch { return '<UnserializableValue>' }
}

function ConvertTo-FlatObject {
    param($InputObject, [string[]]$PropertyNames = @())
    if ($null -eq $InputObject) { return $null }
    $h = [ordered]@{}
    if ($PropertyNames.Count -gt 0) {
        foreach ($name in $PropertyNames) {
            try { $h[$name] = ConvertTo-SafeString $InputObject.$name } catch { $h[$name] = $null }
        }
    }
    else {
        foreach ($p in $InputObject.PSObject.Properties) {
            if ($p.MemberType -in @('NoteProperty','Property','AliasProperty')) { $h[$p.Name] = ConvertTo-SafeString $p.Value }
        }
    }
    [PSCustomObject]$h
}

function Write-JsonSafe {
    param($InputObject, [string]$Path, [int]$Depth = 10)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-DirectorySafe $parent }
    try { $InputObject | ConvertTo-Json -Depth $Depth -ErrorAction Stop | Out-File -LiteralPath $Path -Encoding UTF8 -Force }
    catch {
        [PSCustomObject]@{
            SchemaVersion = 'diagframework.jsonfallback.v1'
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            JsonSerializationFailed = $true
            Error = $_.Exception.Message
            Text = ConvertTo-SafeString ($InputObject | Out-String)
        } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding UTF8 -Force
    }
}

function Write-JsonLinesSafe {
    param($InputObject, [string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-DirectorySafe $parent }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
    foreach ($item in @($InputObject)) {
        try { $item | ConvertTo-Json -Depth 8 -Compress -ErrorAction Stop | Out-File -LiteralPath $Path -Encoding UTF8 -Append }
        catch {
            [PSCustomObject]@{
                SchemaVersion = 'diagframework.jsonl.fallback.v1'
                TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
                Error = $_.Exception.Message
                Text = ConvertTo-SafeString ($item | Out-String)
            } | ConvertTo-Json -Depth 6 -Compress | Out-File -LiteralPath $Path -Encoding UTF8 -Append
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType File -Force | Out-Null }
}

function Add-ProgressEvent {
    param([string]$PackageRoot, [string]$Step, [string]$Status = 'OK', [string]$Message = '')
    try {
        [PSCustomObject]@{
            SchemaVersion = 'diagframework.collector.progress.v1'
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            Step = $Step
            Status = $Status
            Message = $Message
        } | ConvertTo-Json -Depth 6 -Compress | Out-File -LiteralPath (Join-Path $PackageRoot 'collector-progress.jsonl') -Encoding UTF8 -Append
    }
    catch { }
}

function Add-CollectorIssue {
    param(
        $CurrentIssues = @(),
        [string]$Severity = 'Error',
        [string]$Code = 'GeneralError',
        [string]$Step = '',
        [string]$Target = '',
        [string]$Category = '',
        [string]$Message = '',
        [string]$ScriptStackTrace = ''
    )
    $list = @()
    if ($null -ne $CurrentIssues) { $list = @($CurrentIssues) }
    return @($list + [PSCustomObject]@{
        SchemaVersion = 'diagframework.collector.issue.v1'
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Severity = $Severity
        Code = $Code
        Step = $Step
        Target = $Target
        Category = $Category
        Message = $Message
        ScriptStackTrace = $ScriptStackTrace
    })
}

function Split-IssuesBySeverity {
    param($Issues = @())
    $errors = @(@($Issues) | Where-Object { $_.Severity -eq 'Error' })
    $warnings = @(@($Issues) | Where-Object { $_.Severity -ne 'Error' })
    [PSCustomObject]@{ Errors = $errors; Warnings = $warnings }
}

function Write-CollectorIssuesSafe {
    param([string]$PackageRoot, $Issues = @())
    $split = Split-IssuesBySeverity -Issues $Issues
    Write-JsonSafe -InputObject @($Issues) -Path (Join-Path $PackageRoot 'errors/collector-issues.json') -Depth 10
    Write-JsonSafe -InputObject @($split.Errors) -Path (Join-Path $PackageRoot 'errors/collector-errors.json') -Depth 10
    Write-JsonSafe -InputObject @($split.Warnings) -Path (Join-Path $PackageRoot 'errors/collector-warnings.json') -Depth 10
}

function Get-RelativePathSafe {
    param([string]$BasePath, [string]$FullPath)
    try { return [System.IO.Path]::GetRelativePath([string]$BasePath, [string]$FullPath) }
    catch {
        $base = [string]$BasePath; $full = [string]$FullPath
        if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($base.Length).TrimStart([char[]]@('\','/')) }
        return Split-Path -Path $full -Leaf
    }
}

function Get-FileHashSafe {
    param([string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
    catch { return $null }
}

function Write-LogRootReadmes {
    param([string]$LogRootPath, [string]$TargetKB = '')
    New-DirectorySafe $LogRootPath
    $evidenceRoot = Join-Path $LogRootPath 'evidence_packages'
    $aiRoot = Join-Path $LogRootPath 'ai_packages'
    New-DirectorySafe $evidenceRoot; New-DirectorySafe $aiRoot
    $now = (Get-Date).ToString('o')
@"
# DiagFramework LOG Root — AI elemzési útmutató

Generated/Updated: $now
Module: $ModuleId $ModuleVersion
TargetKB context: $TargetKB

## Könyvtárak
- `ai_packages/`: célzott KB evidence csomagok.
- `evidence_packages/`: rendszerszintű boot / driver / update / WER / CBS / DISM evidence csomagok.

## AI sorrend
1. `AI_README.md`
2. `ai_summary.json`
3. `collector-progress.jsonl`
4. `errors/collector-issues.json`
5. `manifest.json`
"@ | Out-File -LiteralPath (Join-Path $LogRootPath 'AI_README.md') -Encoding UTF8 -Force

@"
# System Evidence Packages — AI elemzési útmutató

A v1.3.0 P0 evidence csomagok célja, hogy javítás előtt teljesebb read-only bizonyítékot adjanak.

Fontos új mappák:
- events/raw: nyers EVTX exportok
- windows_update: konvertált WindowsUpdate log és policy snapshot
- servicing: DISM ScanHealth és SFC verifyonly kimenetek
- storage: disk/physicaldisk/volume/partition mapping
- vendor_logs: whitelist/blacklist policy alapján szűrt vendor logok
"@ | Out-File -LiteralPath (Join-Path $evidenceRoot 'AI_README.md') -Encoding UTF8 -Force
}

function Write-PackageReadme {
    param([string]$PackageRoot, [string]$TargetKB = '', [string]$Status = 'InProgress')
@"
# System Evidence Package — AI_README

Generated/Updated: $((Get-Date).ToString('o'))
Computer: $env:COMPUTERNAME
Module: $ModuleId $ModuleVersion
Status: $Status
TargetKB context: $TargetKB

## Elemzési sorrend
1. `ai_summary.json`
2. `collector-progress.jsonl`
3. `errors/collector-issues.json`
4. `events/event-summary.json` és `events/event-export-metadata.json`
5. `events/raw/*.evtx`
6. `windows_update/WindowsUpdate.generated.log`
7. `servicing/*.txt` és `servicing/cbs-hresult-summary.json`
8. `storage/disk-event-map.json`
9. `manifest.json` SHA-256 fájlindex

## Státuszmodell
- OK: nincs hiba és nincs figyelmeztetés.
- OKWithWarnings: a fő evidence elkészült, de nem kritikus figyelmeztetés van.
- Partial: legalább egy várt adatforrás hibázott, de a csomag elkészült.
- Failed: alapvető csomagkészítés nem sikerült.
"@ | Out-File -LiteralPath (Join-Path $PackageRoot 'AI_README.md') -Encoding UTF8 -Force
}

function Convert-EventRecordFlat {
    param($Event)
    $time = $null; $id = $null; $recordId = $null
    try { if ($Event.TimeCreated) { $time = ([datetime]$Event.TimeCreated).ToString('o') } } catch { }
    try { $id = [int]$Event.Id } catch { }
    try { $recordId = [int64]$Event.RecordId } catch { }
    [PSCustomObject]@{
        TimeCreated = $time
        ProviderName = ConvertTo-SafeString $Event.ProviderName
        LogName = ConvertTo-SafeString $Event.LogName
        Id = $id
        LevelDisplayName = ConvertTo-SafeString $Event.LevelDisplayName
        Level = ConvertTo-SafeString $Event.Level
        MachineName = ConvertTo-SafeString $Event.MachineName
        RecordId = $recordId
        TaskDisplayName = ConvertTo-SafeString $Event.TaskDisplayName
        OpcodeDisplayName = ConvertTo-SafeString $Event.OpcodeDisplayName
        KeywordsDisplayNames = ConvertTo-SafeString $Event.KeywordsDisplayNames
        Message = ConvertTo-SafeString $Event.Message
    }
}

function Get-RegistryValuesFlat {
    param([string]$Path)
    $values = @()
    try {
        $props = Get-ItemProperty -Path $Path -ErrorAction Stop
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $values += [PSCustomObject]@{ Name = $p.Name; Value = ConvertTo-SafeString $p.Value }
        }
    }
    catch { $values += [PSCustomObject]@{ Name = '__ERROR__'; Value = $_.Exception.Message } }
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
        try { $exists = [bool](Test-Path -LiteralPath $path) } catch { }
        $values = @()
        if ($exists) { $values = @(Get-RegistryValuesFlat $path) }
        $result += [PSCustomObject]@{ Path = $path; Exists = $exists; Values = $values }
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
        PowerShell = [PSCustomObject]@{ Version = $PSVersionTable.PSVersion.ToString(); Edition = $PSVersionTable.PSEdition; Platform = $PSVersionTable.Platform }
        OS = if ($os) { ConvertTo-FlatObject $os @('Caption','Version','BuildNumber','OSArchitecture','InstallDate','LastBootUpTime') } else { $null }
        ComputerSystem = if ($cs) { ConvertTo-FlatObject $cs @('Manufacturer','Model','SystemType','TotalPhysicalMemory','HypervisorPresent') } else { $null }
        BIOS = if ($bios) { ConvertTo-FlatObject $bios @('Manufacturer','SMBIOSBIOSVersion','ReleaseDate','SerialNumber') } else { $null }
    }
}

function Get-DriverSnapshot {
    $items = @()
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) {
            $items += ConvertTo-FlatObject $d @('DeviceName','Manufacturer','DriverProviderName','DriverVersion','DriverDate','InfName','DeviceClass','DeviceID','PDO','IsSigned','Signer')
        }
    }
    catch { $items += [PSCustomObject]@{ Error = $_.Exception.Message } }
    return $items
}

function Get-SafeLogFileName {
    param([string]$LogName)
    return (($LogName -replace '[\\/:*?"<>|]', '_') + '.jsonl')
}

function Export-EventLogRawSafe {
    param([string]$PackageRoot, [string]$LogName, [string]$SafeBaseName)
    $rawRoot = Join-Path $PackageRoot 'events/raw'
    New-DirectorySafe $rawRoot
    $outFile = Join-Path $rawRoot ($SafeBaseName + '.evtx')
    $stdout = Join-Path $rawRoot ($SafeBaseName + '.wevtutil.stdout.txt')
    $stderr = Join-Path $rawRoot ($SafeBaseName + '.wevtutil.stderr.txt')
    try {
        if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
        $args = @('epl', $LogName, $outFile, '/ow:true')
        $p = Start-Process -FilePath 'wevtutil.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        [PSCustomObject]@{ OutputEvtx = Get-RelativePathSafe $PackageRoot $outFile; ExitCode = $p.ExitCode; StdOut = Get-RelativePathSafe $PackageRoot $stdout; StdErr = Get-RelativePathSafe $PackageRoot $stderr; Length = if (Test-Path -LiteralPath $outFile) { (Get-Item -LiteralPath $outFile).Length } else { 0 } }
    }
    catch { [PSCustomObject]@{ OutputEvtx = Get-RelativePathSafe $PackageRoot $outFile; Error = $_.Exception.Message } }
}

function Collect-Events {
    param([string]$PackageRoot, [datetime]$StartTime, $Issues = @(), [int]$MaxEvents = 1200)
    $eventRoot = Join-Path $PackageRoot 'events'
    New-DirectorySafe $eventRoot
    New-DirectorySafe (Join-Path $eventRoot 'raw')
    $logs = @(
        'System','Application','Setup','Microsoft-Windows-WindowsUpdateClient/Operational',
        'Microsoft-Windows-DeviceSetupManager/Admin','Microsoft-Windows-DeviceSetupManager/Operational',
        'Microsoft-Windows-Kernel-Boot/Operational','Microsoft-Windows-Kernel-PnP/Configuration',
        'Microsoft-Windows-DriverFrameworks-UserMode/Operational','Microsoft-Windows-WHEA-Logger/Operational',
        'Microsoft-Windows-WER-SystemErrorReporting/Operational'
    )
    $summary = @(); $metadata = @(); $localIssues = @($Issues)
    foreach ($log in $logs) {
        $safeBase = ($log -replace '[\\/:*?"<>|]', '_')
        $jsonlPath = Join-Path $eventRoot ($safeBase + '.jsonl')
        $logInfo = $null
        try { $logInfo = Get-WinEvent -ListLog $log -ErrorAction Stop } catch { $logInfo = $null }
        if ($null -eq $logInfo) {
            Write-JsonLinesSafe -InputObject @() -Path $jsonlPath
            $summary += [PSCustomObject]@{ LogName=$log; Status='Warning'; Code='LogNotPresent'; Count=0; OutputFile=('events/' + $safeBase + '.jsonl') }
            $metadata += [PSCustomObject]@{ LogName=$log; Status='Warning'; Code='LogNotPresent'; Count=0; MaxEvents=$MaxEvents; Truncated=$false; OutputJsonl=('events/' + $safeBase + '.jsonl'); OutputEvtx=$null }
            $localIssues = Add-CollectorIssue -CurrentIssues $localIssues -Severity 'Warning' -Code 'LogNotPresent' -Step 'EventLogs' -Target $log -Category 'Get-WinEvent' -Message 'Az opcionális eseménynapló-csatorna nem található.' -ScriptStackTrace ''
            continue
        }
        $rawExport = Export-EventLogRawSafe $PackageRoot $log $safeBase
        try {
            $rawEvents = @(Get-WinEvent -FilterHashtable @{ LogName=$log; StartTime=$StartTime } -MaxEvents $MaxEvents -ErrorAction Stop)
            $flat = @()
            foreach ($ev in $rawEvents) { try { $flat += Convert-EventRecordFlat $ev } catch { } }
            Write-JsonLinesSafe -InputObject $flat -Path $jsonlPath
            $times = @($flat | Where-Object { $_.TimeCreated } | ForEach-Object { try { [datetime]$_.TimeCreated } catch { $null } } | Where-Object { $null -ne $_ })
            $oldest = $null; $newest = $null
            if ($times.Count -gt 0) { $oldest = (($times | Sort-Object | Select-Object -First 1).ToString('o')); $newest = (($times | Sort-Object | Select-Object -Last 1).ToString('o')) }
            $truncated = ($flat.Count -ge $MaxEvents)
            $summary += [PSCustomObject]@{ LogName=$log; Status='OK'; Count=$flat.Count; OutputFile=('events/' + $safeBase + '.jsonl'); Truncated=$truncated; OutputEvtx=$rawExport.OutputEvtx }
            $metadata += [PSCustomObject]@{ LogName=$log; Status='OK'; Count=$flat.Count; MaxEvents=$MaxEvents; Truncated=$truncated; OldestTimeCreated=$oldest; NewestTimeCreated=$newest; OutputJsonl=('events/' + $safeBase + '.jsonl'); OutputEvtx=$rawExport.OutputEvtx; RawExport=$rawExport }
        }
        catch {
            $msg = $_.Exception.Message
            Write-JsonLinesSafe -InputObject @() -Path $jsonlPath
            $summary += [PSCustomObject]@{ LogName=$log; Status='Warning'; Code='NoMatchingEvents'; Count=0; Error=$msg; OutputFile=('events/' + $safeBase + '.jsonl'); OutputEvtx=$rawExport.OutputEvtx }
            $metadata += [PSCustomObject]@{ LogName=$log; Status='Warning'; Code='NoMatchingEvents'; Count=0; MaxEvents=$MaxEvents; Truncated=$false; OutputJsonl=('events/' + $safeBase + '.jsonl'); OutputEvtx=$rawExport.OutputEvtx; RawExport=$rawExport; Error=$msg }
            $localIssues = Add-CollectorIssue -CurrentIssues $localIssues -Severity 'Warning' -Code 'NoMatchingEvents' -Step 'EventLogs' -Target $log -Category 'Get-WinEvent' -Message $msg -ScriptStackTrace $_.ScriptStackTrace
        }
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $eventRoot 'event-summary.json') -Depth 8
    Write-JsonSafe -InputObject $metadata -Path (Join-Path $eventRoot 'event-export-metadata.json') -Depth 10
    [PSCustomObject]@{ Summary=$summary; Metadata=$metadata; Issues=$localIssues }
}


function Get-SystemLogCopyPolicy {
    [PSCustomObject]@{
        SchemaVersion='diagframework.systemlog.copy.policy.v1'
        AllowedExtensions=@('.log','.txt','.json','.xml','.etl','.evtx','.wer','.mdmp','.dmp','.csv','.ini')
        BlockedExtensions=@('.exe','.dll','.sys','.bin','.msi','.msix','.appx','.cab','.zip','.7z','.rar','.efi','.ttf','.fon','.mui','.cip','.sdb','.dat','.que','.png','.jpg','.jpeg','.gif','.bmp')
        MaxBytesPerFile=52428800
        MaxFilesPerRoot=1200
        Reason='System evidence policy: collect logs and text/XML/ETL/EVTX/WER/dump artifacts, skip installer caches and binary payloads.'
    }
}

function Get-SetupLogCopyPolicy {
    [PSCustomObject]@{
        SchemaVersion='diagframework.setuplog.copy.policy.v1'
        AllowedExtensions=@('.log','.txt','.json','.xml','.etl','.evtx','.wer','.csv','.ini')
        BlockedExtensions=@('.exe','.dll','.sys','.bin','.msi','.msix','.appx','.cab','.zip','.7z','.rar','.efi','.ttf','.fon','.mui','.cip','.sdb','.dat','.que','.png','.jpg','.jpeg','.gif','.bmp')
        MaxBytesPerFile=52428800
        MaxFilesPerRoot=1200
        Reason='Setup/Panther evidence policy: prefer human-readable setup/appraiser/Panther logs; skip binary payloads and rollback boot binaries.'
    }
}

function Parse-Disk153Message {
    param([string]$Message)
    $diskNumber = $null
    $pdoObjectName = $null
    $logicalBlockAddress = $null
    $parser = 'None'

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return [PSCustomObject]@{
            DiskNumberFromMessage=$null; PdoObjectName=$null; LogicalBlockAddress=$null; Parser='EmptyMessage'
        }
    }

    # Hungarian localized disk event 153: "2 jelű lemez ... PDO objektum neve: \Device\... ... 0x8000 logikai blokkcímét"
    if ($Message -match '(?i)(\d+)\s+jelű\s+lemez') {
        try { $diskNumber = [int]$Matches[1] } catch { $diskNumber = $null }
        $parser = 'HungarianDiskNumber'
    }
    # English variants commonly contain "disk 2" or "Disk 2".
    elseif ($Message -match '(?i)\bdisk\s+(\d+)\b') {
        try { $diskNumber = [int]$Matches[1] } catch { $diskNumber = $null }
        $parser = 'EnglishDiskNumber'
    }

    if ($Message -match '(?i)PDO\s+objektum\s+neve:\s*(\\Device\\[^\)\s]+)') { $pdoObjectName = $Matches[1] }
    elseif ($Message -match '(?i)PDO\s+name:\s*(\\Device\\[^\)\s]+)') { $pdoObjectName = $Matches[1] }
    elseif ($Message -match '(?i)\\Device\\[0-9a-fA-F]+') { $pdoObjectName = $Matches[0] }

    if ($Message -match '(?i)(0x[0-9a-fA-F]+)\s+logikai\s+blokkcím') { $logicalBlockAddress = $Matches[1] }
    elseif ($Message -match '(?i)logical\s+block\s+address\s+(0x[0-9a-fA-F]+)') { $logicalBlockAddress = $Matches[1] }
    elseif ($Message -match '(?i)\bLBA\s*(0x[0-9a-fA-F]+)') { $logicalBlockAddress = $Matches[1] }

    [PSCustomObject]@{
        DiskNumberFromMessage = $diskNumber
        PdoObjectName = $pdoObjectName
        LogicalBlockAddress = $logicalBlockAddress
        Parser = $parser
    }
}

function New-Disk153Aggregate {
    param($EventMap = @())
    $byDisk = @(@($EventMap) | Group-Object DiskNumberFromMessage | Sort-Object Count -Descending | ForEach-Object {
        [PSCustomObject]@{ DiskNumberFromMessage=$_.Name; Count=$_.Count }
    })
    $byPdo = @(@($EventMap) | Group-Object PdoObjectName | Sort-Object Count -Descending | ForEach-Object {
        [PSCustomObject]@{ PdoObjectName=$_.Name; Count=$_.Count }
    })
    $byLba = @(@($EventMap) | Group-Object LogicalBlockAddress | Sort-Object Count -Descending | Select-Object -First 50 | ForEach-Object {
        [PSCustomObject]@{ LogicalBlockAddress=$_.Name; Count=$_.Count }
    })
    [PSCustomObject]@{
        SchemaVersion='diagframework.storage.disk153.aggregate.v1'
        EventCount=@($EventMap).Count
        ByDiskNumber=$byDisk
        ByPdoObjectName=$byPdo
        ByLogicalBlockAddress=$byLba
    }
}

function Copy-IfExists {
    param([string]$Source, [string]$DestinationRoot, [int64]$MaxBytes = 52428800, [int]$MaxFiles = 300, [string[]]$AllowedExtensions = @(), [string[]]$BlockedExtensions = @())
    if (-not (Test-Path -LiteralPath $Source)) { return @() }
    New-DirectorySafe $DestinationRoot
    $item = Get-Item -LiteralPath $Source -ErrorAction Stop
    $results = @(); $count = 0
    if ($item.PSIsContainer) { $children = @(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) }
    else { $children = @($item) }
    foreach ($child in $children) {
        if ($count -ge $MaxFiles) { $results += [PSCustomObject]@{ Source=$child.FullName; Skipped=$true; Reason='MaxFilesReached'; Length=$child.Length }; continue }
        $ext = ([string]$child.Extension).ToLowerInvariant()
        if ($AllowedExtensions.Count -gt 0 -and $AllowedExtensions -notcontains $ext) { $results += [PSCustomObject]@{ Source=$child.FullName; Skipped=$true; Reason='ExtensionNotWhitelisted'; Extension=$ext; Length=$child.Length }; continue }
        if ($BlockedExtensions -contains $ext) { $results += [PSCustomObject]@{ Source=$child.FullName; Skipped=$true; Reason='ExtensionBlacklisted'; Extension=$ext; Length=$child.Length }; continue }
        if ($child.Length -gt $MaxBytes) { $results += [PSCustomObject]@{ Source=$child.FullName; Skipped=$true; Reason='FileTooLarge'; Length=$child.Length }; continue }
        $targetRoot = if ($item.PSIsContainer) { Join-Path $DestinationRoot $item.Name } else { $DestinationRoot }
        New-DirectorySafe $targetRoot
        $relative = if ($item.PSIsContainer) { Get-RelativePathSafe $item.FullName $child.FullName } else { $child.Name }
        $dest = Join-Path $targetRoot $relative
        New-DirectorySafe (Split-Path -Parent $dest)
        Copy-Item -LiteralPath $child.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
        $results += [PSCustomObject]@{ Source=$child.FullName; Destination=$dest; RelativeDestination=(Get-RelativePathSafe $DestinationRoot $dest); Length=$child.Length; LastWriteTime=$child.LastWriteTime.ToString('o'); Extension=$ext; Skipped=$false }
        $count++
    }
    return $results
}

function Invoke-NativeCommandSafe {
    param([string]$PackageRoot, [string]$SubDirectory, [string]$Name, [string]$File, [string[]]$ArgumentList = @(), [int]$PreviewLines = 20)
    $dir = Join-Path $PackageRoot $SubDirectory
    New-DirectorySafe $dir
    $outFile = Join-Path $dir ($Name + '.txt')
    $errFile = Join-Path $dir ($Name + '.err.txt')
    $start = Get-Date; $end = $start; $exit = $null; $errorText = $null
    try {
        if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
        $p = Start-Process -FilePath $File -ArgumentList ([string[]]$ArgumentList) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
        $exit = $p.ExitCode
    }
    catch { $errorText = $_.Exception.Message }
    $end = Get-Date
    $stdoutBytes = if (Test-Path -LiteralPath $outFile) { (Get-Item -LiteralPath $outFile).Length } else { 0 }
    $stderrBytes = if (Test-Path -LiteralPath $errFile) { (Get-Item -LiteralPath $errFile).Length } else { 0 }
    $stdoutPreview = @(); $stderrPreview = @()
    try { if (Test-Path -LiteralPath $outFile) { $stdoutPreview = @(Get-Content -LiteralPath $outFile -TotalCount $PreviewLines -ErrorAction SilentlyContinue) } } catch { }
    try { if (Test-Path -LiteralPath $errFile) { $stderrPreview = @(Get-Content -LiteralPath $errFile -TotalCount $PreviewLines -ErrorAction SilentlyContinue) } } catch { }
    [PSCustomObject]@{
        SchemaVersion='diagframework.nativecommand.result.v4'
        Name=$Name
        File=$File
        ArgumentList=@($ArgumentList)
        ArgumentString=(@($ArgumentList) -join ' ')
        CommandLine=($File + ' ' + (@($ArgumentList) -join ' ')).Trim()
        ExitCode=$exit
        StartTime=$start.ToString('o')
        EndTime=$end.ToString('o')
        DurationMs=[int](($end-$start).TotalMilliseconds)
        StdOut=Get-RelativePathSafe $PackageRoot $outFile
        StdErr=Get-RelativePathSafe $PackageRoot $errFile
        StdOutBytes=$stdoutBytes
        StdErrBytes=$stderrBytes
        InformationValue=if($errorText){'LaunchError'}elseif($stdoutBytes -gt 0 -or $stderrBytes -gt 0){'Captured'}else{'NoOutput'}
        StdOutPreview=$stdoutPreview
        StdErrPreview=$stderrPreview
        Error=$errorText
    }
}

function Get-NativeCommandDefinitions {
    @(
        [PSCustomObject]@{ Name='reagentc-info'; File='reagentc.exe'; ArgumentList=@('/info'); SubDirectory='commands'; Purpose='Windows RE állapot és recovery konfiguráció.' },
        [PSCustomObject]@{ Name='bcdedit-enum-all-v'; File='bcdedit.exe'; ArgumentList=@('/enum','all','/v'); SubDirectory='commands'; Purpose='BCD teljes olvasási inventory.' },
        [PSCustomObject]@{ Name='dism-packages-table'; File='dism.exe'; ArgumentList=@('/Online','/Get-Packages','/Format:Table','/English'); SubDirectory='commands'; Purpose='Windows package állapot gyors lista.' },
        [PSCustomObject]@{ Name='dism-packages-list'; File='dism.exe'; ArgumentList=@('/Online','/Get-Packages','/Format:List','/English'); SubDirectory='commands'; Purpose='Windows package állapot részletes lista.' },
        [PSCustomObject]@{ Name='dism-checkhealth'; File='dism.exe'; ArgumentList=@('/Online','/Cleanup-Image','/CheckHealth','/English'); SubDirectory='commands'; Purpose='Component store gyors állapot.' },
        [PSCustomObject]@{ Name='dism-scanhealth'; File='dism.exe'; ArgumentList=@('/Online','/Cleanup-Image','/ScanHealth','/English'); SubDirectory='servicing'; Purpose='Component store mélyebb read-only scan.' },
        [PSCustomObject]@{ Name='sfc-verifyonly'; File='sfc.exe'; ArgumentList=@('/verifyonly'); SubDirectory='servicing'; Purpose='Read-only protected system file verification.' },
        [PSCustomObject]@{ Name='sc-query-wuauserv'; File='sc.exe'; ArgumentList=@('query','wuauserv'); SubDirectory='commands'; Purpose='Windows Update service state.' },
        [PSCustomObject]@{ Name='sc-qc-wuauserv'; File='sc.exe'; ArgumentList=@('qc','wuauserv'); SubDirectory='commands'; Purpose='Windows Update service config.' },
        [PSCustomObject]@{ Name='sc-query-bits'; File='sc.exe'; ArgumentList=@('query','BITS'); SubDirectory='commands'; Purpose='BITS service state.' },
        [PSCustomObject]@{ Name='sc-qc-bits'; File='sc.exe'; ArgumentList=@('qc','BITS'); SubDirectory='commands'; Purpose='BITS service config.' },
        [PSCustomObject]@{ Name='sc-query-cryptsvc'; File='sc.exe'; ArgumentList=@('query','cryptsvc'); SubDirectory='commands'; Purpose='Cryptographic Services state.' },
        [PSCustomObject]@{ Name='sc-qc-cryptsvc'; File='sc.exe'; ArgumentList=@('qc','cryptsvc'); SubDirectory='commands'; Purpose='Cryptographic Services config.' },
        [PSCustomObject]@{ Name='sc-query-trustedinstaller'; File='sc.exe'; ArgumentList=@('query','TrustedInstaller'); SubDirectory='commands'; Purpose='Windows Modules Installer state.' },
        [PSCustomObject]@{ Name='sc-qc-trustedinstaller'; File='sc.exe'; ArgumentList=@('qc','TrustedInstaller'); SubDirectory='commands'; Purpose='Windows Modules Installer config.' }
    )
}

function Write-NativeCommandReadme {
    param([string]$PackageRoot, $Definitions)
    $cmdRoot = Join-Path $PackageRoot 'commands'
    New-DirectorySafe $cmdRoot
    $lines = @('# Native command collector', '', 'A parancsok read-only diagnosztikai céllal futnak. A servicing mappába kerülő DISM ScanHealth és SFC verifyonly hosszabb ideig futhat.', '')
    foreach ($d in @($Definitions)) { $lines += ('- `{0} {1}` — {2}' -f $d.File, (@($d.ArgumentList) -join ' '), $d.Purpose) }
    $lines | Out-File -LiteralPath (Join-Path $cmdRoot 'COMMANDS_README.md') -Encoding UTF8 -Force
    Write-JsonSafe -InputObject $Definitions -Path (Join-Path $cmdRoot 'native-command-catalog.json') -Depth 8
}

function Invoke-WindowsUpdateLogConversion {
    param([string]$PackageRoot)
    $wuRoot = Join-Path $PackageRoot 'windows_update'
    New-DirectorySafe $wuRoot
    $outLog = Join-Path $wuRoot 'WindowsUpdate.generated.log'
    $stdout = Join-Path $wuRoot 'Get-WindowsUpdateLog.stdout.txt'
    $stderr = Join-Path $wuRoot 'Get-WindowsUpdateLog.stderr.txt'
    $result = [ordered]@{ SchemaVersion='diagframework.windowsupdate.logconversion.v1'; LogPath=(Get-RelativePathSafe $PackageRoot $outLog); Mode=$null; Status='NotStarted'; Error=$null; Length=0 }
    try {
        try {
            Get-WindowsUpdateLog -LogPath $outLog -ErrorAction Stop *> $stdout
            $result.Mode='LogPath'; $result.Status='OK'
        }
        catch {
            $result.Mode='IncludeAllLogsFallback'
            $_ | Out-String | Out-File -LiteralPath $stderr -Encoding UTF8 -Force
            Get-WindowsUpdateLog -IncludeAllLogs -ErrorAction Stop *> $stdout
            $desktopLog = Join-Path ([Environment]::GetFolderPath('Desktop')) 'WindowsUpdate.log'
            if (Test-Path -LiteralPath $desktopLog) { Copy-Item -LiteralPath $desktopLog -Destination $outLog -Force -ErrorAction SilentlyContinue }
            $result.Status = if (Test-Path -LiteralPath $outLog) { 'OK' } else { 'CompletedButLogNotFound' }
        }
    }
    catch { $result.Status='Error'; $result.Error=$_.Exception.Message }
    if (Test-Path -LiteralPath $outLog) { $result.Length = (Get-Item -LiteralPath $outLog).Length }
    Write-JsonSafe -InputObject ([PSCustomObject]$result) -Path (Join-Path $wuRoot 'Get-WindowsUpdateLog.result.json') -Depth 8
    [PSCustomObject]$result
}

function Collect-ServicingEvidence {
    param([string]$PackageRoot)
    $servRoot = Join-Path $PackageRoot 'servicing'
    New-DirectorySafe $servRoot
    $defs = @(Get-NativeCommandDefinitions | Where-Object { $_.SubDirectory -eq 'servicing' })
    $results = @()
    foreach ($d in $defs) { $results += Invoke-NativeCommandSafe -PackageRoot $PackageRoot -SubDirectory $d.SubDirectory -Name $d.Name -File $d.File -ArgumentList ([string[]]$d.ArgumentList) }
    Write-JsonSafe -InputObject $results -Path (Join-Path $servRoot 'servicing-command-results.json') -Depth 10
    $cbs = Join-Path $PackageRoot 'copied_logs/CBS.log'
    if (Test-Path -LiteralPath $cbs) { New-CbsHResultSummary -CbsLogPath $cbs -OutPath (Join-Path $servRoot 'cbs-hresult-summary.json') }
    return $results
}

function New-CbsHResultSummary {
    param([string]$CbsLogPath, [string]$OutPath)
    $matches = @{}
    try {
        Select-String -LiteralPath $CbsLogPath -Pattern '0x[0-9a-fA-F]{8}' -AllMatches -ErrorAction Stop | ForEach-Object {
            foreach ($m in $_.Matches) { $k=$m.Value.ToLowerInvariant(); if (-not $matches.ContainsKey($k)) { $matches[$k]=0 }; $matches[$k]++ }
        }
    } catch { }
    $summary = @()
    foreach ($key in $matches.Keys) { $summary += [PSCustomObject]@{ HResult=$key; Count=$matches[$key] } }
    Write-JsonSafe -InputObject @($summary | Sort-Object Count -Descending) -Path $OutPath -Depth 6
}


function Get-StorageHints {
    param([string]$PackageRoot)
    $default = [PSCustomObject]@{
        SchemaVersion = 'diagframework.storage.hints.v1'
        Source = 'UserProvidedProjectContext'
        Notes = 'A felhasználói projektkontextus szerint Disk 2 és Disk 3 az alaplapi Intel RAID controllerre csatolt 2x8TB SATA HDD; a RAID JBOD üzemmódban van.'
        KnownDiskGroups = @(
            [PSCustomObject]@{
                GroupName = 'Intel RAID JBOD SATA HDD pair'
                DiskNumbers = @(2,3)
                ControllerHint = 'Onboard Intel RAID controller'
                Mode = 'JBOD'
                DriveCount = 2
                ExpectedDriveDescription = '2x8TB SATA HDD'
                DiagnosticMeaning = 'Event ID 153 ezen diskeken valószínűleg SATA HDD / Intel RAID controller / RST driver / port / kábel / energiagazdálkodás irányú I/O retry jel.'
            }
        )
    }
    $configPath = Join-Path $PSScriptRoot '..\..\config\storage_hints.json'
    try {
        if (Test-Path -LiteralPath $configPath) {
            $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            return $cfg
        }
    }
    catch {
        try {
            Add-ProgressEvent -PackageRoot $PackageRoot -Step 'StorageHints' -Status 'Warning' -Message ("storage_hints.json read failed: {0}" -f $_.Exception.Message)
        } catch { }
    }
    return $default
}

function Test-DiskNumberInHintGroup {
    param($Hints, [AllowNull()]$DiskNumber)
    if ($null -eq $DiskNumber) { return $null }
    foreach ($group in @($Hints.KnownDiskGroups)) {
        foreach ($n in @($group.DiskNumbers)) {
            if ([string]$n -eq [string]$DiskNumber) { return $group }
        }
    }
    return $null
}

function Get-StorageControllerSnapshot {
    $controllers = @()
    try {
        foreach ($c in @(Get-CimInstance -ClassName Win32_SCSIController -ErrorAction Stop)) {
            $controllers += [PSCustomObject]@{ Source='Win32_SCSIController'; Data=(ConvertTo-FlatObject $c) }
        }
    } catch { $controllers += [PSCustomObject]@{ Source='Win32_SCSIController'; Error=$_.Exception.Message } }
    try {
        foreach ($c in @(Get-CimInstance -ClassName Win32_IDEController -ErrorAction Stop)) {
            $controllers += [PSCustomObject]@{ Source='Win32_IDEController'; Data=(ConvertTo-FlatObject $c) }
        }
    } catch { $controllers += [PSCustomObject]@{ Source='Win32_IDEController'; Error=$_.Exception.Message } }
    try {
        $pnp = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { ([string]$_.Name + ' ' + [string]$_.PNPDeviceID + ' ' + [string]$_.Service) -match '(?i)intel|raid|rst|sata|ahci|storage|controller|scsi' })
        foreach ($p in $pnp) { $controllers += [PSCustomObject]@{ Source='Win32_PnPEntityFiltered'; Data=(ConvertTo-FlatObject $p) } }
    } catch { $controllers += [PSCustomObject]@{ Source='Win32_PnPEntityFiltered'; Error=$_.Exception.Message } }
    return $controllers
}

function Get-StorageDriverSnapshot {
    $drivers = @()
    try {
        $raw = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
            ([string]$_.DeviceClass -match '(?i)hdc|scsiadapter|diskdrive|storage') -or
            (([string]$_.DeviceName + ' ' + [string]$_.Manufacturer + ' ' + [string]$_.DriverProviderName + ' ' + [string]$_.InfName) -match '(?i)intel|raid|rst|sata|ahci|storage|controller')
        })
        foreach ($d in $raw) {
            $drivers += ConvertTo-FlatObject $d @('DeviceName','Manufacturer','DriverProviderName','DriverVersion','DriverDate','InfName','DeviceClass','DeviceID','PDO','IsSigned','Signer')
        }
    } catch { $drivers += [PSCustomObject]@{ Error=$_.Exception.Message } }
    return $drivers
}

function Get-PnpStorageDeviceSnapshot {
    $items = @()
    try {
        $cmd = Get-Command -Name Get-PnpDevice -ErrorAction SilentlyContinue
        if ($null -eq $cmd) { return @([PSCustomObject]@{ Status='Unavailable'; Reason='Get-PnpDevice cmdlet is not available in this PowerShell session.' }) }
        $classes = @('DiskDrive','SCSIAdapter','HDC')
        foreach ($cls in $classes) {
            try {
                foreach ($d in @(Get-PnpDevice -Class $cls -ErrorAction SilentlyContinue)) {
                    $items += [PSCustomObject]@{ Class=$cls; Status=$d.Status; FriendlyName=$d.FriendlyName; InstanceId=$d.InstanceId; Problem=$d.Problem; Present=$d.Present }
                }
            } catch { }
        }
    } catch { $items += [PSCustomObject]@{ Status='Error'; Error=$_.Exception.Message } }
    return $items
}

function Get-PropertyFromFlatObjectSafe {
    param($Object, [string]$Name)
    try {
        if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    } catch { }
    return $null
}

function Find-FlatByPropertyValue {
    param($Items, [string]$PropertyName, [AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    try { return @(@($Items) | Where-Object { [string](Get-PropertyFromFlatObjectSafe $_ $PropertyName) -eq [string]$Value } | Select-Object -First 1) } catch { return $null }
}

function New-Disk153Timeline {
    param($EventMap = @())
    $timeline = @()
    $sorted = @($EventMap | Sort-Object { try { [datetime]$_.TimeCreated } catch { [datetime]::MinValue } })
    $index = 0
    $prevTime = $null
    foreach ($ev in $sorted) {
        $index++
        $t = $null
        try { $t = [datetime]$ev.TimeCreated } catch { $t = $null }
        $deltaSeconds = $null
        if ($null -ne $t -and $null -ne $prevTime) { $deltaSeconds = [int]([TimeSpan]($t - $prevTime)).TotalSeconds }
        if ($null -ne $t) { $prevTime = $t }
        $timeline += [PSCustomObject]@{
            Sequence = $index
            TimeCreated = $ev.TimeCreated
            DeltaSecondsFromPreviousDisk153 = $deltaSeconds
            DiskNumber = $ev.DiskNumberFromMessage
            PdoObjectName = $ev.PdoObjectName
            LogicalBlockAddress = $ev.LogicalBlockAddress
            ProviderName = $ev.ProviderName
            EventId = $ev.EventId
            Parser = $ev.Parser
        }
    }
    return $timeline
}

function New-DiskDeviceCorrelation {
    param($EventMap = @(), $StorageResult, $Hints, $Controllers = @(), $Drivers = @(), $PnpDevices = @())
    $diskNumbers = @()
    foreach ($n in @($EventMap | ForEach-Object { $_.DiskNumberFromMessage })) { if ($null -ne $n -and $diskNumbers -notcontains [string]$n) { $diskNumbers += [string]$n } }
    foreach ($g in @($Hints.KnownDiskGroups)) { foreach ($n in @($g.DiskNumbers)) { if ($diskNumbers -notcontains [string]$n) { $diskNumbers += [string]$n } } }
    $correlation = @()
    foreach ($dn in @($diskNumbers | Sort-Object {[int]$_})) {
        $disk = Find-FlatByPropertyValue -Items $StorageResult.Disks -PropertyName 'Number' -Value $dn
        $cimDisk = Find-FlatByPropertyValue -Items $StorageResult.Win32_DiskDrive -PropertyName 'Index' -Value $dn
        if ($null -eq $cimDisk) { $cimDisk = Find-FlatByPropertyValue -Items $StorageResult.Win32_DiskDrive -PropertyName 'DeviceID' -Value ("\\.\PHYSICALDRIVE{0}" -f $dn) }
        $partitions = @($StorageResult.Partitions | Where-Object { [string](Get-PropertyFromFlatObjectSafe $_ 'DiskNumber') -eq [string]$dn })
        $volumes = @()
        foreach ($p in $partitions) {
            $driveLetter = Get-PropertyFromFlatObjectSafe $p 'DriveLetter'
            if (-not [string]::IsNullOrWhiteSpace([string]$driveLetter)) {
                $v = @($StorageResult.Volumes | Where-Object { [string](Get-PropertyFromFlatObjectSafe $_ 'DriveLetter') -eq [string]$driveLetter } | Select-Object -First 1)
                if ($v) { $volumes += $v }
            }
        }
        $physical = $null
        try {
            $physical = @($StorageResult.PhysicalDisks | Where-Object {
                ([string](Get-PropertyFromFlatObjectSafe $_ 'DeviceId') -eq [string]$dn) -or
                ([string](Get-PropertyFromFlatObjectSafe $_ 'FriendlyName') -eq [string](Get-PropertyFromFlatObjectSafe $disk 'FriendlyName')) -or
                ([string](Get-PropertyFromFlatObjectSafe $_ 'SerialNumber') -eq [string](Get-PropertyFromFlatObjectSafe $disk 'SerialNumber'))
            } | Select-Object -First 1)
        } catch { $physical = $null }
        $events = @($EventMap | Where-Object { [string]$_.DiskNumberFromMessage -eq [string]$dn })
        $hint = Test-DiskNumberInHintGroup -Hints $Hints -DiskNumber $dn
        $correlation += [PSCustomObject]@{
            DiskNumber = [int]$dn
            Event153Count = @($events).Count
            PdoObjectNames = @($events | Group-Object PdoObjectName | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ PdoObjectName=$_.Name; Count=$_.Count } })
            Disk = $disk
            Win32_DiskDrive = $cimDisk
            PhysicalDisk = $physical
            Partitions = $partitions
            Volumes = $volumes
            KnownHint = $hint
            ControllerSnapshot = $Controllers
            StorageDriverSnapshot = $Drivers
            PnpStorageDevices = $PnpDevices
            Interpretation = if ($hint) { 'User context maps this disk to the onboard Intel RAID controller JBOD SATA HDD group.' } else { 'No explicit user-provided disk hint matched this disk number.' }
        }
    }
    return $correlation
}

function Get-EventCorrelationWindowSafe {
    param([datetime]$CenterTime, [int]$WindowMinutes = 15, [int]$MaxEventsPerLog = 30)
    $items = @()
    if ($null -eq $CenterTime) { return $items }
    $start = $CenterTime.AddMinutes(-1 * [Math]::Abs($WindowMinutes))
    $end = $CenterTime.AddMinutes([Math]::Abs($WindowMinutes))
    $queries = @(
        @{ Name='WindowsUpdateClient'; LogName='Microsoft-Windows-WindowsUpdateClient/Operational' },
        @{ Name='Setup'; LogName='Setup' },
        @{ Name='KernelBoot'; LogName='Microsoft-Windows-Kernel-Boot/Operational' },
        @{ Name='KernelPnP'; LogName='Microsoft-Windows-Kernel-PnP/Configuration' },
        @{ Name='System'; LogName='System' }
    )
    foreach ($q in $queries) {
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName=$q.LogName; StartTime=$start; EndTime=$end } -MaxEvents $MaxEventsPerLog -ErrorAction Stop)
            foreach ($ev in $events) {
                $items += [PSCustomObject]@{
                    CorrelationLog = $q.Name
                    LogName = $ev.LogName
                    ProviderName = $ev.ProviderName
                    Id = $ev.Id
                    TimeCreated = if ($ev.TimeCreated) { ([datetime]$ev.TimeCreated).ToString('o') } else { $null }
                    LevelDisplayName = ConvertTo-SafeString $ev.LevelDisplayName
                    RecordId = $ev.RecordId
                    MessagePreview = (ConvertTo-SafeString $ev.Message)
                }
            }
        }
        catch { }
    }
    return $items
}

function New-Disk153UpdateCorrelation {
    param($EventMap = @(), [int]$WindowMinutes = 15)
    $correlated = @()
    foreach ($ev in @($EventMap | Sort-Object { try { [datetime]$_.TimeCreated } catch { [datetime]::MinValue } })) {
        $t = $null
        try { $t = [datetime]$ev.TimeCreated } catch { $t = $null }
        $around = @(Get-EventCorrelationWindowSafe -CenterTime $t -WindowMinutes $WindowMinutes -MaxEventsPerLog 20)
        $correlated += [PSCustomObject]@{
            Disk153TimeCreated = $ev.TimeCreated
            DiskNumber = $ev.DiskNumberFromMessage
            PdoObjectName = $ev.PdoObjectName
            LogicalBlockAddress = $ev.LogicalBlockAddress
            WindowMinutes = $WindowMinutes
            CorrelatedEventCount = @($around).Count
            ByLog = @($around | Group-Object CorrelationLog | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ Log=$_.Name; Count=$_.Count } })
            Events = @($around | Select-Object -First 80)
        }
    }
    return $correlated
}

function New-StorageRiskSummary {
    param($EventMap = @(), $Correlation = @(), $Hints, $Timeline = @())
    $disk153Count = @($EventMap).Count
    $byDisk = @($EventMap | Group-Object DiskNumberFromMessage | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ DiskNumber=$_.Name; Count=$_.Count } })
    $byPdo = @($EventMap | Group-Object PdoObjectName | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ PdoObjectName=$_.Name; Count=$_.Count } })
    $riskLevel = if ($disk153Count -ge 30) { 'HighSignal' } elseif ($disk153Count -gt 0) { 'MediumSignal' } else { 'NoSignal' }
    $jbodEvents = 0
    foreach ($ev in @($EventMap)) { if (Test-DiskNumberInHintGroup -Hints $Hints -DiskNumber $ev.DiskNumberFromMessage) { $jbodEvents++ } }
    [PSCustomObject]@{
        SchemaVersion = 'diagframework.storage.risk.summary.v1'
        RiskLevel = $riskLevel
        Disk153Count = $disk153Count
        Disk153EventsOnKnownIntelRaidJbodGroup = $jbodEvents
        UserProvidedTopology = $Hints
        ByDiskNumber = $byDisk
        ByPdoObjectName = $byPdo
        TimeRange = [PSCustomObject]@{
            Oldest = @($Timeline | Where-Object { $_.TimeCreated } | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
            Newest = @($Timeline | Where-Object { $_.TimeCreated } | Sort-Object TimeCreated | Select-Object -Last 1).TimeCreated
        }
        Interpretation = @(
            'Event ID 153 is an I/O retry signal. It does not prove physical disk failure by itself.',
            'Because Disk 2 and Disk 3 are user-confirmed 2x8TB SATA HDDs behind the onboard Intel RAID controller in JBOD mode, the primary diagnostic path is the Intel RST/RAID controller driver, SATA path, ports/cables, HDD health, power management and firmware.',
            'Windows Update / rollback correlation should compare disk 153 timestamps with Setup, WindowsUpdateClient and Kernel-Boot events.'
        )
    }
}

function New-TopFindingsForStorage {
    param($RiskSummary, $Correlation = @())
    $findings = @()
    if ($RiskSummary.Disk153Count -gt 0) {
        $findings += [PSCustomObject]@{
            Severity='High'
            Area='Storage'
            Title='Disk Event ID 153 detected on user-confirmed Intel RAID JBOD HDD group'
            Evidence=("Disk153Count={0}; OnKnownIntelRaidJbodGroup={1}" -f $RiskSummary.Disk153Count, $RiskSummary.Disk153EventsOnKnownIntelRaidJbodGroup)
            Meaning='Storage I/O retry pattern; likely relevant to update/rollback instability if timestamps correlate with setup or reboot windows.'
        }
    }
    foreach ($d in @($RiskSummary.ByDiskNumber)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$d.DiskNumber)) {
            $findings += [PSCustomObject]@{ Severity='Medium'; Area='Storage'; Title=("Disk {0} has Event ID 153 retry events" -f $d.DiskNumber); Evidence=("Count={0}" -f $d.Count); Meaning='Map this disk to physical HDD, controller and volume before repair actions.' }
        }
    }
    return $findings
}

function New-RiskIndicatorsForStorage {
    param($RiskSummary)
    $items = @()
    if ($RiskSummary.Disk153Count -gt 0) { $items += [PSCustomObject]@{ Code='StorageIoRetry153'; Strength=$RiskSummary.RiskLevel; Count=$RiskSummary.Disk153Count; Description='Disk provider Event ID 153 indicates I/O retry. Investigate storage path before aggressive Windows Update repair.' } }
    if ($RiskSummary.Disk153EventsOnKnownIntelRaidJbodGroup -gt 0) { $items += [PSCustomObject]@{ Code='IntelRaidJbodSataPath'; Strength='ContextConfirmed'; Count=$RiskSummary.Disk153EventsOnKnownIntelRaidJbodGroup; Description='User confirmed Disk 2/3 are SATA HDDs behind onboard Intel RAID controller in JBOD mode.' } }
    return $items
}

function New-SuggestedNextEvidenceForStorage {
    param($RiskSummary)
    $items = @(
        [PSCustomObject]@{ Priority='P0'; Evidence='Run vendor or Intel RST storage diagnostics and export logs'; Reason='Controller/JBOD layer is in the suspected path.' },
        [PSCustomObject]@{ Priority='P0'; Evidence='Collect SMART / manufacturer HDD health data for Disk 2 and Disk 3'; Reason='Differentiate controller/path retry from drive-level media or command timeout issues.' },
        [PSCustomObject]@{ Priority='P1'; Evidence='Check SATA cable/port/power path for the two 8TB HDDs'; Reason='Event 153 can be caused by transient storage path retries.' },
        [PSCustomObject]@{ Priority='P1'; Evidence='Correlate disk153-timeline.json with WindowsUpdateClient, Setup and Kernel-Boot event windows'; Reason='Determines whether storage retries happen during update/rollback windows.' },
        [PSCustomObject]@{ Priority='P2'; Evidence='Review Intel RAID/RST driver version, firmware and chipset driver status'; Reason='JBOD behind Intel RAID controller makes the storage controller driver diagnostically relevant.' }
    )
    return $items
}

function Collect-StorageEvidence {
    param([string]$PackageRoot, [datetime]$StartTime)
    $root = Join-Path $PackageRoot 'storage'
    $analysisRoot = Join-Path $PackageRoot 'analysis'
    New-DirectorySafe $root
    New-DirectorySafe $analysisRoot
    $result = @{}
    $hints = Get-StorageHints -PackageRoot $PackageRoot
    Write-JsonSafe -InputObject $hints -Path (Join-Path $root 'storage-hints.json') -Depth 10

    try { $result.Disks = @(Get-Disk -ErrorAction Stop | ForEach-Object { ConvertTo-FlatObject $_ }) } catch { $result.Disks = @([PSCustomObject]@{ Error=$_.Exception.Message }) }
    try { $result.PhysicalDisks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { ConvertTo-FlatObject $_ }) } catch { $result.PhysicalDisks = @([PSCustomObject]@{ Error=$_.Exception.Message }) }
    try { $result.Volumes = @(Get-Volume -ErrorAction Stop | ForEach-Object { ConvertTo-FlatObject $_ }) } catch { $result.Volumes = @([PSCustomObject]@{ Error=$_.Exception.Message }) }
    try { $result.Partitions = @(Get-Partition -ErrorAction Stop | ForEach-Object { ConvertTo-FlatObject $_ }) } catch { $result.Partitions = @([PSCustomObject]@{ Error=$_.Exception.Message }) }
    try { $result.Win32_DiskDrive = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop | ForEach-Object { ConvertTo-FlatObject $_ }) } catch { $result.Win32_DiskDrive = @([PSCustomObject]@{ Error=$_.Exception.Message }) }
    try { $result.Win32_DiskPartition = @(Get-CimInstance Win32_DiskPartition -ErrorAction Stop | ForEach-Object { ConvertTo-FlatObject $_ }) } catch { $result.Win32_DiskPartition = @([PSCustomObject]@{ Error=$_.Exception.Message }) }
    try { $result.Win32_LogicalDisk = @(Get-CimInstance Win32_LogicalDisk -ErrorAction Stop | ForEach-Object { ConvertTo-FlatObject $_ }) } catch { $result.Win32_LogicalDisk = @([PSCustomObject]@{ Error=$_.Exception.Message }) }
    try { $result.DiskDriveToDiskPartition = @(Get-CimInstance Win32_DiskDriveToDiskPartition -ErrorAction Stop | ForEach-Object { ConvertTo-FlatObject $_ }) } catch { $result.DiskDriveToDiskPartition = @([PSCustomObject]@{ Error=$_.Exception.Message }) }
    try { $result.LogicalDiskToPartition = @(Get-CimInstance Win32_LogicalDiskToPartition -ErrorAction Stop | ForEach-Object { ConvertTo-FlatObject $_ }) } catch { $result.LogicalDiskToPartition = @([PSCustomObject]@{ Error=$_.Exception.Message }) }
    try { $result.StorageReliabilityCounters = @(Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop | ForEach-Object { ConvertTo-FlatObject $_ }) } catch { $result.StorageReliabilityCounters = @([PSCustomObject]@{ Error=$_.Exception.Message }) }

    $controllers = @(Get-StorageControllerSnapshot)
    $storageDrivers = @(Get-StorageDriverSnapshot)
    $pnpStorageDevices = @(Get-PnpStorageDeviceSnapshot)

    Write-JsonSafe -InputObject $result.Disks -Path (Join-Path $root 'disks.json') -Depth 8
    Write-JsonSafe -InputObject $result.PhysicalDisks -Path (Join-Path $root 'physical-disks.json') -Depth 8
    Write-JsonSafe -InputObject $result.Volumes -Path (Join-Path $root 'volumes.json') -Depth 8
    Write-JsonSafe -InputObject $result.Partitions -Path (Join-Path $root 'partitions.json') -Depth 8
    Write-JsonSafe -InputObject $result.Win32_DiskDrive -Path (Join-Path $root 'diskdrive-cim.json') -Depth 8
    Write-JsonSafe -InputObject $result.DiskDriveToDiskPartition -Path (Join-Path $root 'diskdrive-to-partition-map.json') -Depth 8
    Write-JsonSafe -InputObject $result.LogicalDiskToPartition -Path (Join-Path $root 'logicaldisk-to-partition-map.json') -Depth 8
    Write-JsonSafe -InputObject $result.StorageReliabilityCounters -Path (Join-Path $root 'storage-reliability-counters.json') -Depth 8
    Write-JsonSafe -InputObject $controllers -Path (Join-Path $root 'controller-driver-map.json') -Depth 12
    Write-JsonSafe -InputObject $storageDrivers -Path (Join-Path $root 'storage-driver-snapshot.json') -Depth 10
    Write-JsonSafe -InputObject $pnpStorageDevices -Path (Join-Path $root 'pnp-storage-devices.json') -Depth 10

    $diskEvents = @()
    try {
        $diskEvents = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='disk'; Id=153; StartTime=$StartTime} -MaxEvents 500 -ErrorAction Stop | ForEach-Object { Convert-EventRecordFlat $_ })
    }
    catch { $diskEvents = @() }
    Write-JsonLinesSafe -InputObject $diskEvents -Path (Join-Path $root 'disk-events-153.jsonl')

    $eventMap = @()
    foreach ($ev in $diskEvents) {
        $parsed = Parse-Disk153Message -Message ([string]$ev.Message)
        $diskObject = $null
        if ($null -ne $parsed.DiskNumberFromMessage) {
            try { $diskObject = @($result.Disks | Where-Object { [string]$_.Number -eq [string]$parsed.DiskNumberFromMessage } | Select-Object -First 1) } catch { $diskObject = $null }
        }
        $hint = Test-DiskNumberInHintGroup -Hints $hints -DiskNumber $parsed.DiskNumberFromMessage
        $eventMap += [PSCustomObject]@{
            DiskNumber = $parsed.DiskNumberFromMessage
            DiskNumberFromMessage = $parsed.DiskNumberFromMessage
            PdoObjectName = $parsed.PdoObjectName
            LogicalBlockAddress = $parsed.LogicalBlockAddress
            Parser = $parsed.Parser
            EventId = $ev.Id
            TimeCreated = $ev.TimeCreated
            ProviderName = $ev.ProviderName
            MatchedDisk = $diskObject
            KnownHint = $hint
            Message = $ev.Message
        }
    }
    $aggregate = New-Disk153Aggregate -EventMap $eventMap
    $timeline = @(New-Disk153Timeline -EventMap $eventMap)
    $correlation = @(New-DiskDeviceCorrelation -EventMap $eventMap -StorageResult $result -Hints $hints -Controllers $controllers -Drivers $storageDrivers -PnpDevices $pnpStorageDevices)
    $eventCorrelation = @(New-Disk153UpdateCorrelation -EventMap $eventMap -WindowMinutes 15)
    $riskSummary = New-StorageRiskSummary -EventMap $eventMap -Correlation $correlation -Hints $hints -Timeline $timeline
    $topFindings = @(New-TopFindingsForStorage -RiskSummary $riskSummary -Correlation $correlation)
    $riskIndicators = @(New-RiskIndicatorsForStorage -RiskSummary $riskSummary)
    $suggestedNextEvidence = @(New-SuggestedNextEvidenceForStorage -RiskSummary $riskSummary)

    Write-JsonSafe -InputObject $eventMap -Path (Join-Path $root 'disk-event-map.json') -Depth 12
    Write-JsonSafe -InputObject $aggregate -Path (Join-Path $root 'disk-event-153-aggregate.json') -Depth 10
    Write-JsonSafe -InputObject $timeline -Path (Join-Path $root 'disk153-timeline.json') -Depth 10
    Write-JsonSafe -InputObject $correlation -Path (Join-Path $root 'disk153-device-correlation.json') -Depth 14
    Write-JsonSafe -InputObject $eventCorrelation -Path (Join-Path $root 'disk153-update-setup-correlation.json') -Depth 12
    Write-JsonSafe -InputObject $riskSummary -Path (Join-Path $root 'storage-risk-summary.json') -Depth 12
    Write-JsonSafe -InputObject $topFindings -Path (Join-Path $analysisRoot 'top-findings.json') -Depth 10
    Write-JsonSafe -InputObject $riskIndicators -Path (Join-Path $analysisRoot 'risk-indicators.json') -Depth 10
    Write-JsonSafe -InputObject $suggestedNextEvidence -Path (Join-Path $analysisRoot 'suggested-next-evidence.json') -Depth 10
    Write-JsonSafe -InputObject $suggestedNextEvidence -Path (Join-Path $analysisRoot 'suggested-next-actions.json') -Depth 10

    return [PSCustomObject]@{
        DiskCount=@($result.Disks).Count
        PhysicalDiskCount=@($result.PhysicalDisks).Count
        Disk153Count=@($diskEvents).Count
        Disk153ByDiskNumber=$aggregate.ByDiskNumber
        Disk153ByPdoObjectName=$aggregate.ByPdoObjectName
        Disk153KnownIntelRaidJbodCount=$riskSummary.Disk153EventsOnKnownIntelRaidJbodGroup
        ControllerDriverMap='storage/controller-driver-map.json'
        Disk153Timeline='storage/disk153-timeline.json'
        Disk153DeviceCorrelation='storage/disk153-device-correlation.json'
        Disk153UpdateSetupCorrelation='storage/disk153-update-setup-correlation.json'
        StorageRiskSummary='storage/storage-risk-summary.json'
        TopFindings=$topFindings
        RiskIndicators=$riskIndicators
        SuggestedNextEvidence=$suggestedNextEvidence
    }
}

function Get-VendorLogPolicy {
    [PSCustomObject]@{
        SchemaVersion='diagframework.vendorlog.policy.v1'
        AllowedExtensions=@('.log','.txt','.json','.xml','.etl','.evtx','.wer','.mdmp','.dmp','.csv')
        BlockedExtensions=@('.exe','.dll','.sys','.bin','.msi','.msix','.appx','.cab','.zip','.7z','.rar')
        MaxBytesPerFile=52428800
        MaxFilesPerVendorRoot=300
        Reason='Evidence policy: collect logs and diagnostic files, skip binary payloads and installer caches.'
    }
}

function Get-WerValueSafe {
    param([hashtable]$Values, [string]$Key)
    if ($Values.ContainsKey($Key)) { return $Values[$Key] }
    return $null
}

function Read-WerReportFile {
    param([string]$Path, [string]$PackageRoot)
    $kv = @{}
    try {
        foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
            if ($line -match '^([^=]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
        }
    } catch { }
    $file = $null
    try { $file = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { }
    [PSCustomObject]@{
        RelativePath = Get-RelativePathSafe $PackageRoot $Path
        LastWriteTime = if ($file) { $file.LastWriteTime.ToString('o') } else { $null }
        Length = if ($file) { $file.Length } else { $null }
        EventType = Get-WerValueSafe $kv 'EventType'
        FriendlyEventName = Get-WerValueSafe $kv 'FriendlyEventName'
        AppName = Get-WerValueSafe $kv 'AppName'
        Sig0Name = Get-WerValueSafe $kv 'Sig[0].Name'
        Sig0 = Get-WerValueSafe $kv 'Sig[0].Value'
        Sig1Name = Get-WerValueSafe $kv 'Sig[1].Name'
        Sig1 = Get-WerValueSafe $kv 'Sig[1].Value'
        Sig2Name = Get-WerValueSafe $kv 'Sig[2].Name'
        Sig2 = Get-WerValueSafe $kv 'Sig[2].Value'
        Sig3Name = Get-WerValueSafe $kv 'Sig[3].Name'
        Sig3 = Get-WerValueSafe $kv 'Sig[3].Value'
        ReportId = Get-WerValueSafe $kv 'ReportIdentifier'
    }
}

function Collect-WerSummary {
    param([string]$PackageRoot)
    $werRoot = Join-Path $PackageRoot 'wer'
    New-DirectorySafe $werRoot
    $reportRoots = @(
        (Join-Path $PackageRoot 'copied_logs\ReportArchive'),
        (Join-Path $PackageRoot 'copied_logs\ReportQueue'),
        (Join-Path $PackageRoot 'vendor_logs')
    )
    $reports = @()
    foreach ($rr in $reportRoots) {
        if (-not (Test-Path -LiteralPath $rr)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $rr -Filter 'Report.wer' -File -Recurse -ErrorAction SilentlyContinue)) {
            $reports += Read-WerReportFile -Path $f.FullName -PackageRoot $PackageRoot
        }
        foreach ($f in @(Get-ChildItem -LiteralPath $rr -Filter '*.wer' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Report.wer' })) {
            $reports += Read-WerReportFile -Path $f.FullName -PackageRoot $PackageRoot
        }
    }
    $byEvent = @($reports | Group-Object EventType | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ EventType=$_.Name; Count=$_.Count } })
    $bySig0 = @($reports | Group-Object Sig0 | Sort-Object Count -Descending | Select-Object -First 50 | ForEach-Object { [PSCustomObject]@{ Sig0=$_.Name; Count=$_.Count } })
    $byAppName = @($reports | Group-Object AppName | Sort-Object Count -Descending | Select-Object -First 50 | ForEach-Object { [PSCustomObject]@{ AppName=$_.Name; Count=$_.Count } })
    $times = @($reports | Where-Object { $_.LastWriteTime } | ForEach-Object { try { [datetime]$_.LastWriteTime } catch { $null } } | Where-Object { $null -ne $_ })
    $oldest = $null; $newest = $null
    if ($times.Count -gt 0) {
        $oldest = (($times | Sort-Object | Select-Object -First 1).ToString('o'))
        $newest = (($times | Sort-Object | Select-Object -Last 1).ToString('o'))
    }
    Write-JsonSafe -InputObject $reports -Path (Join-Path $werRoot 'wer-reports.json') -Depth 10
    $summary = [PSCustomObject]@{
        ReportCount=@($reports).Count
        OldestReportTime=$oldest
        NewestReportTime=$newest
        ByEventType=$byEvent
        BySig0=$bySig0
        ByAppName=$byAppName
        SourceRoots=$reportRoots
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $werRoot 'wer-summary.json') -Depth 12
    return [PSCustomObject]@{ ReportCount=@($reports).Count; OldestReportTime=$oldest; NewestReportTime=$newest }
}
function Copy-BaselineLogs {
    param([string]$PackageRoot)
    $copied = @()
    $skipped = @()
    $systemPolicy = Get-SystemLogCopyPolicy
    $setupPolicy = Get-SetupLogCopyPolicy

    $fileTargets = @(
        "$env:SystemRoot\Logs\CBS\CBS.log",
        "$env:SystemRoot\Logs\DISM\dism.log",
        "$env:SystemRoot\WindowsUpdate.log",
        "$env:SystemRoot\SoftwareDistribution\ReportingEvents.log",
        "$env:SystemRoot\INF\setupapi.dev.log",
        "$env:SystemRoot\INF\setupapi.setup.log"
    )
    foreach ($target in $fileTargets) {
        try { $copied += @(Copy-IfExists -Source $target -DestinationRoot (Join-Path $PackageRoot 'copied_logs') -MaxBytes $systemPolicy.MaxBytesPerFile -MaxFiles 1 -AllowedExtensions $systemPolicy.AllowedExtensions -BlockedExtensions $systemPolicy.BlockedExtensions) }
        catch { $skipped += [PSCustomObject]@{ Source=$target; Skipped=$true; Reason='CopyError'; Error=$_.Exception.Message } }
    }

    $setupTargets = @( "$env:SystemRoot\Panther" )
    foreach ($target in $setupTargets) {
        try { $copied += @(Copy-IfExists -Source $target -DestinationRoot (Join-Path $PackageRoot 'copied_logs') -MaxBytes $setupPolicy.MaxBytesPerFile -MaxFiles $setupPolicy.MaxFilesPerRoot -AllowedExtensions $setupPolicy.AllowedExtensions -BlockedExtensions $setupPolicy.BlockedExtensions) }
        catch { $skipped += [PSCustomObject]@{ Source=$target; Skipped=$true; Reason='CopyError'; Error=$_.Exception.Message } }
    }

    $diagnosticTargets = @(
        "$env:SystemRoot\Minidump",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
    )
    foreach ($target in $diagnosticTargets) {
        try { $copied += @(Copy-IfExists -Source $target -DestinationRoot (Join-Path $PackageRoot 'copied_logs') -MaxBytes $systemPolicy.MaxBytesPerFile -MaxFiles $systemPolicy.MaxFilesPerRoot -AllowedExtensions $systemPolicy.AllowedExtensions -BlockedExtensions $systemPolicy.BlockedExtensions) }
        catch { $skipped += [PSCustomObject]@{ Source=$target; Skipped=$true; Reason='CopyError'; Error=$_.Exception.Message } }
    }

    $policy = Get-VendorLogPolicy
    $vendorTargets = @("$env:ProgramData\Dell","$env:ProgramData\HP","$env:ProgramData\Lenovo","$env:ProgramData\Intel","$env:ProgramData\NVIDIA Corporation","$env:ProgramData\AMD","$env:ProgramData\ASUS")
    $vendorRecords = @()
    foreach ($target in $vendorTargets) {
        try { $vendorRecords += @(Copy-IfExists -Source $target -DestinationRoot (Join-Path $PackageRoot 'vendor_logs') -MaxBytes $policy.MaxBytesPerFile -MaxFiles $policy.MaxFilesPerVendorRoot -AllowedExtensions $policy.AllowedExtensions -BlockedExtensions $policy.BlockedExtensions) }
        catch { $vendorRecords += [PSCustomObject]@{ Source=$target; Skipped=$true; Reason='CopyError'; Error=$_.Exception.Message } }
    }

    $copiedOnly = @($copied | Where-Object { -not $_.Skipped })
    $skipped += @($copied | Where-Object { $_.Skipped })
    Write-JsonSafe -InputObject $copiedOnly -Path (Join-Path $PackageRoot 'copied_logs/copied-files.json') -Depth 8
    Write-JsonSafe -InputObject $skipped -Path (Join-Path $PackageRoot 'copied_logs/skipped-files.json') -Depth 8
    Write-JsonSafe -InputObject $systemPolicy -Path (Join-Path $PackageRoot 'copied_logs/system-log-copy-policy.json') -Depth 8
    Write-JsonSafe -InputObject $setupPolicy -Path (Join-Path $PackageRoot 'copied_logs/setup-log-copy-policy.json') -Depth 8
    Write-JsonSafe -InputObject $policy -Path (Join-Path $PackageRoot 'vendor_logs/vendor-log-policy.json') -Depth 8
    Write-JsonSafe -InputObject $vendorRecords -Path (Join-Path $PackageRoot 'vendor_logs/vendor-log-manifest.json') -Depth 8
    return [PSCustomObject]@{ Copied=$copiedOnly; Skipped=$skipped; VendorRecords=$vendorRecords }
}
function New-PackageManifestSafe {
    param([string]$PackageRoot)
    $files = @()
    foreach ($child in @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $files += [PSCustomObject]@{
                RelativePath = Get-RelativePathSafe $PackageRoot $child.FullName
                Length = $child.Length
                LastWriteTime = $child.LastWriteTime.ToString('o')
                SHA256 = Get-FileHashSafe $child.FullName
            }
        } catch { }
    }
    [PSCustomObject]@{
        SchemaVersion='diagframework.package.manifest.v2'
        PackageType='SystemEvidence'
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        ModuleId=$ModuleId
        ModuleVersion=$ModuleVersion
        ComputerName=$env:COMPUTERNAME
        CollectorPolicy=[PSCustomObject]@{
            EventMaxEvents=$MaxEvents
            VendorLogPolicy=(Get-VendorLogPolicy)
            SystemLogCopyPolicy=(Get-SystemLogCopyPolicy)
            SetupLogCopyPolicy=(Get-SetupLogCopyPolicy)
            HashAlgorithm='SHA256'
        }
        Files=$files
    }
}

function Get-ObjectPropertyValueSafe {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Default = $null
    )
    try {
        if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
            return $Object.PSObject.Properties[$Name].Value
        }
    }
    catch { }
    return $Default
}


function New-SummaryObject {
    param([string]$Status,[string]$PackageRoot,[string]$ZipPath,[string]$TargetKB,[int]$DaysBack,[int]$MaxEvents,$EventSummary=@(),$Copied=@(),$NativeResults=@(),$Issues=@(),$P0Results=@())
    $split = Split-IssuesBySeverity -Issues $Issues
    $truncated = @(
        @($EventSummary) |
        Where-Object { [bool](Get-ObjectPropertyValueSafe -Object $_ -Name 'Truncated' -Default $false) } |
        ForEach-Object {
            [PSCustomObject]@{
                LogName = Get-ObjectPropertyValueSafe -Object $_ -Name 'LogName' -Default ''
                Count = Get-ObjectPropertyValueSafe -Object $_ -Name 'Count' -Default 0
                OutputFile = Get-ObjectPropertyValueSafe -Object $_ -Name 'OutputFile' -Default ''
                OutputEvtx = Get-ObjectPropertyValueSafe -Object $_ -Name 'OutputEvtx' -Default $null
                Note = 'JSONL truncated; raw EVTX available when OutputEvtx is populated.'
            }
        }
    )
    $warningsByCode = @(@($split.Warnings) | Group-Object Code | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ Code=$_.Name; Count=$_.Count } })
    $topFindings = @(); $riskIndicators = @(); $suggestedNextEvidence = @()
    try {
        $storageP0 = @(@($P0Results) | Where-Object { $_.Area -eq 'Storage' } | Select-Object -First 1)
        if ($storageP0 -and $storageP0.Result) {
            $topFindings = @($storageP0.Result.TopFindings)
            $riskIndicators = @($storageP0.Result.RiskIndicators)
            $suggestedNextEvidence = @($storageP0.Result.SuggestedNextEvidence)
        }
    } catch { }
    [PSCustomObject]@{
        SchemaVersion='diagframework.systemevidence.summary.v3.3'
        ModuleId=$ModuleId
        ModuleVersion=$ModuleVersion
        Status=$Status
        TimestampUtc=(Get-Date).ToUniversalTime().ToString('o')
        ComputerName=$env:COMPUTERNAME
        TargetKB=$TargetKB
        DaysBack=$DaysBack
        MaxEvents=$MaxEvents
        PackageRoot=$PackageRoot
        ZipPath=$ZipPath
        EventLogCount=@($EventSummary).Count
        TruncatedEventLogCount=@($truncated).Count
        TruncatedEventLogs=$truncated
        CopiedRecordCount=@($Copied).Count
        NativeCommandCount=@($NativeResults).Count
        ErrorCount=@($split.Errors).Count
        WarningCount=@($split.Warnings).Count
        WarningsByCode=$warningsByCode
        Purpose='AI/szakértő által elemezhető Windows 11 P0 read-only evidence csomag storage korrelációval és top findings mezőkkel.'
        P0Evidence=$P0Results
        TopFindings=$topFindings
        RiskIndicators=$riskIndicators
        SuggestedNextEvidence=$suggestedNextEvidence
    }
}

function Invoke-EvidenceCollection {
    param([int]$DaysBack=30,[int]$MaxEvents=1200,[switch]$WhatIf,[string]$TargetKB='')
    Write-LogRootReadmes -LogRootPath $LogRoot -TargetKB $TargetKB
    $evidenceRoot = Join-Path $LogRoot 'evidence_packages'
    New-DirectorySafe $evidenceRoot
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $suffix = if ([string]::IsNullOrWhiteSpace($TargetKB)) { 'SystemEvidence' } else { 'SystemEvidence-' + $TargetKB }
    $packageRoot = Join-Path $evidenceRoot ("$timestamp-$env:COMPUTERNAME-$suffix")
    $zipPath = "$packageRoot.zip"
    foreach ($sub in 'meta','events','events/raw','registry','copied_logs','drivers','commands','errors','vendor_logs','windows_update','servicing','storage','wer','analysis') { New-DirectorySafe (Join-Path $packageRoot $sub) }
    Write-PackageReadme -PackageRoot $packageRoot -TargetKB $TargetKB -Status 'InProgress'
    $issues=@(); $eventSummary=@(); $copied=@(); $nativeResults=@(); $p0Results=@()
    Add-ProgressEvent $packageRoot 'Start' 'OK' "DaysBack=$DaysBack MaxEvents=$MaxEvents TargetKB=$TargetKB WhatIf=$($WhatIf.IsPresent)"
    if ($WhatIf) {
        $summary=[PSCustomObject]@{ SchemaVersion='diagframework.systemevidence.summary.v3.1'; ModuleId=$ModuleId; ModuleVersion=$ModuleVersion; WhatIf=$true; Status='WhatIf'; PlannedPackageRoot=$packageRoot; PlannedZipPath=$zipPath; P0Planned=@('EVTX export','WindowsUpdate generated log','DISM ScanHealth','SFC verifyonly','Storage mapping','WER aggregation','copied_logs skipped-files manifest','Manifest SHA256','Storage controller correlation','Disk 153 timeline','TopFindings/RiskIndicators/SuggestedNextEvidence') }
        Write-JsonSafe -InputObject $summary -Path (Join-Path $packageRoot 'ai_summary.json') -Depth 8
        return $summary
    }
    $startTime = (Get-Date).AddDays(-1 * [Math]::Abs($DaysBack))
    try { Write-JsonSafe -InputObject (Get-SystemSnapshot) -Path (Join-Path $packageRoot 'meta/system-info.json') -Depth 8; Add-ProgressEvent $packageRoot 'SystemSnapshot' } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'SystemSnapshotFailed' -Step 'SystemSnapshot' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'SystemSnapshot' 'Error' $_.Exception.Message }
    try { Write-JsonSafe -InputObject @(Get-RebootPendingSnapshot) -Path (Join-Path $packageRoot 'registry/reboot-pending.json') -Depth 10; Add-ProgressEvent $packageRoot 'RegistryPendingReboot' } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'RegistryPendingRebootFailed' -Step 'RegistryPendingReboot' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'RegistryPendingReboot' 'Error' $_.Exception.Message }
    try { Write-JsonSafe -InputObject @(Get-DriverSnapshot) -Path (Join-Path $packageRoot 'drivers/pnp-signed-drivers.json') -Depth 8; Add-ProgressEvent $packageRoot 'DriverSnapshot' } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'DriverSnapshotFailed' -Step 'DriverSnapshot' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'DriverSnapshot' 'Error' $_.Exception.Message }
    try { $eventResult=Collect-Events -PackageRoot $packageRoot -StartTime $startTime -Issues $issues -MaxEvents $MaxEvents; $eventSummary=@($eventResult.Summary); $issues=@($eventResult.Issues); $p0Results += [PSCustomObject]@{ Area='Events'; Result='Collected'; Count=@($eventSummary).Count }; Add-ProgressEvent $packageRoot 'EventLogs' 'OK' "Logs=$($eventSummary.Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'EventCollectionFailed' -Step 'EventLogs' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'EventLogs' 'Error' $_.Exception.Message }
    try { $copyResult=Copy-BaselineLogs $packageRoot; $copied=@($copyResult.Copied) + @($copyResult.VendorRecords); $p0Results += [PSCustomObject]@{ Area='CopiedLogs'; CopiedCount=@($copyResult.Copied).Count; SkippedCount=@($copyResult.Skipped).Count; Policy='SystemLogCopyPolicy + SetupLogCopyPolicy + VendorLogPolicy' }; Add-ProgressEvent $packageRoot 'CopyLogs' 'OK' "Copied=$(@($copyResult.Copied).Count) Skipped=$(@($copyResult.Skipped).Count) VendorRecords=$(@($copyResult.VendorRecords).Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'CopyLogsFailed' -Step 'CopyLogs' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'CopyLogs' 'Error' $_.Exception.Message }
    try { $wu=Invoke-WindowsUpdateLogConversion -PackageRoot $packageRoot; $p0Results += [PSCustomObject]@{ Area='WindowsUpdateLog'; Status=$wu.Status; Length=$wu.Length }; Add-ProgressEvent $packageRoot 'WindowsUpdateLog' $wu.Status "Length=$($wu.Length)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'WindowsUpdateLogConversionFailed' -Step 'WindowsUpdateLog' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'WindowsUpdateLog' 'Warning' $_.Exception.Message }
    try { $defs=Get-NativeCommandDefinitions; Write-NativeCommandReadme -PackageRoot $packageRoot -Definitions $defs; foreach($d in $defs | Where-Object { $_.SubDirectory -eq 'commands' }) { $nativeResults += Invoke-NativeCommandSafe -PackageRoot $packageRoot -SubDirectory $d.SubDirectory -Name $d.Name -File $d.File -ArgumentList ([string[]]$d.ArgumentList) }; Write-JsonSafe -InputObject $nativeResults -Path (Join-Path $packageRoot 'commands/native-command-results.json') -Depth 12; Add-ProgressEvent $packageRoot 'NativeCommands' 'OK' "Commands=$($nativeResults.Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'NativeCommandsFailed' -Step 'NativeCommands' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'NativeCommands' 'Error' $_.Exception.Message }
    try { $serv=Collect-ServicingEvidence -PackageRoot $packageRoot; $p0Results += [PSCustomObject]@{ Area='Servicing'; CommandCount=@($serv).Count }; Add-ProgressEvent $packageRoot 'ServicingEvidence' 'OK' "Commands=$(@($serv).Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'ServicingEvidenceFailed' -Step 'ServicingEvidence' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'ServicingEvidence' 'Warning' $_.Exception.Message }
    try { $storage=Collect-StorageEvidence -PackageRoot $packageRoot -StartTime $startTime; $p0Results += [PSCustomObject]@{ Area='Storage'; Result=$storage }; Add-ProgressEvent $packageRoot 'StorageEvidence' 'OK' "Disk153=$($storage.Disk153Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'StorageEvidenceFailed' -Step 'StorageEvidence' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'StorageEvidence' 'Warning' $_.Exception.Message }
    try { $wer=Collect-WerSummary -PackageRoot $packageRoot; $p0Results += [PSCustomObject]@{ Area='WER'; ReportCount=$wer.ReportCount }; Add-ProgressEvent $packageRoot 'WerSummary' 'OK' "Reports=$($wer.ReportCount)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'WerSummaryFailed' -Step 'WerSummary' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'WerSummary' 'Warning' $_.Exception.Message }
    Write-CollectorIssuesSafe -PackageRoot $packageRoot -Issues $issues
    $split = Split-IssuesBySeverity -Issues $issues
    $status = if (@($split.Errors).Count -gt 0) { 'Partial' } elseif (@($split.Warnings).Count -gt 0) { 'OKWithWarnings' } else { 'OK' }
    $summary = New-SummaryObject -Status $status -PackageRoot $packageRoot -ZipPath $zipPath -TargetKB $TargetKB -DaysBack $DaysBack -MaxEvents $MaxEvents -EventSummary $eventSummary -Copied $copied -NativeResults $nativeResults -Issues $issues -P0Results $p0Results
    Write-JsonSafe -InputObject $summary -Path (Join-Path $packageRoot 'ai_summary.json') -Depth 10
    Write-PackageReadme -PackageRoot $packageRoot -TargetKB $TargetKB -Status $status
    try { $manifest=New-PackageManifestSafe -PackageRoot $packageRoot; Write-JsonSafe -InputObject $manifest -Path (Join-Path $packageRoot 'manifest.json') -Depth 12; Add-ProgressEvent $packageRoot 'Manifest' 'OK' "Files=$($manifest.Files.Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'ManifestFailed' -Step 'Manifest' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Write-CollectorIssuesSafe -PackageRoot $packageRoot -Issues $issues; Add-ProgressEvent $packageRoot 'Manifest' 'Error' $_.Exception.Message }
    try { if(Test-Path -LiteralPath $zipPath){Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue}; Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -Force -ErrorAction Stop; Add-ProgressEvent $packageRoot 'Zip' 'OK' $zipPath } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'ZipFailed' -Step 'Zip' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Write-CollectorIssuesSafe -PackageRoot $packageRoot -Issues $issues; Add-ProgressEvent $packageRoot 'Zip' 'Error' $_.Exception.Message }
    return $summary
}

switch ($Action) {
    'Get-Metadata' { Get-Metadata }
    'Test-Condition' {
        [PSCustomObject]@{
            IssueDetected=$true
            FixAvailable=$true
            Severity='Info'
            Summary='Rendszerszintű P0 evidence csomag készíthető EVTX, Windows Update, servicing, storage, WER és lokalizált disk 153 normalizálással.'
            RecommendedAction='Javasolt lépések: 1) Állítsd be a DaysBack értéket. 2) Indítsd el a rendszer LOG csomagot WhatIf nélkül. 3) Először ai_summary.json, collector-issues.json és event-export-metadata.json fájlokat nézd. 4) Storage hibánál disk-event-map.json és disk-event-153-aggregate.json a kulcs. 5) WER zajnál wer-summary.json és wer-reports.json. 6) Javítómodult csak pre-repair evidence után futtass.'
        }
    }
    'Invoke-Fix' { Invoke-EvidenceCollection -DaysBack $DaysBack -MaxEvents $MaxEvents -WhatIf:$WhatIf -TargetKB $TargetKB }
    'Invoke-Rollback' { [PSCustomObject]@{ RollbackSupported=$false; Summary='A SystemEvidenceCollector read-only modul, rollback nem szükséges.' } }
}
