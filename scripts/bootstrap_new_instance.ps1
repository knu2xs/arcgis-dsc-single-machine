#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Version = '',

    [Parameter(Mandatory = $false)]
    [string]$BaseDir = "",

    [Parameter(Mandatory = $false)]
    [string]$PythonStandaloneRoot = "",

    [Parameter(Mandatory = $false)]
    [string]$PythonStandaloneReleaseTag = "",

    [Parameter(Mandatory = $false)]
    [string]$PythonStandaloneChannelUrl = "https://raw.githubusercontent.com/astral-sh/python-build-standalone/latest-release/latest-release.json",

    [Parameter(Mandatory = $false)]
    [switch]$ForceDownload,

    [Parameter(Mandatory = $false)]
    [switch]$ForceEnvRecreate,

    [Parameter(Mandatory = $false)]
    [switch]$SkipResourceSync,

    [Parameter(Mandatory = $false)]
    [switch]$InstallPrerequisites,

    [Parameter(Mandatory = $false)]
    [switch]$BuildDocs
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

if ([string]::IsNullOrWhiteSpace($PythonStandaloneRoot)) {
    $PythonStandaloneRoot = Join-Path $BaseDir '.python'
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $configPath = Join-Path $BaseDir 'config\deployment_config.yaml'
    $Version = Get-ConfigValue -ConfigPath $configPath -Key 'ARCGIS_VERSION'
}

$installResourcesRoot = Join-Path $BaseDir 'resources'
$softwareDir = Join-Path $installResourcesRoot 'software'
$configDir = Join-Path $BaseDir 'config'
$envPrefix = Join-Path $BaseDir 'env'
$requirementsFile = Join-Path $configDir 'python\requirements.txt'
$standaloneArchiveName = ''
$standaloneArchivePath = ''
$pythonExe = ''
$envPython = Join-Path $envPrefix 'Scripts\python.exe'
$zensicalExe = Join-Path $envPrefix 'Scripts\zensical.exe'
$pipCacheDir = Join-Path $BaseDir '.cache\pip'

function Write-Section {
    param([string]$Message)
    Write-Host ''
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Assert-Path {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) {
        throw "$Label not found: $Path"
    }
}

function Invoke-Script {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Script not found: $ScriptPath"
    }

    & $ScriptPath @Arguments
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        if ($LASTEXITCODE -gt 0) {
            throw "Script failed: $ScriptPath (exit code $LASTEXITCODE)"
        }
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$OutputPath,
        [switch]$Force
    )

    if ((Test-Path $OutputPath) -and -not $Force) {
        Write-Host "Using existing file: $OutputPath" -ForegroundColor Yellow
        return
    }

    Write-Host "Downloading: $Url" -ForegroundColor White
    Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing
    Write-Host "Downloaded: $OutputPath" -ForegroundColor Green
}

function Get-PythonBuildStandaloneMetadata {
    $headers = @{ 'User-Agent' = 'Mozilla/5.0' }
    return Invoke-RestMethod -Uri $PythonStandaloneChannelUrl -Headers $headers -ErrorAction Stop
}

function Get-StandaloneAssetName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReleaseTag
    )

    $releaseApi = "https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/$ReleaseTag"
    $headers = @{ 'User-Agent' = 'Mozilla/5.0' }
    $release = Invoke-RestMethod -Uri $releaseApi -Headers $headers -ErrorAction Stop

    $preferredPatterns = @(
        'x86_64-pc-windows-msvc.*install_only_stripped.*\.tar\.gz$',
        'x86_64-pc-windows-msvc.*install_only.*\.tar\.gz$',
        'x86_64-pc-windows-msvc.*install_only_stripped.*\.tar\.zst$',
        'x86_64-pc-windows-msvc.*install_only.*\.tar\.zst$'
    )

    foreach ($pattern in $preferredPatterns) {
        $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
        if ($null -ne $asset) {
            return $asset.name
        }
    }

    throw "Unable to find a Windows install-only archive in release $ReleaseTag."
}

