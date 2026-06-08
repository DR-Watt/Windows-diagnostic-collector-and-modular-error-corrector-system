<#
.SYNOPSIS
  Windows 11 rendszerbizonyíték és vendor diagnosztikai LOG gyűjtő modul.
.DESCRIPTION
  v1.3.0 P0 Evidence Quality Pack.
  Read-only evidence gyűjtés: EVTX export, WindowsUpdate.generated.log, DISM ScanHealth,
  SFC verifyonly, storage mapping, manifest SHA-256, event truncation metadata,
  warning/error státuszmodell és vendor whitelist/blacklist policy.
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
$ModuleVersion = '1.3.0'

function Get-Metadata {
    [PSCustomObject]@{
        Id = $ModuleId
        Name = 'Rendszer LOG bizonyítékgyűjtő'
        Version = $ModuleVersion
        Risk = 'Low'
        Summary = 'Windows 11 P0 minőségű read-only evidence: EVTX, WindowsUpdate.log, DISM/SFC verify, storage mapping, WER/servicing alapok.'
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
    $split = Split-IssuesBySeverity $Issues
    Write-JsonSafe @($Issues) (Join-Path $PackageRoot 'errors/collector-issues.json') 10
    Write-JsonSafe @($split.Errors) (Join-Path $PackageRoot 'errors/collector-errors.json') 10
    Write-JsonSafe @($split.Warnings) (Join-Path $PackageRoot 'errors/collector-warnings.json') 10
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
            Write-JsonLinesSafe @() $jsonlPath
            $summary += [PSCustomObject]@{ LogName=$log; Status='Warning'; Code='LogNotPresent'; Count=0; OutputFile=('events/' + $safeBase + '.jsonl') }
            $metadata += [PSCustomObject]@{ LogName=$log; Status='Warning'; Code='LogNotPresent'; Count=0; MaxEvents=$MaxEvents; Truncated=$false; OutputJsonl=('events/' + $safeBase + '.jsonl'); OutputEvtx=$null }
            $localIssues = Add-CollectorIssue $localIssues 'Warning' 'LogNotPresent' 'EventLogs' $log 'Get-WinEvent' 'Az opcionális eseménynapló-csatorna nem található.' ''
            continue
        }
        $rawExport = Export-EventLogRawSafe $PackageRoot $log $safeBase
        try {
            $rawEvents = @(Get-WinEvent -FilterHashtable @{ LogName=$log; StartTime=$StartTime } -MaxEvents $MaxEvents -ErrorAction Stop)
            $flat = @()
            foreach ($ev in $rawEvents) { try { $flat += Convert-EventRecordFlat $ev } catch { } }
            Write-JsonLinesSafe $flat $jsonlPath
            $times = @($flat | Where-Object { $_.TimeCreated } | ForEach-Object { try { [datetime]$_.TimeCreated } catch { $null } } | Where-Object { $null -ne $_ })
            $oldest = $null; $newest = $null
            if ($times.Count -gt 0) { $oldest = (($times | Sort-Object | Select-Object -First 1).ToString('o')); $newest = (($times | Sort-Object | Select-Object -Last 1).ToString('o')) }
            $truncated = ($flat.Count -ge $MaxEvents)
            $summary += [PSCustomObject]@{ LogName=$log; Status='OK'; Count=$flat.Count; OutputFile=('events/' + $safeBase + '.jsonl'); Truncated=$truncated; OutputEvtx=$rawExport.OutputEvtx }
            $metadata += [PSCustomObject]@{ LogName=$log; Status='OK'; Count=$flat.Count; MaxEvents=$MaxEvents; Truncated=$truncated; OldestTimeCreated=$oldest; NewestTimeCreated=$newest; OutputJsonl=('events/' + $safeBase + '.jsonl'); OutputEvtx=$rawExport.OutputEvtx; RawExport=$rawExport }
        }
        catch {
            $msg = $_.Exception.Message
            Write-JsonLinesSafe @() $jsonlPath
            $summary += [PSCustomObject]@{ LogName=$log; Status='Warning'; Code='NoMatchingEvents'; Count=0; Error=$msg; OutputFile=('events/' + $safeBase + '.jsonl'); OutputEvtx=$rawExport.OutputEvtx }
            $metadata += [PSCustomObject]@{ LogName=$log; Status='Warning'; Code='NoMatchingEvents'; Count=0; MaxEvents=$MaxEvents; Truncated=$false; OutputJsonl=('events/' + $safeBase + '.jsonl'); OutputEvtx=$rawExport.OutputEvtx; RawExport=$rawExport; Error=$msg }
            $localIssues = Add-CollectorIssue $localIssues 'Warning' 'NoMatchingEvents' 'EventLogs' $log 'Get-WinEvent' $msg $_.ScriptStackTrace
        }
    }
    Write-JsonSafe $summary (Join-Path $eventRoot 'event-summary.json') 8
    Write-JsonSafe $metadata (Join-Path $eventRoot 'event-export-metadata.json') 10
    [PSCustomObject]@{ Summary=$summary; Metadata=$metadata; Issues=$localIssues }
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
    Write-JsonSafe $Definitions (Join-Path $cmdRoot 'native-command-catalog.json') 8
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
    Write-JsonSafe ([PSCustomObject]$result) (Join-Path $wuRoot 'Get-WindowsUpdateLog.result.json') 8
    [PSCustomObject]$result
}

