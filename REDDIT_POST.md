## Snapmaker Orca U1 filament profile importer

I made a small Windows tool for Snapmaker Orca because the U1 profile list only exposes a limited set of filament presets in the UI, even though Snapmaker Orca ships with a larger Orca-style filament library in its profile folders.

The tool imports selected filament profiles as **custom user filaments** for the Snapmaker U1. It does **not** modify Snapmaker Orca's system profiles, which was important because system-profile edits can make Snapmaker Orca act more like vanilla Orca Slicer and break some of the U1-specific workflow.

What it does:

- Lets you choose a profile source: Snapmaker Orca or Orca Slicer, if installed.
- Lets you choose a filament brand and series from a numbered list.
- Imports all available U1 nozzle sizes automatically: 0.2, 0.4, 0.6, and 0.8 mm.
- Creates Snapmaker-compatible custom filament presets.
- Backs up your current custom filament folder before writing anything.
- Runs from a double-click `.cmd` launcher with PowerShell execution-policy bypass.

Why I made it:

I use Snapmaker Orca with a Snapmaker U1, and I have a lot of Bambu Lab and Polymaker filament. The stock UI did not make those profiles available in a useful way, even though the profile data was already present. This importer makes those profiles show up under `Custom Filaments` and keeps the normal Snapmaker U1 workflow intact.

Limitations:

- Windows only.
- Built and tested around Snapmaker Orca and the Snapmaker U1.
- Imported profiles are starting points, not magic calibration. You still need to validate temps, flow, pressure advance, chamber/enclosure behavior, and material safety for your setup.
- If you choose the Snapmaker Orca source, you only get the brands bundled with Snapmaker Orca. If you also have Orca Slicer installed, its source may include more brands.
- Close Snapmaker Orca before importing. The script will stop if it detects Snapmaker/Orca processes while writing.

Basic use:

1. Download and extract the zip/folder.
2. Close Snapmaker Orca.
3. Double-click `Run-SnapmakerOrcaFilamentImporter.cmd`.
4. Pick source, brand, and filament series.
5. Reopen Snapmaker Orca and check `Custom Filaments`.

Repo:

https://github.com/mechprone/snapmaker-tools
