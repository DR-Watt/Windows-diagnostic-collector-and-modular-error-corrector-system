# P1 Normalizers acceptance tests v1.4.0

## Futtatás

```powershell
Set-Location C:\git_wdcmac\Windows-diagnostic-collector-and-modular-error-corrector-system
.\diagnostics\Initialize-DiagEnvironment.ps1
.	ools\Invoke-P1Normalizers.ps1
```

Célzott csomaggal:

```powershell
.	ools\Invoke-P1Normalizers.ps1 -PackageRoot "C:\git_wdcmac\Windows-diagnostic-collector-and-modular-error-corrector-system\logs\evidence_packages\<csomag>"
```

## Elvárt output

```text
analysis
ormalized-wer.json
analysis
ormalized-setupapi.json
analysis
ormalized-cbs-hresults.json
analysis
ormalized-pnp-problems.json
analysis
ormalized-event-correlation.json
analysis
ormalized-windowsupdate-errors.json
analysis\p1-findings.json
analysis\p1-normalization-summary.json
analysisi_summary.before-p1-normalizers.json
```

## Elfogadási feltételek

1. A modul nem módosít Windows állapotot.
2. Nem dob hibát, ha egy input fájl hiányzik; részleges outputot készít.
3. `p1-normalization-summary.json` tartalmazza a hat normalizáló darabszámait.
4. `ai_summary.json` kap `P1Normalization` blokkot.
5. `analysis/p1-normalizer-progress.jsonl` append-only progress nyomot tartalmaz.
