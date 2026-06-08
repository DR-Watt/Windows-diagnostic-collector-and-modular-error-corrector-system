<#
.SYNOPSIS
  DiagFramework PowerShell szintaxisvalidátor.
.DESCRIPTION
  A projekt összes .ps1 és .psm1 fájlját PowerShell parserrel ellenőrzi anélkül,
  hogy a fájlokat végrehajtaná. A v1.2.3 javítás explicit Token[] és ParseError[]
  referencia-változókat használ, mert a Parser.ParseFile metódus erősen tipizált
  out-paramétereket vár. Így elkerülhető az "Argument types do not match" típushiba
  PowerShell 7.x alatt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-SyntaxErrorRecord {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$ErrorId,
        [Nullable[int]]$StartLineNumber,
        [Nullable[int]]$StartColumnNumber,
        [string]$Text
    )

    [PSCustomObject]@{
        Message           = $Message
        ErrorId           = $ErrorId
        StartLineNumber   = $StartLineNumber
        StartColumnNumber = $StartColumnNumber
        Text              = $Text
    }
}

function Test-OnePowerShellFileSyntax {
    param([Parameter(Mandatory)][string]$Path)

    [System.Management.Automation.Language.Token[]]$tokens = $null
    [System.Management.Automation.Language.ParseError[]]$parseErrors = $null

    try {
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            [string]$Path,
            [ref]$tokens,
            [ref]$parseErrors
        )
    }
    catch {
        return [PSCustomObject]@{
            Path       = $Path
            Valid      = $false
            ErrorCount = 1
            Errors     = @(
                New-SyntaxErrorRecord `
                    -Message $_.Exception.Message `
                    -ErrorId 'ParserInvocationFailed' `
                    -StartLineNumber $null `
                    -StartColumnNumber $null `
                    -Text $null
            )
        }
    }

    $errorItems = @()
    foreach ($err in @($parseErrors)) {
        $line = $null
        $col = $null
        $text = $null
        try { $line = [int]$err.Extent.StartLineNumber } catch { $line = $null }
        try { $col = [int]$err.Extent.StartColumnNumber } catch { $col = $null }
        try { $text = [string]$err.Extent.Text } catch { $text = $null }

        $errorItems += New-SyntaxErrorRecord `
            -Message ([string]$err.Message) `
            -ErrorId ([string]$err.ErrorId) `
            -StartLineNumber $line `
            -StartColumnNumber $col `
            -Text $text
    }

    [PSCustomObject]@{
        Path       = $Path
        Valid      = ($errorItems.Count -eq 0)
        ErrorCount = $errorItems.Count
        Errors     = @($errorItems)
    }
}

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
    RootPath      = $RootPath
    Checked       = @($results).Count
    Failed        = @($failed).Count
    Valid         = (@($failed).Count -eq 0)
    Results       = @($results)
} | ConvertTo-Json -Depth 16
