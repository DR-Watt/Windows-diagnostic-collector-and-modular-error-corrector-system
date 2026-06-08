<#
.SYNOPSIS
  Környezeti diagnosztika és opcionális javítás Windows 11 / PowerShell 7.x futtatáshoz.
#>
[CmdletBinding()]
param(
    [switch]$InstallPSWindowsUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$logDir = Join-Path $RootPath 'logs'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir ('environment-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-EnvLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $line | Tee-Object -FilePath $logFile -Append
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

Write-EnvLog "RootPath: $RootPath"
Write-EnvLog "PowerShell: $($PSVersionTable.PSVersion) / Edition: $($PSVersionTable.PSEdition) / Platform: $($PSVersionTable.Platform)"

if (-not ($PSVersionTable.Platform -eq 'Win32NT' -or $IsWindows)) { throw 'Windows környezet szükséges.' }
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7.x szükséges.' }
if (-not (Test-IsAdmin)) { throw 'Emelt jogosultság szükséges. Indítsd a PowerShellt Run as Administrator módban.' }

try {
    Add-Type -AssemblyName PresentationFramework
    Write-EnvLog 'WPF PresentationFramework betöltés: OK'
} catch {
    Write-EnvLog "WPF PresentationFramework betöltés: HIBA - $($_.Exception.Message)"
    throw
}

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

if ($InstallPSWindowsUpdate) {
    Write-EnvLog 'PSWindowsUpdate telepítés/frissítés indítása.'
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
    }
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
    Install-Module -Name PSWindowsUpdate -Scope AllUsers -Force -AllowClobber
    Write-EnvLog 'PSWindowsUpdate telepítés/frissítés: OK'
}

Write-EnvLog 'Környezeti diagnosztika befejezve.'
Write-Host "Log: $logFile"
