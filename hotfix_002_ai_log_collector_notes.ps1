[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = Join-Path $RootPath 'modules\AILogCollector\AILogCollector.ps1'
$manifest = Join-Path $RootPath 'modules\AILogCollector\manifest.json'
if (-not (Test-Path $source)) { throw "AILogCollector.ps1 nem található: $source" }
if (-not (Test-Path $manifest)) { throw "AILogCollector manifest nem található: $manifest" }

$backup = "$source.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
Copy-Item -Path $source -Destination $backup -Force

Write-Host "AILogCollector jelenlegi fájl mentve: $backup"
Write-Host "Ha a v1.1.1 patch ZIP tartalmát már bemásoltad, nincs további teendő."
Write-Host "Futtatás: .\collect_ai_logs_for_kb5089573.bat"
