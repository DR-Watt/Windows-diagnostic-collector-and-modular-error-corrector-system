# System Evidence Schema v1.3.2

## Scope

v1.3.2 is a stability and UX hotfix for the v1.3.x P0 evidence collector.

## Changes

- `New-SummaryObject` no longer assumes every event summary row has a `Truncated` property.
- Missing optional event-summary properties are read via `Get-ObjectPropertyValueSafe`.
- Application version is externalized to `config/app.json`.
- WPF GUI title is generated from `config/app.json`.
- WPF status bar includes an indeterminate progress indicator for long collector operations.

## New config file

```text
config/app.json
```

Important fields:

```json
{
  "ProductName": "Windows 11 Update Repair",
  "AppName": "DiagFramework",
  "Version": "1.3.2",
  "BuildName": "System Evidence Truncated Fix + Progress UI",
  "WindowTitleFormat": "{ProductName} - {AppName} v{Version} {BuildName}"
}
```

## Acceptance

- GUI title must show `v1.3.2` after applying the patch.
- System LOG package must not fail with `The property 'Truncated' cannot be found on this object`.
- Status bar must show an indeterminate progress bar while a collector button operation is running.
