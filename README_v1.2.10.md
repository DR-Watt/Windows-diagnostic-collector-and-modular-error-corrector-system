# DiagFramework v1.2.10 — Native command metadata hotfix

## Cél

A rendszer LOG csomag `commands` mappájának pontosítása. A korábbi `native-command-results.json` csak fájlútvonalakat tartalmazott, az `Args` mező üres volt, és nem derült ki, melyik parancs miért futott, mit kellene szolgáltatnia, illetve adott-e tényleges információt.

## Javítás

- `Args` és `CommandLine` helyesen kerül mentésre.
- Minden parancs kap `Purpose`, `ExpectedSignal`, `WhenUseful`, `Limitations`, `LearnReference` mezőt.
- A stdout/stderr fájlméret és preview bekerül a JSON-ba.
- A `commands` mappa kap `COMMANDS_README.md` és `native-command-catalog.json` fájlt.
- Új gyors szolgáltatásállapot parancsok: `sc.exe query wuauserv`, `BITS`, `cryptsvc`, `TrustedInstaller`.

## Érintett fájlok

- `modules/SystemEvidenceCollector/SystemEvidenceCollector.ps1`
- `modules/SystemEvidenceCollector/manifest.json`
- `docs/native_commands_reference.md`
- `README_v1.2.10.md`
- `clean_generation_log.md`
