param(
    [string[]] $Brands = @("Bambu", "Polymaker"),
    [string[]] $FilamentNames = @(),
    [string[]] $CompatiblePrinters = @(
        "Snapmaker U1 (0.2 nozzle)",
        "Snapmaker U1 (0.4 nozzle)",
        "Snapmaker U1 (0.6 nozzle)",
        "Snapmaker U1 (0.8 nozzle)"
    ),
    [string] $PreviewDir,
    [switch] $Interactive,
    [switch] $Apply
)

$ErrorActionPreference = "Stop"

function ConvertTo-Hashtable {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-Hashtable $property.Value
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @()
        foreach ($item in $Value) {
            $items += ConvertTo-Hashtable $item
        }
        return ,$items
    }

    return $Value
}

function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $invalidPattern = "[{0}]" -f ([Regex]::Escape(([IO.Path]::GetInvalidFileNameChars() -join "")))
    $safeName = $Name -replace $invalidPattern, " "
    $safeName = $safeName -replace "\s+", " "
    return $safeName.Trim(" ", ".")
}

function Merge-Profile {
    param(
        $Base,
        $Overlay
    )

    $result = [ordered]@{}
    foreach ($key in $Base.Keys) {
        $result[$key] = $Base[$key]
    }
    foreach ($key in $Overlay.Keys) {
        $result[$key] = $Overlay[$key]
    }
    return $result
}

function Expand-U1ArrayValues {
    param($Profile)

    $metadataKeys = @(
        "compatible_printers",
        "compatible_prints",
        "compatible_printers_condition",
        "compatible_prints_condition",
        "filament_settings_id",
        "from",
        "inherits",
        "instantiation",
        "is_custom_defined",
        "name",
        "setting_id",
        "type",
        "version"
    )

    foreach ($key in @($Profile.Keys)) {
        if ($metadataKeys -contains $key) {
            continue
        }

        $value = $Profile[$key]
        if ($value -is [System.Array]) {
            if ($value.Count -eq 1) {
                $Profile[$key] = @($value[0], $value[0], $value[0], $value[0])
            }
        }
        else {
            $Profile[$key] = @($value, $value, $value, $value)
        }
    }
}

function Copy-ProfileHashtable {
    param($Profile)

    $copy = [ordered]@{}
    foreach ($key in $Profile.Keys) {
        $value = $Profile[$key]
        if ($value -is [System.Array]) {
            $copy[$key] = @($value)
        }
        else {
            $copy[$key] = $value
        }
    }
    return $copy
}

function Get-FirstProfileValue {
    param($Value)

    if ($Value -is [System.Array]) {
        if ($Value.Count -eq 0) {
            return $null
        }
        return $Value[0]
    }

    return $Value
}

function Set-ProfileValueLikeTemplate {
    param(
        $Profile,
        [string] $Key,
        $Value
    )

    if (-not $Profile.Contains($Key)) {
        return
    }

    $current = $Profile[$Key]
    $firstValue = Get-FirstProfileValue $Value
    if ($current -is [System.Array]) {
        if ($current.Count -eq 0) {
            $Profile[$Key] = @()
        }
        elseif ($current.Count -eq 1) {
            $Profile[$Key] = @($firstValue)
        }
        else {
            $expanded = @()
            for ($i = 0; $i -lt $current.Count; $i++) {
                $expanded += $firstValue
            }
            $Profile[$Key] = $expanded
        }
    }
    else {
        $Profile[$Key] = $firstValue
    }
}

