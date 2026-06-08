[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Get-Metadata','Test-Condition','Invoke-Fix','Invoke-Rollback')][string]$Action,
    [switch]$WhatIf,
    [string]$LogRoot = (Join-Path $PSScriptRoot '..\..\logs'),
    [string]$TargetKB = 'KB5089573',
    [int]$DaysBack = 30,
    [int]$MaxEvents = 800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ModuleId = 'AILogCollector'
$ModuleVersion = '1.1.1'

function Get-Metadata {
    [PSCustomObject]@{
        Id = $ModuleId
        Name = 'AI LOG csomag gyűjtő'
        Version = $ModuleVersion
        Risk = 'Low'
    }
}

function New-SafeName {
    param([Parameter(Mandatory)][string]$Value)
    return ($Value -replace '[^A-Za-z0-9_.-]', '_')
}

function Limit-Text {
    param(
        [AllowNull()]$Value,
        [int]$MaxLength = 20000
    )
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ($text.Length -le $MaxLength) { return $text }
    return ($text.Substring(0, $MaxLength) + "`n...[TRUNCATED by DiagFramework, original length: $($text.Length)]")
}

function ConvertTo-SimpleValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return ([datetime]$Value).ToString('o') }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [array]) {
        $out = @()
        foreach ($v in $Value) { $out += ,(Limit-Text -Value $v -MaxLength 4000) }
        return $out
    }
    return (Limit-Text -Value $Value -MaxLength 8000)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 12
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
    $json = $InputObject | ConvertTo-Json -Depth $Depth -WarningAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($json)) { $json = 'null' }
    $json | Out-File -FilePath $Path -Encoding UTF8 -Force
}

function Write-JsonLines {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 8
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
    if (Test-Path $Path) { Remove-Item $Path -Force }
    foreach ($item in @($Items)) {
        $item | ConvertTo-Json -Depth $Depth -Compress -WarningAction SilentlyContinue | Out-File -FilePath $Path -Encoding UTF8 -Append
    }
}

function Write-CollectorStep {
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$Step,
        [ValidateSet('Started','Completed','Warning','Error')][string]$Status = 'Completed',
        [AllowNull()]$Data
    )
    try {
        $entry = [ordered]@{
            SchemaVersion = 'diagframework.collector.step.v1'
            TimestampLocal = (Get-Date).ToString('o')
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            ModuleId = $ModuleId
            ModuleVersion = $ModuleVersion
            Step = $Step
            Status = $Status
            Data = $Data
        }
        $path = Join-Path $PackageRoot 'collector-progress.jsonl'
        $entry | ConvertTo-Json -Depth 8 -Compress -WarningAction SilentlyContinue | Out-File -FilePath $path -Encoding UTF8 -Append
    } catch { }
}

function New-ErrorRecordObject {
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [string]$Step
    )
    [PSCustomObject]@{
        Step = $Step
        Message = $ErrorRecord.Exception.Message
        TypeName = $ErrorRecord.Exception.GetType().FullName
        Category = $ErrorRecord.CategoryInfo.ToString()
        FullyQualifiedErrorId = $ErrorRecord.FullyQualifiedErrorId
        ScriptStackTrace = $ErrorRecord.ScriptStackTrace
        PositionMessage = $ErrorRecord.InvocationInfo.PositionMessage
    }
}

function Invoke-NativeCommandSafe {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 300
    )

    $tempOut = [System.IO.Path]::GetTempFileName()
    $tempErr = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr -ErrorAction Stop
        [PSCustomObject]@{
            FilePath = $FilePath
            Arguments = @($Arguments)
            ExitCode = $process.ExitCode
            StdOut = Limit-Text -Value (Get-Content -Path $tempOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) -MaxLength 200000
            StdErr = Limit-Text -Value (Get-Content -Path $tempErr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) -MaxLength 50000
        }
    }
    catch {
        [PSCustomObject]@{
            FilePath = $FilePath
            Arguments = @($Arguments)
            ExitCode = $null
            StdOut = ''
            StdErr = $_.Exception.Message
        }
    }
    finally {
        Remove-Item -Path $tempOut,$tempErr -Force -ErrorAction SilentlyContinue
    }
}

