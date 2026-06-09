<#
.SYNOPSIS
  DiagFramework P1 normalizálók alrendszer.
.DESCRIPTION
  v1.4.0 P1 Normalizers Pack.
  A legutóbbi vagy megadott SystemEvidence csomag nyers/köztes evidence fájljait normalizált,
  AI-barát, deduplikált és rangsorolt JSON kimenetekké alakítja.

  Read-only modul: nem javít rendszert és nem módosít Windows konfigurációt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Get-Metadata','Test-Condition','Invoke-Fix','Invoke-Rollback')][string]$Action,
    [switch]$WhatIf,
    [string]$LogRoot = (Join-Path $PSScriptRoot '..\..\logs'),
    [string]$TargetKB = '',
    [int]$DaysBack = 30,
    [int]$MaxEvents = 1200,
    [string]$PackageRoot = ''
)

$ErrorActionPreference = 'Stop'
$ModuleId = 'P1Normalizers'
$ModuleVersion = '1.4.0'

function Get-Metadata {
    [PSCustomObject]@{
        Id = $ModuleId
        Name = 'P1 normalizálók'
        Version = $ModuleVersion
        Risk = 'Low'
        Summary = 'WER, SetupAPI, CBS HRESULT, Driver/PnP, Event correlation és Windows Update error normalizálás meglévő evidence csomagból.'
    }
}

function New-DirectorySafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
}

function Get-ObjectPropertyValueSafe {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $Default }
        if ($null -eq $prop.Value) { return $Default }
        return $prop.Value
    } catch { return $Default }
}

function ConvertTo-SafeString {
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [array]) { return (@($Value) | ForEach-Object { ConvertTo-SafeString $_ }) -join '; ' }
        return [string]$Value
    } catch { return '<UnserializableValue>' }
}

function Write-JsonSafe {
    param($InputObject, [string]$Path, [int]$Depth = 12)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-DirectorySafe $parent }
    try { $InputObject | ConvertTo-Json -Depth $Depth -ErrorAction Stop | Out-File -LiteralPath $Path -Encoding UTF8 -Force }
    catch {
        [PSCustomObject]@{
            SchemaVersion = 'diagframework.p1.jsonfallback.v1'
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            JsonSerializationFailed = $true
            Error = $_.Exception.Message
            Text = ConvertTo-SafeString ($InputObject | Out-String)
        } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding UTF8 -Force
    }
}

function Read-JsonSafe {
    param([string]$Path, $Default = $null)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $Default }
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        return ($raw | ConvertFrom-Json -NoEnumerate -ErrorAction Stop)
    } catch { return $Default }
}

function Read-JsonLinesSafe {
    param([string]$Path, [int]$MaxLines = 200000)
    $items = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $items }
    $count = 0
    try {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ($count -ge $MaxLines) { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $items += ($line | ConvertFrom-Json -NoEnumerate -ErrorAction Stop); $count++ } catch { }
        }
    } catch { }
    return $items
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

function Add-ProgressEvent {
    param([string]$PackageRoot, [string]$Step, [string]$Status = 'OK', [string]$Message = '')
    try {
        [PSCustomObject]@{
            SchemaVersion = 'diagframework.p1.progress.v1'
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            ModuleId = $ModuleId
            Step = $Step
            Status = $Status
            Message = $Message
        } | ConvertTo-Json -Depth 6 -Compress | Out-File -LiteralPath (Join-Path $PackageRoot 'analysis/p1-normalizer-progress.jsonl') -Encoding UTF8 -Append
    } catch { }
}

function Add-NormalizerIssue {
    param($Issues = @(), [string]$Severity='Warning', [string]$Code='P1NormalizerIssue', [string]$Area='', [string]$Message='', [string]$Target='')
    return @(@($Issues) + [PSCustomObject]@{
        SchemaVersion = 'diagframework.p1.issue.v1'
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Severity = $Severity
        Code = $Code
        Area = $Area
        Target = $Target
        Message = $Message
    })
}

function Add-Finding {
    param($Findings = @(), [string]$Severity='Info', [string]$Area='', [string]$Title='', [string]$Evidence='', [string]$Meaning='', [string]$SuggestedAction='')
    return @(@($Findings) + [PSCustomObject]@{
        SchemaVersion = 'diagframework.p1.finding.v1'
        Severity = $Severity
        Area = $Area
        Title = $Title
        Evidence = $Evidence
        Meaning = $Meaning
        SuggestedAction = $SuggestedAction
    })
}

function Group-CountObject {
    param($InputObject, [string]$Property, [int]$Top = 50)
    return @(@($InputObject) | ForEach-Object {
        $value = Get-ObjectPropertyValueSafe -Object $_ -Name $Property -Default '<empty>'
        if ([string]::IsNullOrWhiteSpace([string]$value)) { $value = '<empty>' }
        [PSCustomObject]@{ Value = [string]$value }
    } | Group-Object Value | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object {
        [PSCustomObject]@{ Name = $_.Name; Count = $_.Count }
    })
}

