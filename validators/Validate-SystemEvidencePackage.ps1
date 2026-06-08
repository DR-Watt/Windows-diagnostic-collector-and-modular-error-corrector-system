<#
.SYNOPSIS
  SystemEvidence v1.3 package validator.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackagePath)
$ErrorActionPreference = 'Stop'
function Test-Exists([string]$Path) { Test-Path -LiteralPath $Path }
$root = $PackagePath
$temp = $null
if ((Test-Path -LiteralPath $PackagePath -PathType Leaf) -and $PackagePath.ToLowerInvariant().EndsWith('.zip')) {
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('DiagFrameworkEvidenceValidate-' + [guid]::NewGuid().ToString('N'))
    New-Item -Path $temp -ItemType Directory -Force | Out-Null
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $temp -Force
    $root = $temp
}
$checks = @(
    'AI_README.md','ai_summary.json','collector-progress.jsonl','manifest.json',
    'errors/collector-issues.json','events/event-export-metadata.json',
    'windows_update/Get-WindowsUpdateLog.result.json','vendor_logs/vendor-log-policy.json'
)
$results = @()
foreach ($rel in $checks) { $results += [PSCustomObject]@{ Path=$rel; Exists=(Test-Exists (Join-Path $root $rel)) } }
$manifestHashOk = $false
try {
    $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
    $withHash = @($manifest.Files | Where-Object { $_.PSObject.Properties['SHA256'] -and $_.SHA256 })
    $manifestHashOk = ($withHash.Count -gt 0)
} catch { }
$out = [PSCustomObject]@{ PackagePath=$PackagePath; Root=$root; RequiredFiles=$results; ManifestHasSha256=$manifestHashOk; Valid=(@($results | Where-Object { -not $_.Exists }).Count -eq 0 -and $manifestHashOk) }
if ($temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
$out | ConvertTo-Json -Depth 8
