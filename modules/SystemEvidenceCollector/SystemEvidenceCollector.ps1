<#
.SYNOPSIS
  Windows 11 rendszerbizonyíték és vendor diagnosztikai LOG gyűjtő modul.
.DESCRIPTION
  v1.4.1 P0 Evidence Bridge Pack for P1 Normalizers v1.4.0.
  Read-only evidence gyűjtés + Baunok hiányosság-pótlás: CbsPersist teljesebb
  gyűjtés, minidump CDB/WinDbg batch evidence, repair source advisor, KB-context
  handoff és P1 v1.4.0 normalizáló-kompatibilis átadási JSON-ok. Továbbra sem
  javít rendszert.
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
$ModuleVersion = '1.4.1'
$P1NormalizerCompatibleVersion = '1.4.0'

function Get-Metadata {
    [PSCustomObject]@{
        Id = $ModuleId
        Name = 'Rendszer LOG bizonyítékgyűjtő'
        Version = $ModuleVersion
        P1CompatibleVersion = $P1NormalizerCompatibleVersion
        Risk = 'Low'
        Summary = 'Windows 11 P0 read-only evidence bridge P1 v1.4.0 normalizálókhoz: CbsPersist, CDB minidump evidence, repair-source advisor, KB-context handoff, servicing/WU signal summaries.'
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
        InterpretationMode = 'ContextHintOnly_NotAuthoritative'
        Notes = 'A felhasználói projektkontextus szerint Disk 2 és Disk 3 az alaplapi Intel RAID controllerre csatolt 2x8TB SATA HDD; a RAID JBOD üzemmódban van. A v1.3.4 ezt nem tekinti automatikusan bizonyított topológiának: külön validálja a tényleges Windows storage mapping alapján.'
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


function ConvertTo-Int64Safe {
    param([AllowNull()]$Value)
    try {
        if ($null -eq $Value) { return $null }
        $s = [string]$Value
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        return [int64]$s
    } catch { return $null }
}

function Convert-BytesToTiBSafe {
    param([AllowNull()]$Bytes)
    $n = ConvertTo-Int64Safe -Value $Bytes
    if ($null -eq $n) { return $null }
    try { return [math]::Round(($n / 1TB), 2) } catch { return $null }
}

function Get-RaidVolumeClassification {
    param([AllowNull()]$Disk, [AllowNull()]$Win32DiskDrive, [AllowNull()]$PhysicalDisk)
    $text = @(
        (Get-PropertyFromFlatObjectSafe $Disk 'FriendlyName'),
        (Get-PropertyFromFlatObjectSafe $Disk 'Model'),
        (Get-PropertyFromFlatObjectSafe $Win32DiskDrive 'Model'),
        (Get-PropertyFromFlatObjectSafe $Win32DiskDrive 'Caption'),
        (Get-PropertyFromFlatObjectSafe $PhysicalDisk 'FriendlyName'),
        (Get-PropertyFromFlatObjectSafe $PhysicalDisk 'Model')
    ) -join ' '
    if ($text -match '(?i)raid\s*0') { return 'IntelRaid0Volume' }
    if ($text -match '(?i)raid\s*1') { return 'IntelRaid1Volume' }
    if ($text -match '(?i)raid') { return 'RaidVolume' }
    if ($text -match '(?i)ST\d+|Seagate|WDC|Western Digital|TOSHIBA|HGST') { return 'PhysicalHddCandidate' }
    if ($text -match '(?i)NVMe|KINGSTON|Samsung SSD|SSD') { return 'NvmeOrSsdCandidate' }
    return 'Unknown'
}

function New-RaidVolumeMap {
    param($StorageResult)
    $items = @()
    foreach ($d in @($StorageResult.Disks)) {
        $number = Get-PropertyFromFlatObjectSafe $d 'Number'
        $cimDisk = Find-FlatByPropertyValue -Items $StorageResult.Win32_DiskDrive -PropertyName 'Index' -Value $number
        $phys = $null
        try { $phys = @($StorageResult.PhysicalDisks | Where-Object { [string](Get-PropertyFromFlatObjectSafe $_ 'DeviceId') -eq [string]$number } | Select-Object -First 1) } catch { }
        $class = Get-RaidVolumeClassification -Disk $d -Win32DiskDrive $cimDisk -PhysicalDisk $phys
        if ($class -match 'Raid') {
            $items += [PSCustomObject]@{
                DiskNumber=$number
                Classification=$class
                FriendlyName=Get-PropertyFromFlatObjectSafe $d 'FriendlyName'
                Model=Get-PropertyFromFlatObjectSafe $d 'Model'
                SizeBytes=Get-PropertyFromFlatObjectSafe $d 'Size'
                SizeTiB=Convert-BytesToTiBSafe -Bytes (Get-PropertyFromFlatObjectSafe $d 'Size')
                UniqueId=Get-PropertyFromFlatObjectSafe $d 'UniqueId'
                Path=Get-PropertyFromFlatObjectSafe $d 'Path'
                Win32Model=Get-PropertyFromFlatObjectSafe $cimDisk 'Model'
                Win32PNPDeviceID=Get-PropertyFromFlatObjectSafe $cimDisk 'PNPDeviceID'
                PhysicalDiskFriendlyName=Get-PropertyFromFlatObjectSafe $phys 'FriendlyName'
                PhysicalDiskSerialNumber=Get-PropertyFromFlatObjectSafe $phys 'SerialNumber'
            }
        }
    }
    return $items
}

function New-PhysicalDiskCandidateMap {
    param($StorageResult, $PnpDevices = @())
    $items = @()
    foreach ($p in @($StorageResult.PhysicalDisks)) {
        $class = Get-RaidVolumeClassification -PhysicalDisk $p
        $items += [PSCustomObject]@{
            Source='Get-PhysicalDisk'
            CandidateRole=$class
            DeviceId=Get-PropertyFromFlatObjectSafe $p 'DeviceId'
            FriendlyName=Get-PropertyFromFlatObjectSafe $p 'FriendlyName'
            Manufacturer=Get-PropertyFromFlatObjectSafe $p 'Manufacturer'
            Model=Get-PropertyFromFlatObjectSafe $p 'Model'
            SerialNumber=Get-PropertyFromFlatObjectSafe $p 'SerialNumber'
            SizeBytes=Get-PropertyFromFlatObjectSafe $p 'Size'
            SizeTiB=Convert-BytesToTiBSafe -Bytes (Get-PropertyFromFlatObjectSafe $p 'Size')
            HealthStatus=Get-PropertyFromFlatObjectSafe $p 'HealthStatus'
            OperationalStatus=Get-PropertyFromFlatObjectSafe $p 'OperationalStatus'
            BusType=Get-PropertyFromFlatObjectSafe $p 'BusType'
            IsPartial=Get-PropertyFromFlatObjectSafe $p 'IsPartial'
        }
    }
    foreach ($pnp in @($PnpDevices | Where-Object { $_.Class -eq 'DiskDrive' -and $_.Present -eq $true })) {
        $items += [PSCustomObject]@{
            Source='Get-PnpDevice'
            CandidateRole=if ([string]$pnp.FriendlyName -match '(?i)ST\d+|Seagate') { 'PresentSeagateHddCandidate' } elseif ([string]$pnp.FriendlyName -match '(?i)Raid') { 'PresentRaidVolumeCandidate' } else { 'PresentDiskCandidate' }
            DeviceId=$null
            FriendlyName=$pnp.FriendlyName
            Manufacturer=$null
            Model=$pnp.FriendlyName
            SerialNumber=$null
            SizeBytes=$null
            SizeTiB=$null
            HealthStatus=$pnp.Status
            OperationalStatus=$pnp.Status
            BusType=$null
            IsPartial=$null
            InstanceId=$pnp.InstanceId
            Problem=$pnp.Problem
        }
    }
    return $items
}

function New-DetectedStorageTopology {
    param($Correlation = @(), $StorageResult, $Controllers = @(), $Drivers = @(), $PnpDevices = @())
    $diskViews = @()
    foreach ($c in @($Correlation)) {
        $disk = $c.Disk
        $cimDisk = $c.Win32_DiskDrive
        $phys = @($c.PhysicalDisk | Select-Object -First 1)
        $class = Get-RaidVolumeClassification -Disk $disk -Win32DiskDrive $cimDisk -PhysicalDisk $phys
        $driveLetters = @($c.Volumes | ForEach-Object { Get-PropertyFromFlatObjectSafe $_ 'DriveLetter' } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $labels = @($c.Volumes | ForEach-Object { Get-PropertyFromFlatObjectSafe $_ 'FileSystemLabel' } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $diskViews += [PSCustomObject]@{
            DiskNumber=$c.DiskNumber
            Event153Count=$c.Event153Count
            Classification=$class
            FriendlyName=Get-PropertyFromFlatObjectSafe $disk 'FriendlyName'
            Model=Get-PropertyFromFlatObjectSafe $disk 'Model'
            SizeBytes=Get-PropertyFromFlatObjectSafe $disk 'Size'
            SizeTiB=Convert-BytesToTiBSafe -Bytes (Get-PropertyFromFlatObjectSafe $disk 'Size')
            Win32Model=Get-PropertyFromFlatObjectSafe $cimDisk 'Model'
            Win32PNPDeviceID=Get-PropertyFromFlatObjectSafe $cimDisk 'PNPDeviceID'
            DriveLetters=$driveLetters
            VolumeLabels=$labels
            PdoObjectNames=$c.PdoObjectNames
            KnownHint=$c.KnownHint
        }
    }
    $raidMap = @(New-RaidVolumeMap -StorageResult $StorageResult)
    $physCandidates = @(New-PhysicalDiskCandidateMap -StorageResult $StorageResult -PnpDevices $PnpDevices)
    $controllerSummary = @($Controllers | Where-Object { ([string]$_.Data.Caption + ' ' + [string]$_.Data.Name + ' ' + [string]$_.Data.DriverName) -match '(?i)intel|rst|raid|vmd|sata|ahci' } | ForEach-Object {
        [PSCustomObject]@{
            Source=$_.Source
            Caption=$_.Data.Caption
            Name=$_.Data.Name
            Status=$_.Data.Status
            DriverName=$_.Data.DriverName
            Manufacturer=$_.Data.Manufacturer
            DeviceID=$_.Data.DeviceID
            PNPDeviceID=$_.Data.PNPDeviceID
        }
    })
    [PSCustomObject]@{
        SchemaVersion='diagframework.storage.detected.topology.v1'
        Interpretation='DetectedTopology is derived from Windows storage/PnP/CIM data. UserProvidedTopology remains a contextual hint and must be validated against this object.'
        DisksWith153=$diskViews
        RaidVolumeMap=$raidMap
        PhysicalDiskCandidateMap=$physCandidates
        ControllerPathSummary=$controllerSummary
        PresentRaidVolumes=@($raidMap | Where-Object { $_.Classification -match 'Raid' })
        PresentPhysicalDiskCandidates=@($physCandidates | Where-Object { $_.CandidateRole -match 'Hdd|Seagate|Physical' })
    }
}

function Test-StorageHintAgainstDetected {
    param($Hints, $DetectedTopology, $Correlation = @())
    $mismatches = @()
    $matches = @()
    $detectedText = (@($DetectedTopology.DisksWith153 | ForEach-Object { [string]$_.Classification + ' ' + [string]$_.FriendlyName + ' ' + [string]$_.Model + ' ' + [string]$_.Win32Model }) -join ' ')
    foreach ($group in @($Hints.KnownDiskGroups)) {
        $hintDiskNumbers = @($group.DiskNumbers | ForEach-Object { [string]$_ })
        $detectedGroupDisks = @($DetectedTopology.DisksWith153 | Where-Object { $hintDiskNumbers -contains [string]$_.DiskNumber })
        if ($detectedGroupDisks.Count -gt 0) {
            $matches += [PSCustomObject]@{ Code='HintDiskNumbersMatched'; GroupName=$group.GroupName; DiskNumbers=$hintDiskNumbers; Count=$detectedGroupDisks.Count }
        }
        if ([string]$group.Mode -match '(?i)JBOD' -and $detectedText -match '(?i)Raid\s*0|Raid\s*1|IntelRaid0Volume|IntelRaid1Volume') {
            $mismatches += [PSCustomObject]@{
                Code='StorageHintMismatch'
                Severity='Warning'
                GroupName=$group.GroupName
                Hint='Mode=JBOD / ExpectedDriveDescription=' + [string]$group.ExpectedDriveDescription
                Detected='Windows reports RAID volume objects, e.g. Intel Raid 0/1 Volume, for one or more hinted disk numbers.'
                Meaning='Treat storage_hints.json as user context, not authoritative topology. Prefer detected-storage-topology.json for automated reasoning.'
            }
        }
        foreach ($d in @($detectedGroupDisks)) {
            if ([string]$group.ExpectedDriveDescription -match '8TB' -and $d.SizeTiB -and ([double]$d.SizeTiB -gt 12 -or [double]$d.SizeTiB -lt 7)) {
                $mismatches += [PSCustomObject]@{
                    Code='StorageHintSizeMismatch'
                    Severity='Info'
                    GroupName=$group.GroupName
                    DiskNumber=$d.DiskNumber
                    Hint='Expected approximately one 8TB member disk.'
                    Detected=('Disk object size appears as {0} TiB with FriendlyName={1}' -f $d.SizeTiB, $d.FriendlyName)
                    Meaning='This may be normal for an exposed RAID volume, but it is not a simple physical 8TB disk mapping.'
                }
            }
        }
    }
    [PSCustomObject]@{
        SchemaVersion='diagframework.storage.hint.validation.v1'
        Result=if ($mismatches.Count -gt 0) { 'MismatchDetected' } else { 'NoMismatchDetected' }
        UserProvidedTopology=$Hints
        DetectedTopologyReference='storage/detected-storage-topology.json'
        Matches=$matches
        Mismatches=$mismatches
        Recommendation=if ($mismatches.Count -gt 0) { 'Do not use the user hint as a fact. Review detected-storage-topology.json, raid-volume-map.json and physical-disk-candidate-map.json.' } else { 'User hint and detected topology do not materially conflict based on current rules.' }
    }
}

function Get-Disk153Severity {
    param([int]$Count)
    if ($Count -ge 20) { return 'High' }
    if ($Count -ge 5) { return 'Medium' }
    if ($Count -gt 0) { return 'Low' }
    return 'None'
}

function New-TargetKbCorrelation {
    param([string]$TargetKB = '', $EventCorrelation = @())
    if ([string]::IsNullOrWhiteSpace($TargetKB)) {
        return [PSCustomObject]@{ SchemaVersion='diagframework.targetkb.correlation.v1'; TargetKB=$TargetKB; Status='NotRequested'; DirectMatchCount=0; Matches=@(); Meaning='No TargetKB was supplied for this system evidence package.' }
    }
    $matches = @()
    foreach ($bucket in @($EventCorrelation)) {
        foreach ($ev in @($bucket.Events)) {
            if (([string]$ev.MessagePreview -match [regex]::Escape($TargetKB)) -or ([string]$ev.ProviderName -match [regex]::Escape($TargetKB))) {
                $matches += [PSCustomObject]@{
                    Disk153TimeCreated=$bucket.Disk153TimeCreated
                    DiskNumber=$bucket.DiskNumber
                    CorrelationLog=$ev.CorrelationLog
                    ProviderName=$ev.ProviderName
                    Id=$ev.Id
                    TimeCreated=$ev.TimeCreated
                    MessagePreview=$ev.MessagePreview
                }
            }
        }
    }
    [PSCustomObject]@{
        SchemaVersion='diagframework.targetkb.correlation.v1'
        TargetKB=$TargetKB
        Status=if ($matches.Count -gt 0) { 'DirectMatchInCorrelationWindow' } else { 'NoDirectMatchInCorrelationWindow' }
        DirectMatchCount=$matches.Count
        Matches=$matches
        Meaning=if ($matches.Count -gt 0) { 'The target KB appears near one or more Disk 153 correlation windows.' } else { 'No direct target KB text match was found in Disk 153 correlation windows. This does not exclude indirect storage/update interaction.' }
    }
}

function New-StorageRiskSummary {
    param($EventMap = @(), $Correlation = @(), $Hints, $Timeline = @(), $DetectedTopology = $null, $HintValidation = $null)
    $disk153Count = @($EventMap).Count
    $byDisk = @($EventMap | Group-Object DiskNumberFromMessage | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ DiskNumber=$_.Name; Count=$_.Count; Severity=(Get-Disk153Severity -Count $_.Count) } })
    $byPdo = @($EventMap | Group-Object PdoObjectName | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ PdoObjectName=$_.Name; Count=$_.Count } })
    $riskLevel = if ($disk153Count -ge 30) { 'HighSignal' } elseif ($disk153Count -gt 0) { 'MediumSignal' } else { 'NoSignal' }
    $hintMatchedEvents = 0
    foreach ($ev in @($EventMap)) { if (Test-DiskNumberInHintGroup -Hints $Hints -DiskNumber $ev.DiskNumberFromMessage) { $hintMatchedEvents++ } }
    [PSCustomObject]@{
        SchemaVersion = 'diagframework.storage.risk.summary.v2'
        RiskLevel = $riskLevel
        Disk153Count = $disk153Count
        Disk153EventsOnHintedDiskNumbers = $hintMatchedEvents
        UserProvidedTopology = $Hints
        DetectedTopology = $DetectedTopology
        HintValidation = $HintValidation
        ByDiskNumber = $byDisk
        ByPdoObjectName = $byPdo
        TimeRange = (Get-TimeRangeFromObjectsSafe -Items $Timeline -PropertyName 'TimeCreated')
        Interpretation = @(
            'Event ID 153 is an I/O retry signal. It does not prove physical disk failure by itself.',
            'v1.3.4 separates UserProvidedTopology from DetectedTopology. Automated findings must prefer detected-storage-topology.json over storage_hints.json when they conflict.',
            'If Windows reports Intel Raid 0/1 Volume objects, the primary diagnostic path is the Intel RST/VMD/RAID driver and the underlying SATA HDD path, not a simple JBOD-only assumption.',
            'Windows Update / rollback correlation should compare disk 153 timestamps with Setup, WindowsUpdateClient and Kernel-Boot events.'
        )
    }
}

