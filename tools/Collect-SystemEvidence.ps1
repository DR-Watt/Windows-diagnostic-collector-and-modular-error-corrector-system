<#
.SYNOPSIS
  Parancssoros rendszer LOG bizonyítékcsomag készítése Windows 11 boot/setup/driver/update hibákhoz.
#>
[CmdletBinding()]
param(
    [int]$DaysBack = 30,
    [int]$MaxEvents = 1200,
    [string]$TargetKB = '',
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $RootPath 'DiagFramework.psm1') -Force

$module = Get-RegisteredDiagModules | Where-Object Id -eq 'SystemEvidenceCollector' | Select-Object -First 1
if (-not $module) { throw 'A SystemEvidenceCollector modul nem található.' }

$params = @{ DaysBack = $DaysBack; MaxEvents = $MaxEvents }
if (-not [string]::IsNullOrWhiteSpace($TargetKB)) { $params.TargetKB = $TargetKB }

$result = Invoke-DiagModuleAction -Module $module -Action 'Invoke-Fix' -WhatIf:$WhatIf -Parameters $params
$result | ConvertTo-Json -Depth 12