function Normalize-SnapmakerCustomProfile {
    param($Profile)

    $singleArrayKeys = @(
        "compatible_printers",
        "filament_settings_id",
        "filament_type",
        "filament_vendor"
    )

    $scalarKeys = @(
        "compatible_printers_condition",
        "compatible_prints_condition",
        "filament_id",
        "from",
        "inherits",
        "is_custom_defined",
        "name",
        "version"
    )

    foreach ($key in @($Profile.Keys)) {
        if ($key -eq "compatible_prints") {
            continue
        }

        $value = $Profile[$key]
        if ($singleArrayKeys -contains $key) {
            $Profile[$key] = @(Get-FirstProfileValue $value)
            continue
        }

        if ($scalarKeys -contains $key) {
            $Profile[$key] = Get-FirstProfileValue $value
            continue
        }

        if ($value -is [System.Array]) {
            if ($value.Count -eq 0) {
                continue
            }
            if ($value.Count -eq 1) {
                $firstValue = $value[0]
                $Profile[$key] = @($firstValue, $firstValue, $firstValue, $firstValue)
            }
            continue
        }

        $Profile[$key] = @($value, $value, $value, $value)
    }
}

function Get-SnapmakerTemplateName {
    param(
        [string] $FilamentType,
        [string] $PrinterName
    )

    $type = ($FilamentType | ForEach-Object { $_.Trim().ToUpperInvariant() })

    $baseName = switch -Regex ($type) {
        "^PLA-CF$" { "Generic PLA-CF"; break }
        "^PLA" { "Generic PLA"; break }
        "^PETG-CF$" { "Generic PETG-CF"; break }
        "^PETG-GF$" { "Generic PETG-GF"; break }
        "^PETG" { "Generic PETG"; break }
        "^ABS" { "Generic ABS"; break }
        "^ASA" { "Generic ASA"; break }
        "^TPU" { "Generic TPU"; break }
        "^PC" { "Generic PC"; break }
        "^PCTG" { "Generic PCTG"; break }
        "^PA-CF$" { "Generic PA-CF"; break }
        "^PA" { "Generic PA"; break }
        default { "Generic PLA"; break }
    }

    if ($PrinterName -match "\(0\.([268]) nozzle\)$") {
        $variant = "$baseName @U1 0.$($Matches[1]) nozzle"
        if ($script:snapEntryByName.ContainsKey($variant)) {
            return $variant
        }
    }

    return $baseName
}

function Get-StableCustomFilamentId {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $hash = $sha1.ComputeHash($bytes)
    $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
    return "P" + $hex.Substring(0, 7)
}

function Get-ProvenCustomTemplatePath {
    param(
        [string] $PrinterName
    )

    if ($PSScriptRoot) {
        if ($PrinterName -match "\((0\.[2468]) nozzle\)$") {
            $bundledPath = Join-Path $PSScriptRoot "templates\custom-template-$($Matches[1]).json"
            if (Test-Path -LiteralPath $bundledPath) {
                return $bundledPath
            }
        }

        $bundledFallback = Join-Path $PSScriptRoot "templates\custom-template-0.4.json"
        if (Test-Path -LiteralPath $bundledFallback) {
            return $bundledFallback
        }
    }

    $targetDir = Join-Path $env:APPDATA "Snapmaker_Orca\user\default\filament\base"
    if ($PrinterName -match "\((0\.[2468]) nozzle\)$") {
        $path = Join-Path $targetDir "Polymaker ABS Basic @Snapmaker U1 ($($Matches[1]) nozzle).json"
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    $fallback = Join-Path $targetDir "Polymaker ABS Basic @Snapmaker U1 (0.4 nozzle).json"
    if (Test-Path -LiteralPath $fallback) {
        return $fallback
    }

    return $null
}

function Read-NumberedChoice {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Prompt,
        [Parameter(Mandatory = $true)]
        [object[]] $Options
    )

    while ($true) {
        Write-Host ""
        Write-Host $Prompt
        for ($i = 0; $i -lt $Options.Count; $i++) {
            Write-Host ("{0}. {1}" -f ($i + 1), $Options[$i])
        }

        $raw = Read-Host "Enter a number"
        $number = 0
        if ([int]::TryParse($raw, [ref] $number) -and $number -ge 1 -and $number -le $Options.Count) {
            return $number - 1
        }

        Write-Host "Invalid selection. Enter a number from 1 to $($Options.Count)."
    }
}

