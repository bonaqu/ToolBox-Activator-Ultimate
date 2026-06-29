#Requires -Version 5.1
<#
.SYNOPSIS
    Safely detects locally installed JetBrains IDEs on Windows.

.DESCRIPTION
    This script only inventories JetBrains installation/config/cache paths.
    It does not modify files, environment variables, VM options, licenses, or network settings.

.PARAMETER Json
    Output results as JSON instead of a table.

.EXAMPLE
    .\tools\Find-JetBrainsInstallations.ps1
    .\tools\Find-JetBrainsInstallations.ps1 -Json
#>

[CmdletBinding()]
param(
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$KnownProducts = @{
    'idea'       = 'IntelliJ IDEA'
    'idea64'     = 'IntelliJ IDEA'
    'pycharm'    = 'PyCharm'
    'pycharm64'  = 'PyCharm'
    'webstorm'   = 'WebStorm'
    'webstorm64' = 'WebStorm'
    'rider'      = 'Rider'
    'rider64'    = 'Rider'
    'datagrip'   = 'DataGrip'
    'datagrip64' = 'DataGrip'
    'clion'      = 'CLion'
    'clion64'    = 'CLion'
    'goland'     = 'GoLand'
    'goland64'   = 'GoLand'
    'phpstorm'   = 'PhpStorm'
    'phpstorm64' = 'PhpStorm'
    'rubymine'   = 'RubyMine'
    'rubymine64' = 'RubyMine'
    'dataspell'  = 'DataSpell'
    'dataspell64'= 'DataSpell'
    'rustrover'  = 'RustRover'
    'rustrover64'= 'RustRover'
    'appcode'    = 'AppCode'
}

function Add-ExistingPath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    try {
        $resolved = [System.IO.Path]::GetFullPath($Path.Trim().Trim('"'))
        if ((Test-Path -LiteralPath $resolved) -and (-not $List.Contains($resolved))) {
            [void]$List.Add($resolved)
        }
    } catch {
        # Ignore malformed paths from registry/uninstall metadata.
    }
}

function Get-RegistryInstallRoots {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    $uninstallKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($key in $uninstallKeys) {
        Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.DisplayName -match 'JetBrains|IntelliJ|PyCharm|WebStorm|Rider|CLion|GoLand|DataGrip|PhpStorm|RubyMine|DataSpell|RustRover|AppCode') -or
                ($_.Publisher -match 'JetBrains')
            } |
            ForEach-Object {
                Add-ExistingPath -List $roots -Path $_.InstallLocation

                if ($_.DisplayIcon) {
                    $iconPath = ($_.DisplayIcon -split ',')[0]
                    if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
                        $installRoot = Split-Path -Parent (Split-Path -Parent $iconPath)
                        Add-ExistingPath -List $roots -Path $installRoot
                    }
                }
            }
    }

    return $roots
}

function Get-CandidateRoots {
    $roots = New-Object 'System.Collections.Generic.List[string]'

    $wellKnown = @(
        (Join-Path $env:LOCALAPPDATA 'JetBrains\Toolbox\apps'),
        (Join-Path $env:LOCALAPPDATA 'Programs\JetBrains'),
        (Join-Path $env:APPDATA 'JetBrains'),
        (Join-Path $env:USERPROFILE 'JetBrains'),
        (Join-Path $env:ProgramFiles 'JetBrains'),
        ${env:ProgramFiles(x86)} | ForEach-Object { if ($_){ Join-Path $_ 'JetBrains' } },
        'C:\JetBrains',
        'D:\JetBrains'
    )

    foreach ($path in $wellKnown) {
        Add-ExistingPath -List $roots -Path $path
    }

    foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        Add-ExistingPath -List $roots -Path (Join-Path $drive.Root 'JetBrains')
    }

    foreach ($path in (Get-RegistryInstallRoots)) {
        Add-ExistingPath -List $roots -Path $path
    }

    return $roots
}

function Read-IdeaProperty {
    param(
        [string]$InstallPath,
        [string]$Key
    )

    $propertiesPath = Join-Path $InstallPath 'bin\idea.properties'
    if (-not (Test-Path -LiteralPath $propertiesPath -PathType Leaf)) { return $null }

    $line = Get-Content -LiteralPath $propertiesPath -Encoding UTF8 -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "^\s*$([regex]::Escape($Key))\s*=" } |
        Select-Object -First 1

    if (-not $line) { return $null }

    $value = ($line -split '=', 2)[1].Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }

    $value = $value.Replace('${user.home}', $env:USERPROFILE).Replace('/', '\')
    try { return [System.IO.Path]::GetFullPath($value) } catch { return $value }
}

function Get-JetBrainsInstallations {
    $results = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $exeNames = $KnownProducts.Keys | ForEach-Object { "$_.exe" }

    foreach ($root in Get-CandidateRoots) {
        foreach ($exeName in $exeNames) {
            Get-ChildItem -LiteralPath $root -Recurse -Filter $exeName -File -ErrorAction SilentlyContinue |
                Where-Object { $_.DirectoryName -match '[\\/]bin$' } |
                ForEach-Object {
                    $binPath = $_.DirectoryName
                    $installPath = Split-Path -Parent $binPath
                    $dedupeKey = "$installPath|$($_.Name)".ToLowerInvariant()

                    if ($seen.Add($dedupeKey)) {
                        $productKey = [System.IO.Path]::GetFileNameWithoutExtension($_.Name).ToLowerInvariant()
                        $productName = $KnownProducts[$productKey]
                        $customConfigPath = Read-IdeaProperty -InstallPath $installPath -Key 'idea.config.path'

                        [void]$results.Add([pscustomobject]@{
                            Product          = $productName
                            Executable       = $_.Name
                            InstallPath      = $installPath
                            BinPath          = $binPath
                            SourceRoot       = $root
                            CustomConfigPath = $customConfigPath
                        })
                    }
                }
        }
    }

    return $results | Sort-Object Product, InstallPath
}

$installations = @(Get-JetBrainsInstallations)

if ($Json) {
    $installations | ConvertTo-Json -Depth 4
    exit 0
}

if ($installations.Count -eq 0) {
    Write-Warning 'No JetBrains IDE installations were found in common locations, registry uninstall entries, Toolbox folders, or drive-level JetBrains folders.'
    Write-Host 'Tip: pass -Json for machine-readable output, or add your custom root to this script if your layout is unusual.'
    exit 2
}

$installations | Format-Table -AutoSize Product, Executable, InstallPath, CustomConfigPath