function Get-StringHash {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-OSSnapshot {
    $os = $null
    $cs = $null
    $bios = $null
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop } catch { }

    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        TimestampLocal = (Get-Date).ToString('o')
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        PowerShell = [PSCustomObject]@{
            Version = $PSVersionTable.PSVersion.ToString()
            Edition = $PSVersionTable.PSEdition
            Platform = if ($PSVersionTable.ContainsKey('Platform')) { $PSVersionTable.Platform } else { $null }
        }
        OS = if ($os) {
            [PSCustomObject]@{
                Caption = $os.Caption
                Version = $os.Version
                BuildNumber = $os.BuildNumber
                OSArchitecture = $os.OSArchitecture
                WindowsDirectory = $os.WindowsDirectory
                SystemDirectory = $os.SystemDirectory
                InstallDate = if ($os.InstallDate) { ([datetime]$os.InstallDate).ToString('o') } else { $null }
                LastBootUpTime = if ($os.LastBootUpTime) { ([datetime]$os.LastBootUpTime).ToString('o') } else { $null }
            }
        } else { $null }
        ComputerSystem = if ($cs) {
            [PSCustomObject]@{
                Manufacturer = $cs.Manufacturer
                Model = $cs.Model
                SystemType = $cs.SystemType
                Domain = $cs.Domain
                TotalPhysicalMemoryGB = if ($cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 2) } else { $null }
            }
        } else { $null }
        BIOS = if ($bios) {
            [PSCustomObject]@{
                Manufacturer = $bios.Manufacturer
                SMBIOSBIOSVersion = $bios.SMBIOSBIOSVersion
                ReleaseDate = if ($bios.ReleaseDate) { ([datetime]$bios.ReleaseDate).ToString('o') } else { $null }
                SerialNumberHash = if ($bios.SerialNumber) { (Get-StringHash -Value $bios.SerialNumber) } else { $null }
            }
        } else { $null }
    }
}

function Get-RegistrySnapshot {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'
    )

    $items = @()
    foreach ($path in $paths) {
        $exists = Test-Path $path
        $props = $null
        if ($exists) {
            try {
                $raw = Get-ItemProperty -Path $path -ErrorAction Stop
                $props = [ordered]@{}
                foreach ($p in $raw.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') { $props[$p.Name] = ConvertTo-SimpleValue -Value $p.Value }
                }
            }
            catch { $props = @{ Error = $_.Exception.Message } }
        }
        $items += ,[PSCustomObject]@{ Path = $path; Exists = $exists; Properties = $props }
    }

    $pendingRename = $null
    try {
        $pendingRename = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations
    } catch { }

    [PSCustomObject]@{
        RebootPending = @($items | Where-Object { $_.Path -match 'RebootPending|PackagesPending|PostRebootReporting' -and $_.Exists }).Count -gt 0
        PendingFileRenameOperationsExists = $null -ne $pendingRename
        PendingFileRenameOperations = ConvertTo-SimpleValue -Value $pendingRename
        RegistryKeys = @($items)
    }
}

function Convert-EventRecord {
    param([Parameter(Mandatory)]$Event)
    $props = @()
    try {
        foreach ($p in @($Event.Properties)) { $props += ,(ConvertTo-SimpleValue -Value $p.Value) }
    } catch { }

    [PSCustomObject]@{
        TimeCreated = if ($Event.TimeCreated) { ([datetime]$Event.TimeCreated).ToString('o') } else { $null }
        LogName = ConvertTo-SimpleValue -Value $Event.LogName
        ProviderName = ConvertTo-SimpleValue -Value $Event.ProviderName
        Id = $Event.Id
        Level = $Event.Level
        LevelDisplayName = ConvertTo-SimpleValue -Value $Event.LevelDisplayName
        OpcodeDisplayName = ConvertTo-SimpleValue -Value $Event.OpcodeDisplayName
        TaskDisplayName = ConvertTo-SimpleValue -Value $Event.TaskDisplayName
        RecordId = $Event.RecordId
        ProcessId = $Event.ProcessId
        ThreadId = $Event.ThreadId
        MachineName = ConvertTo-SimpleValue -Value $Event.MachineName
        Message = Limit-Text -Value $Event.Message -MaxLength 20000
        Properties = @($props)
    }
}

function Get-EventsFromLog {
    param(
        [Parameter(Mandatory)][string]$LogName,
        [Parameter(Mandatory)][datetime]$StartTime,
        [int]$MaxEvents = 800
    )

    try {
        $log = Get-WinEvent -ListLog $LogName -ErrorAction Stop
        if (-not $log.IsEnabled) {
            return [PSCustomObject]@{ LogName=$LogName; Available=$true; Enabled=$false; Error='Log letiltva'; Events=@() }
        }
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $LogName; StartTime = $StartTime } -MaxEvents $MaxEvents -ErrorAction Stop | ForEach-Object { Convert-EventRecord -Event $_ })
        return [PSCustomObject]@{ LogName=$LogName; Available=$true; Enabled=$true; Error=$null; Events=$events }
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'No events were found|nem található esemény|There are no events') {
            return [PSCustomObject]@{ LogName=$LogName; Available=$true; Enabled=$true; Error=$null; Events=@() }
        }
        return [PSCustomObject]@{ LogName=$LogName; Available=$false; Enabled=$false; Error=$message; Events=@() }
    }
}

function Convert-HResultToHex {
    param([AllowNull()]$HResult)
    if ($null -eq $HResult) { return $null }
    try {
        $bytes = [BitConverter]::GetBytes([int]$HResult)
        $unsigned = [BitConverter]::ToUInt32($bytes, 0)
        return ('0x{0:X8}' -f $unsigned)
    } catch {
        return ([string]$HResult)
    }
}

