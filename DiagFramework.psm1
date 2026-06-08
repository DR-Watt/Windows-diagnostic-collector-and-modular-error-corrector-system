<#
.SYNOPSIS
  Moduláris diagnosztikai és javító core motor Windows 11 Update hibákhoz.

.DESCRIPTION
  A v1.1.0 verzió strukturált, AI által elemezhető JSONL naplózást,
  futási session azonosítót, és opcionális paraméterátadást ad a modulokhoz.
#>

Set-StrictMode -Version Latest

$Script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:ModulesPath = Join-Path $Script:ScriptRoot 'modules'
$Script:LogPath = Join-Path $Script:ScriptRoot 'logs'
$Script:StatePath = Join-Path $Script:LogPath 'state'
$Script:JsonlPath = Join-Path $Script:LogPath 'jsonl'
$Script:PackagePath = Join-Path $Script:LogPath 'ai_packages'
$Script:RunId = ('run-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0,8)))

foreach ($path in @($Script:LogPath, $Script:StatePath, $Script:JsonlPath, $Script:PackagePath)) {
    if (-not (Test-Path $path)) { New-Item -Path $path -ItemType Directory -Force | Out-Null }
}

function Test-DiagAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    }
    catch { return $false }
}

function Get-DiagHostSnapshot {
    [CmdletBinding()]
    param()

    $os = $null
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }

    [PSCustomObject]@{
        ComputerName   = $env:COMPUTERNAME
        UserName       = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        IsAdministrator = Test-DiagAdministrator
        ProcessId      = $PID
        Is64BitProcess = [Environment]::Is64BitProcess
        PowerShell     = [PSCustomObject]@{
            Version = $PSVersionTable.PSVersion.ToString()
            Edition = $PSVersionTable.PSEdition
            Platform = if ($PSVersionTable.ContainsKey('Platform')) { $PSVersionTable.Platform } else { $null }
        }
        OS = if ($os) {
            [PSCustomObject]@{
                Caption      = $os.Caption
                Version      = $os.Version
                BuildNumber  = $os.BuildNumber
                Architecture = $os.OSArchitecture
                InstallDate  = if ($os.InstallDate) { ([datetime]$os.InstallDate).ToString('o') } else { $null }
                LastBootUpTime = if ($os.LastBootUpTime) { ([datetime]$os.LastBootUpTime).ToString('o') } else { $null }
            }
        } else { $null }
    }
}

function Write-DiagLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ModuleId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter()][object]$Data,
        [Parameter()][ValidateSet('Trace','Debug','Info','Warning','Error','Critical')][string]$Severity = 'Info',
        [Parameter()][string]$CorrelationId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationId)) { $CorrelationId = $Script:RunId }

    $entry = [ordered]@{
        SchemaVersion = 'diagframework.logevent.v1'
        TimestampUtc  = (Get-Date).ToUniversalTime().ToString('o')
        TimestampLocal = (Get-Date).ToString('o')
        RunId         = $Script:RunId
        CorrelationId = $CorrelationId
        Severity      = $Severity
        Computer      = $env:COMPUTERNAME
        User          = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Module        = $ModuleId
        Action        = $Action
        Host          = [PSCustomObject]@{
            PSVersion = $PSVersionTable.PSVersion.ToString()
            PSEdition = $PSVersionTable.PSEdition
            ProcessId = $PID
            IsAdmin   = Test-DiagAdministrator
        }
        Data          = $Data
    }

    $file = Join-Path $Script:JsonlPath ('diag-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))
    $entry | ConvertTo-Json -Depth 20 -Compress | Out-File -FilePath $file -Append -Encoding utf8

    # Visszafelé kompatibilis napi fájl is marad.
    $legacyFile = Join-Path $Script:LogPath ('diag-{0}.jsonl' -f (Get-Date -Format 'yyyyMMdd'))
    $entry | ConvertTo-Json -Depth 20 -Compress | Out-File -FilePath $legacyFile -Append -Encoding utf8
}

