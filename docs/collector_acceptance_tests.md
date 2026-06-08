# Collector acceptance tests v1.3.0

## Kézi teszt Windows 11 / PowerShell 7.x alatt

```powershell
Set-Location C:\git_wdcmac\Windows-diagnostic-collector-and-modular-error-corrector-system
.\diagnostics\Initialize-DiagEnvironment.ps1
.	ools\Collect-SystemEvidence.ps1 -DaysBack 30 -MaxEvents 1200
```

## Elvárt fájlok

```text
AI_README.md
ai_summary.json
collector-progress.jsonl
errors/collector-issues.json
errors/collector-warnings.json
errors/collector-errors.json
events/event-export-metadata.json
events/raw/System.evtx
windows_update/Get-WindowsUpdateLog.result.json
servicing/dism-scanhealth.txt
servicing/sfc-verifyonly.txt
storage/disk-event-map.json
vendor_logs/vendor-log-policy.json
manifest.json
```

## Elfogadási feltételek

1. Nem létező opcionális event log `Warning`, nem `Error`.
2. Ha `System`, `Application` vagy `Setup` Count == MaxEvents, akkor `Truncated=true`.
3. `manifest.json` minden fájlhoz tartalmaz `SHA256` mezőt.
4. Vendor binárisok `.exe`, `.dll`, `.sys`, `.bin` nem kerülnek becsomagolásra, csak skipped rekordként jelennek meg.
5. `Status=OKWithWarnings` elfogadható, ha csak opcionális log / NoMatchingEvents figyelmeztetések vannak.
