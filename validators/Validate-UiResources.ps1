<#
.SYNOPSIS
  DiagFramework UI lokalizációs JSON validátor.
#>
[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
    [string]$Culture = 'hu-HU'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$file = Join-Path $RootPath ("config\ui.$Culture.json")
if (-not (Test-Path $file)) { throw "UI resource fájl nem található: $file" }
$json = Get-Content -Path $file -Raw -Encoding UTF8 | ConvertFrom-Json
$errors = New-Object System.Collections.Generic.List[string]

foreach ($field in 'SchemaVersion','Culture','Controls','Messages','Window') {
    if (-not $json.PSObject.Properties[$field]) { $errors.Add("Missing field: $field") }
}

$requiredControls = @(
    'btnReloadModules','btnScan','btnRunSelected','btnRollbackSelected','chkWhatIf','btnSearchUpdates','btnInstallUpdates',
    'lblTargetKB','txtTargetKB','lblDaysBack','txtDaysBack','btnAiLogPackage','btnEvidencePackage','btnOpenLogs','txtTopHint',
    'grpModules','grpSummary','grpRecommendedAction','grpLog','grpUsageNotes','txtUsageNotes','txtStatus'
)
foreach ($name in $requiredControls) {
    if (-not $json.Controls.PSObject.Properties[$name]) { $errors.Add("Missing control resource: $name") }
}

$result = [PSCustomObject]@{
    File = $file
    Valid = ($errors.Count -eq 0)
    ErrorCount = $errors.Count
    Errors = @($errors)
}
$result | ConvertTo-Json -Depth 8
if ($errors.Count -gt 0) { exit 1 }
