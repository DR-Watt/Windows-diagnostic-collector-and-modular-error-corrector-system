<#
.SYNOPSIS
  Parancssoros rendszer LOG bizonyítékcsomag készítése Windows 11 boot/setup/driver/update hibákhoz.
#>
[CmdletBinding()]
param(
    [int]$DaysBack = 30,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $RootPath 'DiagFramework.psm1') -Force

$module = Get-RegisteredDiagModules | Where-Object Id -eq 'SystemEvidenceCollector' | Select-Object -First 1
if (-not $module) { throw 'A SystemEvidenceCollector modul nem található.' }

$result = Invoke-DiagModuleAction -Module $module -Action 'Invoke-Fix' -WhatIf:$WhatIf -Parameters @{ DaysBack = $DaysBack }
$result | ConvertTo-Json -Depth 12