function Collect-ServicingEvidence {
    param([string]$PackageRoot)
    $servRoot = Join-Path $PackageRoot 'servicing'
    New-DirectorySafe $servRoot
    $defs = @(Get-NativeCommandDefinitions | Where-Object { $_.SubDirectory -eq 'servicing' })
    $results = @()
    foreach ($d in $defs) { $results += Invoke-NativeCommandSafe $PackageRoot $d.SubDirectory $d.Name $d.File ([string[]]$d.ArgumentList) }
    Write-JsonSafe $results (Join-Path $servRoot 'servicing-command-results.json') 10
    $cbs = Join-Path $PackageRoot 'copied_logs/CBS.log'
    if (Test-Path -LiteralPath $cbs) { New-CbsHResultSummary $cbs (Join-Path $servRoot 'cbs-hresult-summary.json') }
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
    Write-JsonSafe (@($summary | Sort-Object Count -Descending)) $OutPath 6
}

function Collect-StorageEvidence {
    param([string]$PackageRoot, [datetime]$StartTime)
    $root = Join-Path $PackageRoot 'storage'
    New-DirectorySafe $root
    $result = @{}
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
    Write-JsonSafe $result.Disks (Join-Path $root 'disks.json') 8
    Write-JsonSafe $result.PhysicalDisks (Join-Path $root 'physical-disks.json') 8
    Write-JsonSafe $result.Volumes (Join-Path $root 'volumes.json') 8
    Write-JsonSafe $result.Partitions (Join-Path $root 'partitions.json') 8
    Write-JsonSafe $result.Win32_DiskDrive (Join-Path $root 'diskdrive-cim.json') 8
    Write-JsonSafe $result.DiskDriveToDiskPartition (Join-Path $root 'diskdrive-to-partition-map.json') 8
    Write-JsonSafe $result.LogicalDiskToPartition (Join-Path $root 'logicaldisk-to-partition-map.json') 8
    Write-JsonSafe $result.StorageReliabilityCounters (Join-Path $root 'storage-reliability-counters.json') 8
    $diskEvents = @()
    try { $diskEvents = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='disk'; Id=153; StartTime=$StartTime} -MaxEvents 500 -ErrorAction Stop | ForEach-Object { Convert-EventRecordFlat $_ }) } catch { $diskEvents = @() }
    Write-JsonLinesSafe $diskEvents (Join-Path $root 'disk-events-153.jsonl')
    $eventMap = @()
    foreach ($ev in $diskEvents) {
        $diskNumber = $null
        if ($ev.Message -match '(?i)(disk|lemez)[^0-9]{0,20}(\d+)') { $diskNumber = [int]$Matches[2] }
        $eventMap += [PSCustomObject]@{ DiskNumber=$diskNumber; EventId=$ev.Id; TimeCreated=$ev.TimeCreated; ProviderName=$ev.ProviderName; Message=$ev.Message }
    }
    Write-JsonSafe $eventMap (Join-Path $root 'disk-event-map.json') 8
    return [PSCustomObject]@{ DiskCount=@($result.Disks).Count; PhysicalDiskCount=@($result.PhysicalDisks).Count; Disk153Count=@($diskEvents).Count }
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

