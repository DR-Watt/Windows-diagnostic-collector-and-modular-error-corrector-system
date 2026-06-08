<#
.SYNOPSIS
  WPF GUI indító Windows 11 Update diagnosztikai, javító és AI-barát LOG gyűjtő keretrendszerhez.
#>
[CmdletBinding()]
param(
    [switch]$NoElevationCheck,
    [string]$Culture = 'hu-HU'
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-IsWindows { return ($PSVersionTable.Platform -eq 'Win32NT' -or $IsWindows) }
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
function Restart-SelfElevatedOrSta {
    param([switch]$NeedAdmin, [switch]$NeedSta)
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = (Get-Process -Id $PID).Path }
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"{0}"' -f $PSCommandPath),'-NoElevationCheck','-Culture',$Culture)
    $startInfo = @{ FilePath=$pwsh; ArgumentList=$args; WorkingDirectory=$ScriptRoot }
    if ($NeedAdmin) { $startInfo.Verb = 'RunAs' }
    Start-Process @startInfo | Out-Null
    exit
}

if (-not (Test-IsWindows)) { throw 'Ez a GUI Windows 11 / Windows környezetre készült.' }
$needAdmin = -not $NoElevationCheck.IsPresent -and -not (Test-IsAdministrator)
$needSta = [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'
if ($needAdmin -or $needSta) { Restart-SelfElevatedOrSta -NeedAdmin:$needAdmin -NeedSta:$needSta }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Import-Module (Join-Path $ScriptRoot 'DiagFramework.psm1') -Force

function Import-UiResources {
    param([string]$CultureName = 'hu-HU')
    $candidate = Join-Path $ScriptRoot ("config\ui.$CultureName.json")
    if (-not (Test-Path -LiteralPath $candidate)) { $candidate = Join-Path $ScriptRoot 'config\ui.hu-HU.json' }
    if (-not (Test-Path -LiteralPath $candidate)) { return [PSCustomObject]@{ Controls=[PSCustomObject]@{}; Messages=[PSCustomObject]@{}; Window=[PSCustomObject]@{} } }
    Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json
}
$script:Ui = Import-UiResources -CultureName $Culture

function Import-AppConfig {
    $candidate = Join-Path $ScriptRoot 'config\app.json'
    if (-not (Test-Path -LiteralPath $candidate)) {
        return [PSCustomObject]@{
            ProductName='Windows 11 Update Repair'
            AppName='DiagFramework'
            Version='0.0.0'
            BuildName='local'
            WindowTitleFormat='{ProductName} - {AppName} v{Version} {BuildName}'
        }
    }
    try { return (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch {
        return [PSCustomObject]@{
            ProductName='Windows 11 Update Repair'
            AppName='DiagFramework'
            Version='0.0.0'
            BuildName='config-error'
            WindowTitleFormat='{ProductName} - {AppName} v{Version} {BuildName}'
        }
    }
}
$script:AppConfig = Import-AppConfig
function Get-AppConfigValue { param([string]$Name,[string]$Default='')
    try { if ($script:AppConfig -and $script:AppConfig.PSObject.Properties[$Name]) { return [string]$script:AppConfig.$Name } } catch { }
    return $Default
}
function Get-AppTitle {
    $fmt = Get-AppConfigValue -Name 'WindowTitleFormat' -Default '{ProductName} - {AppName} v{Version}'
    $title = $fmt
    foreach ($kv in @{
        ProductName=(Get-AppConfigValue -Name 'ProductName' -Default 'Windows 11 Update Repair')
        AppName=(Get-AppConfigValue -Name 'AppName' -Default 'DiagFramework')
        Version=(Get-AppConfigValue -Name 'Version' -Default '0.0.0')
        BuildName=(Get-AppConfigValue -Name 'BuildName' -Default '')
    }.GetEnumerator()) {
        $title = $title.Replace(('{' + $kv.Key + '}'), [string]$kv.Value)
    }
    return ($title -replace '\s+', ' ').Trim()
}
function Get-UiValue { param([string]$Path,[string]$Default='')
    $node = $script:Ui
    foreach ($part in ($Path -split '\.')) { if ($null -eq $node -or -not $node.PSObject.Properties[$part]) { return $Default }; $node=$node.$part }
    if ($null -eq $node) { return $Default }
    return [string]$node
}
function Format-UiMessage { param([string]$Key,[string]$Default,[object[]]$Args=@())
    $template = Get-UiValue -Path "Messages.$Key" -Default $Default
    if ($Args.Count -gt 0) { return [string]::Format($template, $Args) }
    return $template
}

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
$btnEvidencePackage = $window.FindName('btnEvidencePackage')
$btnOpenLogs = $window.FindName('btnOpenLogs')
$chkSystemLogMode = $window.FindName('chkSystemLogMode')
$txtTargetKB = $window.FindName('txtTargetKB')
$txtDaysBack = $window.FindName('txtDaysBack')
$txtLog = $window.FindName('txtLog')
$txtStatus = $window.FindName('txtStatus')
$txtSelectedSummary = $window.FindName('txtSelectedSummary')
$txtSelectedAction = $window.FindName('txtSelectedAction')
$chkWhatIf = $window.FindName('chkWhatIf')
$prgOperation = $window.FindName('prgOperation')
$txtProgressDetail = $window.FindName('txtProgressDetail')

function Set-ControlTextFromUi { param([string]$Name,$Control)
    $cfg = $script:Ui.Controls.$Name
    if ($null -eq $cfg) { return }
    if ($cfg.PSObject.Properties['Content'] -and $Control.PSObject.Properties['Content']) { $Control.Content = [string]$cfg.Content }
    if ($cfg.PSObject.Properties['Text'] -and $Control.PSObject.Properties['Text']) { $Control.Text = [string]$cfg.Text }
    if ($cfg.PSObject.Properties['Header'] -and $Control.PSObject.Properties['Header']) { $Control.Header = [string]$cfg.Header }
    if ($cfg.PSObject.Properties['ToolTip']) { $Control.ToolTip = [string]$cfg.ToolTip }
}
function Apply-UiResources {
    $title = Get-AppTitle
    if (-not [string]::IsNullOrWhiteSpace($title)) { $window.Title = $title }
    foreach ($name in @('btnReloadModules','btnScan','btnRunSelected','btnRollbackSelected','chkWhatIf','btnSearchUpdates','btnInstallUpdates','chkSystemLogMode','lblTargetKB','txtTargetKB','lblDaysBack','txtDaysBack','btnAiLogPackage','btnEvidencePackage','btnOpenLogs','txtTopHint','grpModules','grpSummary','grpRecommendedAction','grpLog','grpUsageNotes','txtUsageNotes','txtStatus','txtProgressDetail')) {
        $c=$window.FindName($name); if ($c) { Set-ControlTextFromUi -Name $name -Control $c }
    }
}
Apply-UiResources
$script:CurrentItems = New-Object System.Collections.ArrayList

function Add-UiLog { param([string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $txtLog.AppendText("[$stamp] $Message`r`n")
    $txtLog.ScrollToEnd()
}
function Invoke-UiRefresh {
    try { $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null } catch { }
}
function Set-OperationProgress {
    param([bool]$Busy, [string]$Message = '', [string]$Detail = '')
    try {
        if ($Busy) {
            if ($prgOperation) { $prgOperation.Visibility='Visible'; $prgOperation.IsIndeterminate=$true }
            if ($txtProgressDetail) { $txtProgressDetail.Text = $Detail }
            if (-not [string]::IsNullOrWhiteSpace($Message)) { $txtStatus.Text = $Message }
        }
        else {
            if ($prgOperation) { $prgOperation.IsIndeterminate=$false; $prgOperation.Value=0; $prgOperation.Visibility='Collapsed' }
            if ($txtProgressDetail) { $txtProgressDetail.Text = '' }
            if (-not [string]::IsNullOrWhiteSpace($Message)) { $txtStatus.Text = $Message }
        }
        Invoke-UiRefresh
    } catch { }
}
function Get-IsSystemLogMode { return [bool]$chkSystemLogMode.IsChecked }
function Update-LogScopeUi {
    $systemMode = Get-IsSystemLogMode
    $txtTargetKB.IsEnabled = -not $systemMode
    $btnAiLogPackage.IsEnabled = -not $systemMode
    $btnEvidencePackage.IsEnabled = $systemMode
    if ($systemMode) { $txtStatus.Text = 'Rendszerszintű LOG mód: KB mező és célzott KB gomb inaktív; a Napok mező aktív.' }
    else { $txtStatus.Text = 'Célzott KB LOG mód: add meg a KB azonosítót; a Napok mező aktív.' }
}
function Get-TargetKbFromUi {
    $kb = ([string]$txtTargetKB.Text).Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($kb)) { $kb = 'KB5089573' }
    if ($kb -notmatch '^KB\d{6,}$') { throw (Format-UiMessage -Key 'InvalidKB' -Default 'Érvénytelen KB formátum: {0}. Példa: KB5089573' -Args @($kb)) }
    return $kb
}
function Get-DaysBackFromUi {
    $days = 30
    if (-not [int]::TryParse([string]$txtDaysBack.Text, [ref]$days)) { $days = 30 }
    if ($days -lt 1) { $days = 1 }
    if ($days -gt 180) { $days = 180 }
    $txtDaysBack.Text = [string]$days
    return $days
}
function Get-ManifestUiValue { param([object]$Module,[string]$Field,[string]$Fallback='')
    try { if ($Module -and $Module.PSObject.Properties['Ui'] -and $Module.Ui -and $Module.Ui.PSObject.Properties[$Field]) { return [string]$Module.Ui.$Field } } catch { }
    return $Fallback
}
function Format-DetailTextForPane { param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $out = [string]$Text
    $out = [regex]::Replace($out, '(?<!^)(?<!\r)(?<!\n)\s+(\d+\))', ([Environment]::NewLine + [Environment]::NewLine + '$1'))
    $out = [regex]::Replace($out, '(?<!^)(?<!\r)(?<!\n)\s+(- )', ([Environment]::NewLine + '$1'))
    return $out.Trim()
}
function Update-DetailPanes {
    $item = $lvResults.SelectedItem
    if ($null -eq $item) { $txtSelectedSummary.Text=''; $txtSelectedAction.Text=''; return }
    $txtSelectedSummary.Text = Format-DetailTextForPane -Text ([string]$item.Summary)
    $txtSelectedAction.Text = Format-DetailTextForPane -Text ([string]$item.RecommendedAction)
}
function ConvertTo-ResultItem { param([pscustomobject]$Module,[object]$Result)
    $issue = $false; $fixAvailable = $false
    if ($Result.PSObject.Properties['IssueDetected']) { $issue = [bool]$Result.IssueDetected }
    if ($Result.PSObject.Properties['FixAvailable']) { $fixAvailable = [bool]$Result.FixAvailable }
    $summary = if ($Result.PSObject.Properties['Summary']) { [string]$Result.Summary } else { Get-ManifestUiValue -Module $Module -Field 'Summary' -Fallback $Module.Description }
    $recommended = if ($Result.PSObject.Properties['RecommendedAction']) { [string]$Result.RecommendedAction } else { Get-ManifestUiValue -Module $Module -Field 'RecommendedAction' -Fallback '' }
    [PSCustomObject]@{ Selected=($issue -and $fixAvailable); ModuleId=$Module.Id; Name=$Module.Name; Severity=if ($Result.PSObject.Properties['Severity']) { [string]$Result.Severity } else { [string]$Module.Risk }; Status=if ($issue) { 'Javítás / gyűjtés javasolt' } else { 'Rendben / nincs automatikus javítás' }; Summary=$summary; RecommendedAction=$recommended; FixAvailable=$fixAvailable; DetailsJson=($Result | ConvertTo-Json -Depth 12); RawModule=$Module; RawResult=$Result }
}
function Refresh-ModuleList {
    $script:CurrentItems.Clear() | Out-Null
    $modules = Get-RegisteredDiagModules
    foreach ($m in $modules) {
        [void]$script:CurrentItems.Add([PSCustomObject]@{ Selected=$false; ModuleId=$m.Id; Name=$m.Name; Severity=$m.Risk; Status='Nincs még diagnosztizálva'; Summary=(Get-ManifestUiValue -Module $m -Field 'Summary' -Fallback $m.Description); RecommendedAction=(Get-ManifestUiValue -Module $m -Field 'RecommendedAction' -Fallback ''); FixAvailable=$false; DetailsJson=''; RawModule=$m; RawResult=$null })
    }
    $lvResults.ItemsSource=$null; $lvResults.ItemsSource=$script:CurrentItems
    $paths = Get-DiagPaths
    $txtStatus.Text = "Betöltött modulok: $($modules.Count) | RunId: $($paths.RunId)"
    Update-LogScopeUi; Update-DetailPanes
}
function Run-Diagnostics {
    $btnScan.IsEnabled=$false; $btnRun.IsEnabled=$false
    Set-OperationProgress -Busy $true -Message 'Diagnosztika folyamatban...' -Detail 'Modulok ellenőrzése'
    try {
        $systemMode = Get-IsSystemLogMode
        $targetKb = if ($systemMode) { '' } else { Get-TargetKbFromUi }
        $daysBack = Get-DaysBackFromUi
        Add-UiLog (Format-UiMessage -Key 'DiagStart' -Default 'Diagnosztika indítása. TargetKB={0} DaysBack={1} SystemMode={2}' -Args @($targetKb,$daysBack,$systemMode))
        $script:CurrentItems.Clear() | Out-Null
        foreach ($m in (Get-RegisteredDiagModules)) {
            try {
                $params=@{}
                if ($m.Id -eq 'AILogCollector') { if ($systemMode) { continue } else { $params=@{ TargetKB=$targetKb; DaysBack=$daysBack } } }
                elseif ($m.Id -eq 'SystemEvidenceCollector') { $params=@{ DaysBack=$daysBack; TargetKB=$targetKb } }
                $result = Invoke-DiagModuleAction -Module $m -Action 'Test-Condition' -Parameters $params
                [void]$script:CurrentItems.Add((ConvertTo-ResultItem -Module $m -Result $result))
            } catch {
                [void]$script:CurrentItems.Add([PSCustomObject]@{ Selected=$false; ModuleId=$m.Id; Name=$m.Name; Severity='High'; Status='Diagnosztikai hiba'; Summary=$_.Exception.Message; RecommendedAction='Ellenőrizd a modul scriptjét, manifestjét és a jogosultságokat.'; FixAvailable=$false; DetailsJson=($_ | Out-String); RawModule=$m; RawResult=$null })
                Add-UiLog "HIBA $($m.Id): $($_.Exception.Message)"
            }
        }
        $lvResults.ItemsSource=$null; $lvResults.ItemsSource=$script:CurrentItems
        $count = @($script:CurrentItems | Where-Object { $_.Selected }).Count
        $txtStatus.Text = Format-UiMessage -Key 'DiagComplete' -Default 'Diagnosztika kész. Talált javasolt elemek: {0}' -Args @($count)
    } finally { Set-OperationProgress -Busy $false -Message 'Diagnosztika befejezve.'; $btnScan.IsEnabled=$true; $btnRun.IsEnabled=$true; Update-LogScopeUi; Update-DetailPanes }
}
function Run-SelectedFixes {
    $selected = @($lvResults.ItemsSource | Where-Object { $_.Selected -and $_.FixAvailable })
    if ($selected.Count -eq 0) { [System.Windows.MessageBox]::Show((Format-UiMessage -Key 'NoSelectedFix' -Default 'Nincs kiválasztott, automatikusan javítható/gyűjthető elem.'),'DiagFramework','OK','Information') | Out-Null; return }
    $mode = if ($chkWhatIf.IsChecked) { 'WhatIf / próba' } else { 'ÉLES javítás vagy LOG gyűjtés' }
    $answer = [System.Windows.MessageBox]::Show((Format-UiMessage -Key 'ConfirmRunBody' -Default "Futtassam a kijelölt műveleteket?`n`nMód: {0}`nElemek: {1}" -Args @($mode,$selected.Count)),(Format-UiMessage -Key 'ConfirmRunTitle' -Default 'Megerősítés'),'YesNo','Warning')
    if ($answer -ne 'Yes') { return }
    $btnRun.IsEnabled=$false
    Set-OperationProgress -Busy $true -Message 'Kijelölt műveletek futnak...' -Detail 'Javítás / gyűjtés folyamatban'
    try {
        $systemMode = Get-IsSystemLogMode; $daysBack = Get-DaysBackFromUi; $targetKb = if ($systemMode) { '' } else { Get-TargetKbFromUi }
        foreach ($it in $selected) {
            try {
                $params=@{}
                if ($it.ModuleId -eq 'AILogCollector') { if ($systemMode) { continue } else { $params=@{ TargetKB=$targetKb; DaysBack=$daysBack } } }
                elseif ($it.ModuleId -eq 'SystemEvidenceCollector') { $params=@{ DaysBack=$daysBack; TargetKB=$targetKb } }
                $res = Invoke-DiagModuleAction -Module $it.RawModule -Action 'Invoke-Fix' -WhatIf:$chkWhatIf.IsChecked -Parameters $params
                Add-UiLog (($res | ConvertTo-Json -Depth 12))
                if ($res.PSObject.Properties['ZipPath']) { Add-UiLog "ZIP elkészült: $($res.ZipPath)" }
            } catch { Add-UiLog "MŰVELETI HIBA $($it.ModuleId): $($_.Exception.Message)" }
        }
        $txtStatus.Text='Műveleti kör befejezve. Javasolt új diagnosztikát futtatni.'
    } finally { Set-OperationProgress -Busy $false -Message 'Műveleti kör befejezve.'; $btnRun.IsEnabled=$true; Update-LogScopeUi }
}
function Run-SelectedRollback {
    $selected = @($lvResults.ItemsSource | Where-Object { $_.Selected })
    if ($selected.Count -eq 0) { [System.Windows.MessageBox]::Show((Format-UiMessage -Key 'NoSelectedRollback' -Default 'Nincs kiválasztott modul rollback művelethez.'),'DiagFramework','OK','Information') | Out-Null; return }
    $answer = [System.Windows.MessageBox]::Show((Format-UiMessage -Key 'ConfirmRollbackBody' -Default 'Rollback műveletet csak akkor futtass, ha egy javítás után regresszió jelentkezett. Folytatod?'),'Rollback megerősítés','YesNo','Warning')
    if ($answer -ne 'Yes') { return }
    foreach ($it in $selected) { try { $res=Invoke-DiagModuleAction -Module $it.RawModule -Action 'Invoke-Rollback'; Add-UiLog (($res | ConvertTo-Json -Depth 12)) } catch { Add-UiLog "ROLLBACK HIBA $($it.ModuleId): $($_.Exception.Message)" } }
}
function Search-UpdatesWithPSWindowsUpdate { try { Import-Module PSWindowsUpdate -ErrorAction Stop; $updates=Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop; if (-not $updates) { Add-UiLog 'Nincs elérhető frissítés.' } else { Add-UiLog (($updates | Select-Object KB, Size, Title, MsrcSeverity, IsDownloaded, IsInstalled | Format-Table -AutoSize | Out-String)) } } catch { Add-UiLog "Frissítéskeresési hiba: $($_.Exception.Message)" } }
function Install-UpdatesWithPSWindowsUpdate { $answer=[System.Windows.MessageBox]::Show('A művelet frissítéseket telepíthet és újraindítást igényelhet. Folytatod?','Frissítések telepítése','YesNo','Warning'); if ($answer -ne 'Yes') { return }; try { Import-Module PSWindowsUpdate -ErrorAction Stop; $result=Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -ErrorAction Stop; Add-UiLog (($result | Format-Table -AutoSize | Out-String)) } catch { Add-UiLog "Frissítéstelepítési hiba: $($_.Exception.Message)" } }
function Invoke-CollectorModuleFromButton { param([string]$ModuleId,[string]$DoneMessageKey,[string]$DefaultDoneMessage,$Button)
    $Button.IsEnabled=$false
    try {
        $progressLabel = if ($ModuleId -eq 'SystemEvidenceCollector') { 'Rendszer LOG: EVTX, WindowsUpdate, DISM/SFC, storage, WER, ZIP' } else { 'Célzott KB LOG: Windows Update, CBS/DISM, eseménynaplók, ZIP' }
        Set-OperationProgress -Busy $true -Message ($ModuleId + ' csomag készítése folyamatban...') -Detail $progressLabel
        $systemMode=Get-IsSystemLogMode; $daysBack=Get-DaysBackFromUi; $targetKb=if ($systemMode) { '' } else { Get-TargetKbFromUi }
        $module = Get-RegisteredDiagModules | Where-Object Id -eq $ModuleId | Select-Object -First 1
        if (-not $module) { throw "A $ModuleId modul nem található." }
        $params=@{ DaysBack=$daysBack }
        if ($ModuleId -eq 'AILogCollector') { $params.TargetKB=$targetKb }
        elseif ($ModuleId -eq 'SystemEvidenceCollector') { $params.TargetKB=$targetKb }
        Add-UiLog "$ModuleId csomag készítése: TargetKB=$targetKb DaysBack=$daysBack SystemMode=$systemMode"
        $res = Invoke-DiagModuleAction -Module $module -Action 'Invoke-Fix' -Parameters $params
        Add-UiLog (($res | ConvertTo-Json -Depth 12))
        if ($res.PSObject.Properties['ZipPath']) { [System.Windows.MessageBox]::Show((Format-UiMessage -Key $DoneMessageKey -Default $DefaultDoneMessage -Args @($res.ZipPath)),'DiagFramework','OK','Information') | Out-Null }
    } catch { Add-UiLog "$ModuleId csomag hiba: $($_.Exception.Message)"; [System.Windows.MessageBox]::Show($_.Exception.Message,"$ModuleId csomag hiba",'OK','Error') | Out-Null }
    finally { Set-OperationProgress -Busy $false -Message 'LOG csomag művelet befejezve.'; Update-LogScopeUi }
}
function Open-LogsFolder { $paths=Get-DiagPaths; if (-not (Test-Path $paths.LogPath)) { New-Item -Path $paths.LogPath -ItemType Directory -Force | Out-Null; Add-UiLog (Format-UiMessage -Key 'OpenLogsMissingCreated' -Default 'A logs mappa nem létezett, ezért létrehoztam.') }; Start-Process explorer.exe -ArgumentList ('"{0}"' -f $paths.LogPath) | Out-Null }

$btnReload.Add_Click({ Refresh-ModuleList; Add-UiLog 'Modullista újratöltve.' })
$btnScan.Add_Click({ Run-Diagnostics })
$btnRun.Add_Click({ Run-SelectedFixes })
$btnRollback.Add_Click({ Run-SelectedRollback })
$btnSearchUpdates.Add_Click({ Search-UpdatesWithPSWindowsUpdate })
$btnInstallUpdates.Add_Click({ Install-UpdatesWithPSWindowsUpdate })
$btnAiLogPackage.Add_Click({ Invoke-CollectorModuleFromButton -ModuleId 'AILogCollector' -DoneMessageKey 'KbLogDone' -DefaultDoneMessage "Célzott KB LOG csomag elkészült:`n{0}" -Button $btnAiLogPackage })
$btnEvidencePackage.Add_Click({ Invoke-CollectorModuleFromButton -ModuleId 'SystemEvidenceCollector' -DoneMessageKey 'EvidenceLogDone' -DefaultDoneMessage "Rendszer LOG csomag elkészült:`n{0}" -Button $btnEvidencePackage })
$btnOpenLogs.Add_Click({ Open-LogsFolder })
$lvResults.Add_SelectionChanged({ Update-DetailPanes })
$chkSystemLogMode.Add_Checked({ Update-LogScopeUi })
$chkSystemLogMode.Add_Unchecked({ Update-LogScopeUi })

Refresh-ModuleList
Update-LogScopeUi
Add-UiLog ((Get-AppTitle) + ' elindult.')
$window.ShowDialog() | Out-Null
