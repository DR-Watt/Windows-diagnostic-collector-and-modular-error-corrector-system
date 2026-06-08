<#
.SYNOPSIS
  Környezeti diagnosztika és opcionális javítás Windows 11 / PowerShell 7.x futtatáshoz.
.DESCRIPTION
  v1.2.4: a bootstrap logger nem szennyezi a validátorok success streamjét.
  A validátor JSON kimenete sémavizsgálatot kap, a naplózás pedig Add-Content + Write-Host mintára váltott.
#>
[CmdletBinding()]
param(
    [switch]$InstallPSWindowsUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$logDir = Join-Path $RootPath 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir ('environment-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-EnvLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message

    # Ne használjunk Tee-Objectet itt: a Tee-Object a success output streamre is továbbít,
    # ezért ha a Write-EnvLog egy validátor-wrapperen belül fut, a log sor bekerülhet
    # a JSON validátor visszatérési értékébe. Ez okozta a v1.2.3 hibát:
    # "The property 'Failed' cannot be found on this object".
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    Write-Host $line
}
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function ConvertFrom-ValidatorJsonText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Text
    )

    $trimmed = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw "$Name nem adott JSON kimenetet."
    }

    try {
        return ($trimmed | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        # Védelmi fallback: ha a validátor véletlenül figyelmeztetést vagy egyéb szöveget is írt
        # a success streamre, megpróbáljuk a külső JSON objektumot kivágni.
        $first = $trimmed.IndexOf('{')
        $last = $trimmed.LastIndexOf('}')
        if ($first -ge 0 -and $last -gt $first) {
            $candidate = $trimmed.Substring($first, ($last - $first + 1))
            try { return ($candidate | ConvertFrom-Json -ErrorAction Stop) } catch { }
        }
        throw "$Name kimenete nem feldolgozható JSON-ként: $($_.Exception.Message)"
    }
}

function Assert-ValidatorProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Summary,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$RequiredProperties
    )

    foreach ($prop in $RequiredProperties) {
        if (-not $Summary.PSObject.Properties[$prop]) {
            $available = @($Summary.PSObject.Properties.Name) -join ', '
            throw "$Name hibás JSON sémát adott vissza. Hiányzó mező: $prop. Elérhető mezők: $available"
        }
    }
}

function Invoke-JsonValidatorScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][hashtable]$Arguments = @{}
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Name nem található: $Path"
    }

    Write-EnvLog "$Name futtatása."

    try {
        $output = @(& $Path @Arguments)
        $succeeded = $?
    }
    catch {
        throw "$Name futási hiba: $($_.Exception.Message)"
    }

    $text = ($output | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        Add-Content -LiteralPath $logFile -Value $text -Encoding UTF8
    }

    if (-not $succeeded) {
        throw "$Name sikertelenül futott. Kimenet: $text"
    }

    return (ConvertFrom-ValidatorJsonText -Name $Name -Text $text)
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

$manifestSummary = Invoke-JsonValidatorScript `
    -Name 'Manifest validátor' `
    -Path (Join-Path $RootPath 'validators\Validate-Manifests.ps1') `
    -Arguments @{ RootPath = $RootPath }

Assert-ValidatorProperty -Summary $manifestSummary -Name 'Manifest validátor' -RequiredProperties @('Failed','Checked','Results')

if ([int]$manifestSummary.Failed -gt 0) {
    throw "Manifest validációs hiba. Hibás manifestek száma: $($manifestSummary.Failed)"
}

$uiSummary = Invoke-JsonValidatorScript `
    -Name 'UI resource validátor' `
    -Path (Join-Path $RootPath 'validators\Validate-UiResources.ps1') `
    -Arguments @{ RootPath = $RootPath; Culture = 'hu-HU' }

Assert-ValidatorProperty -Summary $uiSummary -Name 'UI resource validátor' -RequiredProperties @('Valid','ErrorCount','Errors')

if (-not [bool]$uiSummary.Valid) {
    throw "UI resource validációs hiba. Hibák száma: $($uiSummary.ErrorCount)"
}

$syntaxSummary = Invoke-JsonValidatorScript `
    -Name 'PowerShell szintaxisvalidátor' `
    -Path (Join-Path $RootPath 'validators\Validate-PowerShellSyntax.ps1') `
    -Arguments @{ RootPath = $RootPath }

Assert-ValidatorProperty -Summary $syntaxSummary -Name 'PowerShell szintaxisvalidátor' -RequiredProperties @('Valid','Failed','Checked','Results')

if (-not [bool]$syntaxSummary.Valid) {
    throw "PowerShell szintaxisvalidációs hiba. Hibás fájlok száma: $($syntaxSummary.Failed)"
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
