<#
.SYNOPSIS
  Windows 11 rendszerbizonyíték és vendor diagnosztikai LOG gyűjtő modul.
.DESCRIPTION
  v1.2.11: natív parancs argumentumkötési hotfix. A modul nem javít rendszert.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Get-Metadata','Test-Condition','Invoke-Fix','Invoke-Rollback')][string]$Action,
    [switch]$WhatIf,
    [string]$LogRoot = (Join-Path $PSScriptRoot '..\..\logs'),
    [string]$TargetKB = '',
    [int]$DaysBack = 30,
    [int]$MaxEvents = 1200
)
$ErrorActionPreference = 'Stop'
$ModuleId = 'SystemEvidenceCollector'
$ModuleVersion = '1.2.11'
function Get-Metadata { [PSCustomObject]@{ Id=$ModuleId; Name='Rendszer LOG bizonyítékgyűjtő'; Version=$ModuleVersion; Risk='Low'; Summary='Windows boot, setup, update, driver, crash és vendor diagnosztikai LOG gyűjtés.' } }
function New-DirectorySafe { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null } }
function ConvertTo-SafeString { param($Value) if ($null -eq $Value) { return $null }; try { if ($Value -is [array]) { return (@($Value) | ForEach-Object { ConvertTo-SafeString $_ }) -join '; ' }; return [string]$Value } catch { return '<UnserializableValue>' } }
function Write-JsonSafe { param($InputObject,[string]$Path,[int]$Depth=10) $parent=Split-Path -Parent $Path; if ($parent) { New-DirectorySafe $parent }; try { $InputObject | ConvertTo-Json -Depth $Depth -ErrorAction Stop | Out-File -LiteralPath $Path -Encoding UTF8 -Force } catch { [PSCustomObject]@{ SchemaVersion='diagframework.jsonfallback.v1'; TimestampUtc=(Get-Date).ToUniversalTime().ToString('o'); JsonSerializationFailed=$true; Error=$_.Exception.Message; Text=(ConvertTo-SafeString ($InputObject | Out-String)) } | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $Path -Encoding UTF8 -Force } }
function Write-JsonLinesSafe { param($InputObject,[string]$Path) $parent=Split-Path -Parent $Path; if ($parent) { New-DirectorySafe $parent }; if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }; foreach($i in @($InputObject)) { try { $i | ConvertTo-Json -Depth 8 -Compress -ErrorAction Stop | Out-File -LiteralPath $Path -Encoding UTF8 -Append } catch { [PSCustomObject]@{ SchemaVersion='diagframework.jsonl.fallback.v1'; TimestampUtc=(Get-Date).ToUniversalTime().ToString('o'); Error=$_.Exception.Message; Text=(ConvertTo-SafeString ($i | Out-String)) } | ConvertTo-Json -Depth 6 -Compress | Out-File -LiteralPath $Path -Encoding UTF8 -Append } }; if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ItemType File -Force | Out-Null } }
function Add-ProgressEvent { param([string]$PackageRoot,[string]$Step,[string]$Status='OK',[string]$Message='') try { [PSCustomObject]@{ SchemaVersion='diagframework.collector.progress.v1'; TimestampUtc=(Get-Date).ToUniversalTime().ToString('o'); Step=$Step; Status=$Status; Message=$Message } | ConvertTo-Json -Depth 6 -Compress | Out-File -LiteralPath (Join-Path $PackageRoot 'collector-progress.jsonl') -Encoding UTF8 -Append } catch { } }
function Add-CollectorError { param($CurrentErrors=@(),[string]$Step,[string]$Error,[string]$Target='',[string]$Category='',[string]$ScriptStackTrace='') $list=@(); if ($null -ne $CurrentErrors) { $list=@($CurrentErrors) }; return @($list + [PSCustomObject]@{ SchemaVersion='diagframework.collector.error.v1'; TimestampUtc=(Get-Date).ToUniversalTime().ToString('o'); Step=$Step; Target=$Target; Category=$Category; Error=$Error; ScriptStackTrace=$ScriptStackTrace }) }
function Write-CollectorErrorsSafe { param([string]$PackageRoot,$Errors=@()) Write-JsonSafe -InputObject @($Errors) -Path (Join-Path $PackageRoot 'errors/collector-errors.json') -Depth 10 }
function Get-RelativePathSafe { param([string]$BasePath,[string]$FullPath) try { return [System.IO.Path]::GetRelativePath([string]$BasePath,[string]$FullPath) } catch { $base=[string]$BasePath; $full=[string]$FullPath; if ($full.StartsWith($base,[System.StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($base.Length).TrimStart([char[]]@('\','/')) }; return Split-Path -Path $full -Leaf } }
function Write-LogRootReadmes { param([string]$LogRootPath,[string]$TargetKB='') New-DirectorySafe $LogRootPath; $evidenceRoot=Join-Path $LogRootPath 'evidence_packages'; $aiRoot=Join-Path $LogRootPath 'ai_packages'; New-DirectorySafe $evidenceRoot; New-DirectorySafe $aiRoot; $now=(Get-Date).ToString('o'); @" 
# DiagFramework LOG Root — AI elemzési útmutató

Generated/Updated: $now
TargetKB context: $TargetKB

## Könyvtárak
- ai_packages: célzott KB evidence csomagok.
- evidence_packages: rendszerszintű boot / driver / update / WER / CBS / DISM evidence csomagok.

## AI sorrend
1. AI_README.md
2. ai_summary.json
3. collector-progress.jsonl
4. errors/collector-errors.json
"@ | Out-File -LiteralPath (Join-Path $LogRootPath 'AI_README.md') -Encoding UTF8 -Force; @" 
# System Evidence Packages — AI elemzési útmutató

Rendszerszintű evidence csomagok gyökere. Egy csomag részleges állapotban is értékes.
"@ | Out-File -LiteralPath (Join-Path $evidenceRoot 'AI_README.md') -Encoding UTF8 -Force }
function Write-PackageReadme { param([string]$PackageRoot,[string]$TargetKB='',[string]$Status='InProgress') @" 
# System Evidence Package — AI_README

Generated/Updated: $((Get-Date).ToString('o'))
Computer: $env:COMPUTERNAME
Module: $ModuleId $ModuleVersion
Status: $Status
TargetKB context: $TargetKB

## Elemzési sorrend
1. ai_summary.json
2. collector-progress.jsonl
3. errors/collector-errors.json
4. events/event-summary.json
5. registry/reboot-pending.json
6. drivers/pnp-signed-drivers.json
7. copied_logs és vendor_logs
"@ | Out-File -LiteralPath (Join-Path $PackageRoot 'AI_README.md') -Encoding UTF8 -Force }
function Convert-EventRecordFlat { param($Event) $time=$null; $id=$null; $rec=$null; try { if ($Event.TimeCreated) { $time=([datetime]$Event.TimeCreated).ToString('o') } } catch {}; try { $id=[int]$Event.Id } catch {}; try { $rec=[int64]$Event.RecordId } catch {}; [PSCustomObject]@{ TimeCreated=$time; ProviderName=(ConvertTo-SafeString $Event.ProviderName); LogName=(ConvertTo-SafeString $Event.LogName); Id=$id; LevelDisplayName=(ConvertTo-SafeString $Event.LevelDisplayName); MachineName=(ConvertTo-SafeString $Event.MachineName); RecordId=$rec; TaskDisplayName=(ConvertTo-SafeString $Event.TaskDisplayName); OpcodeDisplayName=(ConvertTo-SafeString $Event.OpcodeDisplayName); KeywordsDisplayNames=(ConvertTo-SafeString $Event.KeywordsDisplayNames); Message=(ConvertTo-SafeString $Event.Message) } }
function Get-RegistryValuesFlat { param([string]$Path) $values=@(); try { $props=Get-ItemProperty -Path $Path -ErrorAction Stop; foreach($p in $props.PSObject.Properties) { if ($p.Name -like 'PS*') { continue }; $values += [PSCustomObject]@{ Name=$p.Name; Value=(ConvertTo-SafeString $p.Value) } } } catch { $values += [PSCustomObject]@{ Name='__ERROR__'; Value=$_.Exception.Message } }; return $values }
function Get-RebootPendingSnapshot { $checks=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired','HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'); $result=@(); foreach($path in $checks){ $exists=$false; try { $exists=[bool](Test-Path -LiteralPath $path) } catch {}; $values=@(); if($exists){ $values=@(Get-RegistryValuesFlat $path) }; $result += [PSCustomObject]@{ Path=$path; Exists=$exists; Values=$values } }; return $result }
function Get-SystemSnapshot { $os=$null; $cs=$null; $bios=$null; try { $os=Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch {}; try { $cs=Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch {}; try { $bios=Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop } catch {}; [PSCustomObject]@{ ComputerName=$env:COMPUTERNAME; UserName=[Security.Principal.WindowsIdentity]::GetCurrent().Name; TimestampUtc=(Get-Date).ToUniversalTime().ToString('o'); PowerShell=[PSCustomObject]@{ Version=$PSVersionTable.PSVersion.ToString(); Edition=$PSVersionTable.PSEdition; Platform=$PSVersionTable.Platform }; OS=if($os){[PSCustomObject]@{Caption=$os.Caption;Version=$os.Version;BuildNumber=$os.BuildNumber;Architecture=$os.OSArchitecture;InstallDate=(ConvertTo-SafeString $os.InstallDate);LastBootUpTime=(ConvertTo-SafeString $os.LastBootUpTime)}}else{$null}; ComputerSystem=if($cs){[PSCustomObject]@{Manufacturer=$cs.Manufacturer;Model=$cs.Model;SystemType=$cs.SystemType;TotalPhysicalMemory=$cs.TotalPhysicalMemory}}else{$null}; BIOS=if($bios){[PSCustomObject]@{Manufacturer=$bios.Manufacturer;SMBIOSBIOSVersion=$bios.SMBIOSBIOSVersion;ReleaseDate=(ConvertTo-SafeString $bios.ReleaseDate)}}else{$null} } }
function Get-DriverSnapshot { $items=@(); try { foreach($d in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) { $items += [PSCustomObject]@{ DeviceName=(ConvertTo-SafeString $d.DeviceName); Manufacturer=(ConvertTo-SafeString $d.Manufacturer); DriverProviderName=(ConvertTo-SafeString $d.DriverProviderName); DriverVersion=(ConvertTo-SafeString $d.DriverVersion); DriverDate=(ConvertTo-SafeString $d.DriverDate); InfName=(ConvertTo-SafeString $d.InfName); DeviceClass=(ConvertTo-SafeString $d.DeviceClass); IsSigned=(ConvertTo-SafeString $d.IsSigned); Signer=(ConvertTo-SafeString $d.Signer) } } } catch { $items += [PSCustomObject]@{ Error=$_.Exception.Message } }; return $items }
function Collect-Events { param([string]$PackageRoot,[datetime]$StartTime,$Errors=@(),[int]$MaxEvents=1200) $eventRoot=Join-Path $PackageRoot 'events'; New-DirectorySafe $eventRoot; $logs=@('System','Application','Setup','Microsoft-Windows-WindowsUpdateClient/Operational','Microsoft-Windows-DeviceSetupManager/Admin','Microsoft-Windows-DeviceSetupManager/Operational','Microsoft-Windows-Kernel-Boot/Operational','Microsoft-Windows-Kernel-PnP/Configuration','Microsoft-Windows-DriverFrameworks-UserMode/Operational','Microsoft-Windows-WHEA-Logger/Operational','Microsoft-Windows-WER-SystemErrorReporting/Operational'); $summary=@(); $localErrors=@($Errors); foreach($log in $logs){ $safe=($log -replace '[\\/:*?"<>|]','_'); $outPath=Join-Path $eventRoot ($safe+'.jsonl'); try { $flat=@(); foreach($ev in @(Get-WinEvent -FilterHashtable @{ LogName=$log; StartTime=$StartTime } -MaxEvents $MaxEvents -ErrorAction Stop)) { try { $flat += Convert-EventRecordFlat $ev } catch { $localErrors = Add-CollectorError $localErrors 'EventFlatten' $_.Exception.Message $log 'EventRecord' $_.ScriptStackTrace } }; Write-JsonLinesSafe $flat $outPath; $summary += [PSCustomObject]@{ LogName=$log; Status='OK'; Count=$flat.Count; OutputFile=('events/'+$safe+'.jsonl') } } catch { Write-JsonLinesSafe @() $outPath; $summary += [PSCustomObject]@{ LogName=$log; Status='Error'; Count=0; Error=$_.Exception.Message; OutputFile=('events/'+$safe+'.jsonl') }; $localErrors = Add-CollectorError $localErrors 'EventLog' $_.Exception.Message $log 'Get-WinEvent' $_.ScriptStackTrace } }; Write-JsonSafe $summary (Join-Path $eventRoot 'event-summary.json') 6; [PSCustomObject]@{ Summary=$summary; Errors=$localErrors } }
function Copy-IfExists { param([string]$Source,[string]$DestinationRoot,[int64]$MaxBytes=52428800,[int]$MaxFiles=300) if (-not (Test-Path -LiteralPath $Source)) { return @() }; New-DirectorySafe $DestinationRoot; $item=Get-Item -LiteralPath $Source -ErrorAction Stop; $results=@(); if($item.PSIsContainer){ $target=Join-Path $DestinationRoot $item.Name; New-DirectorySafe $target; $count=0; foreach($child in @(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)){ if($count -ge $MaxFiles){break}; if($child.Length -le $MaxBytes){ $rel=Get-RelativePathSafe $item.FullName $child.FullName; $dest=Join-Path $target $rel; New-DirectorySafe (Split-Path -Parent $dest); Copy-Item -LiteralPath $child.FullName -Destination $dest -Force -ErrorAction SilentlyContinue; $results += [PSCustomObject]@{ Source=$child.FullName; Destination=$dest; Length=$child.Length; LastWriteTime=$child.LastWriteTime.ToString('o')}; $count++ } else { $results += [PSCustomObject]@{ Source=$child.FullName; Skipped=$true; Reason='FileTooLarge'; Length=$child.Length } } }; return $results } else { if($item.Length -gt $MaxBytes){ return @([PSCustomObject]@{ Source=$item.FullName; Skipped=$true; Reason='FileTooLarge'; Length=$item.Length})}; $dest=Join-Path $DestinationRoot $item.Name; Copy-Item -LiteralPath $item.FullName -Destination $dest -Force -ErrorAction SilentlyContinue; return @([PSCustomObject]@{ Source=$item.FullName; Destination=$dest; Length=$item.Length; LastWriteTime=$item.LastWriteTime.ToString('o')}) } }
function Join-CommandArgumentsForDisplay {
    param([AllowNull()][string[]]$ArgumentList = @())
    $parts = @()
    foreach ($arg in @($ArgumentList)) {
        if ($null -eq $arg) { continue }
        $text = [string]$arg
        if ($text -match '\s|"') {
            $parts += ('"' + ($text -replace '"','\"') + '"')
        }
        else { $parts += $text }
    }
    return ($parts -join ' ')
}
function New-NativeCommandDefinition {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$File,
        [AllowEmptyCollection()][string[]]$CommandArguments = @(),
        [string]$Purpose,
        [string]$ExpectedSignal,
        [string]$WhenUseful,
        [string]$Limitations,
        [string]$LearnReference,
        [bool]$EnabledByDefault = $true
    )
    $argList = @()
    foreach ($arg in @($CommandArguments)) {
        if ($null -ne $arg) { $argList += [string]$arg }
    }
    $argumentString = Join-CommandArgumentsForDisplay -ArgumentList $argList
    [PSCustomObject]@{
        Name=$Name
        File=$File
        ArgumentList=@($argList)
        Args=@($argList)
        ArgumentString=$argumentString
        CommandLine=($File + ' ' + $argumentString).Trim()
        Purpose=$Purpose
        ExpectedSignal=$ExpectedSignal
        WhenUseful=$WhenUseful
        Limitations=$Limitations
        LearnReference=$LearnReference
        EnabledByDefault=$EnabledByDefault
        RequiresArguments=($argList.Count -gt 0)
    }
}
function Get-NativeCommandDefinitions { @(
    (New-NativeCommandDefinition -Name 'reagentc-info' -File 'reagentc.exe' -CommandArguments @('/info') -Purpose 'Windows Recovery Environment konfiguráció és állapot lekérdezése.' -ExpectedSignal 'Windows RE status, Windows RE location, Boot Configuration Data identifier, recovery image path/index, reagentc konfiguráció.' -WhenUseful 'Rollback, recovery, sikertelen helyreállítási környezet, WinRE vagy frissítés utáni visszaállítási probléma gyanújánál.' -Limitations 'Ha WinRE nincs engedélyezve, a kimenet rövid lehet, de éppen ez a diagnosztikai jel.' -LearnReference 'REAgentC command-line options / Reagentc /info'),
    (New-NativeCommandDefinition -Name 'bcdedit-enum-all-v' -File 'bcdedit.exe' -CommandArguments @('/enum','all','/v') -Purpose 'Boot Configuration Data store teljesebb, verbose felsorolása.' -ExpectedSignal 'Boot manager, boot loader, recovery, resume és firmware jellegű BCD bejegyzések; GUID-ok teljes formában.' -WhenUseful 'Boot, rollback, recovery, BitLocker/WinRE, több boot entry vagy hibás recoverysequence vizsgálatánál.' -Limitations 'Csak olvasási parancs; a kimenet érzékeny boot azonosítókat tartalmazhat. A /set típusú módosító parancsokat a collector szándékosan nem használja.' -LearnReference 'BCDEdit /enum és bcdedit /v'),
    (New-NativeCommandDefinition -Name 'dism-packages-table' -File 'dism.exe' -CommandArguments @('/Online','/Get-Packages','/Format:Table','/English') -Purpose 'Az online Windows image telepített csomagjainak gyors, táblázatos listája.' -ExpectedSignal 'Package Identity, State, Release Type, Install Time jellegű információk a CBS/DISM csomagállapot értelmezéséhez.' -WhenUseful 'Hiányzó vagy részben telepített csomag, sikertelen kumulatív update, 0x800f081f/0x800f0831 jellegű hiba vizsgálatánál.' -Limitations 'Táblázatos forma gyorsan áttekinthető, de részletezésben szegényebb; ezért list formátumú parancs is készül.' -LearnReference 'DISM package servicing / Get package and feature information'),
    (New-NativeCommandDefinition -Name 'dism-packages-list' -File 'dism.exe' -CommandArguments @('/Online','/Get-Packages','/Format:List','/English') -Purpose 'Az online Windows image csomagjainak részletesebb DISM listája.' -ExpectedSignal 'Csomagazonosító, állapot, release type, install time és részletesebb servicing attribútumok.' -WhenUseful 'Ha a táblázatos dism-packages kimenet nem elég, vagy konkrét KB/csomag állapotát kell pontosítani.' -Limitations 'Nagyobb kimenetet adhat; AI elemzéshez hasznosabb, de embernek kevésbé áttekinthető.' -LearnReference 'DISM inventory / Get Package and Feature Information'),
    (New-NativeCommandDefinition -Name 'dism-checkhealth' -File 'dism.exe' -CommandArguments @('/Online','/Cleanup-Image','/CheckHealth','/English') -Purpose 'Gyors komponens-store korrupciós állapotellenőrzés az online Windows image-en.' -ExpectedSignal 'Megmondja, hogy az image meg van-e jelölve sérültként, illetve javítható-e. Gyors, nem mély scan.' -WhenUseful 'Windows Update korrupció, CBS/DISM servicing hiba, RestoreHealth szükségességének előzetes eldöntése.' -Limitations 'Nem végez javítást és nem teljes mélységű vizsgálat; ha gyanú marad, ScanHealth/RestoreHealth külön javító modulban kezelendő.' -LearnReference 'DISM /Cleanup-Image /CheckHealth, Repair Windows Image'),
    (New-NativeCommandDefinition -Name 'sc-query-wuauserv' -File 'sc.exe' -CommandArguments @('query','wuauserv') -Purpose 'Windows Update szolgáltatás aktuális futási állapotának lekérdezése.' -ExpectedSignal 'SERVICE_NAME, TYPE, STATE, WIN32_EXIT_CODE, SERVICE_EXIT_CODE, CHECKPOINT, WAIT_HINT.' -WhenUseful '0x80070422, leállt vagy letiltott Windows Update szolgáltatás, scan/download indítási probléma esetén.' -Limitations 'Csak runtime állapot; indítási módot külön sc qc vagy Get-Service/CIM mutat.' -LearnReference 'Sc.exe query / wuauserv example'),
    (New-NativeCommandDefinition -Name 'sc-query-bits' -File 'sc.exe' -CommandArguments @('query','BITS') -Purpose 'Background Intelligent Transfer Service aktuális állapotának lekérdezése.' -ExpectedSignal 'BITS STATE és exit code információk, amelyek update letöltési problémáknál fontosak.' -WhenUseful 'Frissítés letöltés elakadása, BITS queue vagy hálózati letöltési probléma gyanújánál.' -Limitations 'Nem listázza a BITS jobokat; ahhoz külön BITSQueueInspector modul javasolt.' -LearnReference 'Sc.exe query'),
    (New-NativeCommandDefinition -Name 'sc-query-cryptsvc' -File 'sc.exe' -CommandArguments @('query','cryptsvc') -Purpose 'Cryptographic Services aktuális állapotának lekérdezése.' -ExpectedSignal 'cryptsvc futási állapot, exit code-ok.' -WhenUseful 'catroot2, aláírási, catalog, hash vagy servicing hitelesítési hiba gyanújánál.' -Limitations 'Csak szolgáltatásállapot; catalog/adatbázis tartalmat nem validál.' -LearnReference 'Sc.exe query'),
    (New-NativeCommandDefinition -Name 'sc-query-trustedinstaller' -File 'sc.exe' -CommandArguments @('query','TrustedInstaller') -Purpose 'Windows Modules Installer szolgáltatás aktuális állapotának lekérdezése.' -ExpectedSignal 'TrustedInstaller futási állapot; servicing műveleteknél kritikus.' -WhenUseful 'CBS/DISM telepítési vagy komponens-store műveletek elakadása esetén.' -Limitations 'A szolgáltatás igény szerint indulhat, ezért STOPPED állapot önmagában nem mindig hiba.' -LearnReference 'Sc.exe query')
) }
function Get-CommandTextPreviewSafe { param([string]$Path,[int]$MaxLines=20) try { if (-not (Test-Path -LiteralPath $Path)) { return @() }; return @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First $MaxLines) } catch { return @("<preview-error: $($_.Exception.Message)>") } }
function Get-FileLengthSafe { param([string]$Path) try { if (Test-Path -LiteralPath $Path) { return ([int64](Get-Item -LiteralPath $Path -ErrorAction Stop).Length) } } catch {}; return 0 }
function Test-NativeCommandHelpOutput {
    param([AllowNull()][string[]]$PreviewLines = @())
    $joined = (@($PreviewLines) -join "`n")
    if ([string]::IsNullOrWhiteSpace($joined)) { return $false }
    return ($joined -match '(^|\n)USAGE:|DISM\.exe \[dism_options\]|REAGENTC\.EXE <command>|The following commands can be specified:')
}
function Get-InformationValue { param([int]$ExitCode,[int64]$StdOutBytes,[int64]$StdErrBytes,[bool]$HelpOutput=$false,[bool]$ArgumentsMissing=$false) if($ArgumentsMissing){ return 'ArgumentsMissing' }; if($HelpOutput){ return 'HelpOutput' }; if ($ExitCode -ne 0) { return 'ErrorExit' }; if ($StdOutBytes -gt 0) { return 'Captured' }; if ($StdErrBytes -gt 0) { return 'StdErrOnly' }; return 'NoOutput' }
function Write-NativeCommandReadme { param([string]$PackageRoot,$Definitions) $cmdRoot=Join-Path $PackageRoot 'commands'; New-DirectorySafe $cmdRoot; $lines=@('# Native command outputs — AI_README','','Ez a mappa olvasási jellegű, natív Windows parancsok kimeneteit tartalmazza. A parancsok nem módosítanak rendszert.','', '## Elemzési sorrend','1. native-command-results.json','2. native-command-catalog.json','3. Az egyes *.txt stdout fájlok','4. Az egyes *.err.txt stderr fájlok','', '## Fontos v1.2.11 megjegyzés','A CommandLine mezőnek minden parancsnál tartalmaznia kell az argumentumokat. Ha az InformationValue `ArgumentsMissing` vagy `HelpOutput`, akkor a kimenet valószínűleg nem diagnosztikai adat, hanem a tool súgója.','', '## Parancsok'); foreach($d in @($Definitions)){ $lines += ''; $lines += ('### ' + $d.Name); $lines += ('- CommandLine: `' + $d.CommandLine + '`'); $lines += ('- ArgumentList: `' + (($d.ArgumentList) -join ' ') + '`'); $lines += ('- Cél: ' + $d.Purpose); $lines += ('- Várt jel: ' + $d.ExpectedSignal); $lines += ('- Mikor hasznos: ' + $d.WhenUseful); $lines += ('- Korlát: ' + $d.Limitations); $lines += ('- Microsoft Learn: ' + $d.LearnReference) }; $lines | Out-File -LiteralPath (Join-Path $cmdRoot 'COMMANDS_README.md') -Encoding UTF8 -Force; Write-JsonSafe @($Definitions) (Join-Path $cmdRoot 'native-command-catalog.json') 10 }
function Invoke-NativeCommandSafe {
    param([string]$PackageRoot,$Definition)
    $name=[string]$Definition.Name
    $file=[string]$Definition.File
    $nativeArgs=@()
    if($Definition.PSObject.Properties['ArgumentList']){ $nativeArgs=@($Definition.ArgumentList | ForEach-Object { [string]$_ }) }
    elseif($Definition.PSObject.Properties['Args']){ $nativeArgs=@($Definition.Args | ForEach-Object { [string]$_ }) }
    $outFile=Join-Path $PackageRoot ('commands/'+$name+'.txt')
    $errFile=Join-Path $PackageRoot ('commands/'+$name+'.err.txt')
    $start=(Get-Date)
    $missingRequiredArgs=([bool]$Definition.RequiresArguments -and $nativeArgs.Count -eq 0)
    try {
        if($missingRequiredArgs){ throw "Native command definition requires arguments but ArgumentList is empty: $name" }
        $processOptions = @{
            FilePath = $file
            Wait = $true
            PassThru = $true
            NoNewWindow = $true
            RedirectStandardOutput = $outFile
            RedirectStandardError = $errFile
            ErrorAction = 'Stop'
        }
        if($nativeArgs.Count -gt 0){ $processOptions.ArgumentList = [string[]]$nativeArgs }
        $p=Start-Process @processOptions
        $exit=[int]$p.ExitCode
        $errorText=$null
    } catch {
        $exit=$null
        $errorText=$_.Exception.Message
        if (-not (Test-Path -LiteralPath $errFile)) { $errorText | Out-File -LiteralPath $errFile -Encoding UTF8 -Force }
    }
    $end=(Get-Date)
    $stdoutBytes=Get-FileLengthSafe $outFile
    $stderrBytes=Get-FileLengthSafe $errFile
    $stdoutPreview=@(Get-CommandTextPreviewSafe $outFile 20)
    $stderrPreview=@(Get-CommandTextPreviewSafe $errFile 20)
    $helpOutput=Test-NativeCommandHelpOutput -PreviewLines $stdoutPreview
    $infoValue=if($missingRequiredArgs){'ArgumentsMissing'}elseif($null -ne $errorText){'LaunchError'}elseif($null -eq $exit){'UnknownExit'}else{Get-InformationValue -ExitCode ([int]$exit) -StdOutBytes $stdoutBytes -StdErrBytes $stderrBytes -HelpOutput:$helpOutput -ArgumentsMissing:$missingRequiredArgs}
    [PSCustomObject]@{
        SchemaVersion='diagframework.nativecommand.result.v3'
        Name=$name
        File=$file
        ArgumentList=@($nativeArgs)
        Args=@($nativeArgs)
        ArgumentString=(Join-CommandArgumentsForDisplay -ArgumentList $nativeArgs)
        CommandLine=($file + ' ' + (Join-CommandArgumentsForDisplay -ArgumentList $nativeArgs)).Trim()
        Purpose=$Definition.Purpose
        ExpectedSignal=$Definition.ExpectedSignal
        WhenUseful=$Definition.WhenUseful
        Limitations=$Definition.Limitations
        LearnReference=$Definition.LearnReference
        ExitCode=$exit
        StartTime=$start.ToString('o')
        EndTime=$end.ToString('o')
        DurationMs=[int](($end-$start).TotalMilliseconds)
        StdOut=$outFile
        StdErr=$errFile
        StdOutBytes=$stdoutBytes
        StdErrBytes=$stderrBytes
        InformationValue=$infoValue
        StdOutPreview=$stdoutPreview
        StdErrPreview=$stderrPreview
        HelpOutputDetected=$helpOutput
        RequiredArgumentsMissing=$missingRequiredArgs
        Error=$errorText
    }
}
function New-PackageManifestSafe { param([string]$PackageRoot) $files=@(); foreach($child in @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -ErrorAction SilentlyContinue)){ try { $files += [PSCustomObject]@{ RelativePath=(Get-RelativePathSafe $PackageRoot $child.FullName); Length=$child.Length; LastWriteTime=$child.LastWriteTime.ToString('o') } } catch {} }; [PSCustomObject]@{ SchemaVersion='diagframework.package.manifest.v1'; PackageType='SystemEvidence'; GeneratedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); ModuleId=$ModuleId; ModuleVersion=$ModuleVersion; ComputerName=$env:COMPUTERNAME; Files=$files } }
function New-SummaryObject { param([string]$Status,[string]$PackageRoot,[string]$ZipPath,[string]$TargetKB,[int]$DaysBack,[int]$MaxEvents,$EventSummary=@(),$Copied=@(),$NativeResults=@(),$Errors=@(),[string]$FatalError='') [PSCustomObject]@{ SchemaVersion='diagframework.systemevidence.summary.v1'; ModuleId=$ModuleId; ModuleVersion=$ModuleVersion; Status=$Status; TimestampUtc=(Get-Date).ToUniversalTime().ToString('o'); ComputerName=$env:COMPUTERNAME; TargetKB=$TargetKB; DaysBack=$DaysBack; MaxEvents=$MaxEvents; PackageRoot=$PackageRoot; ZipPath=$ZipPath; EventLogCount=@($EventSummary).Count; CopiedRecordCount=@($Copied).Count; NativeCommandCount=@($NativeResults).Count; ErrorCount=@($Errors).Count; FatalError=$FatalError; Purpose='AI/szakértő által elemezhető Windows 11 rendszerbizonyíték-csomag.' } }
function Invoke-EvidenceCollection { param([int]$DaysBack=30,[int]$MaxEvents=1200,[switch]$WhatIf,[string]$TargetKB='') Write-LogRootReadmes $LogRoot $TargetKB; $evidenceRoot=Join-Path $LogRoot 'evidence_packages'; New-DirectorySafe $evidenceRoot; $timestamp=Get-Date -Format 'yyyyMMdd-HHmmss'; $suffix=if([string]::IsNullOrWhiteSpace($TargetKB)){'SystemEvidence'}else{'SystemEvidence-'+$TargetKB}; $packageRoot=Join-Path $evidenceRoot ("$timestamp-$env:COMPUTERNAME-$suffix"); $zipPath="$packageRoot.zip"; New-DirectorySafe $packageRoot; foreach($sub in 'meta','events','registry','copied_logs','drivers','commands','errors','vendor_logs'){New-DirectorySafe (Join-Path $packageRoot $sub)}; Write-PackageReadme $packageRoot $TargetKB 'InProgress'; $errors=@(); $eventSummary=@(); $copied=@(); $nativeResults=@(); Add-ProgressEvent $packageRoot 'Start' 'OK' "DaysBack=$DaysBack MaxEvents=$MaxEvents TargetKB=$TargetKB WhatIf=$($WhatIf.IsPresent)"; if($WhatIf){ $summary=[PSCustomObject]@{ SchemaVersion='diagframework.systemevidence.summary.v1'; ModuleId=$ModuleId; ModuleVersion=$ModuleVersion; WhatIf=$true; Status='WhatIf'; PlannedPackageRoot=$packageRoot; PlannedZipPath=$zipPath }; Write-JsonSafe $summary (Join-Path $packageRoot 'ai_summary.json') 8; return $summary }
try { $startTime=(Get-Date).AddDays(-1 * [Math]::Abs($DaysBack)); try { Write-JsonSafe (Get-SystemSnapshot) (Join-Path $packageRoot 'meta/system-info.json') 8; Add-ProgressEvent $packageRoot 'SystemSnapshot' } catch { $errors=Add-CollectorError $errors 'SystemSnapshot' $_.Exception.Message '' $_.CategoryInfo.ToString() $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'SystemSnapshot' 'Error' $_.Exception.Message }
try { Write-JsonSafe @(Get-RebootPendingSnapshot) (Join-Path $packageRoot 'registry/reboot-pending.json') 10; Add-ProgressEvent $packageRoot 'RegistryPendingReboot' } catch { $errors=Add-CollectorError $errors 'RegistryPendingReboot' $_.Exception.Message '' $_.CategoryInfo.ToString() $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'RegistryPendingReboot' 'Error' $_.Exception.Message }
try { Write-JsonSafe @(Get-DriverSnapshot) (Join-Path $packageRoot 'drivers/pnp-signed-drivers.json') 8; Add-ProgressEvent $packageRoot 'DriverSnapshot' } catch { $errors=Add-CollectorError $errors 'DriverSnapshot' $_.Exception.Message '' $_.CategoryInfo.ToString() $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'DriverSnapshot' 'Error' $_.Exception.Message }
try { $eventResult=Collect-Events $packageRoot $startTime $errors $MaxEvents; $eventSummary=@($eventResult.Summary); $errors=@($eventResult.Errors); Add-ProgressEvent $packageRoot 'EventLogs' 'OK' "Logs=$($eventSummary.Count)" } catch { $errors=Add-CollectorError $errors 'EventLogs' $_.Exception.Message '' $_.CategoryInfo.ToString() $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'EventLogs' 'Error' $_.Exception.Message }
$copyTargets=@("$env:SystemRoot\Logs\CBS\CBS.log","$env:SystemRoot\Logs\DISM\dism.log","$env:SystemRoot\WindowsUpdate.log","$env:SystemRoot\SoftwareDistribution\ReportingEvents.log","$env:SystemRoot\Panther","$env:SystemRoot\INF\setupapi.dev.log","$env:SystemRoot\INF\setupapi.setup.log","$env:SystemRoot\Minidump","$env:ProgramData\Microsoft\Windows\WER\ReportArchive","$env:ProgramData\Microsoft\Windows\WER\ReportQueue","$env:ProgramData\Dell","$env:ProgramData\HP","$env:ProgramData\Lenovo","$env:ProgramData\Intel","$env:ProgramData\NVIDIA Corporation","$env:ProgramData\AMD"); foreach($target in $copyTargets){ try { $destRoot=if($target -match 'ProgramData\\(Dell|HP|Lenovo|Intel|NVIDIA Corporation|AMD)'){Join-Path $packageRoot 'vendor_logs'}else{Join-Path $packageRoot 'copied_logs'}; $r=@(Copy-IfExists $target $destRoot); if($r.Count -gt 0){$copied += $r} } catch { $errors=Add-CollectorError $errors 'CopyTarget' $_.Exception.Message $target $_.CategoryInfo.ToString() $_.ScriptStackTrace } }; Write-JsonSafe $copied (Join-Path $packageRoot 'copied_logs/copied-files.json') 8; Add-ProgressEvent $packageRoot 'CopyLogs' 'OK' "CopiedRecords=$($copied.Count)"; $commandDefinitions=@(Get-NativeCommandDefinitions); Write-NativeCommandReadme $packageRoot $commandDefinitions; foreach($cmd in $commandDefinitions){ if(-not [bool]$cmd.EnabledByDefault){ continue }; $nativeResults += Invoke-NativeCommandSafe $packageRoot $cmd }; Write-JsonSafe $nativeResults (Join-Path $packageRoot 'commands/native-command-results.json') 12; Add-ProgressEvent $packageRoot 'NativeCommands' 'OK' "Commands=$($nativeResults.Count)" } catch { $errors=Add-CollectorError $errors 'FatalCollectorBody' $_.Exception.Message '' $_.CategoryInfo.ToString() $_.ScriptStackTrace; Add-ProgressEvent $packageRoot 'FatalCollectorBody' 'Error' $_.Exception.Message }
Write-CollectorErrorsSafe $packageRoot $errors; $status=if(@($errors).Count -gt 0){'Partial'}else{'Complete'}; $summary=New-SummaryObject $status $packageRoot $zipPath $TargetKB $DaysBack $MaxEvents $eventSummary $copied $nativeResults $errors; Write-JsonSafe $summary (Join-Path $packageRoot 'ai_summary.json') 8; Write-PackageReadme $packageRoot $TargetKB $status; try { $manifest=New-PackageManifestSafe $packageRoot; Write-JsonSafe $manifest (Join-Path $packageRoot 'manifest.json') 10; Add-ProgressEvent $packageRoot 'Manifest' 'OK' "Files=$($manifest.Files.Count)" } catch { $errors=Add-CollectorError $errors 'Manifest' $_.Exception.Message '' $_.CategoryInfo.ToString() $_.ScriptStackTrace; Write-CollectorErrorsSafe $packageRoot $errors; Add-ProgressEvent $packageRoot 'Manifest' 'Error' $_.Exception.Message }; try { if(Test-Path -LiteralPath $zipPath){Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue}; Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -Force -ErrorAction Stop; Add-ProgressEvent $packageRoot 'Zip' 'OK' $zipPath } catch { $errors=Add-CollectorError $errors 'Zip' $_.Exception.Message '' $_.CategoryInfo.ToString() $_.ScriptStackTrace; Write-CollectorErrorsSafe $packageRoot $errors; Add-ProgressEvent $packageRoot 'Zip' 'Error' $_.Exception.Message }; return $summary }
switch($Action){ 'Get-Metadata'{Get-Metadata} 'Test-Condition'{[PSCustomObject]@{IssueDetected=$true;FixAvailable=$true;Severity='Info';Summary='Rendszerszintű evidence csomag készíthető boot, setup, driver, Windows Update, WER és vendor diagnosztikai elemzéshez.';RecommendedAction='Javasolt lépések: 1) Rendszerszintű LOG módban állítsd be a napok számát. 2) Indítsd el a rendszer LOG csomagot. 3) A csomagban először AI_README.md, ai_summary.json és collector-progress.jsonl fájlokat nézd. 4) Partial státusz esetén errors/collector-errors.json alapján folytasd.'}} 'Invoke-Fix'{Invoke-EvidenceCollection -DaysBack $DaysBack -MaxEvents $MaxEvents -WhatIf:$WhatIf -TargetKB $TargetKB} 'Invoke-Rollback'{[PSCustomObject]@{RollbackSupported=$false;Summary='A SystemEvidenceCollector nem módosít rendszert, ezért rollback nem szükséges.'}} }
