<#
.SYNOPSIS
  DiagFramework PowerShell szintaxisvalidátor.
.DESCRIPTION
  v1.2.5 Safe Mode: a korábbi Parser.ParseFile / [ref] out-paraméteres validálást
  kiváltja egy ScriptBlock.Create alapú, nem végrehajtó parser-próbával.

  Indok: több PowerShell 7.x környezetben a System.Management.Automation.Language.Parser
  statikus metódusainak [ref] out-paraméter kötése "Argument types do not match" hibával
  megszakíthatja magát a validátort. Ez bootstrap validátornál elfogadhatatlan.

  A ScriptBlock.Create csak parse-olja a forráskódot, nem hajtja végre. Ha a fájl szintaktikailag
  hibás, kivételt dob, amelyet a validátor strukturált JSON eredménnyé alakít.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-SyntaxErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$ErrorId = 'PowerShellSyntaxError',
        [object]$StartLineNumber = $null,
        [object]$StartColumnNumber = $null,
        [string]$Text = $null
    )

    [PSCustomObject]@{
        Message           = [string]$Message
        ErrorId           = [string]$ErrorId
        StartLineNumber   = $StartLineNumber
        StartColumnNumber = $StartColumnNumber
        Text              = $Text
    }
}

function Convert-ExceptionToSyntaxErrors {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $items = New-Object System.Collections.Generic.List[object]
    $exception = $ErrorRecord.Exception

    # ParseException esetén gyakran elérhető több részletes ParserError.
    try {
        if ($exception -is [System.Management.Automation.ParseException] -and $exception.Errors) {
            foreach ($parseError in @($exception.Errors)) {
                $line = $null
                $column = $null
                $text = $null
                try { $line = [int]$parseError.Extent.StartLineNumber } catch { $line = $null }
                try { $column = [int]$parseError.Extent.StartColumnNumber } catch { $column = $null }
                try { $text = [string]$parseError.Extent.Text } catch { $text = $null }

                $items.Add((New-SyntaxErrorRecord `
                    -Message ([string]$parseError.Message) `
                    -ErrorId ([string]$parseError.ErrorId) `
                    -StartLineNumber $line `
                    -StartColumnNumber $column `
                    -Text $text)) | Out-Null
            }
        }
    }
    catch {
        # Szándékosan üres: a validátor soha ne omoljon össze hibaobjektum-feldolgozás közben.
    }

    if ($items.Count -eq 0) {
        $items.Add((New-SyntaxErrorRecord `
            -Message ([string]$exception.Message) `
            -ErrorId ([string]$ErrorRecord.FullyQualifiedErrorId) `
            -StartLineNumber $null `
            -StartColumnNumber $null `
            -Text $null)) | Out-Null
    }

    return @($items)
}

function Test-OnePowerShellFileSyntax {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{
            Path       = $Path
            Valid      = $false
            ErrorCount = 1
            Errors     = @(
                New-SyntaxErrorRecord `
                    -Message ("Fájlolvasási hiba: {0}" -f $_.Exception.Message) `
                    -ErrorId 'FileReadFailed'
            )
        }
    }

    try {
        # Csak szintaktikai elemzés történik. A ScriptBlock nem kerül végrehajtásra.
        $null = [scriptblock]::Create($content)

        return [PSCustomObject]@{
            Path       = $Path
            Valid      = $true
            ErrorCount = 0
            Errors     = @()
        }
    }
    catch {
        $errors = @(Convert-ExceptionToSyntaxErrors -ErrorRecord $_)
        return [PSCustomObject]@{
            Path       = $Path
            Valid      = $false
            ErrorCount = $errors.Count
            Errors     = @($errors)
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $RootPath)) {
        throw "A megadott RootPath nem található: $RootPath"
    }

    $results = New-Object System.Collections.Generic.List[object]
    $files = Get-ChildItem -LiteralPath $RootPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Extension -in @('.ps1', '.psm1')) -and
            ($_.FullName -notmatch '\\logs\\|/logs/')
        } |
        Sort-Object FullName

    foreach ($file in $files) {
        $results.Add((Test-OnePowerShellFileSyntax -Path $file.FullName)) | Out-Null
    }

    $failed = @($results | Where-Object { -not $_.Valid })
    [PSCustomObject]@{
        SchemaVersion = 'diagframework.validator.powershellsyntax.v1'
        ValidatorMode = 'ScriptBlockCreateSafeMode'
        RootPath      = $RootPath
        Checked       = @($results).Count
        Failed        = @($failed).Count
        Valid         = (@($failed).Count -eq 0)
        Results       = @($results)
    } | ConvertTo-Json -Depth 18
}
catch {
    # Végső védőháló: a validátor saját hibáját is JSON-ként adja vissza,
    # hogy az Initialize-DiagEnvironment ne nyers PowerShell kivételként omoljon össze.
    [PSCustomObject]@{
        SchemaVersion = 'diagframework.validator.powershellsyntax.v1'
        ValidatorMode = 'ScriptBlockCreateSafeMode'
        RootPath      = $RootPath
        Checked       = 0
        Failed        = 1
        Valid         = $false
        Results       = @(
            [PSCustomObject]@{
                Path       = $null
                Valid      = $false
                ErrorCount = 1
                Errors     = @(
                    New-SyntaxErrorRecord `
                        -Message ("ValidatorInternalError: {0}" -f $_.Exception.Message) `
                        -ErrorId 'ValidatorInternalError'
                )
            }
        )
    } | ConvertTo-Json -Depth 18
}