function Get-FilamentLibrarySource {
    $candidates = @(
        [pscustomobject]@{
            AppName = "Snapmaker Orca"
            Location = "AppData"
            Root = Join-Path $env:APPDATA "Snapmaker_Orca\system"
        },
        [pscustomobject]@{
            AppName = "Snapmaker Orca"
            Location = "Program Files"
            Root = Join-Path $env:ProgramFiles "Snapmaker_Orca\resources\profiles"
        },
        [pscustomobject]@{
            AppName = "Orca Slicer"
            Location = "AppData"
            Root = Join-Path $env:APPDATA "OrcaSlicer\system"
        },
        [pscustomobject]@{
            AppName = "Orca Slicer"
            Location = "Program Files"
            Root = Join-Path $env:ProgramFiles "OrcaSlicer\resources\profiles"
        }
    )

    $usableSources = @()
    foreach ($candidate in $candidates) {
        $libraryRoot = Join-Path $candidate.Root "OrcaFilamentLibrary"
        if (Test-Path -LiteralPath $libraryRoot) {
            $jsonCount = (Get-ChildItem -LiteralPath $libraryRoot -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue | Measure-Object).Count
            if ($jsonCount -gt 0) {
                $filamentRoot = Join-Path $libraryRoot "filament"
                $brandCount = 0
                if (Test-Path -LiteralPath $filamentRoot) {
                    $brandCount = (Get-ChildItem -LiteralPath $filamentRoot -Directory -ErrorAction SilentlyContinue | Where-Object Name -ne "base" | Measure-Object).Count
                }

                $usableSources += [pscustomobject]@{
                    Name = $candidate.AppName
                    Location = $candidate.Location
                    SystemRoot = $candidate.Root
                    LibraryRoot = $libraryRoot
                    ManifestPath = Join-Path $candidate.Root "OrcaFilamentLibrary.json"
                    BrandCount = $brandCount
                    JsonCount = $jsonCount
                }
            }
        }
    }

    if ($usableSources.Count -gt 0) {
        $bestByApp = [ordered]@{}
        foreach ($source in $usableSources) {
            if (-not $bestByApp.Contains($source.Name)) {
                $bestByApp[$source.Name] = $source
                continue
            }

            $current = $bestByApp[$source.Name]
            $isBetter = $false
            if ($source.BrandCount -gt $current.BrandCount) {
                $isBetter = $true
            }
            elseif ($source.BrandCount -eq $current.BrandCount -and $source.JsonCount -gt $current.JsonCount) {
                $isBetter = $true
            }
            elseif (
                $source.BrandCount -eq $current.BrandCount -and
                $source.JsonCount -eq $current.JsonCount -and
                $source.Location -eq "AppData" -and
                $current.Location -ne "AppData"
            ) {
                $isBetter = $true
            }

            if ($isBetter) {
                $bestByApp[$source.Name] = $source
            }
        }

        $appSources = @($bestByApp.Values)

        if ($Interactive -and $appSources.Count -gt 1) {
            $labels = @(
                $appSources | ForEach-Object {
                    "{0} ({1} brands, {2} profile files)" -f $_.Name, $_.BrandCount, $_.JsonCount
                }
            )
            $sourceIndex = Read-NumberedChoice -Prompt "Select a filament library source:" -Options $labels
            return $appSources[$sourceIndex]
        }

        return $appSources[0]
    }

    throw "Could not find a usable OrcaFilamentLibrary folder in Snapmaker Orca or Orca Slicer."
}