function Get-UpdateHistory {
    param([string]$TargetKB)
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()
        $take = [Math]::Min([int]$count, 300)
        if ($take -le 0) { return @() }
        $items = @($searcher.QueryHistory(0, $take))
        $map = @{ 0='NotStarted'; 1='InProgress'; 2='Succeeded'; 3='SucceededWithErrors'; 4='Failed'; 5='Aborted' }
        $out = @()
        foreach ($item in $items) {
            $resultCode = [int]$item.ResultCode
            $out += ,[PSCustomObject]@{
                Date = if ($item.Date) { ([datetime]$item.Date).ToString('o') } else { $null }
                Title = ConvertTo-SimpleValue -Value $item.Title
                Description = Limit-Text -Value $item.Description -MaxLength 4000
                Operation = $item.Operation
                ResultCode = $resultCode
                ResultText = if ($map.ContainsKey($resultCode)) { $map[$resultCode] } else { [string]$resultCode }
                HResult = Convert-HResultToHex -HResult $item.HResult
                SupportUrl = ConvertTo-SimpleValue -Value $item.SupportUrl
                ClientApplicationID = ConvertTo-SimpleValue -Value $item.ClientApplicationID
                MatchesTargetKB = ($item.Title -match [regex]::Escape($TargetKB) -or $item.Description -match [regex]::Escape($TargetKB))
            }
        }
        return @($out)
    }
    catch {
        return @([PSCustomObject]@{ Error = $_.Exception.Message })
    }
}

function Copy-ExistingFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [string]$Prefix = ''
    )
    $copied = @()
    if (-not (Test-Path $DestinationFolder)) { New-Item -Path $DestinationFolder -ItemType Directory -Force | Out-Null }
    if (Test-Path $Source) {
        try {
            $item = Get-Item -Path $Source -ErrorAction Stop
            if ($item.PSIsContainer) { return @($copied) }
            $name = if ($Prefix) { "$Prefix$($item.Name)" } else { $item.Name }
            $dest = Join-Path $DestinationFolder $name
            Copy-Item -Path $item.FullName -Destination $dest -Force -ErrorAction Stop
            $copied += ,[PSCustomObject]@{ Source=$item.FullName; Destination=$dest; Length=$item.Length; LastWriteTime=$item.LastWriteTime.ToString('o') }
        }
        catch { $copied += ,[PSCustomObject]@{ Source=$Source; Error=$_.Exception.Message } }
    }
    return @($copied)
}

function Get-RelativePathSafe {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$FullName
    )
    try {
        return [System.IO.Path]::GetRelativePath($Root, $FullName)
    }
    catch {
        $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\','/'))
        $fileFull = [System.IO.Path]::GetFullPath($FullName)
        if ($fileFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $fileFull.Substring($rootFull.Length).TrimStart([char[]]@('\','/'))
        }
        return (Split-Path -Leaf $FullName)
    }
}

function Copy-RecentLogsFromFolder {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [string[]]$Include = @('*.log','*.txt'),
        [datetime]$Since,
        [int]$MaxFiles = 40
    )
    $copied = @()
    if (-not (Test-Path $Folder)) { return @([PSCustomObject]@{ Folder=$Folder; Exists=$false }) }
    if (-not (Test-Path $DestinationFolder)) { New-Item -Path $DestinationFolder -ItemType Directory -Force | Out-Null }
    try {
        $files = @(Get-ChildItem -Path $Folder -File -Include $Include -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not $Since -or $_.LastWriteTime -ge $Since } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First $MaxFiles)
        foreach ($file in $files) {
            $safeRel = New-SafeName -Value (Get-RelativePathSafe -Root $Folder -FullName $file.FullName)
            $dest = Join-Path $DestinationFolder $safeRel
            Copy-Item -Path $file.FullName -Destination $dest -Force -ErrorAction Stop
            $copied += ,[PSCustomObject]@{ Source=$file.FullName; Destination=$dest; Length=$file.Length; LastWriteTime=$file.LastWriteTime.ToString('o') }
        }
    }
    catch { $copied += ,[PSCustomObject]@{ Folder=$Folder; Error=$_.Exception.Message } }
    return @($copied)
}

