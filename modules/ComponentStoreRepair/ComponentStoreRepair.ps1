[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Get-Metadata','Test-Condition','Invoke-Fix','Invoke-Rollback')][string]$Action,
    [switch]$WhatIf,
    [string]$LogRoot = (Join-Path $PSScriptRoot '..\..\logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ModuleId = 'ComponentStoreRepair'

function Invoke-NativeCommand {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$Arguments)
    $output = & $FilePath @Arguments 2>&1
    [PSCustomObject]@{ FilePath=$FilePath; Arguments=$Arguments; ExitCode=$LASTEXITCODE; Output=($output -join [Environment]::NewLine) }
}

function Get-Metadata { [PSCustomObject]@{ Id=$ModuleId; Name='DISM / SFC rendszerjavítás'; Version='1.0.0'; Risk='Medium' } }

function Test-Condition {
    $dism = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @('/Online','/Cleanup-Image','/CheckHealth')
    $text = $dism.Output
    $issue = $false
    if ($dism.ExitCode -ne 0) { $issue = $true }
    if ($text -match '(?i)repairable|corrupt|sérült|javítható|component store.*repair') { $issue = $true }

    [PSCustomObject]@{
        ModuleId = $ModuleId
        Severity = if ($issue) { 'High' } else { 'Info' }
        IssueDetected = $issue
        FixAvailable = $true
        Summary = if ($issue) { 'A DISM CheckHealth javítható/sérült állapotot vagy hibát jelzett.' } else { 'A DISM CheckHealth nem jelzett ismert komponens-store sérülést.' }
        RecommendedAction = 'DISM /Online /Cleanup-Image /RestoreHealth, majd sfc /scannow futtatása.'
        Details = $dism
        RollbackHint = 'Nincs közvetlen rollback; a DISM/SFC Microsoft rendszerjavító művelet. Visszaállítási pont/képfájl mentés javasolt nagyobb javítás előtt.'
    }
}

function Invoke-Fix {
    param([switch]$WhatIf)

    if ($WhatIf) {
        return [PSCustomObject]@{
            ModuleId=$ModuleId; Result='WhatIf'; Planned=@('dism.exe /Online /Cleanup-Image /RestoreHealth','sfc.exe /scannow')
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outFile = Join-Path $LogRoot "ComponentStoreRepair-$stamp.txt"

    $dism = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @('/Online','/Cleanup-Image','/RestoreHealth')
    $sfc = Invoke-NativeCommand -FilePath 'sfc.exe' -Arguments @('/scannow')

    @(
        '=== DISM RestoreHealth ===',
        "ExitCode: $($dism.ExitCode)",
        $dism.Output,
        '',
        '=== SFC Scannow ===',
        "ExitCode: $($sfc.ExitCode)",
        $sfc.Output
    ) | Out-File -FilePath $outFile -Encoding UTF8 -Force

    [PSCustomObject]@{ ModuleId=$ModuleId; Result='Completed'; DismExitCode=$dism.ExitCode; SfcExitCode=$sfc.ExitCode; OutputFile=$outFile }
}

function Invoke-Rollback {
    [PSCustomObject]@{ ModuleId=$ModuleId; Result='NoRollback'; Message='DISM/SFC javításnál nincs modul-szintű rollback. Rendszer-visszaállítási pont vagy image backup használható.' }
}

switch ($Action) {
    'Get-Metadata' { Get-Metadata }
    'Test-Condition' { Test-Condition }
    'Invoke-Fix' { Invoke-Fix -WhatIf:$WhatIf }
    'Invoke-Rollback' { Invoke-Rollback }
}
