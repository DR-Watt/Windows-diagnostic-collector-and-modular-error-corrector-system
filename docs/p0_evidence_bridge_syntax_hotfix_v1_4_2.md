# v1.4.2 P0 Evidence Bridge Syntax Hotfix

## Cél

A v1.4.1 csomag PowerShell szintaxisvalidációs hibát okozott a bootstrap alatt. A legvalószínűbb ok az volt, hogy több `[PSCustomObject]@{ ... }` hashtable property értékben közvetlen, zárójelezés nélküli PowerShell parancskifejezés szerepelt, például:

```powershell
bugCheckCode=Get-RegexValueSafe -Text $text -Pattern '...'
```

A v1.4.2 ezeket zárójelezett kifejezéssé alakítja:

```powershell
bugCheckCode=(Get-RegexValueSafe -Text $text -Pattern '...')
```

## Érintett területek

- WinDbg/CDB minidump summary property-k
- WER report property-k
- storage topology property-k
- manifest hash property-k
- event truncation summary property-k

## Funkcionális változás

Új evidence funkció nincs. Ez bootstrap/syntax hotfix.

## Verziókapcsolat

- P1 normalizer ág: `1.4.0`
- P0 evidence bridge: `1.4.2`
- Kompatibilitási cél: P1 normalizer v1.4.0 bemenetének előállítása.