function New-TopFindingsForStorage {
    param($RiskSummary, $Correlation = @(), $HintValidation = $null, $DetectedTopology = $null)
    $findings = @()
    if ($null -eq $RiskSummary) { return @() }
    if ($RiskSummary.Disk153Count -gt 0) {
        $findings += [PSCustomObject]@{
            Severity='High'
            Area='Storage'
            Title='Disk Event ID 153 detected on storage path with Intel RST / RAID volume context'
            Evidence=("Disk153Count={0}; HintedDiskNumberEvents={1}" -f $RiskSummary.Disk153Count, $RiskSummary.Disk153EventsOnHintedDiskNumbers)
            Meaning='Storage I/O retry pattern. Treat as storage path evidence; confirm whether it correlates with update/rollback windows before Windows Update repair.'
        }
    }
    try {
        if ($HintValidation -and @($HintValidation.Mismatches).Count -gt 0) {
            $findings += [PSCustomObject]@{ Severity='Medium'; Area='StorageTopology'; Title='User storage hint conflicts with detected Windows storage topology'; Evidence=(@($HintValidation.Mismatches | ForEach-Object { $_.Code }) -join ', '); Meaning='storage_hints.json is useful context, but detected-storage-topology.json should be treated as stronger evidence.' }
        }
    } catch { }
    foreach ($d in @($RiskSummary.ByDiskNumber)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$d.DiskNumber)) {
            $findings += [PSCustomObject]@{ Severity=$d.Severity; Area='Storage'; Title=("Disk {0} has Event ID 153 retry events" -f $d.DiskNumber); Evidence=("Count={0}" -f $d.Count); Meaning='Map this disk to RAID volume, physical disk candidates, controller and volume before repair actions.' }
        }
    }
    return $findings
}

