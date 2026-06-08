# CLEAN Generation Log / Changelog — DiagFramework v1.2.6 Syntax Validator Non-Blocking Hotfix

## Build metadata

- Project: `Windows-diagnostic-collector-and-modular-error-corrector-system`
- Build version: `v1.2.6`
- Build name: `syntax_validator_nonblocking`
- Generated at: `2026-06-08T11:18:00+02:00`
- Target platform: Windows 11, PowerShell 7.x
- Package type: CLEAN hotfix build

## Purpose

A v1.2.5 buildben a PowerShell szintaxisvalidátor már JSON választ adott, de a kliensgépen továbbra is `ValidatorInternalError: Argument types do not match` belső hibát jelzett. Emiatt a bootstrap blokkolta a GUI indítását, noha ez nem bizonyított tényleges forráskód-szintaktikai hiba volt.

A v1.2.6 célja:

1. a `Validate-PowerShellSyntax.ps1` további egyszerűsítése,
2. a validátor belső hibájának elkülönítése a tényleges fájlszintű szintaktikai hibától,
3. a bootstrap folytatása warning mellett, ha csak a validátor saját belső hibája jelentkezik,
4. a részletek AI-barát JSON fájlba mentése.

## Modified files

| File | Change |
|---|---|
| `validators/Validate-PowerShellSyntax.ps1` | v1.2.6 Safe/Non-blocking compatible validator. Nincs `Parser.ParseFile`, nincs generic list, nincs `Set-StrictMode`, egyszerűbb `ScriptBlock.Create` alapú parse. |
| `diagnostics/Initialize-DiagEnvironment.ps1` | A syntax validator `InternalError=true` eredménye warningként kezelődik. Tényleges fájlszintű syntax error továbbra is blokkol. |
| `README.md` | v1.2.6 hotfix leírás hozzáadva. |
| `clean_generation_log.md` | Markdown changelog/build log frissítve. |

## Runtime behaviour

- Ha a syntax validator tényleges `.ps1` / `.psm1` fájlt talál hibásnak: bootstrap stop.
- Ha a syntax validator saját belső hibát jelez (`InternalError=true`): bootstrap warning, majd folytatás.
- A warning részletei ide kerülnek:

```text
logs\syntax-validator-internal-warning-YYYYMMDD-HHMMSS.json
```

## Execution order

1. `install_and_run.bat`
2. `diagnostics/Initialize-DiagEnvironment.ps1`
3. `validators/Validate-Manifests.ps1`
4. `validators/Validate-UiResources.ps1`
5. `validators/Validate-PowerShellSyntax.ps1`
6. `Launcher.ps1`
7. GUI vagy CLI collector modulok

## Validation

- JSON manifest files: syntax checked.
- UI resource JSON: syntax checked.
- ZIP package integrity: checked.
- Patch ZIP integrity: checked.
- Windows runtime test: not executed in generation environment.

## Known limitation

A `ScriptBlock.Create()` környezeti vagy PowerShell-verzióspecifikus belső hibája továbbra is előfordulhat. A v1.2.6 ezt már nem blokkoló hibaként kezeli, hanem elkülönített warningként naplózza.

## SHA256

Generated after packaging; see final assistant response.

## diagnostics_starter_pack

A build tartalmazza a Windows 11 PowerShell környezetellenőrző és önvalidáló sablont:

```text
diagnostics\Initialize-DiagEnvironment.ps1
```

