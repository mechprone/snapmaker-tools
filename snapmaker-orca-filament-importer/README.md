# Snapmaker Orca Filament Importer

Windows helper for importing bundled Orca-style filament profiles into Snapmaker Orca as user custom filament presets for the Snapmaker U1.

## What It Does

- Reads filament profiles from Snapmaker Orca's local profile library.
- Can also read from Orca Slicer if it is installed.
- Creates user custom filament presets for all U1 nozzle sizes: 0.2, 0.4, 0.6, and 0.8 mm.
- Does not modify Snapmaker Orca system profiles.
- Creates a backup before writing files.

## How To Use

1. Extract this folder anywhere writable, such as Desktop, Downloads, or `C:\Tools`.
2. Close Snapmaker Orca.
3. Double-click `Run-SnapmakerOrcaFilamentImporter.cmd`.
4. Choose a source app, brand, and filament series.
5. Reopen Snapmaker Orca and select the imported custom filaments.

## Notes

- The Snapmaker Orca source is the most portable choice because it does not require Orca Slicer to be installed.
- The Orca Slicer source may show more brands if Orca Slicer is installed.
- Backups are written to:

```text
%APPDATA%\Snapmaker_Orca\custom-filament-import-backups
```

## Files

- `Run-SnapmakerOrcaFilamentImporter.cmd`: double-click launcher with PowerShell execution-policy bypass.
- `Import-SnapmakerOrcaFilaments.ps1`: interactive launcher.
- `New-SnapmakerOrcaCustomFilamentsFromOrca.ps1`: importer logic.
- `templates\`: bundled Snapmaker-compatible custom preset templates.