function Invoke-GetWindowsUpdateLog {
    param([Parameter(Mandatory)][string]$DestinationFolder)
    if (-not (Test-Path $DestinationFolder)) { New-Item -Path $DestinationFolder -ItemType Directory -Force | Out-Null }
    $logPath = Join-Path $DestinationFolder 'WindowsUpdate.log'
    $transcriptPath = Join-Path $DestinationFolder 'Get-WindowsUpdateLog-command-output.txt'
    try {
        $cmd = Get-Command Get-WindowsUpdateLog -ErrorAction SilentlyContinue
        if ($cmd) {
            $out = Get-WindowsUpdateLog -LogPath $logPath -ErrorAction Stop 2>&1
            $out | Out-File -FilePath $transcriptPath -Encoding UTF8 -Force
            return [PSCustomObject]@{ Method='pwsh-current'; Success=(Test-Path $logPath); LogPath=$logPath; OutputPath=$transcriptPath }
        }

        $winPs = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path $winPs) {
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Get-WindowsUpdateLog -LogPath '$logPath'"))
            $res = Invoke-NativeCommandSafe -FilePath $winPs -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -TimeoutSeconds 600
            $res | ConvertTo-Json -Depth 8 -WarningAction SilentlyContinue | Out-File -FilePath $transcriptPath -Encoding UTF8 -Force
            return [PSCustomObject]@{ Method='WindowsPowerShell-fallback'; Success=(Test-Path $logPath); LogPath=$logPath; OutputPath=$transcriptPath; ExitCode=$res.ExitCode }
        }

        return [PSCustomObject]@{ Method='none'; Success=$false; Error='Get-WindowsUpdateLog nem érhető el, és Windows PowerShell fallback sem található.' }
    }
    catch {
        return [PSCustomObject]@{ Method='error'; Success=$false; Error=$_.Exception.Message; LogPath=$logPath; OutputPath=$transcriptPath }
    }
}

function Get-ErrorCodesFromTextFiles {
    param([Parameter(Mandatory)][string]$Root)
    $records = @()
    $files = @(Get-ChildItem -Path $Root -File -Include *.log,*.txt,*.json,*.jsonl -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 50MB })
    foreach ($file in $files) {
        try {
            $lineNo = 0
            Get-Content -Path $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
                $lineNo++
                $line = [string]$_
                $matches = [regex]::Matches($line, '0x[0-9a-fA-F]{8}')
                foreach ($m in $matches) {
                    $relative = Get-RelativePathSafe -Root $Root -FullName $file.FullName
                    $records += ,[PSCustomObject]@{
                        Code = $m.Value.ToLowerInvariant()
                        File = $relative
                        Line = $lineNo
                        Context = $line.Substring(0, [Math]::Min($line.Length, 500))
                    }
                }
            }
        } catch { }
    }
    return @($records | Group-Object Code | Sort-Object Count -Descending | ForEach-Object {
        [PSCustomObject]@{ Code=$_.Name; Count=$_.Count; Samples=@($_.Group | Select-Object -First 5) }
    })
}

