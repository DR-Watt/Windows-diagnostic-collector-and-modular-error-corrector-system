[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Get-Metadata','Test-Condition','Invoke-Fix','Invoke-Rollback')][string]$Action,
    [switch]$WhatIf,
    [string]$LogRoot = (Join-Path $PSScriptRoot '..\..\logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ModuleId = 'WUServiceHealth'
$ServiceDefaults = @{
    wuauserv = 'Manual'
    bits     = 'Manual'
    cryptsvc = 'Automatic'
}

function Get-StatePath {
    $stateDir = Join-Path $LogRoot 'state'
    if (-not (Test-Path $stateDir)) { New-Item -Path $stateDir -ItemType Directory -Force | Out-Null }
    Join-Path $stateDir ("{0}-latest.json" -f $ModuleId)
}

function Get-Metadata {
    [PSCustomObject]@{ Id=$ModuleId; Name='Windows Update szolgáltatások'; Version='1.0.0'; Risk='Low' }
}

function Get-ServiceSnapshot {
    foreach ($name in $ServiceDefaults.Keys) {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            [PSCustomObject]@{ Name=$name; Exists=$false; State=$null; StartMode=$null; Status=$null; PathName=$null }
        }
        else {
            [PSCustomObject]@{ Name=$svc.Name; Exists=$true; State=$svc.State; StartMode=$svc.StartMode; Status=$svc.Status; PathName=$svc.PathName }
        }
    }
}

function Test-Condition {
    $snapshot = @(Get-ServiceSnapshot)
    $issues = @()
    foreach ($svc in $snapshot) {
        if (-not $svc.Exists) { $issues += "$($svc.Name) hiányzik"; continue }
        if ($svc.StartMode -eq 'Disabled') { $issues += "$($svc.Name) le van tiltva" }
    }

    [PSCustomObject]@{
        ModuleId = $ModuleId
        Severity = if ($issues.Count -gt 0) { 'High' } else { 'Info' }
        IssueDetected = $issues.Count -gt 0
        FixAvailable = $true
        Summary = if ($issues.Count -gt 0) { $issues -join '; ' } else { 'A kulcs Windows Update szolgáltatások elérhetők és nincsenek letiltva.' }
        RecommendedAction = 'Letiltott szolgáltatások visszaállítása alap indítási módra, majd szolgáltatásindítás.'
        Details = $snapshot
        RollbackHint = 'A javítás előtt mentett szolgáltatás StartMode értékek visszaállíthatók a Rollback gombbal.'
    }
}

function Invoke-Fix {
    param([switch]$WhatIf)

    $before = @(Get-ServiceSnapshot)
    $statePath = Get-StatePath
    $state = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('o')
        Services = $before
    }

    if ($WhatIf) {
        return [PSCustomObject]@{
            ModuleId=$ModuleId; Result='WhatIf'; Planned=@($ServiceDefaults.GetEnumerator() | ForEach-Object { "Set-Service $($_.Key) -StartupType $($_.Value); Start-Service $($_.Key)" }); StatePath=$statePath
        }
    }

    $state | ConvertTo-Json -Depth 8 | Out-File -FilePath $statePath -Encoding UTF8 -Force

    $actions = New-Object System.Collections.Generic.List[string]
    foreach ($name in $ServiceDefaults.Keys) {
        $startup = $ServiceDefaults[$name]
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            $actions.Add("SKIP: $name nem található")
            continue
        }
        Set-Service -Name $name -StartupType $startup -ErrorAction Stop
        try {
            Start-Service -Name $name -ErrorAction Stop
            $actions.Add("OK: $name StartupType=$startup, Start-Service lefutott")
        }
        catch {
            $actions.Add("WARN: $name StartupType=$startup, Start-Service hiba: $($_.Exception.Message)")
        }
    }

    [PSCustomObject]@{ ModuleId=$ModuleId; Result='Completed'; Actions=$actions; StatePath=$statePath; After=@(Get-ServiceSnapshot) }
}

function Invoke-Rollback {
    $statePath = Get-StatePath
    if (-not (Test-Path $statePath)) {
        return [PSCustomObject]@{ ModuleId=$ModuleId; Result='NoState'; Message='Nincs mentett szolgáltatásállapot.' }
    }

    $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $actions = New-Object System.Collections.Generic.List[string]
    foreach ($svc in $state.Services) {
        if (-not $svc.Exists) { continue }
        try {
            Set-Service -Name $svc.Name -StartupType $svc.StartMode -ErrorAction Stop
            $actions.Add("OK: $($svc.Name) StartupType visszaállítva: $($svc.StartMode)")
        }
        catch {
            $actions.Add("WARN: $($svc.Name) rollback hiba: $($_.Exception.Message)")
        }
    }
    [PSCustomObject]@{ ModuleId=$ModuleId; Result='Completed'; Actions=$actions; StatePath=$statePath }
}

switch ($Action) {
    'Get-Metadata' { Get-Metadata }
    'Test-Condition' { Test-Condition }
    'Invoke-Fix' { Invoke-Fix -WhatIf:$WhatIf }
    'Invoke-Rollback' { Invoke-Rollback }
}
