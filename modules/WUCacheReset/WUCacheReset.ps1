[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Get-Metadata','Test-Condition','Invoke-Fix','Invoke-Rollback')][string]$Action,
    [switch]$WhatIf,
    [string]$LogRoot = (Join-Path $PSScriptRoot '..\..\logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ModuleId = 'WUCacheReset'
$Services = 'bits','wuauserv','cryptsvc'
$Targets = @(
    @{ Name='SoftwareDistribution'; Path=(Join-Path $env:windir 'SoftwareDistribution') },
    @{ Name='catroot2'; Path=(Join-Path $env:windir 'System32\catroot2') }
)

function Get-StateDir {
    $stateDir = Join-Path $LogRoot 'state'
    if (-not (Test-Path $stateDir)) { New-Item -Path $stateDir -ItemType Directory -Force | Out-Null }
    return $stateDir
}

function Get-LatestStateFile {
    Get-ChildItem -Path (Get-StateDir) -Filter "$ModuleId-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-Metadata { [PSCustomObject]@{ Id=$ModuleId; Name='Windows Update cache reset'; Version='1.0.0'; Risk='Medium' } }

function Test-Condition {
    $events = @()
    try {
        $events = Get-WinEvent -LogName 'Microsoft-Windows-WindowsUpdateClient/Operational' -MaxEvents 120 -ErrorAction Stop |
            Where-Object { $_.LevelDisplayName -in @('Error','Warning') -and $_.TimeCreated -gt (Get-Date).AddDays(-14) } |
            Select-Object -First 20 TimeCreated, Id, LevelDisplayName, ProviderName, Message
    }
    catch {
        $events = @([PSCustomObject]@{ TimeCreated=$null; Id=$null; LevelDisplayName='Info'; ProviderName='Get-WinEvent'; Message="Windows Update event log nem olvasható: $($_.Exception.Message)" })
    }

    $targetInfo = foreach ($t in $Targets) {
        $exists = Test-Path $t.Path
        $sizeMb = $null
        if ($exists) {
            try {
                $sizeMb = [math]::Round(((Get-ChildItem -Path $t.Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)
            } catch { $sizeMb = $null }
        }
        [PSCustomObject]@{ Name=$t.Name; Path=$t.Path; Exists=$exists; ApproxSizeMB=$sizeMb }
    }

    $issue = @($events | Where-Object { $_.LevelDisplayName -in @('Error','Warning') }).Count -gt 0
    [PSCustomObject]@{
        ModuleId = $ModuleId
        Severity = if ($issue) { 'Medium' } else { 'Info' }
        IssueDetected = $issue
        FixAvailable = $true
        Summary = if ($issue) { 'Az elmúlt 14 napban Windows Update hibák/figyelmeztetések találhatók; cache reset megfontolható.' } else { 'Nincs friss Windows Update event-log hiba, a reset csak kézi döntéssel javasolt.' }
        RecommendedAction = 'SoftwareDistribution és catroot2 átnevezése időbélyegzett .bak mappára, majd szolgáltatások újraindítása.'
        Details = [PSCustomObject]@{ Targets=$targetInfo; RecentEvents=$events }
        RollbackHint = 'A legutóbbi backup mappák visszanevezhetők, ha a reset után regresszió jelentkezik.'
    }
}

function Stop-WuServices {
    param([System.Collections.Generic.List[string]]$Actions)
    foreach ($svcName in $Services) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($null -eq $svc) { $Actions.Add("SKIP: $svcName nem található"); continue }
        if ($svc.Status -ne 'Stopped') {
            try {
                Stop-Service -Name $svcName -Force -ErrorAction Stop
                $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
                $Actions.Add("OK: $svcName leállítva")
            } catch { $Actions.Add("WARN: $svcName leállítási hiba: $($_.Exception.Message)") }
        } else { $Actions.Add("OK: $svcName már áll") }
    }
}

function Start-WuServices {
    param([System.Collections.Generic.List[string]]$Actions)
    foreach ($svcName in @($Services | Sort-Object -Descending)) {
        try {
            Start-Service -Name $svcName -ErrorAction Stop
            $Actions.Add("OK: $svcName elindítva")
        } catch { $Actions.Add("WARN: $svcName indítási hiba: $($_.Exception.Message)") }
    }
}

function Invoke-Fix {
    param([switch]$WhatIf)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stateFile = Join-Path (Get-StateDir) "$ModuleId-$stamp.json"
    $plan = foreach ($t in $Targets) {
        [PSCustomObject]@{ Original=$t.Path; Backup=("{0}.bak-{1}" -f $t.Path, $stamp); Exists=(Test-Path $t.Path) }
    }

    if ($WhatIf) {
        return [PSCustomObject]@{ ModuleId=$ModuleId; Result='WhatIf'; Planned=$plan; Services=$Services }
    }

    $actions = New-Object System.Collections.Generic.List[string]
    Stop-WuServices -Actions $actions

    foreach ($p in $plan) {
        if (-not $p.Exists) { $actions.Add("SKIP: $($p.Original) nem létezik"); continue }
        try {
            Rename-Item -Path $p.Original -NewName (Split-Path $p.Backup -Leaf) -ErrorAction Stop
            $actions.Add("OK: $($p.Original) -> $($p.Backup)")
        }
        catch {
            $actions.Add("ERROR: $($p.Original) átnevezési hiba: $($_.Exception.Message)")
        }
    }

    Start-WuServices -Actions $actions

    [PSCustomObject]@{ Timestamp=(Get-Date).ToString('o'); Plan=$plan; Actions=$actions } |
        ConvertTo-Json -Depth 8 | Out-File -FilePath $stateFile -Encoding UTF8 -Force

    [PSCustomObject]@{ ModuleId=$ModuleId; Result='Completed'; Actions=$actions; StateFile=$stateFile }
}

function Invoke-Rollback {
    $state = Get-LatestStateFile
    if (-not $state) { return [PSCustomObject]@{ ModuleId=$ModuleId; Result='NoState'; Message='Nincs rollback állomány.' } }

    $data = Get-Content $state.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $actions = New-Object System.Collections.Generic.List[string]
    Stop-WuServices -Actions $actions

    foreach ($p in $data.Plan) {
        try {
            if ((Test-Path $p.Original) -and (Test-Path $p.Backup)) {
                $actions.Add("SKIP: Az eredeti és backup is létezik, kézi döntés kell: $($p.Original)")
                continue
            }
            if ((-not (Test-Path $p.Original)) -and (Test-Path $p.Backup)) {
                Rename-Item -Path $p.Backup -NewName (Split-Path $p.Original -Leaf) -ErrorAction Stop
                $actions.Add("OK: $($p.Backup) -> $($p.Original)")
            }
            else {
                $actions.Add("SKIP: nincs visszaállítható backup: $($p.Backup)")
            }
        } catch { $actions.Add("ERROR: rollback hiba $($p.Backup): $($_.Exception.Message)") }
    }

    Start-WuServices -Actions $actions
    [PSCustomObject]@{ ModuleId=$ModuleId; Result='Completed'; StateFile=$state.FullName; Actions=$actions }
}

switch ($Action) {
    'Get-Metadata' { Get-Metadata }
    'Test-Condition' { Test-Condition }
    'Invoke-Fix' { Invoke-Fix -WhatIf:$WhatIf }
    'Invoke-Rollback' { Invoke-Rollback }
}