function New-RiskIndicatorsForStorage {
    param($RiskSummary, $HintValidation = $null, $DetectedTopology = $null)
    $items = @()
    if ($null -eq $RiskSummary) { return @() }
    if ($RiskSummary.Disk153Count -gt 0) { $items += [PSCustomObject]@{ Code='StorageIoRetry153'; Strength=$RiskSummary.RiskLevel; Count=$RiskSummary.Disk153Count; Description='Disk provider Event ID 153 indicates I/O retry. Investigate storage path before aggressive Windows Update repair.' } }
    if ($RiskSummary.Disk153EventsOnHintedDiskNumbers -gt 0) { $items += [PSCustomObject]@{ Code='HintedDiskNumbersHave153'; Strength='ContextMatched'; Count=$RiskSummary.Disk153EventsOnHintedDiskNumbers; Description='Disk 153 events occurred on disk numbers present in storage_hints.json, but hint validity must be checked against detected topology.' } }
    try { if ($HintValidation -and @($HintValidation.Mismatches).Count -gt 0) { $items += [PSCustomObject]@{ Code='StorageHintMismatch'; Strength='DetectedMismatch'; Count=@($HintValidation.Mismatches).Count; Description='User-provided storage hint conflicts with detected RAID/size topology. Use detected topology for automated conclusions.' } } } catch { }
    try { if ($DetectedTopology -and @($DetectedTopology.PresentRaidVolumes).Count -gt 0) { $items += [PSCustomObject]@{ Code='IntelRaidVolumeDetected'; Strength='DetectedTopology'; Count=@($DetectedTopology.PresentRaidVolumes).Count; Description='Windows reports Intel RAID volume objects in the affected storage path.' } } } catch { }
    return $items
}

function New-SuggestedNextEvidenceForStorage {
    param($RiskSummary, $HintValidation = $null, $TargetKbCorrelation = $null)
    if ($null -eq $RiskSummary -or [int]$RiskSummary.Disk153Count -eq 0) {
        return @([PSCustomObject]@{ Priority='Info'; Evidence='No Disk Event ID 153 events detected in the selected time window'; Reason='Storage path is not a primary P0 signal for this package; review servicing, Windows Update, WER and driver evidence.' })
    }
    $items = @(
        [PSCustomObject]@{ Priority='P0'; Evidence='Open Intel RST / motherboard RAID management UI and export volume/member status if available'; Reason='Detected Windows topology may expose RAID volumes instead of raw JBOD disks.' },
        [PSCustomObject]@{ Priority='P0'; Evidence='Collect SMART / manufacturer HDD health data for the underlying physical disks, especially ST16000NT001 candidates'; Reason='Differentiate controller/path retry from drive-level media or command timeout issues.' },
        [PSCustomObject]@{ Priority='P0'; Evidence='Verify whether Disk 2 = Intel Raid 0 Volume and Disk 3 = Intel Raid 1 Volume are intentional configuration'; Reason='The user hint must be reconciled with detected topology before repair decisions.' },
        [PSCustomObject]@{ Priority='P1'; Evidence='Check SATA data cable, SATA power and motherboard port path for HDDs behind the Intel RST/VMD controller'; Reason='Event 153 can be caused by transient storage path retries.' },
        [PSCustomObject]@{ Priority='P1'; Evidence='Review Intel RST/VMD driver version and motherboard BIOS/chipset storage firmware status'; Reason='Intel RAID/VMD path makes the controller driver diagnostically relevant.' }
    )
    try { if ($TargetKbCorrelation -and $TargetKbCorrelation.Status -eq 'NoDirectMatchInCorrelationWindow') { $items += [PSCustomObject]@{ Priority='P1'; Evidence='Run a targeted KB log collection for the failing KB and compare with target-kb-correlation.json'; Reason='No direct target KB string was found in Disk 153 correlation windows in the system-level package.' } } } catch { }
    return $items
}

function Collect-StorageEvidence {
    param([string]$PackageRoot, [datetime]$StartTime, [string]$TargetKB = '')
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
    $detectedTopology = New-DetectedStorageTopology -Correlation $correlation -StorageResult $result -Controllers $controllers -Drivers $storageDrivers -PnpDevices $pnpStorageDevices
    $hintValidation = Test-StorageHintAgainstDetected -Hints $hints -DetectedTopology $detectedTopology -Correlation $correlation
    $targetKbCorrelation = New-TargetKbCorrelation -TargetKB $TargetKB -EventCorrelation $eventCorrelation
    $riskSummary = New-StorageRiskSummary -EventMap $eventMap -Correlation $correlation -Hints $hints -Timeline $timeline -DetectedTopology $detectedTopology -HintValidation $hintValidation
    $topFindings = @(New-TopFindingsForStorage -RiskSummary $riskSummary -Correlation $correlation -HintValidation $hintValidation -DetectedTopology $detectedTopology)
    $riskIndicators = @(New-RiskIndicatorsForStorage -RiskSummary $riskSummary -HintValidation $hintValidation -DetectedTopology $detectedTopology)
    $suggestedNextEvidence = @(New-SuggestedNextEvidenceForStorage -RiskSummary $riskSummary -HintValidation $hintValidation -TargetKbCorrelation $targetKbCorrelation)

    Write-JsonSafe -InputObject $eventMap -Path (Join-Path $root 'disk-event-map.json') -Depth 12
    Write-JsonSafe -InputObject $aggregate -Path (Join-Path $root 'disk-event-153-aggregate.json') -Depth 10
    Write-JsonSafe -InputObject $timeline -Path (Join-Path $root 'disk153-timeline.json') -Depth 10
    Write-JsonSafe -InputObject $correlation -Path (Join-Path $root 'disk153-device-correlation.json') -Depth 14
    Write-JsonSafe -InputObject $eventCorrelation -Path (Join-Path $root 'disk153-update-setup-correlation.json') -Depth 12
    Write-JsonSafe -InputObject $riskSummary -Path (Join-Path $root 'storage-risk-summary.json') -Depth 12
    Write-JsonSafe -InputObject $detectedTopology -Path (Join-Path $root 'detected-storage-topology.json') -Depth 14
    Write-JsonSafe -InputObject $hintValidation -Path (Join-Path $root 'storage-hint-validation.json') -Depth 12
    Write-JsonSafe -InputObject $detectedTopology.RaidVolumeMap -Path (Join-Path $root 'raid-volume-map.json') -Depth 12
    Write-JsonSafe -InputObject $detectedTopology.PhysicalDiskCandidateMap -Path (Join-Path $root 'physical-disk-candidate-map.json') -Depth 12
    Write-JsonSafe -InputObject $targetKbCorrelation -Path (Join-Path $analysisRoot 'target-kb-correlation.json') -Depth 12
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
        Disk153KnownIntelRaidJbodCount=$riskSummary.Disk153EventsOnHintedDiskNumbers
        StorageHintMismatchCount=@($hintValidation.Mismatches).Count
        ControllerDriverMap='storage/controller-driver-map.json'
        Disk153Timeline='storage/disk153-timeline.json'
        Disk153DeviceCorrelation='storage/disk153-device-correlation.json'
        Disk153UpdateSetupCorrelation='storage/disk153-update-setup-correlation.json'
        StorageRiskSummary='storage/storage-risk-summary.json'
        DetectedStorageTopology='storage/detected-storage-topology.json'
        StorageHintValidation='storage/storage-hint-validation.json'
        RaidVolumeMap='storage/raid-volume-map.json'
        PhysicalDiskCandidateMap='storage/physical-disk-candidate-map.json'
        TargetKBCorrelation='analysis/target-kb-correlation.json'
        TopFindings=$topFindings
        RiskIndicators=$riskIndicators
        SuggestedNextEvidence=$suggestedNextEvidence
        EvidenceGapSummary=$evidenceGapSummary
        EvidenceGapCount=try { [int]$evidenceGapSummary.GapCount } catch { 0 }
        ServicingRiskSummary=$servicingRiskSummary
        WindowsUpdateSignalSummary=$windowsUpdateSignalSummary
        P1NormalizerHandoff=@('WERNormalizer','SetupAPINormalizer','CBSHResultNormalizer','DriverPnPProblemNormalizer','EventCorrelationNormalizer','WindowsUpdateErrorNormalizer')
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



function Get-TimeRangeFromObjectsSafe {
    param(
        [AllowNull()]$Items = @(),
        [string]$PropertyName = 'TimeCreated'
    )
    $times = @()
    foreach ($item in @($Items)) {
        try {
            $value = Get-ObjectPropertyValueSafe -Object $item -Name $PropertyName -Default $null
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                $times += [datetime]$value
            }
        }
        catch { }
    }
    if ($times.Count -eq 0) {
        return [PSCustomObject]@{ Oldest=$null; Newest=$null; Count=0 }
    }
    $sorted = @($times | Sort-Object)
    return [PSCustomObject]@{
        Oldest = ($sorted | Select-Object -First 1).ToString('o')
        Newest = ($sorted | Select-Object -Last 1).ToString('o')
        Count = $sorted.Count
    }
}

function Read-JsonFileSafe {
    param([string]$Path, [AllowNull()]$Default = $null)
    try {
        if (Test-Path -LiteralPath $Path) {
            return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        }
    }
    catch { }
    return $Default
}

function Get-RegexMatchesFromTextSafe {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [int]$Limit = 200
    )
    $items = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    try {
        $matches = [regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($m in $matches) {
            if ($items.Count -ge $Limit) { break }
            $items += [string]$m.Value
        }
    }
    catch { }
    return @($items)
}

