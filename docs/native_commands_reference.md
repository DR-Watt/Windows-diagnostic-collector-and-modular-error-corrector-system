# Native command reference — DiagFramework v1.2.10

A rendszer LOG csomag `commands` mappája nem önmagában javítási lépés, hanem bizonyítékgyűjtés. A korábbi `native-command-results.json` csak fájlútvonalakat és üres Args mezőket mutatott. A v1.2.10 célja, hogy a parancsok célja, várható információértéke és korlátai is a csomagba kerüljenek.

## Alapértelmezett parancsok

1. `reagentc.exe /info` — Windows RE állapot és recovery konfiguráció.
2. `bcdedit.exe /enum all /v` — BCD store olvasási célú, verbose felsorolása.
3. `dism.exe /Online /Get-Packages /Format:Table /English` — gyors csomagállapot áttekintés.
4. `dism.exe /Online /Get-Packages /Format:List /English` — részletesebb csomagállapot.
5. `dism.exe /Online /Cleanup-Image /CheckHealth /English` — komponens-store jelölő állapot gyors ellenőrzése.
6. `sc.exe query wuauserv` — Windows Update szolgáltatás runtime állapot.
7. `sc.exe query BITS` — BITS runtime állapot.
8. `sc.exe query cryptsvc` — Cryptographic Services runtime állapot.
9. `sc.exe query TrustedInstaller` — Windows Modules Installer runtime állapot.

## Kimeneti értelmezés

- `InformationValue = Captured`: stdout tartalmaz adatot.
- `InformationValue = NoOutput`: a parancs lefutott, de nem adott stdoutot. Ez nem automatikusan hiba.
- `InformationValue = StdErrOnly`: stdout üres, stderr tartalmaz üzenetet.
- `InformationValue = ErrorExit`: a parancs nem 0 exit code-dal tért vissza.

## AI elemzési sorrend

1. `COMMANDS_README.md`
2. `native-command-catalog.json`
3. `native-command-results.json`
4. Az adott parancs `.txt` és `.err.txt` kimenete
