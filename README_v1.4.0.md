# DiagFramework v1.4.0 — P1 Normalizers Pack

Ez a patch bevezeti a P1 normalizációs alrendszert.

## Tartalom

- `modules/P1Normalizers/P1Normalizers.ps1`
- `modules/P1Normalizers/manifest.json`
- `tools/Invoke-P1Normalizers.ps1`
- `validators/Validate-P1NormalizerOutput.ps1`
- `docs/p1_normalizers_schema_v1_4_0.md`
- `docs/p1_normalizers_plan_v1_4_0.md`
- `docs/p1_normalizers_acceptance_tests_v1_4_0.md`
- `config/app.json`

## Futtatás

```powershell
.	ools\Invoke-P1Normalizers.ps1
```

A modul a legutóbbi `logs/evidence_packages/<csomag>` mappát dolgozza fel, ha nincs explicit `-PackageRoot` megadva.