function Write-DiagJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][int]$Depth = 20
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
    $InputObject | ConvertTo-Json -Depth $Depth | Out-File -FilePath $Path -Encoding UTF8 -Force
}

function Test-DiagManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $required = 'Id','Name','Version','Author','Script','Risk','Description'
    $json = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $missing = @()
    foreach ($key in $required) {
        if (-not $json.PSObject.Properties[$key] -or [string]::IsNullOrWhiteSpace([string]$json.$key)) {
            $missing += $key
        }
    }
    if ($missing.Count -gt 0) {
        throw "Manifest kötelező mező hiányzik: $($missing -join ', ') / $Path"
    }

    $scriptPath = Join-Path (Split-Path -Parent $Path) $json.Script
    if (-not (Test-Path $scriptPath)) {
        throw "A manifest által hivatkozott script nem található: $scriptPath"
    }

    $json | Add-Member -NotePropertyName ScriptPath -NotePropertyValue $scriptPath -Force
    $json | Add-Member -NotePropertyName ModuleFolder -NotePropertyValue (Split-Path -Parent $Path) -Force
    [PSCustomObject]$json
}

function Get-RegisteredDiagModules {
    [CmdletBinding()]
    param()

    if (-not (Test-Path $Script:ModulesPath)) { return @() }

    $items = New-Object System.Collections.Generic.List[object]
    $manifests = Get-ChildItem -Path $Script:ModulesPath -Recurse -Filter 'manifest.json' -ErrorAction SilentlyContinue
    foreach ($manifest in $manifests) {
        try {
            $module = Test-DiagManifest -Path $manifest.FullName
            $items.Add($module)
        }
        catch {
            Write-DiagLog -ModuleId 'Core' -Action 'ManifestError' -Severity 'Error' -Data @{ Path = $manifest.FullName; Error = $_.Exception.Message }
        }
    }
    return @($items | Sort-Object Id)
}

function Invoke-DiagModuleAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Module,
        [Parameter(Mandatory)][ValidateSet('Get-Metadata','Test-Condition','Invoke-Fix','Invoke-Rollback')][string]$Action,
        [switch]$WhatIf,
        [hashtable]$Parameters
    )

    if (-not (Test-Path $Module.ScriptPath)) {
        throw "Modul script nem található: $($Module.ScriptPath)"
    }

    $parameterLog = if ($Parameters) { $Parameters } else { @{} }
    Write-DiagLog -ModuleId $Module.Id -Action "Invoke-$Action-Start" -Data @{ WhatIf = $WhatIf.IsPresent; Script = $Module.ScriptPath; Parameters = $parameterLog }
    try {
        $splat = @{
            Action = $Action
            WhatIf = $WhatIf.IsPresent
            LogRoot = $Script:LogPath
        }
        if ($Parameters) {
            foreach ($key in $Parameters.Keys) { $splat[$key] = $Parameters[$key] }
        }
        $result = & $Module.ScriptPath @splat
        Write-DiagLog -ModuleId $Module.Id -Action "Invoke-$Action-Complete" -Data $result
        return $result
    }
    catch {
        Write-DiagLog -ModuleId $Module.Id -Action "Invoke-$Action-Error" -Severity 'Error' -Data @{
            Error = $_.Exception.Message
            Category = $_.CategoryInfo.ToString()
            ScriptStackTrace = $_.ScriptStackTrace
        }
        throw
    }
}

function Get-DiagPaths {
    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        ScriptRoot  = $Script:ScriptRoot
        ModulesPath = $Script:ModulesPath
        LogPath     = $Script:LogPath
        JsonlPath    = $Script:JsonlPath
        StatePath   = $Script:StatePath
        PackagePath = $Script:PackagePath
        RunId       = $Script:RunId
    }
}

Export-ModuleMember -Function Get-RegisteredDiagModules,Invoke-DiagModuleAction,Write-DiagLog,Write-DiagJsonFile,Get-DiagPaths,Get-DiagHostSnapshot,Test-DiagManifest,Test-DiagAdministrator