function New-AiReadme {
    param([string]$Path, [string]$TargetKB, [int]$DaysBack)
    @"
# DiagFramework AI LOG csomag

Célzott KB: $TargetKB
Időablak: utolsó $DaysBack nap
Készült: $(Get-Date -Format o)
Gép: $env:COMPUTERNAME
Gyűjtő modul: $ModuleId $ModuleVersion

## AI elemzési javaslat
1. Kezdd az ai_summary.json fájllal.
2. Nézd meg az updates/update-history.json fájlban a TargetKB találatokat és HResult értékeket.
3. Keresd az errors/error-codes.json fájlban a gyakori 0x... hibakódokat.
4. Nézd meg az events/*.jsonl állományokban a WindowsUpdateClient, UpdateOrchestrator, Servicing és Setup hibákat.
5. Telepítési/rollback hibánál nézd át a copied_logs/CBS.log, copied_logs/dism.log, Panther és MoSetup logokat.
6. Függő újraindításnál ellenőrizd a registry/reboot-pending.json fájlt.
7. A collector-progress.jsonl mutatja, meddig jutott a gyűjtés, és volt-e nem végzetes hiba.

## Fontos
A csomag diagnosztikai adatokat tartalmazhat: gépnév, felhasználónév, telepített csomagok, eseménynapló üzenetek, elérési utak. Külső AI-nak küldés előtt szükség esetén anonimizáld.
"@ | Out-File -FilePath $Path -Encoding UTF8 -Force
}

function Test-Condition {
    $normalizedKB = $TargetKB.Trim().ToUpperInvariant()
    $history = @(Get-UpdateHistory -TargetKB $normalizedKB)
    $targetHits = @($history | Where-Object { $_.PSObject.Properties['MatchesTargetKB'] -and $_.MatchesTargetKB })
    $failedHits = @($targetHits | Where-Object { $_.PSObject.Properties['ResultText'] -and $_.ResultText -match 'Failed|Aborted|Errors' })
    $reboot = Get-RegistrySnapshot

    $issue = ($failedHits.Count -gt 0) -or $reboot.RebootPending -or $reboot.PendingFileRenameOperationsExists
    [PSCustomObject]@{
        ModuleId = $ModuleId
        Severity = if ($issue) { 'Medium' } else { 'Info' }
        IssueDetected = $true
        FixAvailable = $true
        Summary = "AI LOG csomag készíthető a(z) $normalizedKB frissítéshez. Előzmény-találatok: $($targetHits.Count), hibás/aborted találatok: $($failedHits.Count), reboot-pending: $($reboot.RebootPending)."
        RecommendedAction = 'Készíts AI LOG csomagot javítás előtt; ez nem módosítja a Windows Update állapotát.'
        Details = [PSCustomObject]@{
            TargetKB = $normalizedKB
            DaysBack = $DaysBack
            HistoryTargetHits = $targetHits
            FailedTargetHits = $failedHits
            RebootPending = $reboot.RebootPending
            PendingFileRenameOperationsExists = $reboot.PendingFileRenameOperationsExists
        }
        RollbackHint = 'Nincs rollback, mert a modul csak naplókat gyűjt.'
    }
}

function Invoke-Fix {
    param([switch]$WhatIf)

    $normalizedKB = $TargetKB.Trim().ToUpperInvariant()
    if ($normalizedKB -notmatch '^KB\d{6,}$') { throw "Érvénytelen TargetKB: $normalizedKB" }
    if ($DaysBack -lt 1) { $DaysBack = 1 }
    if ($DaysBack -gt 180) { $DaysBack = 180 }
    if ($MaxEvents -lt 50) { $MaxEvents = 50 }
    if ($MaxEvents -gt 5000) { $MaxEvents = 5000 }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeKB = New-SafeName -Value $normalizedKB
    $packageBase = Join-Path $LogRoot 'ai_packages'
    $packageRoot = Join-Path $packageBase ("{0}-{1}-{2}" -f $stamp, (New-SafeName -Value $env:COMPUTERNAME), $safeKB)
    $zipPath = "$packageRoot.zip"

    $plan = @(
        'OS és PowerShell környezet snapshot',
        'Windows Update history COM API alapján',
        'Windows Update ETL konverzió olvasható WindowsUpdate.log fájlba',
        'Event log gyűjtés JSONL formában',
        'CBS/DISM/Panther/MoSetup/ReportingEvents logok másolása',
        'Registry reboot/pending és Windows Update policy állapotok mentése',
        'DISM /CheckHealth, csomaglista és hotfix lista mentése',
        'AI összefoglaló és ZIP csomag készítése'
    )

    if ($WhatIf) {
        return [PSCustomObject]@{ ModuleId=$ModuleId; Result='WhatIf'; TargetKB=$normalizedKB; DaysBack=$DaysBack; Planned=$plan; PlannedPackageRoot=$packageRoot; PlannedZip=$zipPath }
    }

    foreach ($dir in @('meta','updates','events','registry','commands','copied_logs','etl_metadata','errors')) {
        New-Item -Path (Join-Path $packageRoot $dir) -ItemType Directory -Force | Out-Null
    }

    $collectorErrors = @()
    $startTime = (Get-Date).AddDays(-1 * $DaysBack)
    $history = @()
    $targetHistory = @()
    $failedHistory = @()
    $registry = $null
    $wuLogResult = [PSCustomObject]@{ Success=$false; Error='NotStarted' }
    $eventSummary = @()
    $targetEventSamples = @()
    $copies = @()
    $errorCodes = @()
    $zipCreated = $false

    try {
        Write-CollectorStep -PackageRoot $packageRoot -Step 'PackageInit' -Status 'Started' -Data @{ TargetKB=$normalizedKB; DaysBack=$DaysBack; MaxEvents=$MaxEvents }

        $manifest = [ordered]@{
            SchemaVersion = 'diagframework.ai_package.v1'
            PackageId = "ai-$stamp-$safeKB"
            TargetKB = $normalizedKB
            DaysBack = $DaysBack
            CreatedAtLocal = (Get-Date).ToString('o')
            CreatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            ComputerName = $env:COMPUTERNAME
            ModuleId = $ModuleId
            ModuleVersion = $ModuleVersion
            Notes = 'A csomag javítást nem végez; csak diagnosztikai gyűjtés.'
        }
        Write-JsonFile -InputObject $manifest -Path (Join-Path $packageRoot 'manifest.json')
        New-AiReadme -Path (Join-Path $packageRoot 'AI_README.md') -TargetKB $normalizedKB -DaysBack $DaysBack
        Write-CollectorStep -PackageRoot $packageRoot -Step 'PackageInit' -Status 'Completed' -Data $null

        try {
            Write-CollectorStep -PackageRoot $packageRoot -Step 'SystemAndRegistrySnapshot' -Status 'Started' -Data $null
            Write-JsonFile -InputObject (Get-OSSnapshot) -Path (Join-Path $packageRoot 'meta\system-info.json')
            $registry = Get-RegistrySnapshot
            Write-JsonFile -InputObject $registry -Path (Join-Path $packageRoot 'registry\reboot-pending.json')
            Write-CollectorStep -PackageRoot $packageRoot -Step 'SystemAndRegistrySnapshot' -Status 'Completed' -Data $null
        } catch {
            $err = New-ErrorRecordObject -ErrorRecord $_ -Step 'SystemAndRegistrySnapshot'
            $collectorErrors += ,$err
            Write-CollectorStep -PackageRoot $packageRoot -Step 'SystemAndRegistrySnapshot' -Status 'Error' -Data $err
        }

        try {
            Write-CollectorStep -PackageRoot $packageRoot -Step 'UpdateHistory' -Status 'Started' -Data $null
            $history = @(Get-UpdateHistory -TargetKB $normalizedKB)
            $targetHistory = @($history | Where-Object { $_.PSObject.Properties['MatchesTargetKB'] -and $_.MatchesTargetKB })
            $failedHistory = @($targetHistory | Where-Object { $_.PSObject.Properties['ResultText'] -and $_.ResultText -match 'Failed|Aborted|Errors' })
            Write-JsonFile -InputObject $history -Path (Join-Path $packageRoot 'updates\update-history.json')
            Write-JsonFile -InputObject $targetHistory -Path (Join-Path $packageRoot "updates\target-$safeKB-history.json")
            $hotfix = @()
            try {
                $hotfix = @(Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | ForEach-Object {
                    [PSCustomObject]@{
                        HotFixID = $_.HotFixID
                        Description = $_.Description
                        InstalledBy = $_.InstalledBy
                        InstalledOn = if ($_.InstalledOn) { ([datetime]$_.InstalledOn).ToString('o') } else { $null }
                    }
                })
            } catch { $hotfix = @([PSCustomObject]@{ Error=$_.Exception.Message }) }
            Write-JsonFile -InputObject $hotfix -Path (Join-Path $packageRoot 'updates\get-hotfix.json')
            Write-CollectorStep -PackageRoot $packageRoot -Step 'UpdateHistory' -Status 'Completed' -Data @{ TargetHistoryCount=$targetHistory.Count; FailedHistoryCount=$failedHistory.Count }
        } catch {
            $err = New-ErrorRecordObject -ErrorRecord $_ -Step 'UpdateHistory'
            $collectorErrors += ,$err
            Write-CollectorStep -PackageRoot $packageRoot -Step 'UpdateHistory' -Status 'Error' -Data $err
        }

        try {
            Write-CollectorStep -PackageRoot $packageRoot -Step 'WindowsUpdateLog' -Status 'Started' -Data $null
            $wuLogResult = Invoke-GetWindowsUpdateLog -DestinationFolder (Join-Path $packageRoot 'copied_logs')
            Write-JsonFile -InputObject $wuLogResult -Path (Join-Path $packageRoot 'updates\get-windowsupdatelog-result.json')
            Write-CollectorStep -PackageRoot $packageRoot -Step 'WindowsUpdateLog' -Status 'Completed' -Data $wuLogResult
        } catch {
            $err = New-ErrorRecordObject -ErrorRecord $_ -Step 'WindowsUpdateLog'
            $collectorErrors += ,$err
            Write-CollectorStep -PackageRoot $packageRoot -Step 'WindowsUpdateLog' -Status 'Error' -Data $err
        }

        try {
            Write-CollectorStep -PackageRoot $packageRoot -Step 'EventLogs' -Status 'Started' -Data $null
            $eventLogs = @(
                'Microsoft-Windows-WindowsUpdateClient/Operational',
                'Microsoft-Windows-UpdateOrchestrator/Operational',
                'Microsoft-Windows-Servicing/Operational',
                'Microsoft-Windows-Bits-Client/Operational',
                'Microsoft-Windows-DeviceSetupManager/Admin',
                'Setup',
                'System',
                'Application'
            )
            foreach ($log in $eventLogs) {
                $result = Get-EventsFromLog -LogName $log -StartTime $startTime -MaxEvents $MaxEvents
                $safeLog = New-SafeName -Value $log
                Write-JsonLines -Items @($result.Events) -Path (Join-Path $packageRoot "events\$safeLog.jsonl")
                $errors = @($result.Events | Where-Object { $_.LevelDisplayName -match 'Error|Warning|Critical|Hiba|Figyelmeztetés|Kritikus' })
                $targetMatches = @($result.Events | Where-Object { ($_.Message -match [regex]::Escape($normalizedKB)) -or ((@($_.Properties) -join ' ') -match [regex]::Escape($normalizedKB)) })
                foreach ($ev in @($targetMatches | Select-Object -First 20)) { $targetEventSamples += ,$ev }
                $eventSummary += ,[PSCustomObject]@{
                    LogName = $log
                    Available = $result.Available
                    Enabled = $result.Enabled
                    Error = $result.Error
                    EventCount = @($result.Events).Count
                    ErrorOrWarningCount = $errors.Count
                    TargetKBMatchCount = $targetMatches.Count
                    File = "events\$safeLog.jsonl"
                }
            }
            Write-JsonFile -InputObject $eventSummary -Path (Join-Path $packageRoot 'events\event-summary.json')
            Write-JsonFile -InputObject @($targetEventSamples | Select-Object -First 100) -Path (Join-Path $packageRoot "events\target-$safeKB-event-samples.json")
            Write-CollectorStep -PackageRoot $packageRoot -Step 'EventLogs' -Status 'Completed' -Data @{ LogCount=$eventLogs.Count; EventSummaryCount=$eventSummary.Count; TargetEventSamples=$targetEventSamples.Count }
        } catch {
            $err = New-ErrorRecordObject -ErrorRecord $_ -Step 'EventLogs'
            $collectorErrors += ,$err
            Write-CollectorStep -PackageRoot $packageRoot -Step 'EventLogs' -Status 'Error' -Data $err
        }

        try {
            Write-CollectorStep -PackageRoot $packageRoot -Step 'CopyLogs' -Status 'Started' -Data $null
            foreach ($copySet in @(
                (Copy-ExistingFile -Source (Join-Path $env:WINDIR 'Logs\CBS\CBS.log') -DestinationFolder (Join-Path $packageRoot 'copied_logs')),
                (Copy-ExistingFile -Source (Join-Path $env:WINDIR 'Logs\DISM\dism.log') -DestinationFolder (Join-Path $packageRoot 'copied_logs')),
                (Copy-ExistingFile -Source (Join-Path $env:WINDIR 'SoftwareDistribution\ReportingEvents.log') -DestinationFolder (Join-Path $packageRoot 'copied_logs'))
            )) { foreach ($c in @($copySet)) { $copies += ,$c } }

            $folders = @(
                (Join-Path $env:WINDIR 'Panther'),
                (Join-Path $env:WINDIR 'Logs\MoSetup'),
                'C:\$WINDOWS.~BT\Sources\Panther',
                'C:\$WINDOWS.~BT\Sources\Rollback'
            )
            foreach ($folder in $folders) {
                foreach ($c in @(Copy-RecentLogsFromFolder -Folder $folder -DestinationFolder (Join-Path $packageRoot 'copied_logs') -Since $startTime -MaxFiles 60)) { $copies += ,$c }
            }
            Write-JsonFile -InputObject $copies -Path (Join-Path $packageRoot 'copied_logs\copied-files.json')
            Write-CollectorStep -PackageRoot $packageRoot -Step 'CopyLogs' -Status 'Completed' -Data @{ CopiedRecords=$copies.Count }
        } catch {
            $err = New-ErrorRecordObject -ErrorRecord $_ -Step 'CopyLogs'
            $collectorErrors += ,$err
            Write-CollectorStep -PackageRoot $packageRoot -Step 'CopyLogs' -Status 'Error' -Data $err
        }

        try {
            Write-CollectorStep -PackageRoot $packageRoot -Step 'EtwMetadataAndNativeCommands' -Status 'Started' -Data $null
            $etlDirs = @((Join-Path $env:WINDIR 'Logs\WindowsUpdate'), 'C:\ProgramData\USOShared\Logs')
            $etlMeta = @()
            foreach ($dir in $etlDirs) {
                if (Test-Path $dir) {
                    $etlMeta += @(Get-ChildItem -Path $dir -File -Include *.etl,*.log -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -ge $startTime } |
                        Sort-Object LastWriteTime -Descending |
                        Select-Object -First 100 |
                        ForEach-Object { [PSCustomObject]@{ FullName=$_.FullName; Length=$_.Length; LastWriteTime=$_.LastWriteTime.ToString('o') } })
                } else {
                    $etlMeta += ,[PSCustomObject]@{ FullName=$dir; Exists=$false }
                }
            }
            Write-JsonFile -InputObject $etlMeta -Path (Join-Path $packageRoot 'etl_metadata\etl-files.json')

            $commands = [ordered]@{}
            $commands['dism-checkhealth'] = Invoke-NativeCommandSafe -FilePath 'dism.exe' -Arguments @('/Online','/Cleanup-Image','/CheckHealth') -TimeoutSeconds 600
            $commands['dism-getpackages'] = Invoke-NativeCommandSafe -FilePath 'dism.exe' -Arguments @('/Online','/Get-Packages','/Format:Table') -TimeoutSeconds 600
            $commands['bcdedit'] = Invoke-NativeCommandSafe -FilePath 'bcdedit.exe' -Arguments @('/enum','{current}') -TimeoutSeconds 120
            $commands['bitsadmin-list'] = Invoke-NativeCommandSafe -FilePath 'bitsadmin.exe' -Arguments @('/list','/allusers') -TimeoutSeconds 180
            Write-JsonFile -InputObject $commands -Path (Join-Path $packageRoot 'commands\native-command-results.json')
            Write-CollectorStep -PackageRoot $packageRoot -Step 'EtwMetadataAndNativeCommands' -Status 'Completed' -Data @{ EtlRecords=$etlMeta.Count }
        } catch {
            $err = New-ErrorRecordObject -ErrorRecord $_ -Step 'EtwMetadataAndNativeCommands'
            $collectorErrors += ,$err
            Write-CollectorStep -PackageRoot $packageRoot -Step 'EtwMetadataAndNativeCommands' -Status 'Error' -Data $err
        }

        try {
            Write-CollectorStep -PackageRoot $packageRoot -Step 'ErrorCodeExtraction' -Status 'Started' -Data $null
            $errorCodes = @(Get-ErrorCodesFromTextFiles -Root $packageRoot)
            Write-JsonFile -InputObject $errorCodes -Path (Join-Path $packageRoot 'errors\error-codes.json')
            Write-CollectorStep -PackageRoot $packageRoot -Step 'ErrorCodeExtraction' -Status 'Completed' -Data @{ UniqueCodes=$errorCodes.Count }
        } catch {
            $err = New-ErrorRecordObject -ErrorRecord $_ -Step 'ErrorCodeExtraction'
            $collectorErrors += ,$err
            Write-CollectorStep -PackageRoot $packageRoot -Step 'ErrorCodeExtraction' -Status 'Error' -Data $err
        }

        $summary = [PSCustomObject]@{
            SchemaVersion = 'diagframework.ai_summary.v1'
            TargetKB = $normalizedKB
            CreatedAtLocal = (Get-Date).ToString('o')
            PackageRoot = $packageRoot
            CollectorVersion = $ModuleVersion
            CollectorErrorCount = $collectorErrors.Count
            CollectorErrors = @($collectorErrors)
            WindowsUpdateLogGenerated = $wuLogResult.Success
            RebootPending = if ($registry) { $registry.RebootPending } else { $null }
            PendingFileRenameOperationsExists = if ($registry) { $registry.PendingFileRenameOperationsExists } else { $null }
            TargetHistoryCount = $targetHistory.Count
            FailedOrAbortedTargetHistoryCount = $failedHistory.Count
            LastTargetHistory = @($targetHistory | Sort-Object Date -Descending | Select-Object -First 10)
            EventSummary = @($eventSummary)
            TargetEventSamples = @($targetEventSamples | Select-Object -First 20)
            TopErrorCodes = @($errorCodes | Select-Object -First 20)
            CollectedFiles = @($copies)
            AnalysisHints = @(
                'Ha a TargetHistory HResult 0x8024..., 0x800f..., 0x8007... kódokat mutat, azok alapján induljon a mélyelemzés.',
                'Ha RebootPending vagy PendingFileRenameOperations igaz, a gép valószínűleg függő újraindítási tranzakcióban maradt.',
                'Ha CBS.log vagy DISM.log 0x800f081f/0x800f0922/0x800f098x kódokat tartalmaz, komponens-store vagy servicing hiba valószínű.',
                'Többszöri rollback esetén a Panther és MoSetup logok időrendje különösen fontos.'
            )
        }
        Write-JsonFile -InputObject $summary -Path (Join-Path $packageRoot 'ai_summary.json')
        Write-JsonFile -InputObject @($collectorErrors) -Path (Join-Path $packageRoot 'collector-errors.json')
    }
    catch {
        $fatal = New-ErrorRecordObject -ErrorRecord $_ -Step 'FatalCollectorScope'
        $collectorErrors += ,$fatal
        Write-JsonFile -InputObject @($collectorErrors) -Path (Join-Path $packageRoot 'collector-errors.json')
        Write-CollectorStep -PackageRoot $packageRoot -Step 'FatalCollectorScope' -Status 'Error' -Data $fatal
    }
    finally {
        try {
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
            Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -Force -ErrorAction Stop
            $zipCreated = Test-Path $zipPath
            Write-CollectorStep -PackageRoot $packageRoot -Step 'ZipPackage' -Status 'Completed' -Data @{ ZipPath=$zipPath; ZipCreated=$zipCreated }
        } catch {
            $err = New-ErrorRecordObject -ErrorRecord $_ -Step 'ZipPackage'
            $collectorErrors += ,$err
            Write-JsonFile -InputObject @($collectorErrors) -Path (Join-Path $packageRoot 'collector-errors.json')
            Write-CollectorStep -PackageRoot $packageRoot -Step 'ZipPackage' -Status 'Error' -Data $err
        }
    }

    [PSCustomObject]@{
        ModuleId = $ModuleId
        Result = if ($collectorErrors.Count -gt 0) { 'CompletedWithWarnings' } else { 'Completed' }
        TargetKB = $normalizedKB
        PackageRoot = $packageRoot
        ZipPath = $zipPath
        ZipCreated = $zipCreated
        SummaryFile = (Join-Path $packageRoot 'ai_summary.json')
        CollectorErrorCount = $collectorErrors.Count
        WindowsUpdateLogGenerated = $wuLogResult.Success
        TargetHistoryCount = $targetHistory.Count
        FailedOrAbortedTargetHistoryCount = $failedHistory.Count
        RebootPending = if ($registry) { $registry.RebootPending } else { $null }
    }
}

function Invoke-Rollback {
    [PSCustomObject]@{ ModuleId=$ModuleId; Result='NoRollback'; Message='Az AI LOG gyűjtés csak olvasási/másolási művelet; nincs rollback.' }
}

switch ($Action) {
    'Get-Metadata' { Get-Metadata }
    'Test-Condition' { Test-Condition }
    'Invoke-Fix' { Invoke-Fix -WhatIf:$WhatIf }
    'Invoke-Rollback' { Invoke-Rollback }
}
