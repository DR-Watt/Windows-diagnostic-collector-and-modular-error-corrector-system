# CLEAN Generation Log / Changelog — DiagFramework v1.2.3 Validator Invocation Hotfix

## Build metadata

- Timestamp: `2026-06-08T08:55:37.932242+00:00`
- Project: `DiagFramework Windows Update Repair / System Evidence Collector`
- Version: `1.2.3`
- Build type: `Hotfix`
- Scope: PowerShell syntax validator and environment bootstrap

## Purpose

Javítás az alábbi futási hibára:

```text
Validate-PowerShellSyntax.ps1: ... Initialize-DiagEnvironment.ps1:85
Argument types do not match
```

A hiba oka az volt, hogy a PowerShell parser-validátor `Parser.ParseFile()` hívása nem elég szigorúan tipizált `[ref]` változókkal dolgozott, miközben a bootstrap script a validátor stdout/error streamjeit egy tömbbe keverte. PowerShell 7.x alatt ez félrevezető validátorhibát eredményezhetett.

## Changed files

- `validators/Validate-PowerShellSyntax.ps1`
  - explicit `Token[]` és `ParseError[]` referencia-változók;
  - lapos, AI-barát JSON kimenet;
  - `SchemaVersion` mező;
  - `logs` könyvtár kizárása továbbra is megmaradt.
- `diagnostics/Initialize-DiagEnvironment.ps1`
  - új `Invoke-JsonValidatorScript` helper;
  - validátorok JSON-kimenetének stream-összemosás nélküli feldolgozása;
  - pontosabb hibaüzenetek.
- `README.md`
  - v1.2.3 hotfix leírás és kézi validálási parancsok.
- `clean_generation_log.md`
  - Markdown changelog/build log, timestampelt CLEAN generálási dokumentáció.

## Execution order

1. `diagnostics/Initialize-DiagEnvironment.ps1`
2. `validators/Validate-Manifests.ps1`
3. `validators/Validate-UiResources.ps1`
4. `validators/Validate-PowerShellSyntax.ps1`
5. `Launcher.ps1` vagy célzott CLI tool
6. `tools/Collect-SystemEvidence.ps1`

## Validation performed in generation environment

- ZIP file creation completed.
- ZIP integrity checked with Python `zipfile.testzip()`.
- JSON files parsed with Python `json` module.
- PowerShell runtime parser validation could not be executed in this Linux container because `pwsh` is unavailable here.

## Known limitations

- A tényleges PowerShell parser-validálást Windows 11 + PowerShell 7.x környezetben kell futtatni.
- A `Get-WinEvent`, vendor logok, WER és védett rendszerkönyvtárak olvasása admin jogosultságot igényelhet.

## Developer changelog

- `v1.2.3`: Validator invocation and parser reference typing hotfix.
- `v1.2.2`: SystemEvidenceCollector syntax hotfix.
- `v1.2.1`: SystemEvidence partial-package and AI_README hotfix.
- `v1.2.0`: Structured AI UI, manifest-driven summaries and system evidence collector.

## diagnostics_starter_pack

A csomag tartalmazza a Windows 11 PowerShell környezetellenőrző diagnosztikai sablont:

```text
diagnostics/Initialize-DiagEnvironment.ps1
```

A diagnosztika minden projektindítás előtt ellenőrzi a futtatási környezetet, a manifesteket, az UI resource fájlokat és a PowerShell szintaxist.