function Get-LatestEvidencePackage {
    param([string]$LogRoot, [string]$PackageRoot = '', [string]$TargetKB = '')
    if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
        if (Test-Path -LiteralPath $PackageRoot -PathType Container) { return (Resolve-Path -LiteralPath $PackageRoot).Path }
        throw "PackageRoot nem található: $PackageRoot"
    }
    $root = Join-Path $LogRoot 'evidence_packages'
    if (-not (Test-Path -LiteralPath $root)) { throw "Evidence packages root nem található: $root" }
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'ai_summary.json') })
    if (-not [string]::IsNullOrWhiteSpace($TargetKB)) { $dirs = @($dirs | Where-Object { $_.Name -like "*$TargetKB*" -or (Get-Content -LiteralPath (Join-Path $_.FullName 'ai_summary.json') -Raw -ErrorAction SilentlyContinue) -like "*$TargetKB*" }) }
    $selected = @($dirs | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($selected.Count -eq 0) { throw 'Nem található normalizálható evidence csomag.' }
    return $selected[0].FullName
}

function Get-HResultClassification {
    param([string]$Code)
    $c = ([string]$Code).ToLowerInvariant()
    $map = @{
        '0x800f081f' = @{ Category='ServicingSourceMissing'; Severity='High'; Meaning='DISM/CBS source files missing or payload unavailable.' }
        '0x800f0831' = @{ Category='CBSMissingPackage'; Severity='High'; Meaning='CBS missing package / referenced package unavailable.' }
        '0x80070002' = @{ Category='FileNotFound'; Severity='Medium'; Meaning='File not found / path missing.' }
        '0x80070003' = @{ Category='PathNotFound'; Severity='Medium'; Meaning='Path not found.' }
        '0x80070005' = @{ Category='AccessDenied'; Severity='High'; Meaning='Access denied / permission issue.' }
        '0x80070422' = @{ Category='ServiceDisabled'; Severity='High'; Meaning='Required service disabled or cannot be started.' }
        '0x80070643' = @{ Category='InstallFailure'; Severity='High'; Meaning='Generic install failure, often MSI/servicing related.' }
        '0x80071a91' = @{ Category='TransactionResourceManager'; Severity='High'; Meaning='File system transaction resource manager issue.' }
        '0x8024001e' = @{ Category='WUOperationCancelledOrStopped'; Severity='Medium'; Meaning='Windows Update operation stopped/cancelled.' }
        '0x80244022' = @{ Category='WUServiceUnavailable'; Severity='Medium'; Meaning='Update service/server unavailable or HTTP service unavailable.' }
        '0x80073d02' = @{ Category='AppxInUse'; Severity='Medium'; Meaning='AppX package in use / Store app update blocked by running package.' }
        '0x80072af9' = @{ Category='NameResolutionFailure'; Severity='Medium'; Meaning='Network/DNS name resolution failure.' }
    }
    if ($map.ContainsKey($c)) { return [PSCustomObject]@{ Code=$c; Category=$map[$c].Category; Severity=$map[$c].Severity; Meaning=$map[$c].Meaning } }
    return [PSCustomObject]@{ Code=$c; Category='UnknownHRESULT'; Severity='Info'; Meaning='Unmapped HRESULT. Inspect source context.' }
}

function Get-TextMatches {
    param([string]$Path, [string[]]$Patterns, [int]$MaxMatches = 2000, [int]$Context = 0)
    $matches = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $matches }
    try {
        foreach ($pattern in $Patterns) {
            if ($matches.Count -ge $MaxMatches) { break }
            $remaining = $MaxMatches - $matches.Count
            $items = @(Select-String -LiteralPath $Path -Pattern $pattern -AllMatches -CaseSensitive:$false -Context $Context -ErrorAction SilentlyContinue | Select-Object -First $remaining)
            foreach ($m in $items) {
                $matches += [PSCustomObject]@{
                    RelativeSource = $null
                    Source = $Path
                    Pattern = $pattern
                    LineNumber = $m.LineNumber
                    Line = $m.Line.Trim()
                }
            }
        }
    } catch { }
    return $matches
}

function Parse-WerReportFile {
    param([string]$Path, [string]$PackageRoot)
    $kv = @{}
    try {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ($line -match '^([^=]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
        }
    } catch { }
    $sig = @{}
    foreach ($key in $kv.Keys) {
        if ($key -match '^Sig\[(\d+)\]\.(Name|Value)$') {
            $idx = $Matches[1]; $kind=$Matches[2]
            if (-not $sig.ContainsKey($idx)) { $sig[$idx] = @{} }
            $sig[$idx][$kind] = $kv[$key]
        }
    }
    $sigObj = @()
    foreach ($idx in @($sig.Keys | Sort-Object {[int]$_})) { $sigObj += [PSCustomObject]@{ Index=[int]$idx; Name=$sig[$idx]['Name']; Value=$sig[$idx]['Value'] } }
    [PSCustomObject]@{
        RelativePath = Get-RelativePathSafe -BasePath $PackageRoot -FullPath $Path
        FileLastWriteTime = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).LastWriteTime.ToString('o')
        EventType = $kv['EventType']
        FriendlyEventName = $kv['FriendlyEventName']
        ConsentKey = $kv['ConsentKey']
        ReportId = $kv['ReportIdentifier']
        Bucket = $kv['Bucket']
        CabId = $kv['CabId']
        AppName = if ($kv.ContainsKey('AppName')) { $kv['AppName'] } elseif ($sig.ContainsKey('0')) { $sig['0']['Value'] } else { $null }
        FaultModule = if ($sig.ContainsKey('1')) { $sig['1']['Value'] } else { $null }
        ExceptionCode = if ($sig.ContainsKey('6')) { $sig['6']['Value'] } else { $null }
        Signatures = $sigObj
    }
}

