#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SiteName = "Default Web Site",

    [Parameter(Mandatory = $false)]
    [string]$Hostname = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$CertifactoryBaseUrl = "https://certifactory.esri.com/api",

    [Parameter(Mandatory = $false)]
    [string]$PfxOutPath = "$env:TEMP\\certifactory-domain-cert.pfx",

    [Parameter(Mandatory = $false)]
    [SecureString]$PfxPassword,

    [Parameter(Mandatory = $false)]
    [switch]$UseDefaultCredentials,

    [Parameter(Mandatory = $false)]
    [switch]$ForceCertificateReinstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-IisInstalled {
    Write-Host "Ensuring IIS and IIS Manager are installed..." -ForegroundColor Cyan

    $installWindowsFeature = Get-Command -Name Install-WindowsFeature -ErrorAction SilentlyContinue
    if ($null -ne $installWindowsFeature) {
        $featureNames = @("Web-Server", "Web-Mgmt-Console")
        $missing = @()

        foreach ($feature in $featureNames) {
            $state = Get-WindowsFeature -Name $feature
            if (-not $state.Installed) {
                $missing += $feature
            }
        }

        if ($missing.Count -gt 0) {
            Install-WindowsFeature -Name $missing -IncludeManagementTools | Out-Null
            Write-Host "Installed features: $($missing -join ', ')" -ForegroundColor Green
        }
        else {
            Write-Host "IIS features already installed." -ForegroundColor Green
        }

        return
    }

    $optionalFeatures = @(
        "IIS-WebServerRole",
        "IIS-WebServer",
        "IIS-ManagementConsole"
    )

    foreach ($feature in $optionalFeatures) {
        $featureState = Get-WindowsOptionalFeature -Online -FeatureName $feature
        if ($featureState.State -ne "Enabled") {
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null
            Write-Host "Enabled optional feature: $feature" -ForegroundColor Green
        }
    }

    Write-Host "IIS optional features ensured." -ForegroundColor Green
}

function Normalize-CertHostname {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputHostname
    )

    $trimmed = $InputHostname.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw "Hostname cannot be empty."
    }

    if ($trimmed -match "\.") {
        return ($trimmed.Split('.')[0])
    }

    return $trimmed
}

function Download-CertifactoryPfx {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$CertHostname,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [bool]$UseWindowsCredentials
    )

    $cleanBase = $BaseUrl.TrimEnd('/')
    $uri = "$cleanBase/$CertHostname.pfx"

    Write-Host "Downloading certificate from: $uri" -ForegroundColor Cyan

    $parentDir = Split-Path -Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path $parentDir)) {
        New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
    }

    $params = @{
        Uri         = $uri
        OutFile     = $OutputPath
        ErrorAction = "Stop"
    }

    if ($UseWindowsCredentials) {
        $params.UseDefaultCredentials = $true
    }

    Invoke-WebRequest @params | Out-Null

    if (-not (Test-Path $OutputPath)) {
        throw "Failed to download certificate to: $OutputPath"
    }

    Write-Host "Downloaded PFX: $OutputPath" -ForegroundColor Green
}

function Import-MachinePfx {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PfxPath,

        [Parameter(Mandatory = $false)]
        [SecureString]$Password
    )

    Write-Host "Importing PFX into LocalMachine\\My..." -ForegroundColor Cyan

    $importParams = @{
        FilePath          = $PfxPath
        CertStoreLocation = "Cert:\\LocalMachine\\My"
        Exportable        = $true
        ErrorAction       = "Stop"
    }

    if ($null -ne $Password) {
        $importParams.Password = $Password
    }

    try {
        $cert = Import-PfxCertificate @importParams
        if ($null -ne $cert) {
            return $cert
        }
    }
    catch {
        if ($null -ne $Password) {
            throw
        }
    }

    $emptyPassword = ConvertTo-SecureString -String "" -AsPlainText -Force
    $cert = Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation "Cert:\\LocalMachine\\My" -Password $emptyPassword -Exportable -ErrorAction Stop
    return $cert
}

function Set-IisHttpsBinding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetSite,

        [Parameter(Mandatory = $true)]
        [string]$CertThumbprint
    )

    Write-Host "Configuring HTTPS binding for '$TargetSite' on port 443..." -ForegroundColor Cyan

    Import-Module WebAdministration -ErrorAction Stop

    $site = Get-Website -Name $TargetSite -ErrorAction SilentlyContinue
    if ($null -eq $site) {
        throw "IIS site '$TargetSite' was not found."
    }

    $httpsBinding = Get-WebBinding -Name $TargetSite -Protocol https -ErrorAction SilentlyContinue | Where-Object { $_.bindingInformation -eq "*:443:" }
    if ($null -eq $httpsBinding) {
        New-WebBinding -Name $TargetSite -IP "*" -Port 443 -Protocol https | Out-Null
        Write-Host "Created HTTPS binding *:443:" -ForegroundColor Green
    }
    else {
        Write-Host "HTTPS binding *:443: already exists." -ForegroundColor Green
    }

    $sslBindingPath = "IIS:\\SslBindings\\0.0.0.0!443"
    if (Test-Path $sslBindingPath) {
        Remove-Item -Path $sslBindingPath -Force
    }

    Get-Item "Cert:\\LocalMachine\\My\\$CertThumbprint" | New-Item -Path $sslBindingPath -Force | Out-Null

    Write-Host "Assigned certificate thumbprint $CertThumbprint to 0.0.0.0:443" -ForegroundColor Green
}

if (-not (Test-IsAdministrator)) {
    throw "This script must be run in an elevated PowerShell session (Run as Administrator)."
}

$normalizedHostname = Normalize-CertHostname -InputHostname $Hostname

Ensure-IisInstalled

Import-Module WebAdministration -ErrorAction Stop

$existingCert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object {
    $_.Subject -like "*CN=$normalizedHostname.esri.com*"
} | Sort-Object NotAfter -Descending | Select-Object -First 1

if ($null -eq $existingCert -or $ForceCertificateReinstall) {
    Download-CertifactoryPfx -BaseUrl $CertifactoryBaseUrl -CertHostname $normalizedHostname -OutputPath $PfxOutPath -UseWindowsCredentials:[bool]$UseDefaultCredentials
    $importedCert = Import-MachinePfx -PfxPath $PfxOutPath -Password $PfxPassword
    if ($null -eq $importedCert) {
        throw "Certificate import did not return a certificate object."
    }
    $selectedThumbprint = $importedCert.Thumbprint
    Write-Host "Imported certificate: $($importedCert.Subject)" -ForegroundColor Green
}
else {
    $selectedThumbprint = $existingCert.Thumbprint
    Write-Host "Using existing certificate in LocalMachine\\My: $($existingCert.Subject)" -ForegroundColor Green
}

Set-IisHttpsBinding -TargetSite $SiteName -CertThumbprint $selectedThumbprint

Write-Host ""
Write-Host "Completed IIS SSL configuration." -ForegroundColor Green
Write-Host "Site: $SiteName" -ForegroundColor White
Write-Host "HTTPS Binding: *:443:" -ForegroundColor White
Write-Host "Certificate Thumbprint: $selectedThumbprint" -ForegroundColor White