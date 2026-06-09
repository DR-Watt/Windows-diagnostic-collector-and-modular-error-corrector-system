# Collector acceptance tests v1.3.5

## Kötelező ellenőrzések

1. `SystemEvidenceCollector` verzió `1.3.5`.
2. Disk 153 nélküli gépen a storage ág nem bukhat `TimeCreated` property hibával.
3. `analysis/evidence-gap-summary.json` létrejön.
4. `servicing/servicing-risk-summary.json` létrejön.
5. `windows_update/windowsupdate-signal-summary.json` létrejön.
6. `ai_summary.json` sémája `diagframework.systemevidence.summary.v3.5`.
7. `ai_summary.json` tartalmazza: `EvidenceGapSummary`, `EvidenceGapCount`, `ServicingRiskSummary`, `WindowsUpdateSignalSummary`, `P1NormalizerHandoff`.
8. A P1 normalizálók nem futnak ebben a csomagban; csak a bemenetüket készíti elő a P0 collector.
