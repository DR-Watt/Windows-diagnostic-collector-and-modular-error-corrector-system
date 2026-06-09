<#
.SYNOPSIS
  Közvetlen P1 normalizer futtató wrapper.
#>
[CmdletBinding()]
param(
  [string]$LogRoot = (Join-Path $PSScriptRoot '..\logs'),
  [string]$PackageRoot = '',
  [string]$TargetKB = '',
  [switch]$WhatIf
)
$script = Join-Path $PSScriptRoot '..\modules\P1Normalizers\P1Normalizers.ps1'
& $script -Action Invoke-Fix -LogRoot $LogRoot -PackageRoot $PackageRoot -TargetKB $TargetKB -WhatIf:$WhatIf
