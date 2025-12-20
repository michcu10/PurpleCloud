#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Local deployment script for debugging PurpleCloud Zero Trust Lab deployments.

.DESCRIPTION
    This script simulates the GitHub Actions deployment workflow locally for debugging purposes.
    It allows you to test deployments without pushing to GitHub Actions.

.PARAMETER DeploymentType
    Type of deployment to perform.

.PARAMETER UserCount
    Number of Azure AD users to create.

.PARAMETER AppCount
    Number of Azure AD applications to create.

.PARAMETER UpnSuffix
    UPN suffix for users (e.g., company.com).

.PARAMETER EnablePrivilegedRoles
    Enable privileged role assignments.

.PARAMETER LabName
    Name for the lab resources.

.PARAMETER AzureLocation
    Azure region for resources.

.PARAMETER DryRun
    Only show what would be done without executing.

.EXAMPLE
    .\local-deploy.ps1 -DeploymentType cloud-only-full -UpnSuffix "mycompany.com"

.EXAMPLE
    .\local-deploy.ps1 -DeploymentType azure-ad-only -UserCount 50 -UpnSuffix "test.onmicrosoft.com" -DryRun

.NOTES
    Prerequisites:
    - Azure CLI installed
    - Terraform installed (version 1.5.0 or later)
    - Python 3.8+ with faker module (pip install faker)
    - .env file with Service Principal credentials (copy from .env.example)
    - Service Principal with appropriate Azure permissions
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('cloud-only-basic', 'cloud-only-full', 'azure-ad-only', 'managed-identity-only', 'storage-only')]
    [string]$DeploymentType,

    [Parameter(Mandatory = $false)]
    [int]$UserCount = 100,

    [Parameter(Mandatory = $false)]
    [int]$AppCount = 7,

    [Parameter(Mandatory = $true)]
    [string]$UpnSuffix,

    [Parameter(Mandatory = $false)]
    [switch]$EnablePrivilegedRoles = $true,

    [Parameter(Mandatory = $false)]
    [string]$LabName = "ZeroTrustLab",

    [Parameter(Mandatory = $false)]
    [ValidateSet('eastus', 'westus', 'centralus', 'northeurope', 'westeurope', 'southeastasia')]
    [string]$AzureLocation = "eastus",

    [Parameter(Mandatory = $false)]
    [int]$Parallelism = 5,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPrerequisiteCheck,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Terraform', 'GraphAPI')]
    [string]$DeploymentMethod = "Terraform"
)

# Configuration
$ErrorActionPreference = "Stop"
$TF_VERSION = "1.5.0"
$PYTHON_VERSION = "3.8"
$Script:PythonCommand = "python" # Default
$WORKSPACE_ROOT = Split-Path -Parent $PSScriptRoot
$ENV_FILE = Join-Path $PSScriptRoot ".env"
$LOGS_DIR = Join-Path $PSScriptRoot "logs"
$transcriptStarted = $false

# ANSI color codes for better output
$Script:Colors = @{
    Reset  = "`e[0m"
    Red    = "`e[31m"
    Green  = "`e[32m"
    Yellow = "`e[33m"
    Blue   = "`e[34m"
    Cyan   = "`e[36m"
    Bold   = "`e[1m"
}

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "Reset",
        [switch]$NoNewline
    )
    
    $colorCode = $Script:Colors[$Color]
    $resetCode = $Script:Colors["Reset"]
    
    if ($NoNewline) {
        Write-Host "$colorCode$Message$resetCode" -NoNewline
    }
    else {
        Write-Host "$colorCode$Message$resetCode"
    }
}

function Write-Header {
    param([string]$Message)
    Write-ColorOutput "`n========================================" -Color "Cyan"
    Write-ColorOutput $Message -Color "Cyan"
    Write-ColorOutput "========================================" -Color "Cyan"
}

function Write-Step {
    param([string]$Message)
    Write-ColorOutput "▶ $Message" -Color "Blue"
}

