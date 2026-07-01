#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$BaseDir = "",

    [Parameter(Mandatory = $false)]
    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'

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

if (-not (Test-Path $BaseDir)) {
    Write-Error "Base directory not found: $BaseDir"
    exit 1
}

$secretsDir = Join-Path $BaseDir 'config'
if (-not (Test-Path $secretsDir)) {
    New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null
    Write-Host "Created config directory: $secretsDir" -ForegroundColor Green
}

$passwordFiles = [ordered]@{
    'service_account_password.txt' = 'Service Account Password'
    'server_site_admin_password.txt' = 'Server Site Admin Password'
    'portal_admin_password.txt' = 'Portal Admin Password'
    'portal_security_answer.txt' = 'Portal Security Answer (vanilla)'
}

function Create-PasswordFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        [string]$DefaultValue = $null
    )

    if ($Interactive) {
        do {
            $secure = Read-Host -Prompt $Description -AsSecureString
            $text = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($secure)
            )

            if ([string]::IsNullOrWhiteSpace($text)) {
                Write-Host '  Password cannot be empty. Try again.' -ForegroundColor Yellow
            }
        } while ([string]::IsNullOrWhiteSpace($text))
    }
    elseif ($null -ne $DefaultValue) {
        $text = $DefaultValue
        Write-Host "  Using default: $DefaultValue"
    }
    else {
        Write-Host '  Provide password (or press Enter to use placeholder ChangeMe123!):'
        $inputValue = Read-Host
        $text = if ([string]::IsNullOrWhiteSpace($inputValue)) { 'ChangeMe123!' } else { $inputValue }
    }

    $text | Set-Content -Path $FilePath -Encoding UTF8 -Force

    $acl = Get-Acl $FilePath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }

    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Administrators',
        'FullControl',
        'Allow'
    )
    [void]$acl.AddAccessRule($adminRule)
    Set-Acl -Path $FilePath -AclObject $acl

    Write-Host "  Created: $(Split-Path $FilePath -Leaf)" -ForegroundColor Green
}

Write-Host ''
Write-Host 'ArcGIS Enterprise Password File Creator' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "Base Directory: $BaseDir"
Write-Host "Config Directory: $secretsDir"
Write-Host ''

if (-not $Interactive) {
    Write-Host 'Running in NON-INTERACTIVE mode. Using placeholder passwords.' -ForegroundColor Yellow
    Write-Host 'Use -Interactive to enter passwords manually.' -ForegroundColor Yellow
    Write-Host ''
}

foreach ($entry in $passwordFiles.GetEnumerator()) {
    $filePath = Join-Path $secretsDir $entry.Key
    Write-Host "Creating: $($entry.Key)"

    if (Test-Path $filePath) {
        $confirm = Read-Host '  File already exists. Overwrite? (y/n)'
        if ($confirm -ne 'y') {
            Write-Host '  Skipped.' -ForegroundColor Yellow
            continue
        }
    }

    $defaultValue = $null
    if ($entry.Key -eq 'portal_security_answer.txt') {
        $defaultValue = 'vanilla'
    }

    Create-PasswordFile -FilePath $filePath -Description $entry.Value -DefaultValue $defaultValue
}

Write-Host ''
Write-Host 'Password Files Created Successfully' -ForegroundColor Green
Write-Host '===================================' -ForegroundColor Green