function Invoke-WERNormalizer {
    param([string]$PackageRoot)
    $analysisRoot = Join-Path $PackageRoot 'analysis'; New-DirectorySafe $analysisRoot
    $records = @()
    $existing = Read-JsonSafe -Path (Join-Path $PackageRoot 'wer/wer-reports.json') -Default @()
    if (@($existing).Count -gt 0) { $records += @($existing) }
    $roots = @(
        (Join-Path $PackageRoot 'copied_logs/ReportArchive'),
        (Join-Path $PackageRoot 'copied_logs/ReportQueue'),
        (Join-Path $PackageRoot 'vendor_logs')
    )
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) {
            foreach ($file in @(Get-ChildItem -LiteralPath $r -Filter 'Report.wer' -File -Recurse -ErrorAction SilentlyContinue)) {
                $rel = Get-RelativePathSafe -BasePath $PackageRoot -FullPath $file.FullName
                if (@($records | Where-Object { (Get-ObjectPropertyValueSafe $_ 'RelativePath' '') -eq $rel }).Count -gt 0) { continue }
                $records += Parse-WerReportFile -Path $file.FullName -PackageRoot $PackageRoot
            }
        }
    }
    $byEvent = Group-CountObject -InputObject $records -Property 'EventType' -Top 30
    $byApp = Group-CountObject -InputObject $records -Property 'AppName' -Top 30
    $byModule = Group-CountObject -InputObject $records -Property 'FaultModule' -Top 30
    $nonCore = @($byApp | Where-Object { $_.Name -and $_.Name -notmatch '^(Microsoft|Windows|System|svchost|explorer\.exe|dwm\.exe|RuntimeBroker\.exe)$' } | Select-Object -First 15)
    $summary = [PSCustomObject]@{
        SchemaVersion='diagframework.p1.normalized.wer.v1'
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        Source='WER ReportArchive/ReportQueue + wer-reports.json'
        ReportCount=@($records).Count
        ByEventType=$byEvent
        ByAppName=$byApp
        ByFaultModule=$byModule
        NonCoreTopApps=$nonCore
        Records=@($records | Select-Object -First 5000)
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $analysisRoot 'normalized-wer.json') -Depth 14
    return $summary
}

function Invoke-SetupAPINormalizer {
    param([string]$PackageRoot)
    $analysisRoot = Join-Path $PackageRoot 'analysis'; New-DirectorySafe $analysisRoot
    $paths = @((Join-Path $PackageRoot 'copied_logs/setupapi.dev.log'), (Join-Path $PackageRoot 'copied_logs/setupapi.setup.log'))
    $patterns = @('!!!','#[EW]', '0x[0-9a-fA-F]{8}', 'failed|failure|error|cannot|not found|missing|hiányzik|sikertelen')
    $records = @()
    foreach ($p in $paths) {
        foreach ($m in @(Get-TextMatches -Path $p -Patterns $patterns -MaxMatches 3000)) {
            $m.RelativeSource = if (Test-Path -LiteralPath $m.Source) { Get-RelativePathSafe -BasePath $PackageRoot -FullPath $m.Source } else { $m.Source }
            $hresults = @([regex]::Matches($m.Line, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value.ToLowerInvariant() })
            $records += [PSCustomObject]@{ RelativeSource=$m.RelativeSource; LineNumber=$m.LineNumber; Pattern=$m.Pattern; HResults=$hresults; Line=$m.Line }
        }
    }
    $h = @()
    foreach ($r in $records) { foreach($code in @($r.HResults)){ $h += Get-HResultClassification $code } }
    $summary = [PSCustomObject]@{
        SchemaVersion='diagframework.p1.normalized.setupapi.v1'
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        SourceFiles=@($paths | ForEach-Object { if(Test-Path -LiteralPath $_){ Get-RelativePathSafe -BasePath $PackageRoot -FullPath $_ }})
        MatchCount=@($records).Count
        HResultSummary=@($h | Group-Object Code | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ Code=$_.Name; Count=$_.Count; Classification=Get-HResultClassification $_.Name } })
        Records=@($records | Select-Object -First 5000)
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $analysisRoot 'normalized-setupapi.json') -Depth 12
    return $summary
}