function Collect-WerSummary {
    param([string]$PackageRoot)
    $werRoot = Join-Path $PackageRoot 'wer'
    New-DirectorySafe $werRoot
    $reportRoots = @(Join-Path $PackageRoot 'copied_logs/ReportArchive', Join-Path $PackageRoot 'copied_logs/ReportQueue')
    $reports = @()
    foreach ($rr in $reportRoots) {
        if (-not (Test-Path -LiteralPath $rr)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $rr -Filter 'Report.wer' -File -Recurse -ErrorAction SilentlyContinue)) {
            $kv = @{}
            try {
                foreach ($line in @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) {
                    if ($line -match '^([^=]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
                }
            } catch { }
            $reports += [PSCustomObject]@{
                RelativePath = Get-RelativePathSafe $PackageRoot $f.FullName
                EventType = $kv['EventType']
                FriendlyEventName = $kv['FriendlyEventName']
                AppName = $kv['Sig[0].Name']
                Sig0 = $kv['Sig[0].Value']
                Sig1 = $kv['Sig[1].Value']
                Sig2 = $kv['Sig[2].Value']
                Sig3 = $kv['Sig[3].Value']
                ReportId = $kv['ReportIdentifier']
            }
        }
    }
    $byEvent = @($reports | Group-Object EventType | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ EventType=$_.Name; Count=$_.Count } })
    $bySig0 = @($reports | Group-Object Sig0 | Sort-Object Count -Descending | Select-Object -First 50 | ForEach-Object { [PSCustomObject]@{ Sig0=$_.Name; Count=$_.Count } })
    Write-JsonSafe $reports (Join-Path $werRoot 'wer-reports.json') 8
    Write-JsonSafe ([PSCustomObject]@{ ReportCount=@($reports).Count; ByEventType=$byEvent; BySig0=$bySig0 }) (Join-Path $werRoot 'wer-summary.json') 10
    return [PSCustomObject]@{ ReportCount=@($reports).Count }
}

function Copy-BaselineLogs {
    param([string]$PackageRoot)
    $copied = @()
    $standardTargets = @(
        "$env:SystemRoot\Logs\CBS\CBS.log",
        "$env:SystemRoot\Logs\DISM\dism.log",
        "$env:SystemRoot\WindowsUpdate.log",
        "$env:SystemRoot\SoftwareDistribution\ReportingEvents.log",
        "$env:SystemRoot\Panther",
        "$env:SystemRoot\INF\setupapi.dev.log",
        "$env:SystemRoot\INF\setupapi.setup.log",
        "$env:SystemRoot\Minidump",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
    )
    foreach ($target in $standardTargets) {
        try { $copied += @(Copy-IfExists $target (Join-Path $PackageRoot 'copied_logs')) }
        catch { $copied += [PSCustomObject]@{ Source=$target; Skipped=$true; Reason='CopyError'; Error=$_.Exception.Message } }
    }
    $policy = Get-VendorLogPolicy
    $vendorTargets = @("$env:ProgramData\Dell","$env:ProgramData\HP","$env:ProgramData\Lenovo","$env:ProgramData\Intel","$env:ProgramData\NVIDIA Corporation","$env:ProgramData\AMD","$env:ProgramData\ASUS")
    $vendorRecords = @()
    foreach ($target in $vendorTargets) {
        try { $vendorRecords += @(Copy-IfExists $target (Join-Path $PackageRoot 'vendor_logs') $policy.MaxBytesPerFile $policy.MaxFilesPerVendorRoot $policy.AllowedExtensions $policy.BlockedExtensions) }
        catch { $vendorRecords += [PSCustomObject]@{ Source=$target; Skipped=$true; Reason='CopyError'; Error=$_.Exception.Message } }
    }
    Write-JsonSafe $copied (Join-Path $PackageRoot 'copied_logs/copied-files.json') 8
    Write-JsonSafe $policy (Join-Path $PackageRoot 'vendor_logs/vendor-log-policy.json') 8
    Write-JsonSafe $vendorRecords (Join-Path $PackageRoot 'vendor_logs/vendor-log-manifest.json') 8
    return [PSCustomObject]@{ Copied=$copied; VendorRecords=$vendorRecords }
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
            HashAlgorithm='SHA256'
        }
        Files=$files
    }
}