function Get-FilamentLibraryEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string] $LibraryRoot,
        [string] $ManifestPath
    )

    if (Test-Path -LiteralPath $ManifestPath) {
        $manifestJson = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
        $manifestEntries = @($manifestJson.filament_list)
        if ($manifestEntries.Count -gt 0) {
            return $manifestEntries
        }
    }

    $entries = @()
    $filamentRoot = Join-Path $LibraryRoot "filament"
    if (-not (Test-Path -LiteralPath $filamentRoot)) {
        throw "Could not find filament folder in library: $LibraryRoot"
    }

    Get-ChildItem -LiteralPath $filamentRoot -Recurse -File -Filter "*.json" | ForEach-Object {
        $profile = Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
        if ($profile.name) {
            $relativePath = $_.FullName.Substring($LibraryRoot.Length).TrimStart("\", "/") -replace "\\", "/"
            $entries += [pscustomobject]@{
                name = $profile.name
                sub_path = $relativePath
            }
        }
    }

    return $entries
}

if ($Interactive) {
    Write-Host ""
    Write-Host "Reminder: close Snapmaker Orca before importing profiles."
    Write-Host "The importer will stop before writing files if Snapmaker Orca is still running."
    Write-Host ""
}

$librarySource = Get-FilamentLibrarySource
$libraryManifestPath = $librarySource.ManifestPath
$libraryRoot = $librarySource.LibraryRoot
$manifest = [pscustomobject]@{
    filament_list = @(Get-FilamentLibraryEntries -LibraryRoot $libraryRoot -ManifestPath $libraryManifestPath)
}
$entryByName = @{}
foreach ($entry in $manifest.filament_list) {
    $entryByName[$entry.name] = $entry
}

if ($Interactive) {
    $availableBrands = @(
        $manifest.filament_list |
            Where-Object { $_.name -like "* @System" -and $_.sub_path -match "^filament/([^/]+)/" } |
            ForEach-Object { [regex]::Match($_.sub_path, "^filament/([^/]+)/").Groups[1].Value } |
            Sort-Object -Unique
    )

    if ($availableBrands.Count -eq 0) {
        throw "No importable filament brands were found in $libraryManifestPath."
    }

    Write-Host "Using filament library: $($librarySource.Name)"
    Write-Host "Library path: $libraryRoot"

    $brandIndex = Read-NumberedChoice -Prompt "Select a filament brand to import:" -Options $availableBrands
    $selectedBrand = $availableBrands[$brandIndex]

    $availableFilaments = @(
        $manifest.filament_list |
            Where-Object {
                $_.name -like "* @System" -and
                $_.sub_path -like "filament/$selectedBrand/*"
            } |
            ForEach-Object { $_.name -replace " @System$", "" } |
            Sort-Object -Unique
    )

    if ($availableFilaments.Count -eq 0) {
        throw "No importable filament series were found for brand '$selectedBrand'."
    }

    $allLabel = "All $selectedBrand filament series"
    $filamentOptions = @($availableFilaments + $allLabel)
    $filamentIndex = Read-NumberedChoice -Prompt "Select a filament series to import:" -Options $filamentOptions

    $Brands = @($selectedBrand)
    if ($filamentIndex -eq ($filamentOptions.Count - 1)) {
        $FilamentNames = @()
    }
    else {
        $FilamentNames = @($availableFilaments[$filamentIndex])
    }

    if ($PreviewDir) {
        $Apply = $false
    }
    else {
        $Apply = $true
    }
    Write-Host ""
    Write-Host "Selected brand: $($Brands -join ', ')"
    if ($FilamentNames.Count -eq 0) {
        Write-Host "Selected filament series: All"
    }
    else {
        Write-Host "Selected filament series: $($FilamentNames -join ', ')"
    }
    Write-Host "Nozzle presets: $($CompatiblePrinters -join ', ')"
    Write-Host ""
}

$resolvedByName = @{}

function Resolve-ProfileByName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($resolvedByName.ContainsKey($Name)) {
        return $resolvedByName[$Name]
    }

    if (-not $entryByName.ContainsKey($Name)) {
        throw "Missing inherited Orca filament profile: $Name"
    }

    $entry = $entryByName[$Name]
    $path = Join-Path $libraryRoot $entry.sub_path
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing Orca filament profile file: $path"
    }

    $profile = ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
    $inherits = $profile["inherits"]
    if ($inherits) {
        $baseProfile = Resolve-ProfileByName -Name $inherits
        $profile = Merge-Profile -Base $baseProfile -Overlay $profile
    }

    $resolvedByName[$Name] = $profile
    return $profile
}