function Invoke-CBSHResultNormalizer {
    param([string]$PackageRoot)
    $analysisRoot = Join-Path $PackageRoot 'analysis'; New-DirectorySafe $analysisRoot
    $paths = @((Join-Path $PackageRoot 'copied_logs/CBS.log'), (Join-Path $PackageRoot 'copied_logs/dism.log'), (Join-Path $PackageRoot 'servicing/dism-scanhealth.txt'), (Join-Path $PackageRoot 'servicing/sfc-verifyonly.txt'), (Join-Path $PackageRoot 'commands/dism-checkhealth.txt'))
    $patterns = @('0x[0-9a-fA-F]{8}', 'corrupt|repair|failed|failure|error|source|payload|manifest|servicing|CBS|CSI')
    $records = @(); $codes=@()
    foreach ($p in $paths) {
        foreach ($m in @(Get-TextMatches -Path $p -Patterns $patterns -MaxMatches 5000)) {
            $rel = if (Test-Path -LiteralPath $m.Source) { Get-RelativePathSafe -BasePath $PackageRoot -FullPath $m.Source } else { $m.Source }
            $hresults = @([regex]::Matches($m.Line, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value.ToLowerInvariant() })
            foreach ($c in $hresults) { $codes += $c }
            $records += [PSCustomObject]@{ RelativeSource=$rel; LineNumber=$m.LineNumber; Pattern=$m.Pattern; HResults=$hresults; Line=$m.Line }
        }
    }
    $existing = Read-JsonSafe -Path (Join-Path $PackageRoot 'servicing/cbs-hresult-summary.json') -Default @()
    foreach ($e in @($existing)) { $c = Get-ObjectPropertyValueSafe $e 'HResult' ''; if($c){ for($i=0; $i -lt [int](Get-ObjectPropertyValueSafe $e 'Count' 1); $i++){ $codes += ([string]$c).ToLowerInvariant() } } }
    $codeSummary = @($codes | Group-Object | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ Code=$_.Name; Count=$_.Count; Classification=Get-HResultClassification $_.Name } })
    $summary = [PSCustomObject]@{
        SchemaVersion='diagframework.p1.normalized.cbs_hresults.v1'
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        SourceFiles=@($paths | ForEach-Object { if(Test-Path -LiteralPath $_){ Get-RelativePathSafe -BasePath $PackageRoot -FullPath $_ }})
        HResultCount=@($codes).Count
        HResultSummary=$codeSummary
        Records=@($records | Select-Object -First 5000)
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $analysisRoot 'normalized-cbs-hresults.json') -Depth 12
    return $summary
}

function Invoke-DriverPnPProblemNormalizer {
    param([string]$PackageRoot)
    $analysisRoot = Join-Path $PackageRoot 'analysis'; New-DirectorySafe $analysisRoot
    $pnpStorage = Read-JsonSafe -Path (Join-Path $PackageRoot 'storage/pnp-storage-devices.json') -Default @()
    if (@($pnpStorage).Count -eq 0) { $pnpStorage = Read-JsonSafe -Path (Join-Path $PackageRoot 'pnp-storage-devices.json') -Default @() }
    $drivers = Read-JsonSafe -Path (Join-Path $PackageRoot 'drivers/pnp-signed-drivers.json') -Default @()
    $kernelPnP = Read-JsonLinesSafe -Path (Join-Path $PackageRoot 'events/Microsoft-Windows-Kernel-PnP_Configuration.jsonl') -MaxLines 50000
    $deviceSetupAdmin = Read-JsonLinesSafe -Path (Join-Path $PackageRoot 'events/Microsoft-Windows-DeviceSetupManager_Admin.jsonl') -MaxLines 50000
    $problemDevices = @()
    foreach ($d in @($pnpStorage)) {
        $problem = Get-ObjectPropertyValueSafe $d 'Problem' 0
        $present = Get-ObjectPropertyValueSafe $d 'Present' $true
        $status = Get-ObjectPropertyValueSafe $d 'Status' ''
        if (($problem -ne 0) -or ($present -eq $false) -or ([string]$status -notin @('','OK'))) {
            $sev = if($problem -eq 45 -and $present -eq $false){'Low'} elseif($problem -ne 0){'Medium'} else {'Info'}
            $problemDevices += [PSCustomObject]@{ Severity=$sev; Source='pnp-storage-devices'; Class=Get-ObjectPropertyValueSafe $d 'Class' ''; FriendlyName=Get-ObjectPropertyValueSafe $d 'FriendlyName' ''; InstanceId=Get-ObjectPropertyValueSafe $d 'InstanceId' ''; Problem=$problem; Present=$present; Status=$status }
        }
    }
    $kernelWarnings = @($kernelPnP | Where-Object { (Get-ObjectPropertyValueSafe $_ 'LevelDisplayName' '') -match 'Hiba|Error|Figyelmeztetés|Warning' -or (Get-ObjectPropertyValueSafe $_ 'Id' 0) -in @(219,411,400,401,442) } | Select-Object -First 1000)
    $setupWarnings = @($deviceSetupAdmin | Where-Object { (Get-ObjectPropertyValueSafe $_ 'LevelDisplayName' '') -match 'Hiba|Error|Figyelmeztetés|Warning' } | Select-Object -First 1000)
    $summary = [PSCustomObject]@{
        SchemaVersion='diagframework.p1.normalized.pnp_problems.v1'
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        ProblemDeviceCount=@($problemDevices).Count
        ProblemDevices=$problemDevices
        KernelPnPWarningCount=@($kernelWarnings).Count
        KernelPnPWarnings=@($kernelWarnings | Select-Object -First 1000)
        DeviceSetupWarningCount=@($setupWarnings).Count
        DeviceSetupWarnings=@($setupWarnings | Select-Object -First 1000)
        DriverInventoryCount=@($drivers).Count
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $analysisRoot 'normalized-pnp-problems.json') -Depth 12
    return $summary
}

