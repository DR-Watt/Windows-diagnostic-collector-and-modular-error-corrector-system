# CLEAN Generation Log — v1.2.11 native command argument binding

- Timestamp: 2026-06-08
- Type: Hotfix
- Scope: Native command runner

## Problem

The generated `native-command-catalog.json` and `native-command-results.json` showed empty `Args`, empty `ArgumentString`, and executable-only `CommandLine` values. Runtime stdout confirmed that tools were launched without arguments, producing help text instead of diagnostic data.

## Root cause

The command definition helper used a parameter named `Args`. This is unsafe/confusing in PowerShell because `$args` is also an automatic variable. The hotfix replaces it with `CommandArguments` and stores the result as `ArgumentList`.

## Modified files

- `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
- `modules/SystemEvidenceCollector/manifest.json`
- `docs/native_commands_reference.md`
- `README_v1.2.11.md`
- `clean_generation_log.md`

## Validation

- JSON manifest syntax checked.
- ZIP integrity checked.
- Windows runtime test must be done on the client machine.
