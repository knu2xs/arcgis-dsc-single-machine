[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Version = "",

    [Parameter(Mandatory = $false)]
    [string]$BaseDir = "",

    [Parameter(Mandatory = $false)]
    [string]$SoftwareSourceRoot = "",

    [Parameter(Mandatory = $false)]
    [string]$AuthorizationSourceRoot = "",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [hashtable]$InstallerPatterns = @{
        'ArcGIS_Server_Windows.exe' = @('ArcGIS_Server_Windows_*.exe', 'ArcGIS_Server_Windows_*.exe.001')
        'Portal_for_ArcGIS_Windows.exe' = @('Portal_for_ArcGIS_Windows_*.exe', 'Portal_for_ArcGIS_Windows_*.exe.001')
        'Portal_for_ArcGIS_Web_Styles_Windows.exe' = @('Portal_for_ArcGIS_Web_Styles_Windows_*.exe')
        'ArcGIS_DataStore_Windows.exe' = @('ArcGIS_DataStore_Windows_*.exe')
        'ArcGIS_Web_Adaptor_for_Microsoft_IIS.exe' = @('ArcGIS_Web_Adaptor_for_Microsoft_IIS_*.exe')
    }
)

$ErrorActionPreference = 'Stop'

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path $ConfigPath)) {
        return ''
    }

    $pattern = "^\s*" + [regex]::Escape($Key) + "\s*:\s*(.+?)\s*$"
    $line = Get-Content -Path $ConfigPath | Where-Object { $_ -match $pattern } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        return ''
    }

    $value = [regex]::Match($line, $pattern).Groups[1].Value.Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    return $value
}

if ([string]::IsNullOrWhiteSpace($BaseDir)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $BaseDir = Split-Path -Parent $PSScriptRoot
    }
    elseif ($MyInvocation.MyCommand.Path) {
        $BaseDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }
    else {
        $BaseDir = (Get-Location).Path
    }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $configPath = Join-Path $BaseDir 'config\deployment_config.yaml'
    $Version = Get-ConfigValue -ConfigPath $configPath -Key 'ARCGIS_VERSION'
}

$normalizedVersion = $Version.Trim()

if (-not [string]::IsNullOrWhiteSpace($normalizedVersion)) {
    $releaseFolder = ($normalizedVersion -replace '\.', '') + '_Final'

    if ([string]::IsNullOrWhiteSpace($SoftwareSourceRoot)) {
        $SoftwareSourceRoot = "\\esri.com\software\Esri\Released\$releaseFolder"
    }

    if ([string]::IsNullOrWhiteSpace($AuthorizationSourceRoot)) {
        $AuthorizationSourceRoot = "\\esri.com\software\Esri\Released\Authorization_Files\Version$normalizedVersion"
    }
}

if ([string]::IsNullOrWhiteSpace($SoftwareSourceRoot) -or [string]::IsNullOrWhiteSpace($AuthorizationSourceRoot)) {
    throw 'Version was not provided and ARCGIS_VERSION was not found in config/deployment_config.yaml. Provide -Version or set ARCGIS_VERSION.'
}

$installResourcesRoot = Join-Path $BaseDir 'resources'
$softwareDest = Join-Path $installResourcesRoot 'software'
$authorizationDest = Join-Path $installResourcesRoot 'authorization_files'

function Write-Section {
    param([string]$Message)
    Write-Host ''
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Assert-SourceExists {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Source path not found: $Path"
    }
}

function Sync-InstallerFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    Write-Section $Label
    Write-Host "Source: $Source" -ForegroundColor White
    Write-Host "Destination: $Destination" -ForegroundColor White

    if (-not (Test-Path $Source)) {
        Write-Host "Skipped (missing): $Source" -ForegroundColor Yellow
        return
    }

    if ($WhatIf) {
        Write-Host "WhatIf: would copy file to destination." -ForegroundColor Yellow
        return
    }

    $destinationDir = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($destinationDir)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }

    Copy-Item -Path $Source -Destination $Destination -Force
    Write-Host "$Label copied." -ForegroundColor Green
}

function Resolve-InstallerSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string[]]$Patterns,

        [Parameter(Mandatory = $true)]
        [string]$DestinationName
    )

    foreach ($pattern in $Patterns) {
        $matches = Get-ChildItem -Path $Root -File -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime, Name -Descending
        if ($matches.Count -gt 0) {
            return $matches | Select-Object -First 1
        }
    }

    return $null
}

function Resolve-AuthFileSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $matches = Get-ChildItem -Path $Root -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Sort-Object -Property FullName
    if ($matches.Count -gt 0) {
        return $matches | Select-Object -First 1
    }

    return $null
}

Write-Host ''
Write-Host 'ArcGIS Install Resources Sync' -ForegroundColor Cyan
Write-Host '=============================' -ForegroundColor Cyan
Write-Host "Base Directory: $BaseDir"
if (-not [string]::IsNullOrWhiteSpace($normalizedVersion)) {
    Write-Host "ArcGIS Version: $normalizedVersion"
}
Write-Host "Install Resources Root: $installResourcesRoot"
Write-Host ''

Assert-SourceExists -Path $SoftwareSourceRoot
Assert-SourceExists -Path $AuthorizationSourceRoot

New-Item -ItemType Directory -Path $softwareDest -Force | Out-Null
New-Item -ItemType Directory -Path $authorizationDest -Force | Out-Null

foreach ($destinationName in $InstallerPatterns.Keys) {
    $installer = Resolve-InstallerSource -Root $SoftwareSourceRoot -Patterns $InstallerPatterns[$destinationName] -DestinationName $destinationName

    if ($null -eq $installer) {
        Write-Host "Skipped (not found): $destinationName" -ForegroundColor Yellow
        continue
    }

    Sync-InstallerFile -Source $installer.FullName -Destination (Join-Path $softwareDest $destinationName) -Label "Software: $destinationName"
}

foreach ($authFileName in @('Server_Ent_Adv.ecp', 'AllUTs_AllCapabilities.json')) {
    $authFile = Resolve-AuthFileSource -Root $AuthorizationSourceRoot -FileName $authFileName

    if ($null -eq $authFile) {
        Write-Host "Skipped (not found): $authFileName" -ForegroundColor Yellow
        continue
    }

    Sync-InstallerFile -Source $authFile.FullName -Destination (Join-Path $authorizationDest $authFileName) -Label "Authorization Files: $authFileName"
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green