function Invoke-EventCorrelationNormalizer {
    param([string]$PackageRoot)
    $analysisRoot = Join-Path $PackageRoot 'analysis'; New-DirectorySafe $analysisRoot
    $correlation = Read-JsonSafe -Path (Join-Path $PackageRoot 'storage/disk153-update-setup-correlation.json') -Default @()
    if (@($correlation).Count -eq 0) { $correlation = Read-JsonSafe -Path (Join-Path $PackageRoot 'disk153-update-setup-correlation.json') -Default @() }
    $windows = @(); $setup=@(); $kernelBoot=@(); $power=@(); $hyperv=@(); $disk=@(); $byProvider=@()
    foreach ($w in @($correlation)) {
        foreach ($e in @(Get-ObjectPropertyValueSafe $w 'Events' @())) {
            $prov = Get-ObjectPropertyValueSafe $e 'ProviderName' ''
            $log = Get-ObjectPropertyValueSafe $e 'CorrelationLog' (Get-ObjectPropertyValueSafe $e 'LogName' '')
            if ($prov -match 'WindowsUpdateClient' -or $log -match 'WindowsUpdate') { $windows += $e }
            if ($log -eq 'Setup') { $setup += $e }
            if ($prov -match 'Kernel-Boot') { $kernelBoot += $e }
            if ($prov -match 'Kernel-Power|Power-Troubleshooter') { $power += $e }
            if ($prov -match 'Hyper-V|VmSwitch|VMSMP') { $hyperv += $e }
            if ($prov -eq 'disk') { $disk += $e }
            $byProvider += [PSCustomObject]@{ ProviderName=$prov; Id=Get-ObjectPropertyValueSafe $e 'Id' ''; Log=$log }
        }
    }
    $summary = [PSCustomObject]@{
        SchemaVersion='diagframework.p1.normalized.event_correlation.v1'
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        WindowCount=@($correlation).Count
        TotalCorrelatedEvents=(@($correlation) | ForEach-Object { [int](Get-ObjectPropertyValueSafe $_ 'CorrelatedEventCount' 0) } | Measure-Object -Sum).Sum
        WindowsUpdateEventCount=@($windows).Count
        SetupEventCount=@($setup).Count
        KernelBootEventCount=@($kernelBoot).Count
        PowerEventCount=@($power).Count
        HyperVEventCount=@($hyperv).Count
        DiskEventCount=@($disk).Count
        TopProviders=@($byProvider | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 30 | ForEach-Object { [PSCustomObject]@{ ProviderName=$_.Name; Count=$_.Count } })
        WindowsUpdateEvents=@($windows | Select-Object -First 500)
        SetupEvents=@($setup | Select-Object -First 500)
        PowerEvents=@($power | Select-Object -First 500)
        HyperVEvents=@($hyperv | Select-Object -First 500)
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $analysisRoot 'normalized-event-correlation.json') -Depth 12
    return $summary
}

function Invoke-WindowsUpdateErrorNormalizer {
    param([string]$PackageRoot, [string]$TargetKB='')
    $analysisRoot = Join-Path $PackageRoot 'analysis'; New-DirectorySafe $analysisRoot
    $paths = @(
        (Join-Path $PackageRoot 'windows_update/WindowsUpdate.generated.log'),
        (Join-Path $PackageRoot 'copied_logs/ReportingEvents.log'),
        (Join-Path $PackageRoot 'copied_logs/WindowsUpdate.log')
    )
    $patterns = @('0x[0-9a-fA-F]{8}', 'KB[0-9]{6,8}', 'error|failed|failure|rollback|revert|reverted|sikertelen|hiba|visszaáll')
    $records=@(); $codes=@(); $kbs=@()
    foreach ($p in $paths) {
        foreach ($m in @(Get-TextMatches -Path $p -Patterns $patterns -MaxMatches 7000)) {
            $rel = if (Test-Path -LiteralPath $m.Source) { Get-RelativePathSafe -BasePath $PackageRoot -FullPath $m.Source } else { $m.Source }
            $hresults = @([regex]::Matches($m.Line, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value.ToLowerInvariant() })
            $kbMatches = @([regex]::Matches($m.Line, 'KB[0-9]{6,8}', 'IgnoreCase') | ForEach-Object { $_.Value.ToUpperInvariant() })
            foreach ($c in $hresults) { $codes += $c }
            foreach ($kb in $kbMatches) { $kbs += $kb }
            $records += [PSCustomObject]@{ RelativeSource=$rel; LineNumber=$m.LineNumber; Pattern=$m.Pattern; HResults=$hresults; KBs=$kbMatches; Line=$m.Line }
        }
    }
    $wuEvents = Read-JsonLinesSafe -Path (Join-Path $PackageRoot 'events/Microsoft-Windows-WindowsUpdateClient_Operational.jsonl') -MaxLines 100000
    $errorEvents = @($wuEvents | Where-Object { (Get-ObjectPropertyValueSafe $_ 'LevelDisplayName' '') -match 'Hiba|Error|Figyelmeztetés|Warning' -or (Get-ObjectPropertyValueSafe $_ 'Message' '') -match '0x[0-9a-fA-F]{8}|fail|error|sikertelen|hiba' })
    $targetMatches = @()
    $target = $TargetKB
    if ([string]::IsNullOrWhiteSpace($target)) {
        $summary = Read-JsonSafe -Path (Join-Path $PackageRoot 'ai_summary.json') -Default $null
        $target = Get-ObjectPropertyValueSafe $summary 'TargetKB' ''
    }
    if (-not [string]::IsNullOrWhiteSpace($target)) { $targetMatches = @($records | Where-Object { (@(Get-ObjectPropertyValueSafe $_ 'KBs' @()) -contains $target.ToUpperInvariant()) -or ((Get-ObjectPropertyValueSafe $_ 'Line' '') -match [regex]::Escape($target)) }) }
    $summary = [PSCustomObject]@{
        SchemaVersion='diagframework.p1.normalized.windowsupdate_errors.v1'
        GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        SourceFiles=@($paths | ForEach-Object { if(Test-Path -LiteralPath $_){ Get-RelativePathSafe -BasePath $PackageRoot -FullPath $_ }})
        TextMatchCount=@($records).Count
        WindowsUpdateClientErrorEventCount=@($errorEvents).Count
        HResultSummary=@($codes | Group-Object | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ Code=$_.Name; Count=$_.Count; Classification=Get-HResultClassification $_.Name } })
        KBSummary=@($kbs | Group-Object | Sort-Object Count -Descending | ForEach-Object { [PSCustomObject]@{ KB=$_.Name; Count=$_.Count } })
        TargetKB=$target
        TargetKBMatchCount=@($targetMatches).Count
        TargetKBMatches=@($targetMatches | Select-Object -First 500)
        WindowsUpdateClientErrorEvents=@($errorEvents | Select-Object -First 1000)
        Records=@($records | Select-Object -First 7000)
    }
    Write-JsonSafe -InputObject $summary -Path (Join-Path $analysisRoot 'normalized-windowsupdate-errors.json') -Depth 12
    return $summary
}

