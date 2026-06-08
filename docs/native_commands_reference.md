# Native command reference — DiagFramework v1.2.11

## Fontos javítás

A v1.2.11-ben a natív parancsdefiníciók nem `Args` nevű paraméterrel készülnek, hanem `CommandArguments` paraméterrel. A létrejövő objektumban továbbra is van `Args` mező a kompatibilitás miatt, de a futtatás elsődleges forrása az `ArgumentList`.

## Elvárt CommandLine értékek

1. `reagentc.exe /info`
2. `bcdedit.exe /enum all /v`
3. `dism.exe /Online /Get-Packages /Format:Table /English`
4. `dism.exe /Online /Get-Packages /Format:List /English`
5. `dism.exe /Online /Cleanup-Image /CheckHealth /English`
6. `sc.exe query wuauserv`
7. `sc.exe query BITS`
8. `sc.exe query cryptsvc`
9. `sc.exe query TrustedInstaller`

## Értelmezési mezők

- `ArgumentList`: ténylegesen átadott argumentumok tömbje.
- `CommandLine`: emberi ellenőrzésre alkalmas parancssor.
- `RequiredArgumentsMissing`: igaz, ha egy definíció argumentumot igényelne, de üres lett a lista.
- `HelpOutputDetected`: igaz, ha a stdout súgó/usage kimenetnek tűnik.
- `InformationValue`: `Captured`, `NoOutput`, `StdErrOnly`, `ErrorExit`, `HelpOutput`, `ArgumentsMissing`, `LaunchError`, `UnknownExit`.

## WhatIf

WhatIf módban a collector nem futtat natív parancsokat. A commands mappa diagnosztikai validálásához éles, de olvasási jellegű futás szükséges.
