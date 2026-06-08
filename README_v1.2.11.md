# DiagFramework v1.2.11 — Native command argument binding hotfix

## Cél

A v1.2.10-ben a natív parancsok metaadatai már megjelentek, de az argumentumok futtatáskor és a JSON-katalógusban üresen maradtak. Ennek oka, hogy a helper függvény `Args` nevű paramétert használt, ami PowerShellben ütközhet az automatikus `$args` változóval / félrevezető kötést eredményezhet.

## Javítás

- `New-NativeCommandDefinition` már `CommandArguments` paramétert használ.
- A definíciós objektum `ArgumentList`, `Args`, `ArgumentString`, `CommandLine` mezőket is tartalmaz.
- `Invoke-NativeCommandSafe` először `ArgumentList` mezőből futtat.
- A `Start-Process` splattinggal kapja meg az `ArgumentList` mezőt.
- Ha egy parancs argumentumot igényel, de üres argumentumlistával indulna, `RequiredArgumentsMissing=true` és `InformationValue=ArgumentsMissing` jelzés készül.
- Ha a stdout súgó jellegű kimenetnek tűnik, `HelpOutputDetected=true` és `InformationValue=HelpOutput` jelzés készül.

## Ellenőrzendő eredmény

A következő futás után a `native-command-catalog.json` és `native-command-results.json` fájlokban például ezt kell látni:

```json
{
  "Name": "dism-checkhealth",
  "ArgumentList": ["/Online", "/Cleanup-Image", "/CheckHealth", "/English"],
  "CommandLine": "dism.exe /Online /Cleanup-Image /CheckHealth /English"
}
```

## WhatIf

A rendszerszintű LOG csomag `WhatIf` módban továbbra sem futtat natív parancsokat. Ez szándékos: WhatIf csak terv/előnézet. A natív parancskimenetek ellenőrzéséhez nem WhatIf futás szükséges.