function New-SummaryObject {
    param([string]$Status,[string]$PackageRoot,[string]$ZipPath,[string]$TargetKB,[int]$DaysBack,[int]$MaxEvents,$EventSummary=@(),$Copied=@(),$NativeResults=@(),$Issues=@(),$P0Results=@())
    $split = Split-IssuesBySeverity $Issues
    [PSCustomObject]@{
        SchemaVersion='diagframework.systemevidence.summary.v2'
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
        CopiedRecordCount=@($Copied).Count
        NativeCommandCount=@($NativeResults).Count
        ErrorCount=@($split.Errors).Count
        WarningCount=@($split.Warnings).Count
        Purpose='AI/szakértő által elemezhető Windows 11 P0 read-only evidence csomag.'
        P0Evidence=$P0Results
    }
}

function Invoke-EvidenceCollection {
    param([int]$DaysBack=30,[int]$MaxEvents=1200,[switch]$WhatIf,[string]$TargetKB='')
    Write-LogRootReadmes $LogRoot $TargetKB
    $evidenceRoot = Join-Path $LogRoot 'evidence_packages'
    New-DirectorySafe $evidenceRoot
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $suffix = if ([string]::IsNullOrWhiteSpace($TargetKB)) { 'SystemEvidence' } else { 'SystemEvidence-' + $TargetKB }
    $packageRoot = Join-Path $evidenceRoot ("$timestamp-$env:COMPUTERNAME-$suffix")
    $zipPath = "$packageRoot.zip"
    foreach ($sub in 'meta','events','events/raw','registry','copied_logs','drivers','commands','errors','vendor_logs','windows_update','servicing','storage','wer') { New-DirectorySafe (Join-Path $packageRoot $sub) }
    Write-PackageReadme $packageRoot $TargetKB 'InProgress'
    $issues=@(); $eventSummary=@(); $copied=@(); $nativeResults=@(); $p0Results=@()
    Add-ProgressEvent $packageRoot 'Start' 'OK' "DaysBack=$DaysBack MaxEvents=$MaxEvents TargetKB=$TargetKB WhatIf=$($WhatIf.IsPresent)"
    if ($WhatIf) {
        $summary=[PSCustomObject]@{ SchemaVersion='diagframework.systemevidence.summary.v2'; ModuleId=$ModuleId; ModuleVersion=$ModuleVersion; WhatIf=$true; Status='WhatIf'; PlannedPackageRoot=$packageRoot; PlannedZipPath=$zipPath; P0Planned=@('EVTX export','WindowsUpdate generated log','DISM ScanHealth','SFC verifyonly','Storage mapping','Manifest SHA256') }
        Write-JsonSafe $summary (Join-Path $packageRoot 'ai_summary.json') 8
        return $summary
    }
    $startTime = (Get-Date).AddDays(-1 * [Math]::Abs($DaysBack))
    try { Write-JsonSafe (Get-SystemSnapshot) (Join-Path $packageRoot 'meta/system-info.json') 8; Add-ProgressEvent $packageRoot 'SystemSnapshot' } catch { $issues=Add-CollectorIssue $issues 'Error' 'SystemSnapshotFailed' 'SystemSnapshot' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'SystemSnapshot' 'Error' $_.Exception.Message }
    try { Write-JsonSafe @(Get-RebootPendingSnapshot) (Join-Path $packageRoot 'registry/reboot-pending.json') 10; Add-ProgressEvent $packageRoot 'RegistryPendingReboot' } catch { $issues=Add-CollectorIssue $issues 'Error' 'RegistryPendingRebootFailed' 'RegistryPendingReboot' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'RegistryPendingReboot' 'Error' $_.Exception.Message }
    try { Write-JsonSafe @(Get-DriverSnapshot) (Join-Path $packageRoot 'drivers/pnp-signed-drivers.json') 8; Add-ProgressEvent $packageRoot 'DriverSnapshot' } catch { $issues=Add-CollectorIssue $issues 'Error' 'DriverSnapshotFailed' 'DriverSnapshot' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'DriverSnapshot' 'Error' $_.Exception.Message }
    try { $eventResult=Collect-Events $packageRoot $startTime $issues $MaxEvents; $eventSummary=@($eventResult.Summary); $issues=@($eventResult.Issues); $p0Results += [PSCustomObject]@{ Area='Events'; Result='Collected'; Count=@($eventSummary).Count }; Add-ProgressEvent $packageRoot 'EventLogs' 'OK' "Logs=$($eventSummary.Count)" } catch { $issues=Add-CollectorIssue $issues 'Error' 'EventCollectionFailed' 'EventLogs' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'EventLogs' 'Error' $_.Exception.Message }
    try { $copyResult=Copy-BaselineLogs $packageRoot; $copied=@($copyResult.Copied) + @($copyResult.VendorRecords); Add-ProgressEvent $packageRoot 'CopyLogs' 'OK' "Records=$($copied.Count)" } catch { $issues=Add-CollectorIssue $issues 'Error' 'CopyLogsFailed' 'CopyLogs' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'CopyLogs' 'Error' $_.Exception.Message }
    try { $wu=Invoke-WindowsUpdateLogConversion $packageRoot; $p0Results += [PSCustomObject]@{ Area='WindowsUpdateLog'; Status=$wu.Status; Length=$wu.Length }; Add-ProgressEvent $packageRoot 'WindowsUpdateLog' $wu.Status "Length=$($wu.Length)" } catch { $issues=Add-CollectorIssue $issues 'Warning' 'WindowsUpdateLogConversionFailed' 'WindowsUpdateLog' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'WindowsUpdateLog' 'Warning' $_.Exception.Message }
    try { $defs=Get-NativeCommandDefinitions; Write-NativeCommandReadme $packageRoot $defs; foreach($d in $defs | Where-Object { $_.SubDirectory -eq 'commands' }) { $nativeResults += Invoke-NativeCommandSafe $packageRoot $d.SubDirectory $d.Name $d.File ([string[]]$d.ArgumentList) }; Write-JsonSafe $nativeResults (Join-Path $packageRoot 'commands/native-command-results.json') 12; Add-ProgressEvent $packageRoot 'NativeCommands' 'OK' "Commands=$($nativeResults.Count)" } catch { $issues=Add-CollectorIssue $issues 'Error' 'NativeCommandsFailed' 'NativeCommands' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'NativeCommands' 'Error' $_.Exception.Message }
    try { $serv=Collect-ServicingEvidence $packageRoot; $p0Results += [PSCustomObject]@{ Area='Servicing'; CommandCount=@($serv).Count }; Add-ProgressEvent $packageRoot 'ServicingEvidence' 'OK' "Commands=$(@($serv).Count)" } catch { $issues=Add-CollectorIssue $issues 'Warning' 'ServicingEvidenceFailed' 'ServicingEvidence' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'ServicingEvidence' 'Warning' $_.Exception.Message }
    try { $storage=Collect-StorageEvidence $packageRoot $startTime; $p0Results += [PSCustomObject]@{ Area='Storage'; Result=$storage }; Add-ProgressEvent $packageRoot 'StorageEvidence' 'OK' "Disk153=$($storage.Disk153Count)" } catch { $issues=Add-CollectorIssue $issues 'Warning' 'StorageEvidenceFailed' 'StorageEvidence' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'StorageEvidence' 'Warning' $_.Exception.Message }
    try { $wer=Collect-WerSummary $packageRoot; $p0Results += [PSCustomObject]@{ Area='WER'; ReportCount=$wer.ReportCount }; Add-ProgressEvent $packageRoot 'WerSummary' 'OK' "Reports=$($wer.ReportCount)" } catch { $issues=Add-CollectorIssue $issues 'Warning' 'WerSummaryFailed' 'WerSummary' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'WerSummary' 'Warning' $_.Exception.Message }
    Write-CollectorIssuesSafe $packageRoot $issues
    $split = Split-IssuesBySeverity $issues
    $status = if (@($split.Errors).Count -gt 0) { 'Partial' } elseif (@($split.Warnings).Count -gt 0) { 'OKWithWarnings' } else { 'OK' }
    $summary = New-SummaryObject $status $packageRoot $zipPath $TargetKB $DaysBack $MaxEvents $eventSummary $copied $nativeResults $issues $p0Results
    Write-JsonSafe $summary (Join-Path $packageRoot 'ai_summary.json') 10
    Write-PackageReadme $packageRoot $TargetKB $status
    try { $manifest=New-PackageManifestSafe $packageRoot; Write-JsonSafe $manifest (Join-Path $packageRoot 'manifest.json') 12; Add-ProgressEvent $packageRoot 'Manifest' 'OK' "Files=$($manifest.Files.Count)" } catch { $issues=Add-CollectorIssue $issues 'Error' 'ManifestFailed' 'Manifest' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Write-CollectorIssuesSafe $packageRoot $issues; Add-ProgressEvent $packageRoot 'Manifest' 'Error' $_.Exception.Message }
    try { if(Test-Path -LiteralPath $zipPath){Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue}; Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -Force -ErrorAction Stop; Add-ProgressEvent $packageRoot 'Zip' 'OK' $zipPath } catch { $issues=Add-CollectorIssue $issues 'Error' 'ZipFailed' 'Zip' '' $_.CategoryInfo.ToString() $_.Exception.Message $_.ScriptStackTrace; Write-CollectorIssuesSafe $packageRoot $issues; Add-ProgressEvent $packageRoot 'Zip' 'Error' $_.Exception.Message }
    return $summary
}

switch ($Action) {
    'Get-Metadata' { Get-Metadata }
    'Test-Condition' {
        [PSCustomObject]@{
            IssueDetected=$true
            FixAvailable=$true
            Severity='Info'
            Summary='Rendszerszintű P0 evidence csomag készíthető EVTX, Windows Update, servicing, storage és WER információkkal.'
            RecommendedAction='Javasolt lépések: 1) Állítsd be a DaysBack értéket. 2) Indítsd el a rendszer LOG csomagot WhatIf nélkül. 3) Először ai_summary.json, collector-issues.json és event-export-metadata.json fájlokat nézd. 4) OKWithWarnings esetén warnings alapján folytasd. 5) Javítómodult csak pre-repair evidence után futtass.'
        }
    }
    'Invoke-Fix' { Invoke-EvidenceCollection -DaysBack $DaysBack -MaxEvents $MaxEvents -WhatIf:$WhatIf -TargetKB $TargetKB }
    'Invoke-Rollback' { [PSCustomObject]@{ RollbackSupported=$false; Summary='A SystemEvidenceCollector read-only modul, rollback nem szükséges.' } }
}