function Write-Success {
    param([string]$Message)
    Write-ColorOutput "✅ $Message" -Color "Green"
}

function Write-Warning {
    param([string]$Message)
    Write-ColorOutput "⚠️  $Message" -Color "Yellow"
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-ColorOutput "❌ $Message" -Color "Red"
}

function Read-EnvFile {
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        Write-ErrorMsg ".env file not found at: $FilePath"
        Write-Host "Please copy .env.example to .env and configure your Service Principal credentials."
        Write-Host "Location: $(Join-Path $PSScriptRoot '.env.example')"
        throw ".env file not found"
    }
    
    Write-Step "Loading environment variables from .env file..."
    
    $envVars = @{}
    Get-Content $FilePath | ForEach-Object {
        $line = $_.Trim()
        # Skip empty lines and comments
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                $envVars[$key] = $value
                
                # Set as environment variable for Terraform
                [Environment]::SetEnvironmentVariable($key, $value, "Process")
            }
        }
    }
    
    # Validate required variables
    $required = @('ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_SUBSCRIPTION_ID', 'ARM_TENANT_ID')
    $missing = @()
    
    foreach ($var in $required) {
        if (-not $envVars[$var] -or $envVars[$var] -match '^x+') {
            $missing += $var
        }
    }
    
    if ($missing.Count -gt 0) {
        Write-ErrorMsg "Missing or unconfigured variables in .env file:"
        $missing | ForEach-Object { Write-Host "  - $_" }
        throw "Incomplete .env configuration"
    }
    
    Write-Success "Environment variables loaded successfully"
    return $envVars
}

function Test-AzureNamingConventions {
    param([string]$Name)
    
    Write-Step "Validating Azure resource naming conventions..."
    
    $issues = @()
    
    # Storage account name validation (will be sanitized, but warn if problematic)
    $sanitizedName = ($Name -replace '[^a-z0-9]', '').ToLower()
    if ($sanitizedName.Length -lt 3) {
        $issues += "Lab name is too short (will use default random name for storage account)"
        Write-Warning "Lab name '$Name' will result in a very short storage account name"
    }
    elseif ($Name -match '[^a-zA-Z0-9-]') {
        Write-Warning "Lab name contains special characters - will be sanitized for storage account"
    }
    
    # Resource group naming (can be more flexible)
    if ($Name.Length -gt 90) {
        $issues += "Lab name is too long (max 90 characters for resource groups)"
    }
    
    if ($issues.Count -gt 0) {
        Write-Warning "Resource naming validation found potential issues:"
        $issues | ForEach-Object { Write-ColorOutput "  - $_" -Color "Yellow" }
    }
    else {
        Write-Success "Resource naming validation passed"
    }
}

function Connect-AzureServicePrincipal {
    param([hashtable]$EnvVars)
    
    Write-Step "Authenticating with Azure Service Principal..."
    
    try {
        # Login with Service Principal
        az login --service-principal `
            --username $EnvVars['ARM_CLIENT_ID'] `
            --password $EnvVars['ARM_CLIENT_SECRET'] `
            --tenant $EnvVars['ARM_TENANT_ID'] `
            --output none
        
        if ($LASTEXITCODE -ne 0) {
            throw "Azure login failed"
        }
        
        # Set the subscription
        az account set --subscription $EnvVars['ARM_SUBSCRIPTION_ID']
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set subscription"
        }
        
        # Verify authentication
        $account = az account show | ConvertFrom-Json
        
        Write-Success "Authenticated successfully"
        Write-ColorOutput "  Subscription: $($account.name)" -Color "Cyan"
        Write-ColorOutput "  Tenant: $($account.tenantId)" -Color "Cyan"
        Write-ColorOutput "  Service Principal: $($EnvVars['ARM_CLIENT_ID'])" -Color "Cyan"
        
    }
    catch {
        Write-ErrorMsg "Azure authentication failed: $_"
        Write-Host "Please verify your Service Principal credentials in .env file"
        throw
    }
}

