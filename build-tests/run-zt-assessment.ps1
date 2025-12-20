#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Runs the Microsoft Zero Trust Assessment tool using Service Principal credentials from a .env file.

.DESCRIPTION
    This script automates the authentication process for the Zero Trust Assessment tool.
    It reads credentials from the local .env file and establishes connections to 
    Microsoft Graph and Azure before invoking the assessment.

.NOTES
    Prerequisites:
    - Microsoft Graph PowerShell SDK
    - Az PowerShell module
    - ZeroTrustAssessment module (Install-Module ZeroTrustAssessment)
    - .env file in the same directory with SPN credentials
#>

$ErrorActionPreference = "Stop"

# Configuration
$ENV_FILE = Join-Path $PSScriptRoot ".env"
$REPORT_PATH = Join-Path $PSScriptRoot "ZeroTrustReport"

function Write-Step {
    param([string]$Message)
    Write-Host "`n▶ $Message" -ForegroundColor Blue
}

function Write-Success {
    param([string]$Message)
    Write-Host "✅ $Message" -ForegroundColor Green
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "❌ $Message" -ForegroundColor Red
}

function Read-EnvFile {
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        Write-ErrorMsg ".env file not found at: $FilePath"
        throw ".env file not found"
    }
    
    Write-Step "Loading environment variables from .env file..."
    
    $envVars = @{}
    Get-Content $FilePath | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                $envVars[$key] = $value
                [Environment]::SetEnvironmentVariable($key, $value, "Process")
            }
        }
    }
    
    $required = @('ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID')
    foreach ($var in $required) {
        if (-not $envVars[$var]) {
            Write-ErrorMsg "Missing required variable: $var"
            throw "Incomplete .env configuration"
        }
    }
    
    return $envVars
}

try {
    # 1. Load Environment Variables
    $envVars = Read-EnvFile -FilePath $ENV_FILE

    # 2. Check for required modules
    Write-Step "Checking for required PowerShell modules..."
    $modules = @("Microsoft.Graph.Authentication", "Az.Accounts", "ZeroTrustAssessment")
    foreach ($module in $modules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Warning "Module '$module' is not installed."
            Write-Host "Please run: Install-Module $module -Scope CurrentUser"
            # We don't auto-install to avoid user surprises, but we check.
        }
    }

    # 3. Authenticate to Microsoft Graph
    Write-Step "Authenticating to Microsoft Graph with SPN..."
    $secSecret = ConvertTo-SecureString $envVars['ARM_CLIENT_SECRET'] -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($envVars['ARM_CLIENT_ID'], $secSecret)
    
    Connect-MgGraph -TenantId $envVars['ARM_TENANT_ID'] `
        -ClientSecretCredential $credential `
        -NoWelcome
    Write-Success "Connected to Microsoft Graph"

    # 4. Authenticate to Azure
    Write-Step "Authenticating to Azure with SPN..."
    Connect-AzAccount -ServicePrincipal `
        -Credential $credential `
        -Tenant $envVars['ARM_TENANT_ID'] `
        -Subscription $envVars['ARM_SUBSCRIPTION_ID']
    Write-Success "Connected to Azure"

    # 5. Run the Assessment
    Write-Step "Starting Zero Trust Assessment..."
    if (-not (Get-Module -ListAvailable -Name ZeroTrustAssessment)) {
        throw "ZeroTrustAssessment module not found. Please install it first."
    }

    if (-not (Test-Path $REPORT_PATH)) {
        New-Item -ItemType Directory -Path $REPORT_PATH | Out-Null
    }

    Invoke-ZtAssessment -Path $REPORT_PATH

    Write-Success "Assessment complete! Report saved to: $REPORT_PATH"

}
catch {
    Write-ErrorMsg "Failed to run assessment: $_"
    exit 1
}
finally {
    # Optional: Disconnect to clean up session
    # Disconnect-MgGraph | Out-Null
}