function New-ServicingRiskSummary {
    param([string]$PackageRoot)
    $servicingRoot = Join-Path $PackageRoot 'servicing'
    $copiedRoot = Join-Path $PackageRoot 'copied_logs'
    $hresultSummaryPath = Join-Path $servicingRoot 'cbs-hresult-summary.json'
    $hresults = @(Read-JsonFileSafe -Path $hresultSummaryPath -Default @())
    $dismScanPath = Join-Path $servicingRoot 'dism-scanhealth.txt'
    $sfcVerifyPath = Join-Path $servicingRoot 'sfc-verifyonly.txt'
    $dismCheckHealthPath = Join-Path $copiedRoot 'dism.log'
    $dismScanText = ''
    $sfcText = ''
    try { if (Test-Path -LiteralPath $dismScanPath) { $dismScanText = Get-Content -LiteralPath $dismScanPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } } catch { }
    try { if (Test-Path -LiteralPath $sfcVerifyPath) { $sfcText = Get-Content -LiteralPath $sfcVerifyPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } } catch { }

    $topHResults = @($hresults | Sort-Object Count -Descending | Select-Object -First 20)
    $highSignal = $false
    $reasons = @()
    foreach ($hr in @($topHResults)) {
        try {
            if ([int]$hr.Count -ge 10 -and [string]$hr.HResult -ne '0x00000000') {
                $highSignal = $true
                $reasons += ('Frequent CBS HRESULT {0} Count={1}' -f $hr.HResult, $hr.Count)
            }
        } catch { }
    }
    if ($dismScanText -match 'repairable|sérült|corruption|component store') { $highSignal = $true; $reasons += 'DISM ScanHealth text contains repair/corruption-related wording.' }
    [PSCustomObject]@{
        SchemaVersion='diagframework.servicing.risk.summary.v1'
        Status=if ($highSignal) { 'SignalDetected' } else { 'NoStrongSignal' }
        TopHResults=$topHResults
        DismScanHealthFile='servicing/dism-scanhealth.txt'
        SfcVerifyOnlyFile='servicing/sfc-verifyonly.txt'
        HasFrequentNonZeroHRESULT=$highSignal
        Reasons=$reasons
        SuggestedNormalizer='CBSHResultNormalizer'
        Meaning='P0 servicing summary only. Detailed classification belongs to the P1 CBSHResultNormalizer.'
    }
}

function New-WindowsUpdateSignalSummary {
    param([string]$PackageRoot, [string]$TargetKB = '')
    $wuRoot = Join-Path $PackageRoot 'windows_update'
    $logPath = Join-Path $wuRoot 'WindowsUpdate.generated.log'
    $text = ''
    try { if (Test-Path -LiteralPath $logPath) { $text = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } } catch { }
    $hresults = @(Get-RegexMatchesFromTextSafe -Text $text -Pattern '0x[0-9a-fA-F]{8}' -Limit 5000 | Group-Object | Sort-Object Count -Descending | Select-Object -First 30 | ForEach-Object { [PSCustomObject]@{ Code=$_.Name; Count=$_.Count } })
    $kbMatches = @(Get-RegexMatchesFromTextSafe -Text $text -Pattern 'KB\d{6,8}' -Limit 5000 | Group-Object | Sort-Object Count -Descending | Select-Object -First 30 | ForEach-Object { [PSCustomObject]@{ KB=$_.Name; Count=$_.Count } })
    $targetMatches = @()
    if (-not [string]::IsNullOrWhiteSpace($TargetKB)) { $targetMatches = @($kbMatches | Where-Object { [string]$_.KB -ieq [string]$TargetKB }) }
    [PSCustomObject]@{
        SchemaVersion='diagframework.windowsupdate.signal.summary.v1'
        LogPath='windows_update/WindowsUpdate.generated.log'
        LogPresent=(Test-Path -LiteralPath $logPath)
        TargetKB=$TargetKB
        TargetKBDirectMatchCount=if ($targetMatches.Count -gt 0) { [int]$targetMatches[0].Count } else { 0 }
        TopErrorCodes=$hresults
        TopKBs=$kbMatches
        SuggestedNormalizer='WindowsUpdateErrorNormalizer'
        Meaning='P0 lightweight extraction. Detailed error classification belongs to the P1 WindowsUpdateErrorNormalizer.'
    }
}

function New-P0EvidenceGapSummary {
    param(
        [string]$PackageRoot,
        [string]$TargetKB = '',
        $Issues = @(),
        $EventSummary = @(),
        $P0Results = @(),
        $ServicingRisk = $null,
        $WindowsUpdateSignal = $null,
        $WerSummary = $null
    )
    $gaps = @()
    $notes = @()
    foreach ($issue in @($Issues)) {
        if ([string]$issue.Code -eq 'StorageEvidenceFailed') {
            $gaps += [PSCustomObject]@{ Priority='P0'; Code='StorageEvidenceFailed'; Area='Storage'; Action='Fix storage evidence collection so absence of Disk 153 is represented as NoSignal, not as module failure.'; Reason=$issue.Message }
        }
    }
    $truncated = @(@($EventSummary) | Where-Object { [bool](Get-ObjectPropertyValueSafe -Object $_ -Name 'Truncated' -Default $false) })
    if ($truncated.Count -gt 0) {
        $gaps += [PSCustomObject]@{ Priority='P1'; Code='JsonlTruncatedRawEvtxAvailable'; Area='Events'; Action='P1 normalizers should prefer raw EVTX or increase MaxEvents for high-volume logs.'; Reason=('Truncated logs: ' + (@($truncated | ForEach-Object { $_.LogName }) -join ', ')) }
    }
    if ([string]::IsNullOrWhiteSpace($TargetKB)) {
        $notes += [PSCustomObject]@{ Code='TargetKBNotSupplied'; Area='WindowsUpdate'; Meaning='System-level evidence package was created without TargetKB. This is valid, but direct KB correlation cannot be decided.' }
    }
    try {
        if ($ServicingRisk -and $ServicingRisk.Status -eq 'SignalDetected') {
            $gaps += [PSCustomObject]@{ Priority='P0'; Code='ServicingSignalDetected'; Area='Servicing'; Action='Feed servicing/cbs-hresult-summary.json and DISM/SFC outputs into CBSHResultNormalizer.'; Reason=(@($ServicingRisk.Reasons) -join '; ') }
        }
    } catch { }
    try {
        $werCount = [int](Get-ObjectPropertyValueSafe -Object $WerSummary -Name 'ReportCount' -Default 0)
        if ($werCount -ge 300) {
            $gaps += [PSCustomObject]@{ Priority='P1'; Code='HighWERVolume'; Area='WER'; Action='Use WERNormalizer to reduce WER noise and separate vendor/app crashes from update-relevant failures.'; Reason=('WER ReportCount=' + $werCount) }
        }
    } catch { }
    try {
        if ($WindowsUpdateSignal -and @($WindowsUpdateSignal.TopErrorCodes).Count -gt 0) {
            $gaps += [PSCustomObject]@{ Priority='P1'; Code='WindowsUpdateErrorsPresent'; Area='WindowsUpdate'; Action='Use WindowsUpdateErrorNormalizer to classify TopErrorCodes and correlate with CBS/Setup events.'; Reason=('Top error code=' + [string]$WindowsUpdateSignal.TopErrorCodes[0].Code + ' Count=' + [string]$WindowsUpdateSignal.TopErrorCodes[0].Count) }
        }
    } catch { }
    try {
        $cbsBridge = (@($P0Results) | Where-Object { $_.Area -eq 'CbsPersistEvidence' } | Select-Object -First 1).Result
        if ($cbsBridge -and [int](Get-ObjectPropertyValueSafe -Object $cbsBridge -Name 'CbsPersistCabCount' -Default 0) -eq 0) {
            $notes += [PSCustomObject]@{ Code='NoCbsPersistCabFound'; Area='Servicing'; Meaning='No CbsPersist CAB files were collected. This can be normal, but CBSHResultNormalizer should use available CBS/DISM logs.' }
        }
    } catch { }
    try {
        $mini = (@($P0Results) | Where-Object { $_.Area -eq 'MiniDumpWinDbg' } | Select-Object -First 1).Result
        if ($mini -and [string]$mini.Status -eq 'CdbNotFound' -and [int]$mini.DumpCount -gt 0) {
            $gaps += [PSCustomObject]@{ Priority='P0'; Code='MiniDumpPresentButCdbMissing'; Area='CrashDump'; Action='Install Microsoft Debugging Tools for Windows or run MiniDumpWinDbgAnalyzer on a machine with cdb.exe.'; Reason=('DumpCount=' + [string]$mini.DumpCount) }
        }
        elseif ($mini -and [int]$mini.DumpCount -gt 0) {
            $gaps += [PSCustomObject]@{ Priority='P1'; Code='MiniDumpAnalysisAvailable'; Area='CrashDump'; Action='Feed analysis/windbg/normalized/*.json into WERNormalizer, DriverPnPProblemNormalizer and EventCorrelationNormalizer.'; Reason=('DumpCount=' + [string]$mini.DumpCount + ' Status=' + [string]$mini.Status) }
        }
    } catch { }
    try {
        $advisor = (@($P0Results) | Where-Object { $_.Area -eq 'RepairSourceAdvisor' } | Select-Object -First 1).Result
        if ($advisor -and [string]$advisor.Status -eq 'RepairSourceIssueCandidate') {
            $gaps += [PSCustomObject]@{ Priority='P0'; Code='RepairSourceIssueCandidate'; Area='Servicing'; Action='Do not prioritize generic WU reset. Collect/prepare matching repair source and let P1 CBSHResultNormalizer validate 0x800F0915/repair-content evidence.'; Reason='RepairSourceAdvisor detected repair-source-missing signals.' }
        }
    } catch { }
    [PSCustomObject]@{
        SchemaVersion='diagframework.p0.evidence.gap.summary.v1.4.1'
        CompatibleP1Version=$P1NormalizerCompatibleVersion
        Source='P0EvidenceCollectorRuntime'
        GapCount=@($gaps).Count
        NoteCount=@($notes).Count
        Gaps=$gaps
        Notes=$notes
        P1Handoff=@(
            'WERNormalizer',
            'SetupAPINormalizer',
            'CBSHResultNormalizer',
            'DriverPnPProblemNormalizer',
            'EventCorrelationNormalizer',
            'WindowsUpdateErrorNormalizer'
        )
    }
}