function Test-Prerequisites {
    Write-Header "Checking Prerequisites"
    
    $allGood = $true
    
    # Check Azure CLI
    Write-Step "Checking Azure CLI..."
    try {
        $azVersion = az --version 2>$null | Select-Object -First 1
        if ($azVersion) {
            Write-Success "Azure CLI installed: $azVersion"
        }
        else {
            throw "Azure CLI not found"
        }
    }
    catch {
        Write-ErrorMsg "Azure CLI not installed or not in PATH"
        Write-Host "Install from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        $allGood = $false
    }
    
    # Note: Azure authentication will be done via Service Principal from .env file
    Write-Step "Azure authentication will use Service Principal from .env file..."
    Write-Success "Will authenticate with Service Principal after loading .env"
    
    # Check Terraform
    Write-Step "Checking Terraform..."
    try {
        $tfVersion = terraform --version 2>$null | Select-Object -First 1
        if ($tfVersion) {
            Write-Success "Terraform installed: $tfVersion"
            
            # Extract version number
            if ($tfVersion -match 'v?(\d+\.\d+\.\d+)') {
                $installedVersion = [version]$matches[1]
                $requiredVersion = [version]$TF_VERSION
                
                if ($installedVersion -lt $requiredVersion) {
                    Write-Warning "Recommended Terraform version is $TF_VERSION or later"
                }
            }
        }
        else {
            throw "Terraform not found"
        }
    }
    catch {
        Write-ErrorMsg "Terraform not installed or not in PATH"
        Write-Host "Install from: https://www.terraform.io/downloads"
        $allGood = $false
    }
    
    # Check Python
    Write-Step "Checking Python..."
    $pythonFound = $false
    
    # Try python first
    try {
        $pythonVersion = & python --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            $Script:PythonCommand = "python"
            $pythonFound = $true
            Write-Success "Python installed: $pythonVersion"
        }
    }
    catch {}

    # If python not found, try python3
    if (-not $pythonFound) {
        try {
            $pythonVersion = & python3 --version 2>$null
            if ($LASTEXITCODE -eq 0) {
                $Script:PythonCommand = "python3"
                $pythonFound = $true
                Write-Success "Python installed (as python3): $pythonVersion"
            }
        }
        catch {}
    }

    if (-not $pythonFound) {
        Write-ErrorMsg "Python not installed or not in PATH"
        Write-Host "Install from: https://www.python.org/downloads/"
        $allGood = $false
    }
    else {
        # Check faker module
        Write-Step "Checking Python faker module (using $Script:PythonCommand)..."
        try {
            # Try to import faker
            $fakerCheck = & $Script:PythonCommand -c "import faker; print('OK')" 2>$null
            if ($fakerCheck -eq 'OK') {
                Write-Success "faker module installed"
            }
            else {
                Write-Warning "faker module not installed. Run 'pip install faker'"
                Write-ColorOutput "  Attempting to install..." -Color "Yellow"
                & $Script:PythonCommand -m pip install faker --quiet
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "faker module installed"
                }
                else {
                    throw "Failed to install faker"
                }
            }
        }
        catch {
            Write-Warning "Could not verify/install faker module: $_"
        }
    }
    
    if (-not $allGood) {
        Write-ErrorMsg "`nPrerequisite checks failed. Please install missing components."
        exit 1
    }
    
    Write-Success "`nAll prerequisites met!"
}