function New-P1Findings {
    param($WER,$SetupAPI,$CBS,$PnP,$Correlation,$WindowsUpdate)
    $findings=@()
    if ([int](Get-ObjectPropertyValueSafe $WER 'ReportCount' 0) -gt 0) {
        $topApp = @($WER.ByAppName | Select-Object -First 1)[0]
        $findings = Add-Finding -Findings $findings -Severity 'Info' -Area 'WER' -Title 'WER reports normalized' -Evidence "ReportCount=$($WER.ReportCount); TopApp=$($topApp.Name) Count=$($topApp.Count)" -Meaning 'Application/crash noise can now be separated from Windows core update evidence.' -SuggestedAction 'Use normalized-wer.json to suppress non-core repeated application noise unless time-correlated with reboot/update failures.'
    }
    if (@($SetupAPI.HResultSummary).Count -gt 0 -or [int](Get-ObjectPropertyValueSafe $SetupAPI 'MatchCount' 0) -gt 0) {
        $findings = Add-Finding -Findings $findings -Severity 'Medium' -Area 'SetupAPI' -Title 'SetupAPI warnings/errors normalized' -Evidence "MatchCount=$($SetupAPI.MatchCount); HRESULTs=$(@($SetupAPI.HResultSummary).Count)" -Meaning 'Driver/package install issues are now searchable by line, HRESULT and source file.' -SuggestedAction 'Review normalized-setupapi.json before driver repair or driver-store cleanup.'
    }
    $highCbs = @($CBS.HResultSummary | Where-Object { (Get-ObjectPropertyValueSafe (Get-ObjectPropertyValueSafe $_ 'Classification' $null) 'Severity' '') -eq 'High' })
    if (@($highCbs).Count -gt 0) {
        $findings = Add-Finding -Findings $findings -Severity 'High' -Area 'CBS' -Title 'High severity CBS/DISM HRESULT found' -Evidence (($highCbs | Select-Object -First 5 | ForEach-Object { "$($_.Code)=$($_.Count)" }) -join '; ') -Meaning 'Servicing corruption/source/package problems may affect Windows Update reliability.' -SuggestedAction 'Run repair workflow only after pre-repair evidence and pending reboot checks.'
    } elseif ([int](Get-ObjectPropertyValueSafe $CBS 'HResultCount' 0) -gt 0) {
        $findings = Add-Finding -Findings $findings -Severity 'Medium' -Area 'CBS' -Title 'CBS/DISM HRESULTs normalized' -Evidence "HResultCount=$($CBS.HResultCount)" -Meaning 'Servicing signals exist, but no mapped high severity code was identified.' -SuggestedAction 'Inspect normalized-cbs-hresults.json for unmapped recurring HRESULTs.'
    }
    if ([int](Get-ObjectPropertyValueSafe $PnP 'ProblemDeviceCount' 0) -gt 0) {
        $findings = Add-Finding -Findings $findings -Severity 'Medium' -Area 'PnP' -Title 'PnP problem/stale devices normalized' -Evidence "ProblemDeviceCount=$($PnP.ProblemDeviceCount)" -Meaning 'Device presence/problem codes are now separated from storage/topology and driver inventory.' -SuggestedAction 'Check current Present=true problem devices first; treat Problem 45 not-present devices as stale unless tied to target evidence.'
    }
    if ([int](Get-ObjectPropertyValueSafe $Correlation 'WindowsUpdateEventCount' 0) -gt 0 -or [int](Get-ObjectPropertyValueSafe $Correlation 'SetupEventCount' 0) -gt 0) {
        $findings = Add-Finding -Findings $findings -Severity 'Medium' -Area 'EventCorrelation' -Title 'Update/setup events found in correlation windows' -Evidence "WindowsUpdate=$($Correlation.WindowsUpdateEventCount); Setup=$($Correlation.SetupEventCount); Power=$($Correlation.PowerEventCount)" -Meaning 'Storage retry windows overlap with system/update/power activity and should be evaluated before repair.' -SuggestedAction 'Use normalized-event-correlation.json to separate update-related windows from sleep/resume or peripheral noise.'
    }
    if ([int](Get-ObjectPropertyValueSafe $WindowsUpdate 'WindowsUpdateClientErrorEventCount' 0) -gt 0 -or @($WindowsUpdate.HResultSummary).Count -gt 0) {
        $findings = Add-Finding -Findings $findings -Severity 'Medium' -Area 'WindowsUpdate' -Title 'Windows Update error signals normalized' -Evidence "WUErrorEvents=$($WindowsUpdate.WindowsUpdateClientErrorEventCount); HRESULTs=$(@($WindowsUpdate.HResultSummary).Count); TargetKBMatches=$($WindowsUpdate.TargetKBMatchCount)" -Meaning 'Windows Update textual and event evidence is now searchable by HRESULT and KB.' -SuggestedAction 'Review normalized-windowsupdate-errors.json before WU reset or servicing repair.'
    }
    return $findings
}

