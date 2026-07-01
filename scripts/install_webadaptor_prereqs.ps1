#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SoftwareDir = "",

    [Parameter(Mandatory = $false)]
    [string]$HostingBundleUrl = "https://aka.ms/dotnet/8.0/dotnet-hosting-win.exe",

    [Parameter(Mandatory = $false)]
    [string]$WebDeployUrl = "https://aka.ms/webdeploy",

    [Parameter(Mandatory = $false)]
    [switch]$ForceDownload,

    [Parameter(Mandatory = $false)]
    [switch]$DownloadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SoftwareDir)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $SoftwareDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'resources\software'
    }
    elseif ($MyInvocation.MyCommand.Path) {
        $SoftwareDir = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'resources\software'
    }
    else {
        $SoftwareDir = Join-Path (Get-Location).Path 'resources\software'
    }
}

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$OutputPath,
        [switch]$Force
    )

    if ((Test-Path -Path $OutputPath) -and -not $Force) {
        Write-Host "Using existing file: $OutputPath" -ForegroundColor Yellow
        return
    }

    Write-Host "Downloading: $Url" -ForegroundColor White
    Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing
    Write-Host "Downloaded: $OutputPath" -ForegroundColor Green
}

function Get-InstalledProgram {
    param([string]$NameRegex)

    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match $NameRegex } |
        Select-Object -First 1
}

function Install-HostingBundle {
    param(
        [string]$InstallerPath,
        [string]$LogPath
    )

    $existing = Get-InstalledProgram -NameRegex "Hosting Bundle"
    if ($null -ne $existing) {
        Write-Host "Hosting Bundle already installed: $($existing.DisplayName) $($existing.DisplayVersion)" -ForegroundColor Green
        return
    }

    Write-Host "Installing Hosting Bundle..." -ForegroundColor White
    $proc = Start-Process -FilePath $InstallerPath -ArgumentList "/install /quiet /norestart /log `"$LogPath`"" -Wait -PassThru

    if ($proc.ExitCode -notin @(0, 3010, 1638)) {
        throw "Hosting Bundle install failed with exit code $($proc.ExitCode). Log: $LogPath"
    }

    Write-Host "Hosting Bundle install completed. ExitCode=$($proc.ExitCode)" -ForegroundColor Green
}

function Install-WebDeploy {
    param(
        [string]$InstallerPath,
        [string]$LogPath
    )

    $existing = Get-InstalledProgram -NameRegex "IIS.*Deployment Tool|Web Deploy"
    if ($null -ne $existing) {
        Write-Host "Web Deploy already installed: $($existing.DisplayName) $($existing.DisplayVersion)" -ForegroundColor Green
        return
    }

    Write-Host "Installing Web Deploy..." -ForegroundColor White
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$InstallerPath`" /qn /norestart /l*v `"$LogPath`"" -Wait -PassThru

    if ($proc.ExitCode -notin @(0, 3010, 1638)) {
        throw "Web Deploy install failed with exit code $($proc.ExitCode). Log: $LogPath"
    }

    Write-Host "Web Deploy install completed. ExitCode=$($proc.ExitCode)" -ForegroundColor Green
}

if (-not (Test-IsAdministrator)) {
    throw "Run this script in an elevated PowerShell session (Run as Administrator)."
}

Write-Section "Preparing folders"
Ensure-Directory -Path $SoftwareDir
$logDir = Join-Path (Split-Path -Parent $PSScriptRoot) "Logs"
Ensure-Directory -Path $logDir

$hostingInstaller = Join-Path $SoftwareDir "dotnet-hosting-8.0-win.exe"
$webDeployInstaller = Join-Path $SoftwareDir "WebDeploy_amd64_en-US.msi"

Write-Section "Downloading installers"
Download-File -Url $HostingBundleUrl -OutputPath $hostingInstaller -Force:$ForceDownload
Download-File -Url $WebDeployUrl -OutputPath $webDeployInstaller -Force:$ForceDownload

if ($DownloadOnly) {
    Write-Host "DownloadOnly specified. Skipping installation." -ForegroundColor Yellow
    exit 0
}

Write-Section "Installing prerequisites"
$hostingLog = Join-Path $logDir "dotnet-hosting-install.log"
$webDeployLog = Join-Path $logDir "webdeploy-install.log"

Install-HostingBundle -InstallerPath $hostingInstaller -LogPath $hostingLog
Install-WebDeploy -InstallerPath $webDeployInstaller -LogPath $webDeployLog

Write-Section "Complete"
Write-Host "Prerequisites are installed (or already present)." -ForegroundColor Green
Write-Host "Hosting log: $hostingLog"
Write-Host "Web Deploy log: $webDeployLog"
