<#
.SYNOPSIS
  Windows 11 rendszerbizonyíték és vendor diagnosztikai LOG gyűjtő modul.

.DESCRIPTION
  Nem javít rendszert. Strukturált, AI által elemezhető ZIP csomagot készít
  boot, setup, driver, update, crash és ismert gyártói diagnosztikai nyomokból.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Get-Metadata','Test-Condition','Invoke-Fix','Invoke-Rollback')][string]$Action,
    [switch]$WhatIf,
    [string]$LogRoot = (Join-Path $PSScriptRoot '..\..\logs'),
    [int]$DaysBack = 30,
    [int]$MaxEvents = 1200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ModuleId = 'SystemEvidenceCollector'
$ModuleVersion = '1.2.0'

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
    if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
}

function Write-JsonSafe {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 10
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { New-DirectorySafe -Path $parent }
    $InputObject | ConvertTo-Json -Depth $Depth | Out-File -FilePath $Path -Encoding UTF8 -Force
}

function Write-JsonLinesSafe {
    param(
        [Parameter(Mandatory)][object[]]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { New-DirectorySafe -Path $parent }
    foreach ($item in $InputObject) {
        $item | ConvertTo-Json -Depth 8 -Compress | Out-File -FilePath $Path -Encoding UTF8 -Append
    }
}

function Add-ProgressEvent {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$Step,
        [string]$Status = 'OK',
        [string]$Message = ''
    )
    $entry = [PSCustomObject]@{
        SchemaVersion = 'diagframework.collector.progress.v1'
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Step = $Step
        Status = $Status
        Message = $Message
    }
    $entry | ConvertTo-Json -Depth 6 -Compress | Out-File -FilePath (Join-Path $PackageRoot 'collector-progress.jsonl') -Encoding UTF8 -Append
}

function Convert-EventRecordFlat {
    param([Parameter(Mandatory)]$Event)
    [PSCustomObject]@{
        TimeCreated = if ($Event.TimeCreated) { ([datetime]$Event.TimeCreated).ToString('o') } else { $null }
        ProviderName = $Event.ProviderName
        LogName = $Event.LogName
        Id = $Event.Id
        LevelDisplayName = $Event.LevelDisplayName
        MachineName = $Event.MachineName
        RecordId = $Event.RecordId
        TaskDisplayName = $Event.TaskDisplayName
        OpcodeDisplayName = $Event.OpcodeDisplayName
        KeywordsDisplayNames = @($Event.KeywordsDisplayNames)
        Message = $Event.Message
    }
}

function Copy-IfExists {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [int64]$MaxBytes = 52428800
    )
    if (-not (Test-Path $Source)) { return $null }
    New-DirectorySafe -Path $DestinationRoot
    $item = Get-Item -Path $Source -ErrorAction Stop
    if ($item.PSIsContainer) {
        $target = Join-Path $DestinationRoot $item.Name
        New-DirectorySafe -Path $target
        $copied = New-Object System.Collections.Generic.List[object]
        Get-ChildItem -Path $item.FullName -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Length -le $MaxBytes) {
                $relative = [System.IO.Path]::GetRelativePath($item.FullName, $_.FullName)
                $dest = Join-Path $target $relative
                New-DirectorySafe -Path (Split-Path -Parent $dest)
                Copy-Item -Path $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
                $copied.Add([PSCustomObject]@{ Source=$_.FullName; Destination=$dest; Length=$_.Length; LastWriteTime=$_.LastWriteTime.ToString('o') }) | Out-Null
            }
        }
        return @($copied)
    }
    else {
        if ($item.Length -gt $MaxBytes) {
            return [PSCustomObject]@{ Source=$item.FullName; Skipped=$true; Reason='FileTooLarge'; Length=$item.Length }
        }
        $dest = Join-Path $DestinationRoot $item.Name
        Copy-Item -Path $item.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Source=$item.FullName; Destination=$dest; Length=$item.Length; LastWriteTime=$item.LastWriteTime.ToString('o') }
    }
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
        $values = $null
        if ($exists) {
            try { $values = Get-ItemProperty -Path $path | Select-Object * } catch { $values = $_.Exception.Message }
        }
        $result.Add([PSCustomObject]@{ Path=$path; Exists=$exists; Values=$values }) | Out-Null
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
        PowerShell = [PSCustomObject]@{ Version=$PSVersionTable.PSVersion.ToString(); Edition=$PSVersionTable.PSEdition; Platform=$PSVersionTable.Platform }
        OS = if ($os) { [PSCustomObject]@{ Caption=$os.Caption; Version=$os.Version; BuildNumber=$os.BuildNumber; Architecture=$os.OSArchitecture; InstallDate=([datetime]$os.InstallDate).ToString('o'); LastBootUpTime=([datetime]$os.LastBootUpTime).ToString('o') } } else { $null }
        ComputerSystem = if ($cs) { [PSCustomObject]@{ Manufacturer=$cs.Manufacturer; Model=$cs.Model; SystemType=$cs.SystemType; TotalPhysicalMemory=$cs.TotalPhysicalMemory } } else { $null }
        BIOS = if ($bios) { [PSCustomObject]@{ Manufacturer=$bios.Manufacturer; SMBIOSBIOSVersion=$bios.SMBIOSBIOSVersion; ReleaseDate=if ($bios.ReleaseDate) { ([datetime]$bios.ReleaseDate).ToString('o') } else { $null } } } else { $null }
    }
}