function Get-P1NormalizerHandoffDefinition {
    [PSCustomObject]@{
        SchemaVersion='diagframework.p1.normalizer.handoff.definition.v1'
        CompatibleP1Version=$P1NormalizerCompatibleVersion
        SourceCollectorVersion=$ModuleVersion
        Normalizers=@(
            [PSCustomObject]@{ Id='WERNormalizer'; Version='1.4.0'; Input=@('wer/wer-summary.json','wer/wer-reports.json','analysis/windbg/normalized/minidump-summary.json'); Purpose='WER és crash jellegű zaj normalizálása.' },
            [PSCustomObject]@{ Id='SetupAPINormalizer'; Version='1.4.0'; Input=@('copied_logs/setupapi.dev.log','copied_logs/setupapi.setup.log'); Purpose='Driver telepítési események és hibák egységesítése.' },
            [PSCustomObject]@{ Id='CBSHResultNormalizer'; Version='1.4.0'; Input=@('servicing/cbs-hresult-summary.json','analysis/servicing/cbs-log-inventory.json','copied_logs/CBS'); Purpose='CBS/DISM HRESULT kódok és servicing állapotok normalizálása.' },
            [PSCustomObject]@{ Id='DriverPnPProblemNormalizer'; Version='1.4.0'; Input=@('drivers/pnp-signed-drivers.json','storage/pnp-storage-devices.json','analysis/windbg/normalized/suspect-drivers.json'); Purpose='PnP problémák és driverjelöltek összekötése.' },
            [PSCustomObject]@{ Id='EventCorrelationNormalizer'; Version='1.4.0'; Input=@('events/event-summary.json','events/raw','analysis/kb-context-handoff.json','analysis/windbg/normalized/crash-timeline.json'); Purpose='KB, CBS, DISM, WER, reboot és crash idővonal korreláció.' },
            [PSCustomObject]@{ Id='WindowsUpdateErrorNormalizer'; Version='1.4.0'; Input=@('windows_update/windowsupdate-signal-summary.json','windows_update/WindowsUpdate.generated.log','copied_logs/ReportingEvents.log'); Purpose='Windows Update hibakódok és KB-kontextus normalizálása.' }
        )
    }
}

function Find-CdbExecutable {
    $candidates = @()
    try { if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe') } } catch { }
    try { if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Windows Kits\10\Debuggers\x64\cdb.exe') } } catch { }
    try { if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\arm64\cdb.exe') } } catch { }
    try {
        $cmd = Get-Command cdb.exe -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $candidates += $cmd.Source }
    } catch { }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) { return [string]$candidate }
    }
    return $null
}

function Get-RegexValueSafe {
    param([AllowNull()][string]$Text, [string]$Pattern, [int]$Group = 1)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        $m = [regex]::Match($Text, $Pattern)
        if ($m.Success -and $m.Groups.Count -gt $Group) { return $m.Groups[$Group].Value.Trim() }
    } catch { }
    return $null
}

