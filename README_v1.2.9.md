# DiagFramework v1.2.9 — UI Scope & System LOG Hotfix

## Változások

- A felső információs szöveg külön, diszkrét színű panelbe került.
- Új checkbox: `Rendszerszintű LOG csomag`.
- Rendszerszintű módban a KB mező és a célzott KB LOG gomb inaktív.
- Célzott KB módban a KB mező és a célzott KB LOG gomb aktív, a rendszer LOG gomb inaktív.
- Az `AI LOG` elnevezés helyett: `Célzott KB LOG csomag`, mert mindkét csomag AI-barát.
- A napok száma mindkét módban módosítható.
- Az ÖSSZEFOGLALÓ és JAVASOLT MŰVELET szövegek több soros, számozott lépéslistákat kaptak.

## Patch alkalmazása

A ZIP tartalmát csomagold ki a repo gyökerébe felülírással.

```powershell
Set-Location C:\git_wdcmac\Windows-diagnostic-collector-and-modular-error-corrector-system
.\diagnostics\Initialize-DiagEnvironment.ps1
.\install_and_run.bat
```
