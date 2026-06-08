<#
.SYNOPSIS
  Drop-in diagnosztikai modul manifest validátor.
#>
[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $RootPath 'modules'
$required = 'Id','Name','Version','Author','Script','Risk','Description'
$results = New-Object System.Collections.Generic.List[object]

if (-not (Test-Path $modulePath)) {
    throw "Modules mappa nem található: $modulePath"
}

$manifests = Get-ChildItem -Path $modulePath -Recurse -Filter 'manifest.json' -ErrorAction Stop
foreach ($manifest in $manifests) {
    $ok = $true
    $errors = New-Object System.Collections.Generic.List[string]
    try {
        $json = Get-Content $manifest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in $required) {
            if (-not $json.PSObject.Properties[$key] -or [string]::IsNullOrWhiteSpace([string]$json.$key)) {
                $ok = $false; $errors.Add("Missing field: $key")
            }
        }
        if ($json.PSObject.Properties['Script']) {
            $scriptPath = Join-Path $manifest.DirectoryName $json.Script
            if (-not (Test-Path $scriptPath)) { $ok = $false; $errors.Add("Script not found: $scriptPath") }
        }
    }
    catch {
        $ok = $false; $errors.Add($_.Exception.Message)
    }
    $results.Add([PSCustomObject]@{ Manifest=$manifest.FullName; Valid=$ok; Errors=@($errors) })
}

$summary = [PSCustomObject]@{
    RootPath = $RootPath
    Checked = $results.Count
    Failed = @($results | Where-Object { -not $_.Valid }).Count
    Results = $results
}

$summary | ConvertTo-Json -Depth 8
if ($summary.Failed -gt 0) { exit 1 }