function Invoke-AzureADDeployment {
    Write-Header "Deploying Azure AD Resources"
    
    $generatorPath = Join-Path $WORKSPACE_ROOT "generators\azure_ad"
    Set-Location $generatorPath
    
    # Clean up any stale state from previous failed runs
    Write-Step "Checking for existing Terraform state..."
    if (Test-Path "terraform.tfstate") {
        Write-Warning "Found existing Terraform state from previous run"
        Write-ColorOutput "  If deployment fails, consider running local-cleanup.ps1 first" -Color "Yellow"
    }
    
    # Build Python command
    Write-Step "Generating users list (using internal python script)..."
    $privFlags = if ($EnablePrivilegedRoles) { "-aa -pra -ga" } else { "" }
    
    $pythonCmd = "$Script:PythonCommand azure_ad.py -c $UserCount -u $UpnSuffix --apps $AppCount --groups 4 $privFlags"
    Write-ColorOutput "  Command: $pythonCmd" -Color "Cyan"
    
    if (-not $DryRun) {
        Invoke-Expression $pythonCmd
        if ($LASTEXITCODE -ne 0) {
            throw "Python script failed"
        }
        Write-Success "Configuration/Data generated"
    }

    if ($DeploymentMethod -eq "GraphAPI") {
        # GRAPH API DEPLOYMENT
        Write-Header "Executing Graph API Deployment"
        
        $csvFile = Join-Path $generatorPath "azure_users.csv"
        
        # Generate a random password for all users (simplification for lab)
        $password = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 12 | ForEach-Object { [char]$_ }) + "1!Aa"
        Write-ColorOutput "generated password for users: $password" -Color "Yellow"
        
        $graphCmd = "pwsh .\deploy-graph-users.ps1 -CsvFile `"$csvFile`" -Password `"$password`""
        if ($DryRun) { $graphCmd += " -DryRun" }
        
        Write-Step "Running Graph API script..."
        Write-ColorOutput "  Command: $graphCmd" -Color "Cyan"
        
        Invoke-Expression $graphCmd
        if ($LASTEXITCODE -ne 0) {
            throw "Graph API script failed"
        }
        
    }
    else {
        # TERRAFORM DEPLOYMENT (Existing Logic)
        
        # Terraform Init
        Write-Step "Initializing Terraform..."
        if (-not $DryRun) {
            terraform init
            if ($LASTEXITCODE -ne 0) {
                throw "Terraform init failed"
            }
            Write-Success "Terraform initialized"
        }
        
        # Terraform Plan
        Write-Step "Creating Terraform plan..."
        if (-not $DryRun) {
            terraform plan -input=false "-out=azure_ad.tfplan"
            if ($LASTEXITCODE -ne 0) {
                throw "Terraform plan failed"
            }
            Write-Success "Terraform plan created"
        }
        
        # Terraform Apply
        Write-Step "Applying Terraform configuration (this may take several minutes)..."
        if (-not $DryRun) {
            $maxRetries = 3
            $retryCount = 0
            $success = $false
            
            while ($retryCount -lt $maxRetries -and -not $success) {
                Write-ColorOutput "  Attempt $($retryCount + 1) of $maxRetries..." -Color "Yellow"
                
                if ($retryCount -eq 0) {
                    # First attempt: use the saved plan
                    terraform apply -auto-approve "-parallelism=$Parallelism" -input=false "-lock-timeout=30m" azure_ad.tfplan
                }
                else {
                    # Retry attempts: remove stale plan and apply directly
                    if (Test-Path "azure_ad.tfplan") {
                        Remove-Item "azure_ad.tfplan" -Force
                        Write-ColorOutput "  Removed stale plan file" -Color "Yellow"
                    }
                    Write-ColorOutput "  Refreshing state and applying changes..." -Color "Yellow"
                    terraform apply -auto-approve "-parallelism=$Parallelism" -input=false "-lock-timeout=30m" -refresh=true
                }
                
                if ($LASTEXITCODE -eq 0) {
                    $success = $true
                    Write-Success "Azure AD resources deployed successfully"
                }
                else {
                    $retryCount++
                    if ($retryCount -lt $maxRetries) {
                        Write-Warning "Apply failed. Waiting 90 seconds before retry..."
                        Write-ColorOutput "  This may be due to Azure AD replication delays or transient errors" -Color "Yellow"
                        Start-Sleep -Seconds 90
                    }
                    else {
                        Write-ErrorMsg "All retry attempts exhausted for Azure AD deployment"
                        Write-Warning "Partial deployment may exist. Check Azure Portal and run local-cleanup.ps1 if needed"
                        throw "Azure AD deployment failed after $maxRetries attempts"
                    }
                }
            }
        }
    }
    
    Set-Location $WORKSPACE_ROOT
}

