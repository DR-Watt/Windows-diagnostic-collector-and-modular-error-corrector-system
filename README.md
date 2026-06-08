# DiagFramework Windows Update Repair MVP v1.2.5 — Syntax Validator Safe Mode Hotfix

## Cél

Ez a build a v1.2.4 bootstrap szintaxisvalidátor-hibáját javítja.

A hiba:

```text
PowerShell szintaxisvalidátor futási hiba: Argument types do not match
```

A hiba nem a Windows Update javítólogikában, és nem a SystemEvidenceCollector gyűjtési folyamatában keletkezett, hanem a frissen beépített `validators\Validate-PowerShellSyntax.ps1` validátor saját `Parser.ParseFile()` hívásában.

## Javítás

A `Validate-PowerShellSyntax.ps1` v1.2.5-ben nem használja a `Parser.ParseFile()` / `[ref]` out-paraméteres mintát. Helyette:

```powershell
$null = [scriptblock]::Create($content)
```

Ez a forráskódot szintaktikailag parse-olja, de nem hajtja végre.

## Patch alkalmazása

Csomagold ki a patch ZIP-et a repo gyökerébe felülírással:

```text
C:\git_wdcmac\Windows-diagnostic-collector-and-modular-error-corrector-system
```

Majd futtasd:

```powershell
Set-Location C:\git_wdcmac\Windows-diagnostic-collector-and-modular-error-corrector-system
.\diagnostics\Initialize-DiagEnvironment.ps1
```

Ha sikeres:

```powershell
.\install_and_run.bat
```

Rendszer evidence csomag:

```powershell
.\tools\Collect-SystemEvidence.ps1 -DaysBack 30 -MaxEvents 1200 -TargetKB KB5089573
```

## Érintett fájl

```text
validators\Validate-PowerShellSyntax.ps1
```

## LOG gyökér AI dokumentáció

A v1.2.x ágban továbbra is cél, hogy a rendszer LOG gyökerében és az evidence package mappákban AI számára értelmezhető magyarázó fájlok legyenek:

```text
logs\AI_README.md
logs\evidence_packages\AI_README.md
logs\ai_packages\AI_README.md
```