function Get-DriverSnapshot {
    try {
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Select-Object DeviceName, Manufacturer, DriverProviderName, DriverVersion, DriverDate, InfName, DeviceClass, IsSigned, Signer
    }
    catch {
        [PSCustomObject]@{ Error = $_.Exception.Message }
    }
}

function Collect-Events {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][datetime]$StartTime,
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
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName=$log; StartTime=$StartTime } -MaxEvents $MaxEvents -ErrorAction Stop | ForEach-Object { Convert-EventRecordFlat -Event $_ })
            $safe = ($log -replace '[\\/\:\*\?"\<\>\|]', '_')
            Write-JsonLinesSafe -InputObject $events -Path (Join-Path $eventRoot ($safe + '.jsonl'))
            $summary.Add([PSCustomObject]@{ LogName=$log; Status='OK'; Count=$events.Count; OutputFile=('events/' + $safe + '.jsonl') }) | Out-Null
        }
        catch {
            $summary.Add([PSCustomObject]@{ LogName=$log; Status='Error'; Error=$_.Exception.Message }) | Out-Null
        }
    }
    Write-JsonSafe -InputObject @($summary) -Path (Join-Path $eventRoot 'event-summary.json') -Depth 6
    return @($summary)
}

function Invoke-EvidenceCollection {
    param([int]$DaysBack = 30, [int]$MaxEvents = 1200, [switch]$WhatIf)
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $packageRoot = Join-Path (Join-Path $LogRoot 'evidence_packages') ("$timestamp-$env:COMPUTERNAME-SystemEvidence")
    $zipPath = "$packageRoot.zip"
    New-DirectorySafe -Path $packageRoot
    foreach ($sub in 'meta','events','registry','copied_logs','drivers','commands','errors','vendor_logs') { New-DirectorySafe -Path (Join-Path $packageRoot $sub) }

    Add-ProgressEvent -PackageRoot $packageRoot -Step 'Start' -Message "DaysBack=$DaysBack MaxEvents=$MaxEvents WhatIf=$($WhatIf.IsPresent)"

    if ($WhatIf) {
        $summary = [PSCustomObject]@{
            SchemaVersion='diagframework.systemevidence.summary.v1'
            ModuleVersion=$ModuleVersion
            WhatIf=$true
            Summary='WhatIf mód: a modul nem gyűjtött fájlokat, csak jelezte a tervezett evidence package műveletet.'
            PlannedPackageRoot=$packageRoot
            PlannedZipPath=$zipPath
        }
        Write-JsonSafe -InputObject $summary -Path (Join-Path $packageRoot 'ai_summary.json') -Depth 8
        return $summary
    }

    $errors = New-Object System.Collections.Generic.List[object]
    $startTime = (Get-Date).AddDays(-1 * [Math]::Abs($DaysBack))

    try { Write-JsonSafe -InputObject (Get-SystemSnapshot) -Path (Join-Path $packageRoot 'meta/system-info.json') -Depth 8; Add-ProgressEvent -PackageRoot $packageRoot -Step 'SystemSnapshot' } catch { $errors.Add([PSCustomObject]@{ Step='SystemSnapshot'; Error=$_.Exception.Message }) | Out-Null }
    try { Write-JsonSafe -InputObject (Get-RebootPendingSnapshot) -Path (Join-Path $packageRoot 'registry/reboot-pending.json') -Depth 10; Add-ProgressEvent -PackageRoot $packageRoot -Step 'RegistryPendingReboot' } catch { $errors.Add([PSCustomObject]@{ Step='RegistryPendingReboot'; Error=$_.Exception.Message }) | Out-Null }
    try { Write-JsonSafe -InputObject (Get-DriverSnapshot) -Path (Join-Path $packageRoot 'drivers/pnp-signed-drivers.json') -Depth 8; Add-ProgressEvent -PackageRoot $packageRoot -Step 'DriverSnapshot' } catch { $errors.Add([PSCustomObject]@{ Step='DriverSnapshot'; Error=$_.Exception.Message }) | Out-Null }
    try { $eventSummary = Collect-Events -PackageRoot $packageRoot -StartTime $startTime -MaxEvents $MaxEvents; Add-ProgressEvent -PackageRoot $packageRoot -Step 'EventLogs' } catch { $errors.Add([PSCustomObject]@{ Step='EventLogs'; Error=$_.Exception.Message }) | Out-Null; $eventSummary=@() }

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
    $copied = New-Object System.Collections.Generic.List[object]
    foreach ($target in $copyTargets) {
        try {
            $destRoot = if ($target -match 'ProgramData\\(Dell|HP|Lenovo|Intel|NVIDIA Corporation|AMD)') { Join-Path $packageRoot 'vendor_logs' } else { Join-Path $packageRoot 'copied_logs' }
            $result = Copy-IfExists -Source $target -DestinationRoot $destRoot
            if ($null -ne $result) { foreach ($r in @($result)) { $copied.Add($r) | Out-Null } }
        }
        catch { $errors.Add([PSCustomObject]@{ Step='CopyTarget'; Target=$target; Error=$_.Exception.Message }) | Out-Null }
    }
    Write-JsonSafe -InputObject @($copied) -Path (Join-Path $packageRoot 'copied_logs/copied-files.json') -Depth 8
    Add-ProgressEvent -PackageRoot $packageRoot -Step 'CopyLogs' -Message "CopiedRecords=$($copied.Count)"

    $nativeResults = New-Object System.Collections.Generic.List[object]
    $commands = @(
        @{ Name='reagentc-info'; File='reagentc.exe'; Args=@('/info') },
        @{ Name='bcdedit-enum-all'; File='bcdedit.exe'; Args=@('/enum','all') },
        @{ Name='dism-packages'; File='dism.exe'; Args=@('/Online','/Get-Packages','/Format:Table') },
        @{ Name='dism-checkhealth'; File='dism.exe'; Args=@('/Online','/Cleanup-Image','/CheckHealth') }
    )
    foreach ($cmd in $commands) {
        try {
            $outFile = Join-Path $packageRoot ('commands/' + $cmd.Name + '.txt')
            $errFile = Join-Path $packageRoot ('commands/' + $cmd.Name + '.err.txt')
            $p = Start-Process -FilePath $cmd.File -ArgumentList $cmd.Args -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $nativeResults.Add([PSCustomObject]@{ Name=$cmd.Name; ExitCode=$p.ExitCode; StdOut=$outFile; StdErr=$errFile }) | Out-Null
        }
        catch { $nativeResults.Add([PSCustomObject]@{ Name=$cmd.Name; Error=$_.Exception.Message }) | Out-Null }
    }
    Write-JsonSafe -InputObject @($nativeResults) -Path (Join-Path $packageRoot 'commands/native-command-results.json') -Depth 6

    $summary = [PSCustomObject]@{
        SchemaVersion = 'diagframework.systemevidence.summary.v1'
        ModuleId = $ModuleId
        ModuleVersion = $ModuleVersion
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName = $env:COMPUTERNAME
        DaysBack = $DaysBack
        MaxEvents = $MaxEvents
        PackageRoot = $packageRoot
        ZipPath = $zipPath
        EventLogCount = @($eventSummary).Count
        CopiedRecordCount = $copied.Count
        ErrorCount = $errors.Count
        Purpose = 'AI/szakértő által elemezhető Windows 11 rendszerbizonyíték-csomag boot, setup, driver, update, crash és vendor diagnosztikai hibákhoz.'
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $packageRoot 'ai_summary.json') -Depth 8
    Write-JsonSafe -InputObject @($errors) -Path (Join-Path $packageRoot 'errors/collector-errors.json') -Depth 8

    @"
# System Evidence Package

Generated: $((Get-Date).ToString('o'))
Computer: $env:COMPUTERNAME
Module: $ModuleId $ModuleVersion

## Purpose
This ZIP contains Windows 11 boot, setup, driver, update, crash and vendor diagnostic evidence for AI or expert review.

## Important
This package was generated by a read-only collector. It does not repair or modify the system.
"@ | Out-File -FilePath (Join-Path $packageRoot 'AI_README.md') -Encoding UTF8 -Force

    $manifest = [PSCustomObject]@{
        SchemaVersion='diagframework.package.manifest.v1'
        PackageType='SystemEvidence'
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        ModuleId=$ModuleId
        ModuleVersion=$ModuleVersion
        ComputerName=$env:COMPUTERNAME
        Files=@(Get-ChildItem -Path $packageRoot -File -Recurse | ForEach-Object { [PSCustomObject]@{ RelativePath=[System.IO.Path]::GetRelativePath($packageRoot,$_.FullName); Length=$_.Length; LastWriteTime=$_.LastWriteTime.ToString('o') } })
    }
    Write-JsonSafe -InputObject $manifest -Path (Join-Path $packageRoot 'manifest.json') -Depth 10

    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -Force
    Add-ProgressEvent -PackageRoot $packageRoot -Step 'Zip' -Message $zipPath
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
    'Invoke-Fix' { Invoke-EvidenceCollection -DaysBack $DaysBack -MaxEvents $MaxEvents -WhatIf:$WhatIf }
    'Invoke-Rollback' {
        [PSCustomObject]@{
            RollbackSupported = $false
            Summary = 'A SystemEvidenceCollector nem módosít rendszert, ezért rollback nem szükséges.'
        }
    }
}
