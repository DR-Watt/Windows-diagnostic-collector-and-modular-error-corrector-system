[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Get-Metadata','Test-Condition','Invoke-Fix','Invoke-Rollback')][string]$Action,
    [switch]$WhatIf,
    [string]$LogRoot = (Join-Path $PSScriptRoot '..\..\logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ModuleId = 'PSWindowsUpdateManager'

function Get-Metadata { [PSCustomObject]@{ Id=$ModuleId; Name='PSWindowsUpdate integráció'; Version='1.0.0'; Risk='Medium' } }

function Get-ModuleInfoSafe {
    $available = Get-Module -ListAvailable -Name PSWindowsUpdate | Sort-Object Version -Descending | Select-Object -First 1
    if ($available) {
        [PSCustomObject]@{ Installed=$true; Version=$available.Version.ToString(); Path=$available.Path }
    } else {
        [PSCustomObject]@{ Installed=$false; Version=$null; Path=$null }
    }
}

function Test-Condition {
    $info = Get-ModuleInfoSafe
    $commands = @()
    if ($info.Installed) {
        try {
            Import-Module PSWindowsUpdate -ErrorAction Stop
            $commands = Get-Command -Module PSWindowsUpdate | Select-Object Name, CommandType
        } catch { }
    }

    [PSCustomObject]@{
        ModuleId=$ModuleId
        Severity= if ($info.Installed) { 'Info' } else { 'Medium' }
        IssueDetected= -not $info.Installed
        FixAvailable=$true
        Summary= if ($info.Installed) { "PSWindowsUpdate telepítve: $($info.Version)" } else { 'A PSWindowsUpdate modul nincs telepítve.' }
        RecommendedAction='PSWindowsUpdate telepítése/frissítése PowerShell Gallery forrásból; utána a GUI Frissítések keresése/telepítése gombjai használhatók.'
        Details=[PSCustomObject]@{ Module=$info; Commands=$commands }
        RollbackHint='A modul eltávolítása kézzel végezhető: Uninstall-Module PSWindowsUpdate -AllVersions.'
    }
}

function Invoke-Fix {
    param([switch]$WhatIf)

    if ($WhatIf) {
        return [PSCustomObject]@{ ModuleId=$ModuleId; Result='WhatIf'; Planned='Install-Module PSWindowsUpdate -Scope AllUsers -Force -AllowClobber' }
    }

    $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $nuget) {
        Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
    }

    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    Install-Module -Name PSWindowsUpdate -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    Import-Module PSWindowsUpdate -Force -ErrorAction Stop
    $info = Get-ModuleInfoSafe
    [PSCustomObject]@{ ModuleId=$ModuleId; Result='Completed'; Installed=$info }
}

function Invoke-Rollback {
    [PSCustomObject]@{ ModuleId=$ModuleId; Result='ManualRollback'; Message='Szükség esetén: Uninstall-Module PSWindowsUpdate -AllVersions. A modul automatikus eltávolítását szándékosan nem végzem.' }
}

switch ($Action) {
    'Get-Metadata' { Get-Metadata }
    'Test-Condition' { Test-Condition }
    'Invoke-Fix' { Invoke-Fix -WhatIf:$WhatIf }
    'Invoke-Rollback' { Invoke-Rollback }
}