function Update-AiSummaryWithP1 {
    param([string]$PackageRoot, $P1Summary)
    $summaryPath = Join-Path $PackageRoot 'ai_summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath)) { return }
    try {
        Copy-Item -LiteralPath $summaryPath -Destination (Join-Path $PackageRoot 'analysis/ai_summary.before-p1-normalizers.json') -Force -ErrorAction SilentlyContinue
        $summary = Read-JsonSafe -Path $summaryPath -Default $null
        if ($null -eq $summary) { return }
        $summary | Add-Member -NotePropertyName 'P1Normalization' -NotePropertyValue $P1Summary -Force
        Write-JsonSafe -InputObject $summary -Path $summaryPath -Depth 16
    } catch { }
}

function Invoke-P1Normalizers {
    param([string]$LogRoot, [string]$PackageRoot='', [string]$TargetKB='', [switch]$WhatIf)
    $pkg = Get-LatestEvidencePackage -LogRoot $LogRoot -PackageRoot $PackageRoot -TargetKB $TargetKB
    $analysisRoot = Join-Path $pkg 'analysis'; New-DirectorySafe $analysisRoot
    $issues=@()
    $planned=@('WERNormalizer','SetupAPINormalizer','CBSHResultNormalizer','DriverPnPProblemNormalizer','EventCorrelationNormalizer','WindowsUpdateErrorNormalizer')
    if($WhatIf){
        $what=[PSCustomObject]@{ SchemaVersion='diagframework.p1.summary.v1'; ModuleId=$ModuleId; ModuleVersion=$ModuleVersion; WhatIf=$true; PackageRoot=$pkg; PlannedNormalizers=$planned }
        Write-JsonSafe -InputObject $what -Path (Join-Path $analysisRoot 'p1-normalization-summary.json') -Depth 8
        return $what
    }
    Add-ProgressEvent -PackageRoot $pkg -Step 'P1Start' -Status 'OK' -Message "PackageRoot=$pkg"
    try { $wer = Invoke-WERNormalizer -PackageRoot $pkg; Add-ProgressEvent -PackageRoot $pkg -Step 'WERNormalizer' -Status 'OK' -Message "ReportCount=$($wer.ReportCount)" } catch { $issues=Add-NormalizerIssue -Issues $issues -Severity 'Error' -Code 'WERNormalizerFailed' -Area 'WER' -Message $_.Exception.Message; $wer=[PSCustomObject]@{ReportCount=0}; Add-ProgressEvent -PackageRoot $pkg -Step 'WERNormalizer' -Status 'Error' -Message $_.Exception.Message }
    try { $setup = Invoke-SetupAPINormalizer -PackageRoot $pkg; Add-ProgressEvent -PackageRoot $pkg -Step 'SetupAPINormalizer' -Status 'OK' -Message "MatchCount=$($setup.MatchCount)" } catch { $issues=Add-NormalizerIssue -Issues $issues -Severity 'Error' -Code 'SetupAPINormalizerFailed' -Area 'SetupAPI' -Message $_.Exception.Message; $setup=[PSCustomObject]@{MatchCount=0;HResultSummary=@()}; Add-ProgressEvent -PackageRoot $pkg -Step 'SetupAPINormalizer' -Status 'Error' -Message $_.Exception.Message }
    try { $cbs = Invoke-CBSHResultNormalizer -PackageRoot $pkg; Add-ProgressEvent -PackageRoot $pkg -Step 'CBSHResultNormalizer' -Status 'OK' -Message "HResultCount=$($cbs.HResultCount)" } catch { $issues=Add-NormalizerIssue -Issues $issues -Severity 'Error' -Code 'CBSHResultNormalizerFailed' -Area 'CBS' -Message $_.Exception.Message; $cbs=[PSCustomObject]@{HResultCount=0;HResultSummary=@()}; Add-ProgressEvent -PackageRoot $pkg -Step 'CBSHResultNormalizer' -Status 'Error' -Message $_.Exception.Message }
    try { $pnp = Invoke-DriverPnPProblemNormalizer -PackageRoot $pkg; Add-ProgressEvent -PackageRoot $pkg -Step 'DriverPnPProblemNormalizer' -Status 'OK' -Message "ProblemDeviceCount=$($pnp.ProblemDeviceCount)" } catch { $issues=Add-NormalizerIssue -Issues $issues -Severity 'Error' -Code 'DriverPnPProblemNormalizerFailed' -Area 'PnP' -Message $_.Exception.Message; $pnp=[PSCustomObject]@{ProblemDeviceCount=0}; Add-ProgressEvent -PackageRoot $pkg -Step 'DriverPnPProblemNormalizer' -Status 'Error' -Message $_.Exception.Message }
    try { $corr = Invoke-EventCorrelationNormalizer -PackageRoot $pkg; Add-ProgressEvent -PackageRoot $pkg -Step 'EventCorrelationNormalizer' -Status 'OK' -Message "WindowCount=$($corr.WindowCount)" } catch { $issues=Add-NormalizerIssue -Issues $issues -Severity 'Error' -Code 'EventCorrelationNormalizerFailed' -Area 'EventCorrelation' -Message $_.Exception.Message; $corr=[PSCustomObject]@{WindowCount=0}; Add-ProgressEvent -PackageRoot $pkg -Step 'EventCorrelationNormalizer' -Status 'Error' -Message $_.Exception.Message }
    try { $wu = Invoke-WindowsUpdateErrorNormalizer -PackageRoot $pkg -TargetKB $TargetKB; Add-ProgressEvent -PackageRoot $pkg -Step 'WindowsUpdateErrorNormalizer' -Status 'OK' -Message "TextMatchCount=$($wu.TextMatchCount)" } catch { $issues=Add-NormalizerIssue -Issues $issues -Severity 'Error' -Code 'WindowsUpdateErrorNormalizerFailed' -Area 'WindowsUpdate' -Message $_.Exception.Message; $wu=[PSCustomObject]@{TextMatchCount=0;HResultSummary=@()}; Add-ProgressEvent -PackageRoot $pkg -Step 'WindowsUpdateErrorNormalizer' -Status 'Error' -Message $_.Exception.Message }
    $findings = New-P1Findings -WER $wer -SetupAPI $setup -CBS $cbs -PnP $pnp -Correlation $corr -WindowsUpdate $wu
    $status = if(@($issues | Where-Object Severity -eq 'Error').Count -gt 0){'Partial'} elseif(@($issues).Count -gt 0){'OKWithWarnings'} else {'OK'}
    $summary=[PSCustomObject]@{
        SchemaVersion='diagframework.p1.summary.v1'
        ModuleId=$ModuleId
        ModuleVersion=$ModuleVersion
        Status=$status
        TimestampUtc=(Get-Date).ToUniversalTime().ToString('o')
        PackageRoot=$pkg
        Outputs=@(
            'analysis/normalized-wer.json',
            'analysis/normalized-setupapi.json',
            'analysis/normalized-cbs-hresults.json',
            'analysis/normalized-pnp-problems.json',
            'analysis/normalized-event-correlation.json',
            'analysis/normalized-windowsupdate-errors.json',
            'analysis/p1-findings.json'
        )
        Counts=[PSCustomObject]@{
            WERReports=$wer.ReportCount
            SetupAPIMatches=$setup.MatchCount
            CBSHRESULTs=$cbs.HResultCount
            PnPProblemDevices=$pnp.ProblemDeviceCount
            CorrelationWindows=$corr.WindowCount
            WindowsUpdateTextMatches=$wu.TextMatchCount
        }
        IssueCount=@($issues).Count
        Issues=$issues
        FindingCount=@($findings).Count
        Findings=$findings
    }
    Write-JsonSafe -InputObject $findings -Path (Join-Path $analysisRoot 'p1-findings.json') -Depth 12
    Write-JsonSafe -InputObject $summary -Path (Join-Path $analysisRoot 'p1-normalization-summary.json') -Depth 12
    Update-AiSummaryWithP1 -PackageRoot $pkg -P1Summary $summary
    Add-ProgressEvent -PackageRoot $pkg -Step 'P1Completed' -Status $status -Message "Findings=$(@($findings).Count); Issues=$(@($issues).Count)"
    return $summary
}