function Invoke-StorageDeployment {
    Write-Header "Deploying Storage Resources"
    
    $generatorPath = Join-Path $WORKSPACE_ROOT "generators\storage"
    Set-Location $generatorPath
    
    # Get Public IP
    $clientIp = Get-PublicIp
    $ipArg = if ($clientIp) { "-ip $clientIp" } else { "" }
    
    Write-Step "Generating Terraform configuration..."
    $pythonCmd = "$Script:PythonCommand storage.py -n $LabName -l $AzureLocation $ipArg"
    Write-ColorOutput "  Command: $pythonCmd" -Color "Cyan"
    
    if (-not $DryRun) {
        Invoke-Expression $pythonCmd
        if ($LASTEXITCODE -ne 0) {
            throw "Python script failed"
        }
        Write-Success "Terraform configuration generated"
    }
    
    Write-Step "Initializing Terraform..."
    if (-not $DryRun) {
        terraform init
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform init failed"
        }
        Write-Success "Terraform initialized"
    }
    
    Write-Step "Creating Terraform plan..."
    if (-not $DryRun) {
        terraform plan "-out=storage.tfplan"
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMsg "Terraform plan failed for storage resources"
            Write-ColorOutput "  This is often due to invalid naming (storage accounts must be lowercase alphanumeric)" -Color "Yellow"
            Write-ColorOutput "  Lab name used: $LabName" -Color "Yellow"
            throw "Terraform plan failed"
        }
        Write-Success "Terraform plan created"
    }
    
    Write-Step "Applying Terraform configuration..."
    if (-not $DryRun) {
        terraform apply -auto-approve "-parallelism=$Parallelism" storage.tfplan
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform apply failed"
        }
        Write-Success "Storage resources deployed successfully"
    }
    
    Set-Location $WORKSPACE_ROOT
}

function Invoke-ManagedIdentityDeployment {
    Write-Header "Deploying Managed Identity Resources"
    
    $generatorPath = Join-Path $WORKSPACE_ROOT "generators\managed_identity"
    Set-Location $generatorPath
    
    Write-Step "Generating Terraform configuration..."
    
    # Determine if we should reuse existing RG (e.g. created by Storage deployment)
    $existingRgArg = ""
    if ($DeploymentType -eq "cloud-only-full") {
        $existingRgArg = "-e"
    }

    $pythonCmd = "$Script:PythonCommand managed_identity.py -u $UpnSuffix -ua owner -sa -n $LabName -l $AzureLocation $existingRgArg"
    Write-ColorOutput "  Command: $pythonCmd" -Color "Cyan"
    
    if (-not $DryRun) {
        Invoke-Expression $pythonCmd
        if ($LASTEXITCODE -ne 0) {
            throw "Python script failed"
        }
        Write-Success "Terraform configuration generated"
    }
    
    Write-Step "Initializing Terraform..."
    if (-not $DryRun) {
        terraform init
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform init failed"
        }
        Write-Success "Terraform initialized"
    }
    
    Write-Step "Creating Terraform plan..."
    if (-not $DryRun) {
        terraform plan "-out=managed_identity.tfplan"
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform plan failed"
        }
        Write-Success "Terraform plan created"
    }
    
    Write-Step "Applying Terraform configuration..."
    if (-not $DryRun) {
        terraform apply -auto-approve "-parallelism=$Parallelism" managed_identity.tfplan
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform apply failed"
        }
        Write-Success "Managed Identity resources deployed successfully"
    }
    
    Set-Location $WORKSPACE_ROOT
}