$snapmakerManifestPath = Join-Path $env:APPDATA "Snapmaker_Orca\system\Snapmaker.json"
$snapmakerRoot = Join-Path $env:APPDATA "Snapmaker_Orca\system\Snapmaker"
if (-not (Test-Path -LiteralPath $snapmakerManifestPath)) {
    throw "Could not find Snapmaker Orca system profile manifest: $snapmakerManifestPath"
}

$snapmakerManifest = Get-Content -Raw -LiteralPath $snapmakerManifestPath | ConvertFrom-Json
$script:snapEntryByName = @{}
foreach ($entry in $snapmakerManifest.filament_list) {
    $script:snapEntryByName[$entry.name] = $entry
}

$snapResolvedByName = @{}

function Resolve-SnapmakerProfileByName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($snapResolvedByName.ContainsKey($Name)) {
        return $snapResolvedByName[$Name]
    }

    if (-not $script:snapEntryByName.ContainsKey($Name)) {
        throw "Missing Snapmaker filament template profile: $Name"
    }

    $entry = $script:snapEntryByName[$Name]
    $path = Join-Path $snapmakerRoot $entry.sub_path
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing Snapmaker filament template file: $path"
    }

    $profile = ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
    $inherits = $profile["inherits"]
    if ($inherits) {
        $baseProfile = Resolve-SnapmakerProfileByName -Name $inherits
        $profile = Merge-Profile -Base $baseProfile -Overlay $profile
    }

    $snapResolvedByName[$Name] = $profile
    return $profile
}

$selected = @()
foreach ($entry in $manifest.filament_list) {
    $brandMatch = $false
    foreach ($brand in $Brands) {
        if ($entry.sub_path -like "filament/$brand/*") {
            $brandMatch = $true
        }
    }

    $nameMatch = $true
    if ($FilamentNames.Count -gt 0) {
        $nameMatch = $false
        foreach ($filamentName in $FilamentNames) {
            if ($entry.name -eq $filamentName -or $entry.name -eq "$filamentName @System") {
                $nameMatch = $true
            }
        }
    }

    if ($brandMatch -and $nameMatch -and $entry.name -like "* @System") {
        $selected += $entry
    }
}

