<#
.SYNOPSIS
  DiagFramework AI LOG csomag szerkezeti validátora.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PackagePath)) {
    throw "Nem található a megadott AI LOG csomag/mappa: $PackagePath"
}

$temp = $null
$root = $PackagePath
try {
    if ((Get-Item $PackagePath).Extension -eq '.zip') {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('diag-ai-validate-' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $temp -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $PackagePath -DestinationPath $temp -Force
        $root = $temp
    }

    $required = @(
        'manifest.json',
        'ai_summary.json',
        'AI_README.md',
        'meta\system-info.json',
        'updates\update-history.json',
        'registry\reboot-pending.json',
        'events\event-summary.json',
        'errors\error-codes.json'
    )

    $results = foreach ($rel in $required) {
        $path = Join-Path $root $rel
        $exists = Test-Path $path
        $jsonValid = $null
        $errorText = $null
        if ($exists -and $rel -match '\.json$') {
            try {
                Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop | Out-Null
                $jsonValid = $true
            }
            catch {
                $jsonValid = $false
                $errorText = $_.Exception.Message
            }
        }
        [PSCustomObject]@{ RelativePath=$rel; Exists=$exists; JsonValid=$jsonValid; Error=$errorText }
    }

    $failed = @($results | Where-Object { -not $_.Exists -or $_.JsonValid -eq $false })
    [PSCustomObject]@{
        PackagePath = $PackagePath
        Checked = $required.Count
        Failed = $failed.Count
        Results = @($results)
    } | ConvertTo-Json -Depth 8
}
finally {
    if ($temp -and (Test-Path $temp)) { Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
