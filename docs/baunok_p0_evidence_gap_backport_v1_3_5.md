# Baunok P0 Evidence Gap Backport v1.3.5

## Cél

A v1.3.5 a NOTI-BAUNOK rendszer evidence futásából és a Baunok hiányosság/pótlás elemzésből visszavezetett P0 gyűjtési hiányokat javítja. A csomag nem P1 normalizáló, hanem P0 evidence-minőségi backport, hogy a v1.4.0 normalizálók stabilabb bemenetet kapjanak.

## Implementált backport pontok

1. **Storage no-event safe mode**  
   Ha nincs Disk Event ID 153, a storage ág nem hibázhat `TimeCreated` hiány miatt. A kimenet `NoSignal` legyen, nem `StorageEvidenceFailed`.

2. **Evidence gap summary**  
   Új fájlok:
   - `analysis/evidence-gap-summary.json`
   - `analysis/baunok-evidence-gap-backport.json`

3. **Servicing risk summary**  
   Új fájl:
   - `servicing/servicing-risk-summary.json`

   A P0 szint csak gyakoriságot és jelzést ad. A részletes osztályozás a P1 `CBSHResultNormalizer` feladata.

4. **Windows Update signal summary**  
   Új fájl:
   - `windows_update/windowsupdate-signal-summary.json`

   A P0 szint csak HRESULT és KB kinyerést végez. A részletes osztályozás a P1 `WindowsUpdateErrorNormalizer` feladata.

5. **P1 handoff readiness**  
   Az `ai_summary.json` tartalmazza, mely normalizálók következnek:
   - WERNormalizer
   - SetupAPINormalizer
   - CBSHResultNormalizer
   - DriverPnPProblemNormalizer
   - EventCorrelationNormalizer
   - WindowsUpdateErrorNormalizer

## Elvárt eredmény Baunok jellegű gépen

- A storage ág ne adjon `StorageEvidenceFailed` figyelmeztetést akkor, ha nincs Disk 153 esemény.
- A servicing jelzések külön összefoglalóba kerüljenek.
- A WER magas volumen ne kézzel legyen észlelve, hanem `HighWERVolume` gapként jelenjen meg.
- A WindowsUpdate log hibakódjai P1 normalizer-ready formában jelenjenek meg.