function Install-PythonStandalone {
    $existingPython = Get-ChildItem -Path $PythonStandaloneRoot -Filter python.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not [string]::IsNullOrWhiteSpace($existingPython) -and (Test-Path $existingPython)) {
        $script:pythonExe = $existingPython
        Write-Host "Python standalone already installed: $script:pythonExe" -ForegroundColor Green
        return
    }

    $releaseInfo = Get-PythonBuildStandaloneMetadata
    $releaseTag = if ([string]::IsNullOrWhiteSpace($PythonStandaloneReleaseTag)) { $releaseInfo.tag } else { $PythonStandaloneReleaseTag }
    $assetName = Get-StandaloneAssetName -ReleaseTag $releaseTag

    New-Item -ItemType Directory -Path $softwareDir -Force | Out-Null
    New-Item -ItemType Directory -Path $PythonStandaloneRoot -Force | Out-Null

    $downloadUrl = "https://github.com/astral-sh/python-build-standalone/releases/download/$releaseTag/$assetName"
    $standaloneArchivePath = Join-Path $softwareDir $assetName
    Download-File -Url $downloadUrl -OutputPath $standaloneArchivePath -Force:$ForceDownload

    Write-Host "Extracting Python standalone to: $PythonStandaloneRoot" -ForegroundColor White
    Get-ChildItem -Path $PythonStandaloneRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $PythonStandaloneRoot -Force | Out-Null
    tar -xf $standaloneArchivePath -C $PythonStandaloneRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract python-build-standalone archive (exit code $LASTEXITCODE)."
    }

    $script:pythonExe = Get-ChildItem -Path $PythonStandaloneRoot -Filter python.exe -Recurse | Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($script:pythonExe) -or -not (Test-Path $script:pythonExe)) {
        throw "Unable to locate python.exe under $PythonStandaloneRoot after extraction."
    }

    Write-Host "Python standalone installed successfully: $script:pythonExe" -ForegroundColor Green
}

function Initialize-VirtualEnvironment {
    Assert-Path -Path $requirementsFile -Label 'config/python/requirements.txt'
    Assert-Path -Path $pythonExe -Label 'python.exe'

    if ($ForceEnvRecreate -and (Test-Path $envPrefix)) {
        Write-Host "Removing existing virtual environment: $envPrefix" -ForegroundColor Yellow
        Remove-Item -Path $envPrefix -Recurse -Force
    }

    if (-not (Test-Path $envPython)) {
        Write-Host "Creating virtual environment: $envPrefix" -ForegroundColor White
        & $pythonExe -m venv $envPrefix
    }
    else {
        Write-Host "Reusing existing virtual environment: $envPrefix" -ForegroundColor White
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Virtual environment creation failed with exit code $LASTEXITCODE."
    }

    Assert-Path -Path $envPython -Label 'env python.exe'

    $env:PIP_CACHE_DIR = $pipCacheDir
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    New-Item -ItemType Directory -Path $pipCacheDir -Force | Out-Null

    & $envPython -m pip install --upgrade pip setuptools wheel
    if ($LASTEXITCODE -ne 0) {
        throw "pip bootstrap failed with exit code $LASTEXITCODE."
    }

    & $envPython -m pip install --upgrade -r $requirementsFile
    if ($LASTEXITCODE -ne 0) {
        throw "Dependency installation failed with exit code $LASTEXITCODE."
    }

    Write-Host "Virtual environment ready: $envPrefix" -ForegroundColor Green
}

function Render-DeploymentConfig {
    $renderScript = Join-Path $BaseDir 'scripts\render_deployment.py'
    & $envPython $renderScript
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment rendering failed with exit code $LASTEXITCODE."
    }
}

function Build-Docs {
    if (-not (Test-Path $zensicalExe)) {
        throw "zensical.exe not found in environment: $zensicalExe"
    }

    & $zensicalExe build --clean -f (Join-Path $BaseDir 'zensical.toml')
    if ($LASTEXITCODE -ne 0) {
        throw "Docs build failed with exit code $LASTEXITCODE."
    }
}

Write-Host ''
Write-Host 'ArcGIS Deployment Bootstrap' -ForegroundColor Cyan
Write-Host '===========================' -ForegroundColor Cyan
Write-Host "Base Directory: $BaseDir"
if (-not [string]::IsNullOrWhiteSpace($Version)) {
    Write-Host "ArcGIS Version: $Version"
}
Write-Host "Python Standalone Root: $PythonStandaloneRoot"
Write-Host "Virtual Environment: $envPrefix"
Write-Host ''

if (-not $SkipResourceSync) {
    Write-Section 'Sync install resources'
    $syncArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $syncArgs += @('-Version', $Version)
    }
    Invoke-Script -ScriptPath (Join-Path $BaseDir 'scripts\sync_install_resources.ps1') -Arguments $syncArgs
}

Write-Section 'Install python-build-standalone'
Install-PythonStandalone

Write-Section 'Create or update virtual environment'
Initialize-VirtualEnvironment

Write-Section 'Render deployment configuration'
Render-DeploymentConfig

if ($BuildDocs) {
    Write-Section 'Build documentation'
    Build-Docs
}

if ($InstallPrerequisites) {
    Write-Section 'Install Web Adaptor prerequisites'
    Invoke-Script -ScriptPath (Join-Path $BaseDir 'scripts\install_webadaptor_prereqs.ps1')
}

Write-Section 'Bootstrap complete'
Write-Host 'Next step: run Invoke-ArcGISConfiguration with BaseDeployment-SingleMachine.json.' -ForegroundColor Green