<#
.SYNOPSIS
  WPF GUI indító Windows 11 Update diagnosztikai, javító és AI LOG gyűjtő keretrendszerhez.

.DESCRIPTION
  PowerShell 7.x + WPF/XAML interaktív felület. A script automatikusan
  emelt jogosultságot és STA módot kér, mert a WPF-hez STA szál szükséges.
#>

[CmdletBinding()]
param(
    [switch]$NoElevationCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-IsWindows {
    return $PSVersionTable.Platform -eq 'Win32NT' -or $IsWindows
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Restart-SelfElevatedOrSta {
    param([switch]$NeedAdmin, [switch]$NeedSta)

    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = (Get-Process -Id $PID).Path }

    $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-STA',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-NoElevationCheck'
    )

    $startInfo = @{
        FilePath     = $pwsh
        ArgumentList = $args
        WorkingDirectory = $ScriptRoot
    }
    if ($NeedAdmin) { $startInfo.Verb = 'RunAs' }
    Start-Process @startInfo | Out-Null
    exit
}

if (-not (Test-IsWindows)) {
    throw 'Ez a GUI Windows 11 / Windows környezetre készült.'
}

$needAdmin = -not $NoElevationCheck.IsPresent -and -not (Test-IsAdministrator)
$needSta = [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'
if ($needAdmin -or $needSta) {
    Restart-SelfElevatedOrSta -NeedAdmin:$needAdmin -NeedSta:$needSta
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Import-Module (Join-Path $ScriptRoot 'DiagFramework.psm1') -Force

[xml]$xaml = Get-Content (Join-Path $ScriptRoot 'MainWindow.xaml') -Raw -Encoding UTF8
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$lvResults = $window.FindName('lvResults')
$btnScan = $window.FindName('btnScan')
$btnRun = $window.FindName('btnRunSelected')
$btnRollback = $window.FindName('btnRollbackSelected')
$btnReload = $window.FindName('btnReloadModules')
$btnSearchUpdates = $window.FindName('btnSearchUpdates')
$btnInstallUpdates = $window.FindName('btnInstallUpdates')
$btnAiLogPackage = $window.FindName('btnAiLogPackage')
$btnOpenLogs = $window.FindName('btnOpenLogs')
$txtTargetKB = $window.FindName('txtTargetKB')
$txtDaysBack = $window.FindName('txtDaysBack')
$txtLog = $window.FindName('txtLog')
$txtStatus = $window.FindName('txtStatus')
$chkWhatIf = $window.FindName('chkWhatIf')

$script:CurrentItems = New-Object System.Collections.ArrayList

function Add-UiLog {
    param([Parameter(Mandatory)][string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $txtLog.AppendText("[$stamp] $Message`r`n")
    $txtLog.ScrollToEnd()
}

function Get-TargetKbFromUi {
    $kb = [string]$txtTargetKB.Text
    if ([string]::IsNullOrWhiteSpace($kb)) { $kb = 'KB5089573' }
    $kb = $kb.Trim().ToUpperInvariant()
    if ($kb -notmatch '^KB\d{6,}$') { throw "Érvénytelen KB formátum: $kb. Példa: KB5089573" }
    return $kb
}

function Get-DaysBackFromUi {
    $days = 30
    if (-not [int]::TryParse([string]$txtDaysBack.Text, [ref]$days)) { $days = 30 }
    if ($days -lt 1) { $days = 1 }
    if ($days -gt 180) { $days = 180 }
    return $days
}

function ConvertTo-ResultItem {
    param(
        [Parameter(Mandatory)][pscustomobject]$Module,
        [Parameter(Mandatory)][object]$Result
    )

    $issue = $false
    $fixAvailable = $false
    if ($null -ne $Result.PSObject.Properties['IssueDetected']) { $issue = [bool]$Result.IssueDetected }
    if ($null -ne $Result.PSObject.Properties['FixAvailable']) { $fixAvailable = [bool]$Result.FixAvailable }

    [PSCustomObject]@{
        Selected          = ($issue -and $fixAvailable)
        ModuleId          = $Module.Id
        Name              = $Module.Name
        Severity          = if ($Result.PSObject.Properties['Severity']) { [string]$Result.Severity } else { 'Info' }
        Status            = if ($issue) { 'Javítás / gyűjtés javasolt' } else { 'Rendben / nincs automatikus javítás' }
        Summary           = if ($Result.PSObject.Properties['Summary']) { [string]$Result.Summary } else { '' }
        RecommendedAction = if ($Result.PSObject.Properties['RecommendedAction']) { [string]$Result.RecommendedAction } else { '' }
        FixAvailable      = $fixAvailable
        DetailsJson       = ($Result | ConvertTo-Json -Depth 12)
        RawModule         = $Module
        RawResult         = $Result
    }
}

function Refresh-ModuleList {
    $script:CurrentItems.Clear() | Out-Null
    $modules = Get-RegisteredDiagModules
    foreach ($m in $modules) {
        $item = [PSCustomObject]@{
            Selected          = $false
            ModuleId          = $m.Id
            Name              = $m.Name
            Severity          = $m.Risk
            Status            = 'Nincs még diagnosztizálva'
            Summary           = $m.Description
            RecommendedAction = ''
            FixAvailable      = $false
            DetailsJson       = ''
            RawModule         = $m
            RawResult         = $null
        }
        [void]$script:CurrentItems.Add($item)
    }
    $lvResults.ItemsSource = $null
    $lvResults.ItemsSource = $script:CurrentItems
    $paths = Get-DiagPaths
    $txtStatus.Text = "Betöltött modulok: $($modules.Count) | RunId: $($paths.RunId)"
}

function Run-Diagnostics {
    $btnScan.IsEnabled = $false
    $btnRun.IsEnabled = $false
    try {
        $targetKb = Get-TargetKbFromUi
        $daysBack = Get-DaysBackFromUi
        Add-UiLog "Diagnosztika indítása. TargetKB=$targetKb DaysBack=$daysBack"
        $script:CurrentItems.Clear() | Out-Null
        $modules = Get-RegisteredDiagModules
        foreach ($m in $modules) {
            try {
                Add-UiLog "Modul futtatása: $($m.Id) / Test-Condition"
                $params = @{}
                if ($m.Id -eq 'AILogCollector') { $params = @{ TargetKB = $targetKb; DaysBack = $daysBack } }
                $result = Invoke-DiagModuleAction -Module $m -Action 'Test-Condition' -Parameters $params
                $item = ConvertTo-ResultItem -Module $m -Result $result
                [void]$script:CurrentItems.Add($item)
                Add-UiLog "$($m.Id): $($item.Status) - $($item.Summary)"
            }
            catch {
                $item = [PSCustomObject]@{
                    Selected          = $false
                    ModuleId          = $m.Id
                    Name              = $m.Name
                    Severity          = 'High'
                    Status            = 'Diagnosztikai hiba'
                    Summary           = $_.Exception.Message
                    RecommendedAction = 'Ellenőrizd a modul scriptjét és a jogosultságokat.'
                    FixAvailable      = $false
                    DetailsJson       = ($_ | Out-String)
                    RawModule         = $m
                    RawResult         = $null
                }
                [void]$script:CurrentItems.Add($item)
                Add-UiLog "HIBA $($m.Id): $($_.Exception.Message)"
            }
        }
        $lvResults.ItemsSource = $null
        $lvResults.ItemsSource = $script:CurrentItems
        $txtStatus.Text = "Diagnosztika kész. Talált javasolt elemek: $(($script:CurrentItems | Where-Object { $_.Selected }).Count)"
    }
    finally {
        $btnScan.IsEnabled = $true
        $btnRun.IsEnabled = $true
    }
}

function Run-SelectedFixes {
    $selected = @($lvResults.ItemsSource | Where-Object { $_.Selected -and $_.FixAvailable })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Nincs kiválasztott, automatikusan javítható/gyűjthető elem.', 'DiagFramework', 'OK', 'Information') | Out-Null
        return
    }

    $mode = if ($chkWhatIf.IsChecked) { 'WhatIf / próba' } else { 'ÉLES javítás vagy LOG gyűjtés' }
    $question = "Futtassam a kijelölt műveleteket?`n`nMód: $mode`nElemek: $($selected.Count)"
    $answer = [System.Windows.MessageBox]::Show($question, 'Megerősítés', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    $btnRun.IsEnabled = $false
    try {
        $targetKb = Get-TargetKbFromUi
        $daysBack = Get-DaysBackFromUi
        foreach ($it in $selected) {
            try {
                Add-UiLog "Művelet futtatása: $($it.ModuleId) / Invoke-Fix / WhatIf=$($chkWhatIf.IsChecked)"
                $params = @{}
                if ($it.ModuleId -eq 'AILogCollector') { $params = @{ TargetKB = $targetKb; DaysBack = $daysBack } }
                $res = Invoke-DiagModuleAction -Module $it.RawModule -Action 'Invoke-Fix' -WhatIf:$chkWhatIf.IsChecked -Parameters $params
                Add-UiLog (($res | ConvertTo-Json -Depth 12))
                if ($res.PSObject.Properties['ZipPath']) { Add-UiLog "AI LOG ZIP elkészült: $($res.ZipPath)" }
            }
            catch {
                Add-UiLog "MŰVELETI HIBA $($it.ModuleId): $($_.Exception.Message)"
            }
        }
        $txtStatus.Text = 'Műveleti kör befejezve. Javasolt új diagnosztikát futtatni.'
    }
    finally {
        $btnRun.IsEnabled = $true
    }
}

function Run-SelectedRollback {
    $selected = @($lvResults.ItemsSource | Where-Object { $_.Selected })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Nincs kiválasztott modul rollback művelethez.', 'DiagFramework', 'OK', 'Information') | Out-Null
        return
    }
    $answer = [System.Windows.MessageBox]::Show('Rollback műveletet csak akkor futtass, ha egy javítás után regresszió jelentkezett. Folytatod?', 'Rollback megerősítés', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    foreach ($it in $selected) {
        try {
            Add-UiLog "Rollback futtatása: $($it.ModuleId)"
            $res = Invoke-DiagModuleAction -Module $it.RawModule -Action 'Invoke-Rollback'
            Add-UiLog (($res | ConvertTo-Json -Depth 12))
        }
        catch {
            Add-UiLog "ROLLBACK HIBA $($it.ModuleId): $($_.Exception.Message)"
        }
    }
}

function Search-UpdatesWithPSWindowsUpdate {
    try {
        Add-UiLog 'PSWindowsUpdate modul importálása.'
        Import-Module PSWindowsUpdate -ErrorAction Stop
        Add-UiLog 'Elérhető frissítések keresése. Ez több percig is tarthat.'
        $updates = Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop
        if (-not $updates) {
            Add-UiLog 'Nincs elérhető frissítés, vagy a Windows Update API nem adott vissza telepíthető elemet.'
        }
        else {
            Add-UiLog (($updates | Select-Object KB, Size, Title, MsrcSeverity, IsDownloaded, IsInstalled | Format-Table -AutoSize | Out-String))
        }
    }
    catch {
        Add-UiLog "Frissítéskeresési hiba: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show('A PSWindowsUpdate modul hiányzik vagy a Windows Update API hibát adott. Futtasd a PSWindowsUpdateManager javítást, majd próbáld újra.', 'Frissítéskeresés', 'OK', 'Warning') | Out-Null
    }
}

function Install-UpdatesWithPSWindowsUpdate {
    $answer = [System.Windows.MessageBox]::Show('A művelet elérhető Windows/Microsoft Update frissítéseket telepíthet. A rendszer újraindítást igényelhet. Folytatod?', 'Frissítések telepítése', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    try {
        Import-Module PSWindowsUpdate -ErrorAction Stop
        Add-UiLog 'Frissítések telepítése: Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot'
        $result = Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -ErrorAction Stop
        Add-UiLog (($result | Format-Table -AutoSize | Out-String))
        Add-UiLog 'Telepítési kör befejezve. Ellenőrizd a reboot státuszt.'
        try {
            $reboot = Get-WURebootStatus -Silent -ErrorAction Stop
            Add-UiLog "Reboot szükséges: $reboot"
        } catch {
            Add-UiLog 'A reboot státusz nem volt lekérdezhető.'
        }
    }
    catch {
        Add-UiLog "Frissítéstelepítési hiba: $($_.Exception.Message)"
    }
}

function New-AiLogPackageFromButton {
    $btnAiLogPackage.IsEnabled = $false
    try {
        $targetKb = Get-TargetKbFromUi
        $daysBack = Get-DaysBackFromUi
        $module = Get-RegisteredDiagModules | Where-Object Id -eq 'AILogCollector' | Select-Object -First 1
        if (-not $module) { throw 'Az AILogCollector modul nem található.' }
        Add-UiLog "AI LOG csomag készítése: TargetKB=$targetKb DaysBack=$daysBack"
        $res = Invoke-DiagModuleAction -Module $module -Action 'Invoke-Fix' -Parameters @{ TargetKB = $targetKb; DaysBack = $daysBack }
        Add-UiLog (($res | ConvertTo-Json -Depth 12))
        if ($res.PSObject.Properties['ZipPath']) {
            Add-UiLog "AI LOG ZIP: $($res.ZipPath)"
            $txtStatus.Text = "AI LOG csomag elkészült: $($res.ZipPath)"
            [System.Windows.MessageBox]::Show("AI LOG csomag elkészült:`n$($res.ZipPath)", 'DiagFramework', 'OK', 'Information') | Out-Null
        }
    }
    catch {
        Add-UiLog "AI LOG csomag hiba: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'AI LOG csomag hiba', 'OK', 'Error') | Out-Null
    }
    finally {
        $btnAiLogPackage.IsEnabled = $true
    }
}

function Open-LogsFolder {
    $paths = Get-DiagPaths
    if (-not (Test-Path $paths.LogPath)) { New-Item -Path $paths.LogPath -ItemType Directory -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $paths.LogPath) | Out-Null
}

$btnReload.Add_Click({ Refresh-ModuleList; Add-UiLog 'Modullista újratöltve.' })
$btnScan.Add_Click({ Run-Diagnostics })
$btnRun.Add_Click({ Run-SelectedFixes })
$btnRollback.Add_Click({ Run-SelectedRollback })
$btnSearchUpdates.Add_Click({ Search-UpdatesWithPSWindowsUpdate })
$btnInstallUpdates.Add_Click({ Install-UpdatesWithPSWindowsUpdate })
$btnAiLogPackage.Add_Click({ New-AiLogPackageFromButton })
$btnOpenLogs.Add_Click({ Open-LogsFolder })

Refresh-ModuleList
Add-UiLog 'DiagFramework Windows Update Repair v1.1 AI Log Pack elindult.'
$window.ShowDialog() | Out-Null
