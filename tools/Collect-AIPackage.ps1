<#
.SYNOPSIS
  Parancssoros AI LOG csomag készítése célzott Windows Update KB hibához.
#>
[CmdletBinding()]
param(
    [string]$TargetKB = 'KB5089573',
    [int]$DaysBack = 30,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $RootPath 'DiagFramework.psm1') -Force

$module = Get-RegisteredDiagModules | Where-Object Id -eq 'AILogCollector' | Select-Object -First 1
if (-not $module) { throw 'Az AILogCollector modul nem található.' }

$result = Invoke-DiagModuleAction -Module $module -Action 'Invoke-Fix' -WhatIf:$WhatIf -Parameters @{ TargetKB = $TargetKB; DaysBack = $DaysBack }
$result | ConvertTo-Json -Depth 12
