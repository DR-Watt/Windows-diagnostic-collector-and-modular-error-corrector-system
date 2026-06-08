<#
.SYNOPSIS
  Hotfix 001: Initialize-DiagEnvironment.ps1 $LASTEXITCODE StrictMode hiba javítása.

.DESCRIPTION
  A futó DiagFramework_WURepair_MVP mappában lecseréli a diagnosztikai bootstrap
  manifest-validátor ellenőrző blokkját olyan változatra, amely JSON summary alapján dönt.
#>
[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$target = Join-Path $RootPath 'diagnostics\Initialize-DiagEnvironment.ps1'
if (-not (Test-Path $target)) {
    throw "Nem található: $target"
}

$backup = '{0}.hotfix001.bak-{1}' -f $target, (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item -Path $target -Destination $backup -Force

$text = Get-Content -Path $target -Raw -Encoding UTF8
$old = @'
Write-EnvLog 'Manifest validátor futtatása.'
$validator = Join-Path $RootPath 'validators\Validate-Manifests.ps1'
& $validator -RootPath $RootPath | Tee-Object -FilePath $logFile -Append
if ($LASTEXITCODE -ne 0) { throw 'Manifest validációs hiba.' }
'@
$new = @'
Write-EnvLog 'Manifest validátor futtatása.'
$validator = Join-Path $RootPath 'validators\Validate-Manifests.ps1'

# PowerShell script hívás után a $LASTEXITCODE nem megbízható ellenőrzési pont,
# mert csak natív folyamatok vagy explicit exit kulcsszó állítja be biztosan.
# Set-StrictMode -Version Latest mellett egy még nem létező $LASTEXITCODE olvasása
# termináló hibát okozhat, ezért a validátor JSON kimenetét értékeljük ki.
$validationOutput = @(& $validator -RootPath $RootPath 2>&1)
$validationSucceeded = $?
$validationOutput | Tee-Object -FilePath $logFile -Append

if (-not $validationSucceeded) {
    throw 'Manifest validátor futási hiba.'
}

try {
    $validationSummary = ($validationOutput | Out-String | ConvertFrom-Json -ErrorAction Stop)
}
catch {
    throw "Manifest validátor kimenete nem feldolgozható JSON-ként: $($_.Exception.Message)"
}

if ([int]$validationSummary.Failed -gt 0) {
    throw "Manifest validációs hiba. Hibás manifestek száma: $($validationSummary.Failed)"
}
'@

if ($text -notlike "*$old*") {
    if ($text -like "*`$validationOutput = @(& `$validator -RootPath `$RootPath 2>&1)*") {
        Write-Host "A hotfix már telepítve van. Backup: $backup"
        return
    }
    throw 'A javítandó blokk nem található. Lehet, hogy a fájl már módosítva lett.'
}

$text = $text.Replace($old, $new)
Set-Content -Path $target -Value $text -Encoding UTF8
Write-Host "Hotfix telepítve: $target"
Write-Host "Backup: $backup"
