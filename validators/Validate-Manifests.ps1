<#
.SYNOPSIS
  Drop-in diagnosztikai modul manifest validátor.

.DESCRIPTION
  v1.2.0: a kötelező mezők mellett ellenőrzi a manifestbe áthelyezett UI információs
  mezőket is: Ui.Summary, Ui.RecommendedAction, Ui.ToolTip, Ui.Impact.
#>
[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $RootPath 'modules'
$required = 'Id','Name','Version','Author','Script','Risk','Description'
$requiredUi = 'Summary','RecommendedAction','ToolTip','Impact'
$results = New-Object System.Collections.Generic.List[object]

if (-not (Test-Path $modulePath)) {
    throw "Modules mappa nem található: $modulePath"
}

$manifests = Get-ChildItem -Path $modulePath -Recurse -Filter 'manifest.json' -ErrorAction Stop
foreach ($manifest in $manifests) {
    $ok = $true
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
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
        if (-not $json.PSObject.Properties['Ui'] -or -not $json.Ui) {
            $ok = $false; $errors.Add('Missing object: Ui')
        }
        else {
            foreach ($key in $requiredUi) {
                if (-not $json.Ui.PSObject.Properties[$key] -or [string]::IsNullOrWhiteSpace([string]$json.Ui.$key)) {
                    $ok = $false; $errors.Add("Missing Ui field: Ui.$key")
                }
            }
        }
        if (-not $json.PSObject.Properties['Category']) { $warnings.Add('Recommended field missing: Category') }
    }
    catch {
        $ok = $false; $errors.Add($_.Exception.Message)
    }
    $results.Add([PSCustomObject]@{ Manifest=$manifest.FullName; Valid=$ok; Errors=@($errors); Warnings=@($warnings) })
}

$summary = [PSCustomObject]@{
    RootPath = $RootPath
    Checked = $results.Count
    Failed = @($results | Where-Object { -not $_.Valid }).Count
    WarningCount = @($results | ForEach-Object { $_.Warnings } | Where-Object { $_ }).Count
    Results = $results
}

$summary | ConvertTo-Json -Depth 10
if ($summary.Failed -gt 0) { exit 1 }