function Get-PublicIp {
    Write-Step "Detecting public IP address for firewall rules..."
    try {
        $ip = Invoke-RestMethod -Uri "https://api.ipify.org" -ErrorAction Stop
        if ($ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            Write-Success "Detected Public IP: $ip"
            return $ip
        }
        throw "Invalid IP format received"
    }
    catch {
        Write-Warning "Could not detect public IP: $_"
        Write-Warning "Storage firewall rules may not include your client IP."
        return $null
    }
}

function Get-ResourceGroups {
    Write-Step "Capturing created resource groups..."
    
    try {
        $rgs = az group list --query "[?starts_with(name, 'PurpleCloud') || contains(name, '$LabName')].name" -o tsv
        
        if ($rgs) {
            Write-Success "Found resource groups:"
            $rgs -split "`n" | ForEach-Object {
                Write-ColorOutput "  • $_" -Color "Cyan"
            }
            return $rgs
        }
        else {
            Write-Warning "No resource groups found matching criteria"
            return $null
        }
    }
    catch {
        Write-Warning "Could not retrieve resource groups: $_"
        return $null
    }
}

function Show-DeploymentSummary {
    param(
        [string]$ResourceGroups,
        [datetime]$StartTime
    )
    
    $duration = (Get-Date) - $StartTime
    
    Write-Header "🚀 Deployment Summary"
    
    Write-ColorOutput "`nConfiguration:" -Color "Bold"
    Write-ColorOutput "  • Deployment Type: $DeploymentType" -Color "Cyan"
    Write-ColorOutput "  • UPN Suffix: $UpnSuffix" -Color "Cyan"
    Write-ColorOutput "  • Lab Name: $LabName" -Color "Cyan"
    Write-ColorOutput "  • Azure Location: $AzureLocation" -Color "Cyan"
    Write-ColorOutput "  • Users Created: $UserCount" -Color "Cyan"
    Write-ColorOutput "  • Apps Created: $AppCount" -Color "Cyan"
    Write-ColorOutput "  • Privileged Roles: $EnablePrivilegedRoles" -Color "Cyan"
    Write-ColorOutput "  • Parallelism: $Parallelism" -Color "Cyan"
    Write-ColorOutput "`nResources:" -Color "Bold"
    Write-ColorOutput "  • Deployment Time: $($duration.ToString('hh\:mm\:ss'))" -Color "Cyan"
    Write-ColorOutput "  • Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')" -Color "Cyan"
    
    if ($ResourceGroups) {
        Write-ColorOutput "  • Resource Groups:" -Color "Cyan"
        $ResourceGroups -split "`n" | ForEach-Object {
            Write-ColorOutput "    - $_" -Color "Cyan"
        }
    }
    
    Write-ColorOutput "`nNext Steps:" -Color "Bold"
    Write-ColorOutput "  1. Review deployed resources in Azure Portal" -Color "Green"
    Write-ColorOutput "  2. Run your Zero Trust audit scripts" -Color "Green"
    Write-ColorOutput "  3. Clean up using .\build-tests\local-cleanup.ps1 when done" -Color "Green"
    
    Write-ColorOutput "`n  Azure Portal:" -Color "Bold"
    Write-ColorOutput "  https://portal.azure.com/#blade/HubsExtension/BrowseResourceGroups" -Color "Blue"
}

# ============================================================
# Main Execution
# ============================================================