function Collect-CbsPersistEvidence {
    param([string]$PackageRoot)
    $analysisRoot = Join-Path $PackageRoot 'analysis/servicing'
    $cbsDest = Join-Path $PackageRoot 'copied_logs/CBS'
    $dismDest = Join-Path $PackageRoot 'copied_logs/DISM'
    $extractDest = Join-Path $cbsDest 'extracted'
    New-DirectorySafe $analysisRoot; New-DirectorySafe $cbsDest; New-DirectorySafe $dismDest; New-DirectorySafe $extractDest

    $inventory = @()
    $seen = @{}
    $patterns = @(
        [PSCustomObject]@{ Area='CBS'; Root=$cbsDest; Pattern=(Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'); ExtractCab=$false },
        [PSCustomObject]@{ Area='CBS'; Root=$cbsDest; Pattern=(Join-Path $env:SystemRoot 'Logs\CBS\CbsPersist*.log'); ExtractCab=$false },
        [PSCustomObject]@{ Area='CBS'; Root=$cbsDest; Pattern=(Join-Path $env:SystemRoot 'Logs\CBS\CbsPersist*.cab'); ExtractCab=$true },
        [PSCustomObject]@{ Area='DISM'; Root=$dismDest; Pattern=(Join-Path $env:SystemRoot 'Logs\DISM\dism.log'); ExtractCab=$false },
        [PSCustomObject]@{ Area='DISM'; Root=$dismDest; Pattern=(Join-Path $env:SystemRoot 'Logs\DISM\dism*.log'); ExtractCab=$false }
    )

    $expandPath = $null
    try { $expandPath = (Get-Command expand.exe -ErrorAction SilentlyContinue).Source } catch { $expandPath = $null }

    foreach ($spec in $patterns) {
        $files = @()
        try { $files = @(Get-ChildItem -Path $spec.Pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) } catch { $files = @() }
        foreach ($file in $files) {
            if ($seen.ContainsKey($file.FullName)) { continue }
            $seen[$file.FullName] = $true
            $dest = Join-Path $spec.Root $file.Name
            $record = [ordered]@{
                SchemaVersion='diagframework.cbs.persist.inventory.item.v1'
                Area=$spec.Area
                SourcePath=$file.FullName
                RelativePath=(Get-RelativePathSafe $PackageRoot $dest)
                SizeBytes=$file.Length
                LastWriteTime=$file.LastWriteTime.ToString('o')
                IsCab=(([string]$file.Extension).ToLowerInvariant() -eq '.cab')
                Copied=$false
                Extracted=$false
                ExtractedFileCount=0
                ExtractedRoot=$null
                Errors=@()
            }
            try {
                Copy-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
                $record.Copied = $true
            } catch { $record.Errors += ('CopyError: ' + $_.Exception.Message) }

            if ($record.Copied -and $record.IsCab -and [bool]$spec.ExtractCab) {
                if ([string]::IsNullOrWhiteSpace($expandPath)) {
                    $record.Errors += 'ExpandExeNotFound: CAB copied but not extracted.'
                }
                else {
                    try {
                        $safeName = [IO.Path]::GetFileNameWithoutExtension($file.Name)
                        $outDir = Join-Path $extractDest $safeName
                        New-DirectorySafe $outDir
                        $expandOut = Join-Path $outDir 'expand.stdout.txt'
                        $expandErr = Join-Path $outDir 'expand.stderr.txt'
                        $p = Start-Process -FilePath $expandPath -ArgumentList @('-F:*', $dest, $outDir) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $expandOut -RedirectStandardError $expandErr -ErrorAction Stop
                        $record.Extracted = ($p.ExitCode -eq 0)
                        $record.ExtractedRoot = Get-RelativePathSafe $PackageRoot $outDir
                        $record.ExtractedFileCount = @(Get-ChildItem -LiteralPath $outDir -File -Recurse -ErrorAction SilentlyContinue).Count
                        if ($p.ExitCode -ne 0) { $record.Errors += ('ExpandExitCode: ' + [string]$p.ExitCode) }
                    } catch { $record.Errors += ('ExpandError: ' + $_.Exception.Message) }
                }
            }
            $inventory += [PSCustomObject]$record
        }
    }

    Write-JsonSafe -InputObject $inventory -Path (Join-Path $analysisRoot 'cbs-log-inventory.json') -Depth 12
    $cbsCount = @($inventory | Where-Object { $_.Area -eq 'CBS' }).Count
    $dismCount = @($inventory | Where-Object { $_.Area -eq 'DISM' }).Count
    $cabCount = @($inventory | Where-Object { $_.IsCab }).Count
    $extractedCount = @($inventory | Where-Object { $_.Extracted }).Count
    $summary = [PSCustomObject]@{
        SchemaVersion='diagframework.cbs.persist.collection.summary.v1'
        Status=if($cbsCount -gt 0 -or $dismCount -gt 0){'Collected'}else{'NoLogsFound'}
        CbsLogCount=$cbsCount
        DismLogCount=$dismCount
        CbsPersistCabCount=$cabCount
        ExtractedCabCount=$extractedCount
        Inventory='analysis/servicing/cbs-log-inventory.json'
        P1Handoff='CBSHResultNormalizer'
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $analysisRoot 'cbs-persist-collection-summary.json') -Depth 10
    return $summary
}

function Invoke-MiniDumpCdbAnalysis {
    param([string]$PackageRoot)
    $dumpRoot = Join-Path $PackageRoot 'copied_logs/Minidump'
    $windbgRoot = Join-Path $PackageRoot 'analysis/windbg'
    $rawRoot = Join-Path $windbgRoot 'raw'
    $xmlRoot = Join-Path $windbgRoot 'xml'
    $normRoot = Join-Path $windbgRoot 'normalized'
    New-DirectorySafe $rawRoot; New-DirectorySafe $xmlRoot; New-DirectorySafe $normRoot

    $dumps = @()
    try { if (Test-Path -LiteralPath $dumpRoot) { $dumps = @(Get-ChildItem -LiteralPath $dumpRoot -Filter '*.dmp' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime) } } catch { $dumps = @() }
    $cdb = Find-CdbExecutable
    $discovery = [PSCustomObject]@{
        SchemaVersion='diagframework.windbg.cdb.discovery.v1'
        CdbPath=$cdb
        CdbFound=(-not [string]::IsNullOrWhiteSpace($cdb))
        DumpCount=@($dumps).Count
        RawOutputRoot='analysis/windbg/raw'
        XmlOutputRoot='analysis/windbg/xml'
        NormalizedRoot='analysis/windbg/normalized'
        Note='CDB is part of Microsoft Debugging Tools for Windows. If absent, the collector records warnings and preserves raw dumps.'
    }
    Write-JsonSafe -InputObject $discovery -Path (Join-Path $windbgRoot 'cdb-discovery.json') -Depth 8

    $results = @()
    if (@($dumps).Count -eq 0) {
        $summary = [PSCustomObject]@{ SchemaVersion='diagframework.windbg.minidump.summary.v1'; Status='NoDumpsFound'; DumpCount=0; CdbFound=$discovery.CdbFound; Results=@(); SuspectDrivers=@(); P1Handoff=@('WERNormalizer','DriverPnPProblemNormalizer','EventCorrelationNormalizer') }
        Write-JsonSafe -InputObject @() -Path (Join-Path $normRoot 'minidump-summary.json') -Depth 12
        Write-JsonSafe -InputObject @() -Path (Join-Path $normRoot 'suspect-drivers.json') -Depth 12
        Write-JsonSafe -InputObject @() -Path (Join-Path $normRoot 'crash-timeline.json') -Depth 12
        Write-JsonSafe -InputObject @() -Path (Join-Path $normRoot 'crash-update-correlation.json') -Depth 12
        Write-JsonSafe -InputObject @() -Path (Join-Path $normRoot 'crash-blackbox-summary.json') -Depth 12
        Write-JsonSafe -InputObject $summary -Path (Join-Path $normRoot 'windbg-analysis-summary.json') -Depth 12
        return $summary
    }

    if ([string]::IsNullOrWhiteSpace($cdb)) {
        foreach ($dump in $dumps) {
            $results += [PSCustomObject]@{
                dumpFile=Get-RelativePathSafe $PackageRoot $dump.FullName
                dumpTimestampLocal=$dump.LastWriteTime.ToString('o')
                analysisStatus='CdbNotFound'
                bugCheckCode=$null; bugCheckName=$null; bugCheckParameters=@(); probablyCausedBy=$null; moduleName=$null; imageName=$null; failureBucketId=$null; processName=$null
                stackTextExtracted=$false; loadedModulesExtracted=$false
                hasBlackboxBSD=$false; hasBlackboxPNP=$false; hasBlackboxNTFS=$false; hasBlackboxWinlogon=$false
                rawLogPath=$null; xmlPath=$null; confidence='NotAnalyzed'; notes=@('cdb.exe was not found. Install Microsoft Debugging Tools for Windows for automated dump analysis.')
            }
        }
    }
    else {
        $symbolCache = Join-Path $windbgRoot 'symbols'
        New-DirectorySafe $symbolCache
        $symbolPath = 'srv*' + $symbolCache + '*https://msdl.microsoft.com/download/symbols'
        foreach ($dump in $dumps) {
            $safeName = [IO.Path]::GetFileNameWithoutExtension($dump.Name)
            $rawLog = Join-Path $rawRoot ($safeName + '.windbg.txt')
            $xmlPath = Join-Path $xmlRoot ($safeName + '.analyze.xml')
            $analysisStatus = 'Success'
            $errorText = $null
            try {
                $xmlCommand = '!analyze -v -xml -xmf "' + $xmlPath + '"'
                $commands = @(
                    '.symfix',
                    ('.sympath+ ' + $symbolPath),
                    '.reload',
                    'vertarget',
                    '!analyze -show',
                    '!analyze -v',
                    $xmlCommand,
                    '.bugcheck',
                    'kv',
                    'lm N T',
                    '!blackboxbsd',
                    '!blackboxpnp',
                    '!blackboxntfs',
                    '!blackboxwinlogon',
                    'q'
                ) -join '; '
                & $cdb -z $dump.FullName -c $commands -logo $rawLog | Out-Null
            }
            catch {
                $analysisStatus = 'AnalysisFailed'
                $errorText = $_.Exception.Message
            }
            $text = ''
            try { if (Test-Path -LiteralPath $rawLog) { $text = Get-Content -LiteralPath $rawLog -Raw -ErrorAction SilentlyContinue } } catch { $text = '' }
            $results += [PSCustomObject]@{
                dumpFile=Get-RelativePathSafe $PackageRoot $dump.FullName
                dumpTimestampLocal=$dump.LastWriteTime.ToString('o')
                analysisStatus=$analysisStatus
                bugCheckCode=Get-RegexValueSafe -Text $text -Pattern '(?im)^BugCheck\s+([^,\r\n]+)'
                bugCheckName=Get-RegexValueSafe -Text $text -Pattern '(?im)^([A-Z_]+)\s+\([0-9a-fA-Fx]+'
                bugCheckParameters=@()
                probablyCausedBy=Get-RegexValueSafe -Text $text -Pattern '(?im)^Probably caused by\s*:\s*(.+)$'
                moduleName=Get-RegexValueSafe -Text $text -Pattern '(?im)^\s*MODULE_NAME:\s*(.+)$'
                imageName=Get-RegexValueSafe -Text $text -Pattern '(?im)^\s*IMAGE_NAME:\s*(.+)$'
                failureBucketId=Get-RegexValueSafe -Text $text -Pattern '(?im)^\s*FAILURE_BUCKET_ID:\s*(.+)$'
                processName=Get-RegexValueSafe -Text $text -Pattern '(?im)^\s*PROCESS_NAME:\s*(.+)$'
                stackTextExtracted=($text -match '(?im)^STACK_TEXT:')
                loadedModulesExtracted=($text -match '(?im)^start\s+end\s+module name|^Loaded Module List')
                hasBlackboxBSD=($text -match '(?i)BLACKBOXBSD|BlackBoxBSD')
                hasBlackboxPNP=($text -match '(?i)BLACKBOXPNP|BlackBoxPNP')
                hasBlackboxNTFS=($text -match '(?i)BLACKBOXNTFS|BlackBoxNTFS')
                hasBlackboxWinlogon=($text -match '(?i)BLACKBOXWINLOGON|BlackBoxWinlogon')
                rawLogPath=if(Test-Path -LiteralPath $rawLog){Get-RelativePathSafe $PackageRoot $rawLog}else{$null}
                xmlPath=if(Test-Path -LiteralPath $xmlPath){Get-RelativePathSafe $PackageRoot $xmlPath}else{$null}
                confidence='NeedsManualReview'
                notes=@($errorText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            }
        }
    }

    $suspects = @(
        @($results) |
        ForEach-Object {
            $name = if(-not [string]::IsNullOrWhiteSpace($_.imageName)){ $_.imageName } elseif(-not [string]::IsNullOrWhiteSpace($_.moduleName)){ $_.moduleName } elseif(-not [string]::IsNullOrWhiteSpace($_.probablyCausedBy)){ $_.probablyCausedBy } else { $null }
            if($name){ [PSCustomObject]@{ DriverName=$name; DumpFile=$_.dumpFile; Time=$_.dumpTimestampLocal; RawLogPath=$_.rawLogPath } }
        } |
        Group-Object DriverName |
        Sort-Object Count -Descending |
        ForEach-Object { [PSCustomObject]@{ driverName=$_.Name; occurrences=$_.Count; evidenceSources=@($_.Group | ForEach-Object { $_.RawLogPath }); firstSeen=(@($_.Group.Time) | Sort-Object | Select-Object -First 1); lastSeen=(@($_.Group.Time) | Sort-Object | Select-Object -Last 1); role='Kernel driver candidate, not confirmed root cause'; confidence='CandidateOnly' } }
    )
    $timeline = @(@($results) | Sort-Object dumpTimestampLocal | ForEach-Object { [PSCustomObject]@{ Time=$_.dumpTimestampLocal; DumpFile=$_.dumpFile; BugCheckCode=$_.bugCheckCode; ProbablyCausedBy=$_.probablyCausedBy; ImageName=$_.imageName; RawLogPath=$_.rawLogPath; AnalysisStatus=$_.analysisStatus } })
    $blackbox = @(@($results) | ForEach-Object { [PSCustomObject]@{ DumpFile=$_.dumpFile; HasBlackboxBSD=$_.hasBlackboxBSD; HasBlackboxPNP=$_.hasBlackboxPNP; HasBlackboxNTFS=$_.hasBlackboxNTFS; HasBlackboxWinlogon=$_.hasBlackboxWinlogon } })

    Write-JsonSafe -InputObject @($results) -Path (Join-Path $normRoot 'minidump-summary.json') -Depth 12
    Write-JsonSafe -InputObject @($suspects) -Path (Join-Path $normRoot 'suspect-drivers.json') -Depth 12
    Write-JsonSafe -InputObject @($timeline) -Path (Join-Path $normRoot 'crash-timeline.json') -Depth 12
    Write-JsonSafe -InputObject @() -Path (Join-Path $normRoot 'crash-update-correlation.json') -Depth 12
    Write-JsonSafe -InputObject @($blackbox) -Path (Join-Path $normRoot 'crash-blackbox-summary.json') -Depth 12

    $summary = [PSCustomObject]@{
        SchemaVersion='diagframework.windbg.analysis.summary.v1'
        Status=if(-not $discovery.CdbFound){'CdbNotFound'}elseif(@($results | Where-Object {$_.analysisStatus -eq 'Success'}).Count -gt 0){'Analyzed'}else{'AnalysisFailed'}
        CdbFound=$discovery.CdbFound
        CdbPath=$discovery.CdbPath
        DumpCount=@($dumps).Count
        AnalyzedCount=@($results | Where-Object {$_.analysisStatus -eq 'Success'}).Count
        SuspectDriverCount=@($suspects).Count
        SummaryPath='analysis/windbg/normalized/minidump-summary.json'
        SuspectDriversPath='analysis/windbg/normalized/suspect-drivers.json'
        P1Handoff=@('WERNormalizer','DriverPnPProblemNormalizer','EventCorrelationNormalizer')
        ImportantNote='Probably caused by is treated as candidate-only evidence, not final root cause.'
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $normRoot 'windbg-analysis-summary.json') -Depth 12
    return $summary
}

function New-RepairSourceAdvisor {
    param([string]$PackageRoot, $ServicingRisk=$null, $WindowsUpdateSignal=$null)
    $paths = @(
        (Join-Path $PackageRoot 'copied_logs/CBS.log'),
        (Join-Path $PackageRoot 'copied_logs/CBS'),
        (Join-Path $PackageRoot 'copied_logs/DISM'),
        (Join-Path $PackageRoot 'copied_logs/dism.log'),
        (Join-Path $PackageRoot 'wer/wer-reports.json'),
        (Join-Path $PackageRoot 'windows_update/WindowsUpdate.generated.log')
    )
    $signals = @()
    $patterns = @(
        [PSCustomObject]@{ Code='0x800F0915'; Category='RepairSourceMissing'; Severity='High'; Pattern='0x800f0915' },
        [PSCustomObject]@{ Code='SourceFilesCouldNotBeFound'; Category='RepairSourceMissing'; Severity='High'; Pattern='source files could not be found|not able to find repair content anywhere|repair content' },
        [PSCustomObject]@{ Code='0x800F0845'; Category='ServicingInstallFailure'; Severity='High'; Pattern='0x800f0845' }
    )
    foreach ($root in $paths) {
        $files = @()
        try {
            if (Test-Path -LiteralPath $root -PathType Leaf) { $files = @(Get-Item -LiteralPath $root -ErrorAction SilentlyContinue) }
            elseif (Test-Path -LiteralPath $root -PathType Container) { $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '\.(log|txt|json|wer)$' }) }
        } catch { $files = @() }
        foreach ($file in $files) {
            foreach ($p in $patterns) {
                try {
                    $count = @(Select-String -LiteralPath $file.FullName -Pattern $p.Pattern -AllMatches -ErrorAction SilentlyContinue).Count
                    if ($count -gt 0) { $signals += [PSCustomObject]@{ Code=$p.Code; Category=$p.Category; Severity=$p.Severity; Count=$count; EvidenceFile=Get-RelativePathSafe $PackageRoot $file.FullName } }
                } catch { }
            }
        }
    }
    $hasRepairMissing = @($signals | Where-Object { $_.Category -eq 'RepairSourceMissing' }).Count -gt 0
    $advisor = [PSCustomObject]@{
        SchemaVersion='diagframework.repair.source.advisor.v1'
        Status=if($hasRepairMissing){'RepairSourceIssueCandidate'}elseif(@($signals).Count -gt 0){'ServicingSignalsDetected'}else{'NoRepairSourceSignal'}
        Signals=$signals
        SuggestedFirstAction=if($hasRepairMissing){'Prefer DISM repair-source investigation before generic Windows Update reset.'}else{'No repair-source-specific action from P0 evidence.'}
        ReadOnly=$true
        RepairModeRequiredForFix=$true
        ExampleCommands=@(
            'DISM /Online /Cleanup-Image /CheckHealth',
            'DISM /Online /Cleanup-Image /ScanHealth',
            'DISM /Online /Cleanup-Image /RestoreHealth',
            'DISM /Online /Cleanup-Image /RestoreHealth /Source:C:\RepairSource\Windows /LimitAccess',
            'sfc /scannow'
        )
        P1Handoff=@('CBSHResultNormalizer','WindowsUpdateErrorNormalizer','EventCorrelationNormalizer')
    }
    $out = Join-Path $PackageRoot 'analysis/repair-source-advisor.json'
    Write-JsonSafe -InputObject $advisor -Path $out -Depth 12
    return $advisor
}

function New-KBContextHandoff {
    param([string]$PackageRoot, [string]$TargetKB='')
    $target = [string]$TargetKB
    $roots = @(
        (Join-Path $PackageRoot 'windows_update/WindowsUpdate.generated.log'),
        (Join-Path $PackageRoot 'copied_logs/ReportingEvents.log'),
        (Join-Path $PackageRoot 'copied_logs/CBS'),
        (Join-Path $PackageRoot 'copied_logs/CBS.log'),
        (Join-Path $PackageRoot 'copied_logs/DISM'),
        (Join-Path $PackageRoot 'servicing')
    )
    $files = @()
    foreach($root in $roots){
        try {
            if(Test-Path -LiteralPath $root -PathType Leaf){ $files += Get-Item -LiteralPath $root }
            elseif(Test-Path -LiteralPath $root -PathType Container){ $files += @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '\.(log|txt|json|wer)$' }) }
        } catch { }
    }
    $kbCounts = @{}
    $errorCounts = @{}
    $targetMatches = @()
    foreach($file in @($files | Select-Object -Unique)){
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            foreach($m in [regex]::Matches($text, 'KB\d{7,8}', 'IgnoreCase')) { $k=$m.Value.ToUpperInvariant(); if(-not $kbCounts.ContainsKey($k)){$kbCounts[$k]=0}; $kbCounts[$k]++ }
            foreach($m in [regex]::Matches($text, '0x[0-9a-fA-F]{8}', 'IgnoreCase')) { $k=$m.Value.ToLowerInvariant(); if(-not $errorCounts.ContainsKey($k)){$errorCounts[$k]=0}; $errorCounts[$k]++ }
            if(-not [string]::IsNullOrWhiteSpace($target) -and $text -match [regex]::Escape($target)) { $targetMatches += [PSCustomObject]@{ File=Get-RelativePathSafe $PackageRoot $file.FullName; Count=([regex]::Matches($text, [regex]::Escape($target), 'IgnoreCase')).Count } }
        } catch { }
    }
    $topKbs = @($kbCounts.Keys | ForEach-Object { [PSCustomObject]@{ KB=$_; Count=$kbCounts[$_] } } | Sort-Object Count -Descending | Select-Object -First 30)
    $topErrors = @($errorCounts.Keys | ForEach-Object { [PSCustomObject]@{ Code=$_; Count=$errorCounts[$_] } } | Sort-Object Count -Descending | Select-Object -First 30)
    $handoff = [PSCustomObject]@{
        SchemaVersion='diagframework.kb.context.handoff.v1'
        TargetKB=$target
        TargetKBDirectMatchCount=@($targetMatches | Measure-Object Count -Sum).Sum
        TargetKBMatchedFiles=$targetMatches
        TopKBs=$topKbs
        TopErrorCodes=$topErrors
        Assessment=if([string]::IsNullOrWhiteSpace($target)){'NoTargetKBRequested'}elseif(@($targetMatches).Count -gt 0){'TargetKBSignalsPresent'}else{'NoDirectTargetKBMatch'}
        P1Handoff=@('WindowsUpdateErrorNormalizer','CBSHResultNormalizer','EventCorrelationNormalizer')
    }
    Write-JsonSafe -InputObject $handoff -Path (Join-Path $PackageRoot 'analysis/kb-context-handoff.json') -Depth 12
    return $handoff
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
    $evidenceGapSummary = $null; $servicingRiskSummary = $null; $windowsUpdateSignalSummary = $null; $cbsPersistSummary=$null; $miniDumpSummary=$null; $repairSourceAdvisor=$null; $kbContextHandoff=$null
    try { $evidenceGapSummary = (@($P0Results) | Where-Object { $_.Area -eq 'P0EvidenceGaps' } | Select-Object -First 1).Result } catch { }
    try { $servicingRiskSummary = (@($P0Results) | Where-Object { $_.Area -eq 'ServicingRisk' } | Select-Object -First 1).Result } catch { }
    try { $windowsUpdateSignalSummary = (@($P0Results) | Where-Object { $_.Area -eq 'WindowsUpdateSignal' } | Select-Object -First 1).Result } catch { }
    try { $cbsPersistSummary = (@($P0Results) | Where-Object { $_.Area -eq 'CbsPersistEvidence' } | Select-Object -First 1).Result } catch { }
    try { $miniDumpSummary = (@($P0Results) | Where-Object { $_.Area -eq 'MiniDumpWinDbg' } | Select-Object -First 1).Result } catch { }
    try { $repairSourceAdvisor = (@($P0Results) | Where-Object { $_.Area -eq 'RepairSourceAdvisor' } | Select-Object -First 1).Result } catch { }
    try { $kbContextHandoff = (@($P0Results) | Where-Object { $_.Area -eq 'KBContextHandoff' } | Select-Object -First 1).Result } catch { }
    try {
        $storageP0 = @(@($P0Results) | Where-Object { $_.Area -eq 'Storage' } | Select-Object -First 1)
        if ($storageP0 -and $storageP0.Result) {
            $topFindings = @($storageP0.Result.TopFindings)
            $riskIndicators = @($storageP0.Result.RiskIndicators)
            $suggestedNextEvidence = @($storageP0.Result.SuggestedNextEvidence)
        }
    } catch { }
    [PSCustomObject]@{
        SchemaVersion='diagframework.systemevidence.summary.v4.1'
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
        Purpose='AI/szakértő által elemezhető Windows 11 P0 read-only evidence bridge P1 v1.4.0 normalizálókhoz: CbsPersist, minidump CDB/WinDbg, repair-source advisor, KB context handoff, servicing/WU signal summary.'
        CompatibleP1Version=$P1NormalizerCompatibleVersion
        P1NormalizerHandoffDefinition=(Get-P1NormalizerHandoffDefinition)
        P0Evidence=$P0Results
        CbsPersistEvidence=$cbsPersistSummary
        MiniDumpWinDbg=$miniDumpSummary
        RepairSourceAdvisor=$repairSourceAdvisor
        KBContextHandoff=$kbContextHandoff
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
        $summary=[PSCustomObject]@{ SchemaVersion='diagframework.systemevidence.summary.v4.1'; ModuleId=$ModuleId; ModuleVersion=$ModuleVersion; WhatIf=$true; Status='WhatIf'; PlannedPackageRoot=$packageRoot; PlannedZipPath=$zipPath; P0Planned=@('EVTX export','WindowsUpdate generated log','DISM ScanHealth','SFC verifyonly','Storage mapping','WER aggregation','copied_logs skipped-files manifest','Manifest SHA256','Storage controller correlation','Disk 153 timeline','User hint vs detected topology validation','RAID volume map','Physical disk candidate map','Target KB correlation','TopFindings/RiskIndicators/SuggestedNextEvidence','Baunok evidence-gap summary','Servicing risk summary','WindowsUpdate signal summary','P1 normalizer handoff readiness') }
        Write-JsonSafe -InputObject $summary -Path (Join-Path $packageRoot 'ai_summary.json') -Depth 8
        return $summary
    }
    $startTime = (Get-Date).AddDays(-1 * [Math]::Abs($DaysBack))
    try { Write-JsonSafe -InputObject (Get-SystemSnapshot) -Path (Join-Path $packageRoot 'meta/system-info.json') -Depth 8; Add-ProgressEvent $packageRoot 'SystemSnapshot' } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'SystemSnapshotFailed' -Step 'SystemSnapshot' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'SystemSnapshot' 'Error' $_.Exception.Message }
    try { Write-JsonSafe -InputObject @(Get-RebootPendingSnapshot) -Path (Join-Path $packageRoot 'registry/reboot-pending.json') -Depth 10; Add-ProgressEvent $packageRoot 'RegistryPendingReboot' } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'RegistryPendingRebootFailed' -Step 'RegistryPendingReboot' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'RegistryPendingReboot' 'Error' $_.Exception.Message }
    try { Write-JsonSafe -InputObject @(Get-DriverSnapshot) -Path (Join-Path $packageRoot 'drivers/pnp-signed-drivers.json') -Depth 8; Add-ProgressEvent $packageRoot 'DriverSnapshot' } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'DriverSnapshotFailed' -Step 'DriverSnapshot' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'DriverSnapshot' 'Error' $_.Exception.Message }
    try { $eventResult=Collect-Events -PackageRoot $packageRoot -StartTime $startTime -Issues $issues -MaxEvents $MaxEvents; $eventSummary=@($eventResult.Summary); $issues=@($eventResult.Issues); $p0Results += [PSCustomObject]@{ Area='Events'; Result='Collected'; Count=@($eventSummary).Count }; Add-ProgressEvent $packageRoot 'EventLogs' 'OK' "Logs=$($eventSummary.Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'EventCollectionFailed' -Step 'EventLogs' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'EventLogs' 'Error' $_.Exception.Message }
    try { $copyResult=Copy-BaselineLogs $packageRoot; $copied=@($copyResult.Copied) + @($copyResult.VendorRecords); $p0Results += [PSCustomObject]@{ Area='CopiedLogs'; CopiedCount=@($copyResult.Copied).Count; SkippedCount=@($copyResult.Skipped).Count; Policy='SystemLogCopyPolicy + SetupLogCopyPolicy + VendorLogPolicy' }; Add-ProgressEvent $packageRoot 'CopyLogs' 'OK' "Copied=$(@($copyResult.Copied).Count) Skipped=$(@($copyResult.Skipped).Count) VendorRecords=$(@($copyResult.VendorRecords).Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'CopyLogsFailed' -Step 'CopyLogs' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'CopyLogs' 'Error' $_.Exception.Message }
    try { $cbsPersist=Collect-CbsPersistEvidence -PackageRoot $packageRoot; $p0Results += [PSCustomObject]@{ Area='CbsPersistEvidence'; Result=$cbsPersist }; Add-ProgressEvent $packageRoot 'CbsPersistEvidence' 'OK' ("CBS=" + [string]$cbsPersist.CbsLogCount + " DISM=" + [string]$cbsPersist.DismLogCount + " CAB=" + [string]$cbsPersist.CbsPersistCabCount) } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'CbsPersistEvidenceFailed' -Step 'CbsPersistEvidence' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'CbsPersistEvidence' 'Warning' $_.Exception.Message }
    try { $wu=Invoke-WindowsUpdateLogConversion -PackageRoot $packageRoot; $p0Results += [PSCustomObject]@{ Area='WindowsUpdateLog'; Status=$wu.Status; Length=$wu.Length }; Add-ProgressEvent $packageRoot 'WindowsUpdateLog' $wu.Status "Length=$($wu.Length)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'WindowsUpdateLogConversionFailed' -Step 'WindowsUpdateLog' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'WindowsUpdateLog' 'Warning' $_.Exception.Message }
    try { $defs=Get-NativeCommandDefinitions; Write-NativeCommandReadme -PackageRoot $packageRoot -Definitions $defs; foreach($d in $defs | Where-Object { $_.SubDirectory -eq 'commands' }) { $nativeResults += Invoke-NativeCommandSafe -PackageRoot $packageRoot -SubDirectory $d.SubDirectory -Name $d.Name -File $d.File -ArgumentList ([string[]]$d.ArgumentList) }; Write-JsonSafe -InputObject $nativeResults -Path (Join-Path $packageRoot 'commands/native-command-results.json') -Depth 12; Add-ProgressEvent $packageRoot 'NativeCommands' 'OK' "Commands=$($nativeResults.Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Error' -Code 'NativeCommandsFailed' -Step 'NativeCommands' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'NativeCommands' 'Error' $_.Exception.Message }
    try { $serv=Collect-ServicingEvidence -PackageRoot $packageRoot; $p0Results += [PSCustomObject]@{ Area='Servicing'; CommandCount=@($serv).Count }; Add-ProgressEvent $packageRoot 'ServicingEvidence' 'OK' "Commands=$(@($serv).Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'ServicingEvidenceFailed' -Step 'ServicingEvidence' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'ServicingEvidence' 'Warning' $_.Exception.Message }
    try { $storage=Collect-StorageEvidence -PackageRoot $packageRoot -StartTime $startTime -TargetKB $TargetKB; $p0Results += [PSCustomObject]@{ Area='Storage'; Result=$storage }; Add-ProgressEvent $packageRoot 'StorageEvidence' 'OK' "Disk153=$($storage.Disk153Count)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'StorageEvidenceFailed' -Step 'StorageEvidence' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'StorageEvidence' 'Warning' $_.Exception.Message }
    $wer = $null
    try { $wer=Collect-WerSummary -PackageRoot $packageRoot; $p0Results += [PSCustomObject]@{ Area='WER'; ReportCount=$wer.ReportCount }; Add-ProgressEvent $packageRoot 'WerSummary' 'OK' "Reports=$($wer.ReportCount)" } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'WerSummaryFailed' -Step 'WerSummary' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'WerSummary' 'Warning' $_.Exception.Message }
    try { $miniDump=Invoke-MiniDumpCdbAnalysis -PackageRoot $packageRoot; $p0Results += [PSCustomObject]@{ Area='MiniDumpWinDbg'; Result=$miniDump }; $miniStatus = if($miniDump){[string]$miniDump.Status}else{'Unknown'}; Add-ProgressEvent $packageRoot 'MiniDumpWinDbg' 'OK' ("Status=" + $miniStatus) } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'MiniDumpWinDbgFailed' -Step 'MiniDumpWinDbg' -Target '' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'MiniDumpWinDbg' 'Warning' $_.Exception.Message }
    $servicingRisk = $null
    try { $servicingRisk = New-ServicingRiskSummary -PackageRoot $packageRoot; Write-JsonSafe -InputObject $servicingRisk -Path (Join-Path $packageRoot 'servicing/servicing-risk-summary.json') -Depth 12; $p0Results += [PSCustomObject]@{ Area='ServicingRisk'; Result=$servicingRisk }; Add-ProgressEvent $packageRoot 'ServicingRiskSummary' 'OK' $servicingRisk.Status } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'ServicingRiskSummaryFailed' -Step 'ServicingRiskSummary' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace }
    $wuSignal = $null
    try { $wuSignal = New-WindowsUpdateSignalSummary -PackageRoot $packageRoot -TargetKB $TargetKB; Write-JsonSafe -InputObject $wuSignal -Path (Join-Path $packageRoot 'windows_update/windowsupdate-signal-summary.json') -Depth 12; $p0Results += [PSCustomObject]@{ Area='WindowsUpdateSignal'; Result=$wuSignal }; Add-ProgressEvent $packageRoot 'WindowsUpdateSignalSummary' 'OK' ("ErrorCodes=" + @($wuSignal.TopErrorCodes).Count) } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'WindowsUpdateSignalSummaryFailed' -Step 'WindowsUpdateSignalSummary' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace }
    try { $repairAdvisor = New-RepairSourceAdvisor -PackageRoot $packageRoot -ServicingRisk $servicingRisk -WindowsUpdateSignal $wuSignal; $p0Results += [PSCustomObject]@{ Area='RepairSourceAdvisor'; Result=$repairAdvisor }; Add-ProgressEvent $packageRoot 'RepairSourceAdvisor' 'OK' ([string]$repairAdvisor.Status) } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'RepairSourceAdvisorFailed' -Step 'RepairSourceAdvisor' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace }
    try { $kbHandoff = New-KBContextHandoff -PackageRoot $packageRoot -TargetKB $TargetKB; $p0Results += [PSCustomObject]@{ Area='KBContextHandoff'; Result=$kbHandoff }; Add-ProgressEvent $packageRoot 'KBContextHandoff' 'OK' ([string]$kbHandoff.Assessment) } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'KBContextHandoffFailed' -Step 'KBContextHandoff' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace }
    try { $gapSummary = New-P0EvidenceGapSummary -PackageRoot $packageRoot -TargetKB $TargetKB -Issues $issues -EventSummary $eventSummary -P0Results $p0Results -ServicingRisk $servicingRisk -WindowsUpdateSignal $wuSignal -WerSummary $wer; Write-JsonSafe -InputObject $gapSummary -Path (Join-Path $packageRoot 'analysis/evidence-gap-summary.json') -Depth 12; Write-JsonSafe -InputObject $gapSummary -Path (Join-Path $packageRoot 'analysis/baunok-evidence-gap-backport.json') -Depth 12; $p0Results += [PSCustomObject]@{ Area='P0EvidenceGaps'; Result=$gapSummary }; Add-ProgressEvent $packageRoot 'EvidenceGapSummary' 'OK' ("Gaps=" + $gapSummary.GapCount) } catch { $issues=Add-CollectorIssue -CurrentIssues $issues -Severity 'Warning' -Code 'EvidenceGapSummaryFailed' -Step 'EvidenceGapSummary' -Category $_.CategoryInfo.ToString() -Message $_.Exception.Message -ScriptStackTrace $_.ScriptStackTrace }
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
            Summary='Rendszerszintű P0 evidence bridge csomag készíthető EVTX, Windows Update, servicing, CbsPersist, minidump CDB/WinDbg, storage, WER és P1 v1.4.0 normalizer átadási pontokkal.'
            RecommendedAction='Javasolt lépések: 1) Állítsd be a DaysBack értéket. 2) Indítsd el a rendszer LOG csomagot WhatIf nélkül. 3) Először ai_summary.json, collector-issues.json és event-export-metadata.json fájlokat nézd. 4) Storage hibánál disk-event-map.json és disk-event-153-aggregate.json a kulcs. 5) WER zajnál wer-summary.json és wer-reports.json. 6) Minidump esetén nézd meg az analysis/windbg/normalized/minidump-summary.json fájlt. 7) Repair-source jelzésnél ne WU-reset legyen az első javítási javaslat. 8) Javítómodult csak pre-repair evidence után futtass.'
        }
    }
    'Invoke-Fix' { Invoke-EvidenceCollection -DaysBack $DaysBack -MaxEvents $MaxEvents -WhatIf:$WhatIf -TargetKB $TargetKB }
    'Invoke-Rollback' { [PSCustomObject]@{ RollbackSupported=$false; Summary='A SystemEvidenceCollector read-only modul, rollback nem szükséges.' } }
}
