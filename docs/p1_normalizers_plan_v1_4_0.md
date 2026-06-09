# P1 normalizers plan v1.4.0

## Implementált normalizálók

1. `WERNormalizer`
   - Input: `wer/wer-reports.json`, `copied_logs/ReportArchive/**/Report.wer`, `copied_logs/ReportQueue/**/Report.wer`.
   - Output: `analysis/normalized-wer.json`.

2. `SetupAPINormalizer`
   - Input: `copied_logs/setupapi.dev.log`, `copied_logs/setupapi.setup.log`.
   - Output: `analysis/normalized-setupapi.json`.

3. `CBSHResultNormalizer`
   - Input: `copied_logs/CBS.log`, `copied_logs/dism.log`, `servicing/*.txt`, `commands/dism-checkhealth.txt`.
   - Output: `analysis/normalized-cbs-hresults.json`.

4. `DriverPnPProblemNormalizer`
   - Input: `storage/pnp-storage-devices.json`, `drivers/pnp-signed-drivers.json`, `events/Microsoft-Windows-Kernel-PnP_Configuration.jsonl`, `events/Microsoft-Windows-DeviceSetupManager_Admin.jsonl`.
   - Output: `analysis/normalized-pnp-problems.json`.

5. `EventCorrelationNormalizer`
   - Input: `storage/disk153-update-setup-correlation.json`.
   - Output: `analysis/normalized-event-correlation.json`.

6. `WindowsUpdateErrorNormalizer`
   - Input: `windows_update/WindowsUpdate.generated.log`, `copied_logs/ReportingEvents.log`, `events/Microsoft-Windows-WindowsUpdateClient_Operational.jsonl`.
   - Output: `analysis/normalized-windowsupdate-errors.json`.

## Következő P2 irány

- WinDbg / dump summary opcionális modul.
- Hyper-V/HNS dedikált normalizáló.
- Network/TCP ephemeral port normalizáló.
- Power/sleep-resume normalizáló.