try {
    $startTime = Get-Date
    
    # Setup logging to build-tests/logs
    try {
        if (-not (Test-Path $LOGS_DIR)) {
            New-Item -ItemType Directory -Path $LOGS_DIR | Out-Null
        }
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $logFile = Join-Path $LOGS_DIR ("local-deploy-{0}-{1}.log" -f $DeploymentType, $timestamp)
        Start-Transcript -Path $logFile -IncludeInvocationHeader -Force | Out-Null
        $transcriptStarted = $true
    }
    catch {
        Write-Warning "Unable to start transcript logging: $_"
    }
    
    Write-Header "PurpleCloud Local Deployment Script"
    Write-ColorOutput "Deployment Type: $DeploymentType" -Color "Cyan"
    
    if ($DryRun) {
        Write-Warning "🔍 DRY RUN MODE - No changes will be made"
    }
    
    # Load environment variables from .env file
    $envVars = Read-EnvFile -FilePath $ENV_FILE
    
    # Authenticate with Azure using Service Principal
    if (-not $DryRun) {
        Connect-AzureServicePrincipal -EnvVars $envVars
    }
    else {
        Write-ColorOutput "  [DRY RUN] Would authenticate with Service Principal" -Color "Cyan"
    }
    
    # Check prerequisites
    if (-not $SkipPrerequisiteCheck) {
        Test-Prerequisites
        Test-AzureNamingConventions -Name $LabName
    }
    else {
        Write-Warning "Skipping prerequisite checks"
    }
    
    # Execute deployment based on type
    switch ($DeploymentType) {
        'cloud-only-basic' {
            Invoke-AzureADDeployment
        }
        'cloud-only-full' {
            Invoke-AzureADDeployment
            Invoke-StorageDeployment
            Invoke-ManagedIdentityDeployment
        }
        'azure-ad-only' {
            Invoke-AzureADDeployment
        }
        'managed-identity-only' {
            Invoke-ManagedIdentityDeployment
        }
        'storage-only' {
            Invoke-StorageDeployment
        }
    }
    
    # Capture resource groups
    if (-not $DryRun) {
        $resourceGroups = Get-ResourceGroups
    }
    else {
        $resourceGroups = $null
    }
    
    # Show summary
    Show-DeploymentSummary -ResourceGroups $resourceGroups -StartTime $startTime
    
    Write-Success "`n✅ Deployment Complete!"
    
}
catch {
    Write-ErrorMsg "`n❌ Deployment failed: $_"
    Write-ColorOutput $_.ScriptStackTrace -Color "Red"
    
    Write-ColorOutput "`nTroubleshooting:" -Color "Yellow"
    Write-ColorOutput "  • Check if resources already exist from a previous run" -Color "Yellow"
    Write-ColorOutput "  • Run .\build-tests\local-cleanup.ps1 to remove partial deployments" -Color "Yellow"
    Write-ColorOutput "  • Review logs in .\build-tests\logs\ for detailed error information" -Color "Yellow"
    Write-ColorOutput "  • For Azure AD replication issues, wait 5-10 minutes and retry" -Color "Yellow"
    
    # Provide specific guidance based on error message
    $errorMessage = $_.Exception.Message
    if ($errorMessage -like "*name*lowercase*") {
        Write-ColorOutput "`nStorage Account Naming Issue:" -Color "Red"
        Write-ColorOutput "  • Storage account names must be lowercase alphanumeric only (3-24 chars)" -Color "Yellow"
        Write-ColorOutput "  • Your lab name '$LabName' will be sanitized automatically" -Color "Yellow"
        Write-ColorOutput "  • Try using a simpler name like 'mytestlab' or 'lab001'" -Color "Yellow"
    }
    elseif ($errorMessage -like "*already exists*" -or $errorMessage -like "*duplicate*") {
        Write-ColorOutput "`nResource Already Exists:" -Color "Red"
        Write-ColorOutput "  • Run: .\build-tests\local-cleanup.ps1 -DeploymentType $DeploymentType" -Color "Yellow"
        Write-ColorOutput "  • Then retry this deployment" -Color "Yellow"
    }
    elseif ($errorMessage -like "*replication*" -or $errorMessage -like "*propagat*") {
        Write-ColorOutput "`nAzure AD Replication Issue:" -Color "Red"
        Write-ColorOutput "  • Wait 5-10 minutes for Azure AD to replicate changes" -Color "Yellow"
        Write-ColorOutput "  • Then run the same command again" -Color "Yellow"
    }
    
    exit 1
}
finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
    Set-Location $WORKSPACE_ROOT
}