switch ($Action) {
    'Get-Metadata' { Get-Metadata }
    'Test-Condition' {
        try {
            $pkg = Get-LatestEvidencePackage -LogRoot $LogRoot -PackageRoot $PackageRoot -TargetKB $TargetKB
            [PSCustomObject]@{
                IssueDetected=$true
                FixAvailable=$true
                Severity='Info'
                Summary="P1 normalizálás futtatható a legutóbbi evidence csomagon: $pkg"
                RecommendedAction='Javasolt lépések: 1) Futtasd a P1 normalizálókat. 2) Először analysis/p1-normalization-summary.json fájlt olvasd. 3) Ezután p1-findings.json alapján dönts a P2 vagy javítómodul irányról.'
            }
        } catch {
            [PSCustomObject]@{ IssueDetected=$false; FixAvailable=$false; Severity='Warning'; Summary=$_.Exception.Message; RecommendedAction='Előbb készíts SystemEvidence csomagot.' }
        }
    }
    'Invoke-Fix' { Invoke-P1Normalizers -LogRoot $LogRoot -PackageRoot $PackageRoot -TargetKB $TargetKB -WhatIf:$WhatIf }
    'Invoke-Rollback' { [PSCustomObject]@{ RollbackSupported=$false; Summary='A P1 normalizáló read-only elemző modul. Windows rollback nem szükséges; az analysis/*.json fájlok törölhetők, ha újrafuttatás kell.' } }
}
