<#
.SYNOPSIS
  P1 normalizer output validator.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot)
$required = @(
 'analysis/normalized-wer.json',
 'analysis/normalized-setupapi.json',
 'analysis/normalized-cbs-hresults.json',
 'analysis/normalized-pnp-problems.json',
 'analysis/normalized-event-correlation.json',
 'analysis/normalized-windowsupdate-errors.json',
 'analysis/p1-findings.json',
 'analysis/p1-normalization-summary.json'
)
$results = foreach($rel in $required){
  $path = Join-Path $PackageRoot $rel
  [PSCustomObject]@{ Path=$rel; Exists=(Test-Path -LiteralPath $path); Length=if(Test-Path -LiteralPath $path){(Get-Item -LiteralPath $path).Length}else{0} }
}
[PSCustomObject]@{ PackageRoot=$PackageRoot; Results=$results; Valid=(@($results | Where-Object { -not $_.Exists }).Count -eq 0) } | ConvertTo-Json -Depth 8
