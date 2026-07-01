# Encrypt or decrypt ArcGIS deployment config password files using Windows DPAPI.
#
# Encrypt mode (default):
#   - Reads plaintext from each password file
#   - Rewrites file as raw ConvertFrom-SecureString output (ArcGIS compatible)
#
# Decrypt mode:
#   - Reads DPAPI:<ciphertext>
#   - Rewrites file as plaintext

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Encrypt", "Decrypt")]
    [string]$Mode = "Encrypt",

    [Parameter(Mandatory = $false)]
    [string]$BaseDir = ""
)

$ErrorActionPreference = "Stop"

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

$secretsDir = Join-Path $BaseDir "config"
if (-not (Test-Path $secretsDir)) {
    Write-Error "Config directory not found: $secretsDir"
    exit 1
}

$secretFiles = @(
    "service_account_password.txt",
    "server_site_admin_password.txt",
    "portal_admin_password.txt"
)

function Convert-SecureStringToPlainText {
    param([System.Security.SecureString]$Secure)

    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Write-TextNoBomNoNewline {
    param(
        [string]$Path,
        [string]$Value
    )

    # ArcGIS module reads password files with Get-Content | ConvertTo-SecureString,
    # so avoid BOM/newline wrappers and write only the secure-string payload text.
    [System.IO.File]::WriteAllText($Path, $Value, [System.Text.Encoding]::ASCII)
}

function Get-SecretFormat {
    param([string]$Value)

    if ($Value.StartsWith("DPAPI:")) {
        return "LegacyPrefixed"
    }

    if ($Value -match '^[0-9A-Fa-f]+$') {
        return "ArcGISEncrypted"
    }

    return "PlainText"
}

Write-Host "Mode: $Mode" -ForegroundColor Cyan
Write-Host "Config directory: $secretsDir" -ForegroundColor Cyan

foreach ($name in $secretFiles) {
    $path = Join-Path $secretsDir $name

    if (-not (Test-Path $path)) {
        Write-Host "Skipped (missing): $name" -ForegroundColor Yellow
        continue
    }

    $raw = Get-Content -Path $path -Raw
    $raw = $raw.TrimEnd("`r", "`n")

    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "Skipped (empty): $name" -ForegroundColor Yellow
        continue
    }

    $format = Get-SecretFormat -Value $raw

    if ($Mode -eq "Encrypt") {
        if ($format -eq "ArcGISEncrypted") {
            Write-Host "Already encrypted (ArcGIS format): $name" -ForegroundColor Yellow
            continue
        }

        if ($format -eq "LegacyPrefixed") {
            $cipher = $raw.Substring(6)
            Write-TextNoBomNoNewline -Path $path -Value $cipher
            Write-Host "Migrated encrypted format: $name" -ForegroundColor Green
            continue
        }

        $secure = ConvertTo-SecureString -String $raw -AsPlainText -Force
        $cipher = ConvertFrom-SecureString -SecureString $secure
        Write-TextNoBomNoNewline -Path $path -Value $cipher
        Write-Host "Encrypted: $name" -ForegroundColor Green
    }
    else {
        if ($format -eq "PlainText") {
            Write-Host "Already plaintext: $name" -ForegroundColor Yellow
            continue
        }

        if ($format -eq "LegacyPrefixed") {
            $cipher = $raw.Substring(6)
        }
        else {
            $cipher = $raw
        }

        $secure = ConvertTo-SecureString -String $cipher
        $plain = Convert-SecureStringToPlainText -Secure $secure
        Write-TextNoBomNoNewline -Path $path -Value $plain
        Write-Host "Decrypted: $name" -ForegroundColor Green
    }
}

Write-Host "Done." -ForegroundColor Cyan