$targetDir = Join-Path $env:APPDATA "Snapmaker_Orca\user\default\filament\base"
if ($PreviewDir) {
    $targetDir = $PreviewDir
}
$backupRoot = Join-Path $env:APPDATA ("Snapmaker_Orca\custom-filament-import-backups\" + (Get-Date -Format "yyyyMMdd-HHmmss"))

if ($Apply) {
    $running = Get-Process | Where-Object {
        $_.ProcessName -like "*Snapmaker*" -or $_.ProcessName -like "*Orca*"
    }
    if ($running) {
        $running | Select-Object Id, ProcessName, MainWindowTitle | Format-Table -AutoSize
        throw "Close Snapmaker Orca before applying custom filament files."
    }

    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    Copy-Item -LiteralPath $targetDir -Destination (Join-Path $backupRoot "base") -Recurse -Force

    $selectedBaseNames = @{}
    foreach ($entry in $selected) {
        $selectedBaseNames[$entry.name -replace " @System$", ""] = $true
    }

    Get-ChildItem -LiteralPath $targetDir -File | Where-Object {
        $remove = $false
        foreach ($baseName in $selectedBaseNames.Keys) {
            $safeBaseName = ConvertTo-SafeFileName -Name $baseName
            if ($_.BaseName -like "$safeBaseName @Snapmaker U1" -or $_.BaseName -like "$safeBaseName @Snapmaker U1 (* nozzle)") {
                $remove = $true
                break
            }
        }
        $remove
    } | Remove-Item -Force
}
elseif ($PreviewDir) {
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    Get-ChildItem -LiteralPath $targetDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
}

$created = @()
foreach ($entry in $selected) {
    $sourceProfile = Resolve-ProfileByName -Name $entry.name
    $baseName = $entry.name -replace " @System$", ""
    $filamentType = Get-FirstProfileValue $sourceProfile["filament_type"]
    $filamentVendor = Get-FirstProfileValue $sourceProfile["filament_vendor"]
    $filamentId = Get-StableCustomFilamentId -Name $baseName

    foreach ($printerName in $CompatiblePrinters) {
        $templatePath = Get-ProvenCustomTemplatePath -PrinterName $printerName
        if ($templatePath) {
            $templateProfile = ConvertTo-Hashtable (Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json)
        }
        else {
            $templateName = Get-SnapmakerTemplateName -FilamentType $filamentType -PrinterName $printerName
            $templateProfile = Resolve-SnapmakerProfileByName -Name $templateName
        }
        $profile = Copy-ProfileHashtable -Profile $templateProfile
        $customName = "$baseName @$printerName"
        $fileBaseName = ConvertTo-SafeFileName -Name $customName

        foreach ($key in $sourceProfile.Keys) {
            if ($key -in @(
                "compatible_printers",
                "compatible_prints",
                "compatible_printers_condition",
                "compatible_prints_condition",
                "filament_settings_id",
                "from",
                "inherits",
                "instantiation",
                "is_custom_defined",
                "name",
                "setting_id",
                "type",
                "version"
            )) {
                continue
            }

            Set-ProfileValueLikeTemplate -Profile $profile -Key $key -Value $sourceProfile[$key]
        }

        if ($sourceProfile.Contains("chamber_temperatures") -and $profile.Contains("chamber_temperature")) {
            Set-ProfileValueLikeTemplate -Profile $profile -Key "chamber_temperature" -Value $sourceProfile["chamber_temperatures"]
        }

        $profile.Remove("type")
        $profile.Remove("setting_id")
        $profile.Remove("instantiation")
        $profile["name"] = $customName
        $profile["from"] = "User"
        $profile["inherits"] = ""
        $profile["is_custom_defined"] = "0"
        $profile["compatible_printers"] = @($printerName)
        $profile["compatible_printers_condition"] = ""
        $profile["compatible_prints"] = @()
        $profile["compatible_prints_condition"] = ""
        $profile["filament_settings_id"] = @($customName)
        $profile["filament_type"] = @($filamentType)
        $profile["filament_vendor"] = @($filamentVendor)
        if ($filamentId) {
            $profile["filament_id"] = $filamentId
        }
        Normalize-SnapmakerCustomProfile -Profile $profile

        $jsonPath = Join-Path $targetDir "$fileBaseName.json"
        $infoPath = Join-Path $targetDir "$fileBaseName.info"

        if ($Apply -or $PreviewDir) {
            $profile | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
            @(
                "sync_info = "
                "user_id = "
                "setting_id = "
                "base_id = "
                "updated_time = " + [DateTimeOffset]::Now.ToUnixTimeSeconds()
            ) | Set-Content -LiteralPath $infoPath -Encoding UTF8
        }

        $created += [pscustomobject]@{
            Name = $customName
            Json = $jsonPath
        }
    }
}

if ($Apply) {
    Write-Host "Created/updated $($created.Count) Snapmaker Orca custom filament presets."
    Write-Host "Backup written to: $backupRoot"
}
elseif ($PreviewDir) {
    Write-Host "Preview wrote $($created.Count) Snapmaker Orca custom filament presets to: $PreviewDir"
}
else {
    Write-Host "Dry run: would create/update $($created.Count) Snapmaker Orca custom filament presets."
    Write-Host "Run again with -Apply after closing Snapmaker Orca to write files."
}

$created | Select-Object -First 120 Name,Json | Format-Table -AutoSize
