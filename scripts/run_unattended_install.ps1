#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$BaseDir = '',

    [Parameter(Mandatory = $false)]
    [string]$Version = '',

    [Parameter(Mandatory = $false)]
    [string]$DscZipUrl = '',

    [Parameter(Mandatory = $false)]
    [switch]$ForceDscDownload,

    [Parameter(Mandatory = $false)]
    [switch]$SkipResourceSync,

    [Parameter(Mandatory = $false)]
    [switch]$SkipBootstrap,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPrerequisites,

    [Parameter(Mandatory = $false)]
    [switch]$SkipIisSslConfiguration,

    [Parameter(Mandatory = $false)]
    [switch]$ForceCertificateReinstall,

    [Parameter(Mandatory = $false)]
    [string]$ConfigurationParametersFile = ''
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

if ([string]::IsNullOrWhiteSpace($ConfigurationParametersFile)) {
    $ConfigurationParametersFile = Join-Path $BaseDir 'BaseDeployment-SingleMachine.json'
}

$configPath = Join-Path $BaseDir 'config\deployment_config.yaml'

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-ConfigValue -ConfigPath $configPath -Key 'ARCGIS_VERSION'
}

if ([string]::IsNullOrWhiteSpace($DscZipUrl)) {
    $DscZipUrl = Get-ConfigValue -ConfigPath $configPath -Key 'ARCGIS_DSC_ZIP_URL'
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    throw 'ArcGIS version not specified. Provide -Version or set ARCGIS_VERSION in config/deployment_config.yaml.'
}

if ([string]::IsNullOrWhiteSpace($DscZipUrl)) {
    throw 'DSC zip URL not specified. Provide -DscZipUrl or set ARCGIS_DSC_ZIP_URL in config/deployment_config.yaml.'
}

$scriptsDir = Join-Path $BaseDir 'scripts'
$installResourcesRoot = Join-Path $BaseDir 'resources'
$softwareDir = Join-Path $installResourcesRoot 'software'
$dscZipPath = Join-Path $softwareDir 'arcgis-powershell-dsc.zip'
$dscExtractRoot = Join-Path $installResourcesRoot 'dsc_module'
$protectSecretsScript = Join-Path $scriptsDir 'protect_secrets.ps1'
$syncScript = Join-Path $scriptsDir 'sync_install_resources.ps1'
$bootstrapScript = Join-Path $scriptsDir 'bootstrap_new_instance.ps1'
$prereqScript = Join-Path $scriptsDir 'install_webadaptor_prereqs.ps1'
$configureSslScript = Join-Path $scriptsDir 'configure_iis_ssl_certifactory.ps1'

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

function Invoke-LocalScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [string[]]$Arguments = @()
    )

    Assert-Path -Path $ScriptPath -Label 'Script'
    & $ScriptPath @Arguments
    if ($LASTEXITCODE -gt 0) {
        throw "Script failed: $ScriptPath (exit code $LASTEXITCODE)"
    }
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    if ((Test-Path $OutputPath) -and -not $Force) {
        Write-Host "Using existing artifact: $OutputPath" -ForegroundColor Yellow
        return
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
    Write-Host "Downloading: $Url" -ForegroundColor White
    Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing
    Write-Host "Downloaded: $OutputPath" -ForegroundColor Green
}

function Install-ArcGISDscFromZip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$ExtractRoot
    )

    if (Test-Path $ExtractRoot) {
        Remove-Item -Path $ExtractRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractRoot -Force

    $moduleManifest = Get-ChildItem -Path $ExtractRoot -Recurse -File -Filter 'ArcGIS.psd1' |
        Where-Object { $_.FullName -match '[\\/]Modules[\\/]ArcGIS[\\/]ArcGIS\.psd1$' } |
        Select-Object -First 1

    if ($null -eq $moduleManifest) {
        throw "ArcGIS module manifest not found under extracted archive: $ExtractRoot"
    }

    Import-Module -Name $moduleManifest.FullName -Force -ErrorAction Stop
    Write-Host "Imported module: $($moduleManifest.FullName)" -ForegroundColor Green

    if (-not (Get-Command -Name Invoke-ArcGISConfiguration -ErrorAction SilentlyContinue)) {
        throw 'Invoke-ArcGISConfiguration command is not available after module import.'
    }
}

Write-Host ''
Write-Host 'ArcGIS Unattended Install' -ForegroundColor Cyan
Write-Host '=========================' -ForegroundColor Cyan
Write-Host "Base Directory: $BaseDir"
Write-Host "Version: $Version"
Write-Host "DSC Zip URL: $DscZipUrl"
Write-Host "Configuration File: $ConfigurationParametersFile"

if (-not $SkipResourceSync) {
    Write-Section 'Sync install resources'
    Invoke-LocalScript -ScriptPath $syncScript -Arguments @('-Version', $Version)
}

if (-not $SkipBootstrap) {
    Write-Section 'Bootstrap Python environment and render configuration'
    Invoke-LocalScript -ScriptPath $bootstrapScript -Arguments @('-Version', $Version, '-SkipResourceSync')
}

if (-not $SkipPrerequisites) {
    Write-Section 'Install Web Adaptor prerequisites'
    Invoke-LocalScript -ScriptPath $prereqScript
}

if (-not $SkipIisSslConfiguration) {
    Write-Section 'Configure IIS SSL certificate'
    $sslArgs = @('-UseDefaultCredentials')
    if ($ForceCertificateReinstall) {
        $sslArgs += '-ForceCertificateReinstall'
    }
    Invoke-LocalScript -ScriptPath $configureSslScript -Arguments $sslArgs
}

Write-Section 'Encrypt password files if needed'
Invoke-LocalScript -ScriptPath $protectSecretsScript -Arguments @('-Mode', 'Encrypt')

Write-Section 'Acquire ArcGIS DSC module artifact'
Download-File -Url $DscZipUrl -OutputPath $dscZipPath -Force:$ForceDscDownload

Write-Section 'Import ArcGIS DSC module from local zip extract'
Install-ArcGISDscFromZip -ZipPath $dscZipPath -ExtractRoot $dscExtractRoot

Write-Section 'Invoke ArcGIS DSC configuration'
Assert-Path -Path $ConfigurationParametersFile -Label 'Configuration file'
Invoke-ArcGISConfiguration -ConfigurationParametersFile $ConfigurationParametersFile -Mode InstallLicenseConfigure

Write-Section 'Install complete'
Write-Host 'ArcGIS unattended installation flow finished.' -ForegroundColor Green