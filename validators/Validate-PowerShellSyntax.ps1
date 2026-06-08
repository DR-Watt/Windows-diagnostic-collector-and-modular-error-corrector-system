<#
.SYNOPSIS
  DiagFramework PowerShell szintaxisvalidátor.
.DESCRIPTION
  A projekt összes .ps1 és .psm1 fájlját PowerShell parserrel ellenőrzi anélkül,
  hogy a fájlokat végrehajtaná. Célja, hogy a GUI futtatása előtt jelezze a
  hiányzó kapcsos zárójelet, váratlan tokeneket és egyéb parser-hibákat.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RootPath)) {
    throw "A megadott RootPath nem található: $RootPath"
}

$results = New-Object System.Collections.Generic.List[object]
$files = Get-ChildItem -LiteralPath $RootPath -Recurse -File -Include '*.ps1','*.psm1' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\logs\\|/logs/' }

foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    try {
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        $errorItems = @()
        foreach ($err in @($parseErrors)) {
            $errorItems += [PSCustomObject]@{
                Message = $err.Message
                ErrorId = $err.ErrorId
                StartLineNumber = $err.Extent.StartLineNumber
                StartColumnNumber = $err.Extent.StartColumnNumber
                Text = $err.Extent.Text
            }
        }
        $results.Add([PSCustomObject]@{
            Path = $file.FullName
            Valid = ($errorItems.Count -eq 0)
            ErrorCount = $errorItems.Count
            Errors = $errorItems
        }) | Out-Null
    }
    catch {
        $results.Add([PSCustomObject]@{
            Path = $file.FullName
            Valid = $false
            ErrorCount = 1
            Errors = @([PSCustomObject]@{
                Message = $_.Exception.Message
                ErrorId = 'ParserInvocationFailed'
                StartLineNumber = $null
                StartColumnNumber = $null
                Text = $null
            })
        }) | Out-Null
    }
}

$failed = @($results | Where-Object { -not $_.Valid })
[PSCustomObject]@{
    RootPath = $RootPath
    Checked = @($results).Count
    Failed = @($failed).Count
    Valid = (@($failed).Count -eq 0)
    Results = @($results)
} | ConvertTo-Json -Depth 10
