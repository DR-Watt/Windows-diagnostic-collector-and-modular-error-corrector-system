# CLEAN Generation Log / Changelog — v1.4.0 P1 Normalizers Pack

## Build metadata

- Timestamp: `2026-06-08T18:49:42.836801+00:00`
- Version: `1.4.0`
- Scope: P1 normalizációs alrendszer

## Módosított / új fájlok

- `modules/P1Normalizers/P1Normalizers.ps1`
- `modules/P1Normalizers/manifest.json`
- `tools/Invoke-P1Normalizers.ps1`
- `validators/Validate-P1NormalizerOutput.ps1`
- `docs/p1_normalizers_schema_v1_4_0.md`
- `docs/p1_normalizers_plan_v1_4_0.md`
- `docs/p1_normalizers_acceptance_tests_v1_4_0.md`
- `config/app.json`
- `README_v1.4.0.md`

## Implementált modulok

1. WERNormalizer
2. SetupAPINormalizer
3. CBSHResultNormalizer
4. DriverPnPProblemNormalizer
5. EventCorrelationNormalizer
6. WindowsUpdateErrorNormalizer

## Validáció

- JSON manifest validálva Python parserrel.
- ZIP integritás ellenőrizve.
- PowerShell runtime teszt nem futott ebben a Linux konténerben.

## diagnostics_starter_pack

A futtatási sorrend továbbra is: `Initialize-DiagEnvironment.ps1` → SystemEvidenceCollector → P1Normalizers → P2/repair döntés.
