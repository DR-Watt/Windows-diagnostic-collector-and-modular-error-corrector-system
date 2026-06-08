<#
.SYNOPSIS
  DiagFramework PowerShell szintaxisvalidátor.
.DESCRIPTION
  v1.2.6 Safe/Non-blocking compatible validator.

  Cél:
  - .ps1 és .psm1 fájlok szintaktikai ellenőrzése végrehajtás nélkül.
  - A validátor saját hibája ne állítsa meg a teljes bootstrap folyamatot.
  - Tényleges fájlszintű szintaktikai hiba strukturált JSON-ként jelenjen meg.

  Megjegyzés:
  A korábbi Parser.ParseFile / [ref] out-paraméteres megoldást eltávolítottuk, mert
  bizonyos PowerShell 7.x környezetekben "Argument types do not match" hibát okozott.
  A ScriptBlock.Create csak parse-olja a forrást, nem futtatja.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RootPath
)

$ErrorActionPreference = 'Stop'

function New-DfSyntaxErrorRecord {
    param(
        [string]$Message,
        [string]$ErrorId,
        $StartLineNumber,
        $StartColumnNumber,
        [string]$Text
    )

    [PSCustomObject]@{
        Message           = [string]$Message
        ErrorId           = [string]$ErrorId
        StartLineNumber   = $StartLineNumber
        StartColumnNumber = $StartColumnNumber
        Text              = [string]$Text
    }
}

function Convert-DfExceptionToErrors {
    param($CaughtError)

    $out = @()
    $message = $null
    $errorId = $null

    try { $message = [string]$CaughtError.Exception.Message } catch { $message = 'Ismeretlen PowerShell parse hiba.' }
    try { $errorId = [string]$CaughtError.FullyQualifiedErrorId } catch { $errorId = 'PowerShellSyntaxError' }

    # ParseException esetén megpróbáljuk kinyerni a részletes parser hibákat.
    # Minden mezőolvasás védett, mert bootstrap validátornál nem megengedett a másodlagos hiba.
    try {
        $exception = $CaughtError.Exception
        $parserErrors = $null
        try { $parserErrors = $exception.Errors } catch { $parserErrors = $null }

        if ($null -ne $parserErrors) {
            foreach ($parseError in @($parserErrors)) {
                $line = $null
                $column = $null
                $text = $null
                $peMessage = $message
                $peErrorId = $errorId

                try { $peMessage = [string]$parseError.Message } catch { }
                try { $peErrorId = [string]$parseError.ErrorId } catch { }
                try { $line = $parseError.Extent.StartLineNumber } catch { $line = $null }
                try { $column = $parseError.Extent.StartColumnNumber } catch { $column = $null }
                try { $text = [string]$parseError.Extent.Text } catch { $text = $null }

                $out += New-DfSyntaxErrorRecord -Message $peMessage -ErrorId $peErrorId -StartLineNumber $line -StartColumnNumber $column -Text $text
            }
        }
    }
    catch {
        # Nincs teendő: fallback üzenetet adunk lentebb.
    }

    if (@($out).Count -eq 0) {
        $out += New-DfSyntaxErrorRecord -Message $message -ErrorId $errorId -StartLineNumber $null -StartColumnNumber $null -Text $null
    }

    return @($out)
}

function Test-DfPowerShellFileSyntax {
    param([string]$Path)

    try {
        $content = [System.IO.File]::ReadAllText([string]$Path, [System.Text.Encoding]::UTF8)
    }
    catch {
        return [PSCustomObject]@{
            Path       = [string]$Path
            Valid      = $false
            ErrorCount = 1
            Errors     = @(
                New-DfSyntaxErrorRecord -Message ("Fájlolvasási hiba: {0}" -f $_.Exception.Message) -ErrorId 'FileReadFailed' -StartLineNumber $null -StartColumnNumber $null -Text $null
            )
        }
    }

    try {
        # Csak szintaktikai elemzés: a ScriptBlock nem kerül végrehajtásra.
        [void][scriptblock]::Create([string]$content)
        return [PSCustomObject]@{
            Path       = [string]$Path
            Valid      = $true
            ErrorCount = 0
            Errors     = @()
        }
    }
    catch {
        $errs = @(Convert-DfExceptionToErrors -CaughtError $_)
        return [PSCustomObject]@{
            Path       = [string]$Path
            Valid      = $false
            ErrorCount = @($errs).Count
            Errors     = @($errs)
        }
    }
}

$results = @()
$checked = 0
try {
    if (-not (Test-Path -LiteralPath $RootPath)) {
        throw "A megadott RootPath nem található: $RootPath"
    }

    $allFiles = @(Get-ChildItem -LiteralPath $RootPath -Recurse -File -ErrorAction SilentlyContinue)
    $psFiles = @()
    foreach ($item in $allFiles) {
        $fullName = [string]$item.FullName
        $extension = [string]$item.Extension
        if (($extension -eq '.ps1' -or $extension -eq '.psm1') -and ($fullName -notmatch '\\logs\\|/logs/')) {
            $psFiles += $item
        }
    }

    $psFiles = @($psFiles | Sort-Object FullName)
    foreach ($file in $psFiles) {
        $checked++
        $results += Test-DfPowerShellFileSyntax -Path ([string]$file.FullName)
    }

    $failed = @($results | Where-Object { -not [bool]$_.Valid })
    [PSCustomObject]@{
        SchemaVersion = 'diagframework.validator.powershellsyntax.v1'
        ValidatorMode = 'ScriptBlockCreateSafeMode-v1.2.6'
        RootPath      = [string]$RootPath
        Checked       = [int]$checked
        Failed        = [int]@($failed).Count
        Valid         = (@($failed).Count -eq 0)
        InternalError = $false
        Results       = @($results)
    } | ConvertTo-Json -Depth 18
}
catch {
    # A validátor saját hibája nem fájlszintű PowerShell szintaktikai hiba.
    # Strukturáltan visszaadjuk, hogy a bootstrap eldönthesse: warningként folytatható-e.
    [PSCustomObject]@{
        SchemaVersion = 'diagframework.validator.powershellsyntax.v1'
        ValidatorMode = 'ScriptBlockCreateSafeMode-v1.2.6'
        RootPath      = [string]$RootPath
        Checked       = [int]$checked
        Failed        = 1
        Valid         = $false
        InternalError = $true
        Results       = @(
            [PSCustomObject]@{
                Path       = $null
                Valid      = $false
                ErrorCount = 1
                Errors     = @(
                    New-DfSyntaxErrorRecord -Message ("ValidatorInternalError: {0}" -f $_.Exception.Message) -ErrorId 'ValidatorInternalError' -StartLineNumber $null -StartColumnNumber $null -Text $null
                )
            }
        )
    } | ConvertTo-Json -Depth 18
}
