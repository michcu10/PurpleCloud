#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Local cleanup script for debugging PurpleCloud Zero Trust Lab cleanup.

.DESCRIPTION
    This script simulates the GitHub Actions cleanup workflow locally for debugging purposes.
    It allows you to test cleanup operations without using GitHub Actions.

.PARAMETER DeploymentType
    Type of deployment to clean up.

.PARAMETER ConfirmDestroy
    Type "DESTROY" to confirm deletion.

.PARAMETER DeleteState
    Delete Terraform state files.

.PARAMETER CleanupOrphaned
    Clean up orphaned resource groups.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER DryRun
    Only show what would be done without executing.

.EXAMPLE
    .\local-cleanup.ps1 -DeploymentType all -ConfirmDestroy "DESTROY"

.EXAMPLE
    .\local-cleanup.ps1 -DeploymentType azure-ad-only -ConfirmDestroy "DESTROY" -DryRun

.EXAMPLE
    .\local-cleanup.ps1 -DeploymentType all -ConfirmDestroy "DESTROY" -CleanupOrphaned -DeleteState

.NOTES
    Prerequisites:
    - Azure CLI installed
    - Terraform installed
    - .env file with Service Principal credentials (copy from .env.example)
    - Service Principal with appropriate Azure permissions
    - Terraform state files exist in generator directories
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('all', 'cloud-only-basic', 'cloud-only-full', 'azure-ad-only', 'managed-identity-only', 'storage-only')]
    [string]$DeploymentType,

    [Parameter(Mandatory = $false)]
    [string]$ConfirmDestroy,

    [Parameter(Mandatory = $false)]
    [switch]$DeleteState,

    [Parameter(Mandatory = $false)]
    [switch]$CleanupOrphaned = $true,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Terraform', 'GraphAPI')]
    [string]$DeploymentMethod = "Terraform"
)

# Configuration
$ErrorActionPreference = "Stop"
$WORKSPACE_ROOT = Split-Path -Parent $PSScriptRoot
$ENV_FILE = Join-Path $PSScriptRoot ".env"

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

function Confirm-Destruction {
    if ($Force) {
        Write-Warning "Force flag set - skipping confirmation"
        return $true
    }

    if ($ConfirmDestroy -ne "DESTROY") {
        Write-ErrorMsg "Confirmation failed!"
        Write-ColorOutput "You must provide -ConfirmDestroy `"DESTROY`" to proceed" -Color "Red"
        Write-ColorOutput "You entered: '$ConfirmDestroy'" -Color "Red"
        return $false
    }
    
    Write-Success "Destroy confirmation validated"
    return $true
}

function Show-DestructionWarning {
    Write-Header "⚠️  DESTRUCTION WARNING"
    Write-ColorOutput "This will destroy Azure resources!" -Color "Red"
    Write-ColorOutput "`nConfiguration:" -Color "Yellow"
    Write-ColorOutput "  • Deployment Type: $DeploymentType" -Color "Yellow"
    Write-ColorOutput "  • Delete State: $DeleteState" -Color "Yellow"
    Write-ColorOutput "  • Cleanup Orphaned: $CleanupOrphaned" -Color "Yellow"
    
    if (-not $Force -and -not $DryRun) {
        Write-ColorOutput "`nPress any key to continue or Ctrl+C to cancel..." -Color "Red"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

function Remove-AzureADResources {
    Write-Header "🗑️  Destroying Azure AD Resources"
    
    $generatorPath = Join-Path $WORKSPACE_ROOT "generators\azure_ad"
    
    if (-not (Test-Path $generatorPath)) {
        Write-Warning "Azure AD generator path not found, skipping..."
        return
    }
    
    Set-Location $generatorPath
    
    if ($DeploymentMethod -eq "GraphAPI" -or (Test-Path "azure_users.csv")) {
        if (Test-Path "azure_users.csv") {
            Write-Step "Cleaning up users via Graph API (detected azure_users.csv)..."
            $graphCmd = "pwsh .\cleanup-graph-users.ps1 -CsvFile `"azure_users.csv`""
            if ($DryRun) { $graphCmd += " -DryRun" }
            
            Write-ColorOutput "  Command: $graphCmd" -Color "Cyan"
            Invoke-Expression $graphCmd
            Write-Success "Graph API cleanup completed"
        }
        elseif ($DeploymentMethod -eq "GraphAPI") {
            Write-Warning "DeploymentMethod set to GraphAPI but azure_users.csv not found at: $(Get-Location)"
        }
    }

    if ((Test-Path "terraform.tfstate") -or (Test-Path "users.tf")) {
        Write-Step "Initializing Terraform..."
        if (-not $DryRun) {
            terraform init
        }
        
        Write-Step "Destroying Azure AD resources..."
        if (-not $DryRun) {
            try {
                terraform destroy -auto-approve
                Write-Success "Azure AD cleanup complete"
            }
            catch {
                Write-Warning "Some resources may have already been deleted: $_"
            }
        }
        else {
            Write-ColorOutput "  [DRY RUN] Would run: terraform destroy -auto-approve" -Color "Cyan"
        }
    }
    else {
        Write-ColorOutput "ℹ️  No Azure AD state found, skipping..." -Color "Yellow"
    }
    
    Set-Location $WORKSPACE_ROOT
}

function Remove-StorageResources {
    Write-Header "🗑️  Destroying Storage Resources"
    
    $generatorPath = Join-Path $WORKSPACE_ROOT "generators\storage"
    
    if (-not (Test-Path $generatorPath)) {
        Write-Warning "Storage generator path not found, skipping..."
        return
    }
    
    Set-Location $generatorPath
    
    if ((Test-Path "terraform.tfstate") -or (Test-Path "storage.tf")) {
        Write-Step "Initializing Terraform..."
        if (-not $DryRun) {
            terraform init
        }
        
        Write-Step "Destroying Storage resources..."
        if (-not $DryRun) {
            try {
                terraform destroy -auto-approve
                Write-Success "Storage cleanup complete"
            }
            catch {
                Write-Warning "Some resources may have already been deleted: $_"
            }
        }
        else {
            Write-ColorOutput "  [DRY RUN] Would run: terraform destroy -auto-approve" -Color "Cyan"
        }
    }
    else {
        Write-ColorOutput "ℹ️  No Storage state found, skipping..." -Color "Yellow"
    }
    
    Set-Location $WORKSPACE_ROOT
}

function Remove-ManagedIdentityResources {
    Write-Header "🗑️  Destroying Managed Identity Resources"
    
    $generatorPath = Join-Path $WORKSPACE_ROOT "generators\managed_identity"
    
    if (-not (Test-Path $generatorPath)) {
        Write-Warning "Managed Identity generator path not found, skipping..."
        return
    }
    
    Set-Location $generatorPath
    
    if ((Test-Path "terraform.tfstate") -or (Test-Path "managed_identity.tf")) {
        Write-Step "Initializing Terraform..."
        if (-not $DryRun) {
            terraform init
        }
        
        Write-Step "Destroying Managed Identity resources..."
        if (-not $DryRun) {
            try {
                terraform destroy -auto-approve
                Write-Success "Managed Identity cleanup complete"
            }
            catch {
                Write-Warning "Some resources may have already been deleted: $_"
            }
        }
        else {
            Write-ColorOutput "  [DRY RUN] Would run: terraform destroy -auto-approve" -Color "Cyan"
        }
    }
    else {
        Write-ColorOutput "ℹ️  No Managed Identity state found, skipping..." -Color "Yellow"
    }
    
    Set-Location $WORKSPACE_ROOT
}

function Remove-OrphanedResources {
    Write-Header "🔍 Cleaning Orphaned Azure Resources"
    
    Write-Step "Searching for orphaned PurpleCloud resource groups..."
    
    try {
        if (-not $DryRun) {
            $orphanedRGs = az group list --query "[?starts_with(name, 'PurpleCloud') || contains(name, 'ZeroTrust')].name" -o tsv
        }
        else {
            Write-ColorOutput "  [DRY RUN] Would run: az group list --query ..." -Color "Cyan"
            $orphanedRGs = "PurpleCloud-Example-RG`nPurpleCloud-Test-RG"
        }
        
        if ([string]::IsNullOrWhiteSpace($orphanedRGs)) {
            Write-Success "No orphaned resource groups found"
            return
        }
        
        Write-Warning "Found orphaned resource groups:"
        $rgArray = $orphanedRGs -split "`n" | Where-Object { $_ -ne "" }
        $rgArray | ForEach-Object {
            Write-ColorOutput "  • $_" -Color "Yellow"
        }
        
        Write-Step "Deleting orphaned resource groups..."
        foreach ($rg in $rgArray) {
            if ([string]::IsNullOrWhiteSpace($rg)) { continue }
            
            Write-ColorOutput "  Deleting: $rg" -Color "Cyan"
            
            if (-not $DryRun) {
                try {
                    # Use --no-wait for async deletion
                    az group delete --name $rg --yes --no-wait
                    Write-Success "  Deletion initiated for: $rg"
                }
                catch {
                    Write-Warning "  Failed to delete $rg : $_"
                }
            }
            else {
                Write-ColorOutput "  [DRY RUN] Would delete: $rg" -Color "Cyan"
            }
        }
        
        Write-Success "Orphaned resource group deletion initiated (async)"
        
        # Verify cleanup
        if (-not $DryRun) {
            Write-Step "Waiting for deletion to process..."
            Start-Sleep -Seconds 10
            
            $remaining = az group list --query "[?starts_with(name, 'PurpleCloud') || contains(name, 'ZeroTrust')].name" -o tsv
            
            if ([string]::IsNullOrWhiteSpace($remaining)) {
                Write-Success "All PurpleCloud resource groups cleaned up"
            }
            else {
                Write-Warning "Some resource groups may still be deleting (async operation)"
                az group list --query "[?starts_with(name, 'PurpleCloud') || contains(name, 'ZeroTrust')].[name,properties.provisioningState]" -o table
            }
        }
        
    }
    catch {
        Write-ErrorMsg "Error during orphaned resource cleanup: $_"
    }
}

function Remove-TerraformState {
    Write-Header "🗑️  Deleting Terraform State Files"
    
    $stateFiles = @(
        "generators\azure_ad\terraform.tfstate*",
        "generators\storage\terraform.tfstate*",
        "generators\managed_identity\terraform.tfstate*",
        "generators\azure_ad\.terraform*",
        "generators\storage\.terraform*",
        "generators\managed_identity\.terraform*",
        "generators\azure_ad\*.tfplan",
        "generators\storage\*.tfplan",
        "generators\managed_identity\*.tfplan"
    )
    
    $deletedCount = 0
    
    foreach ($pattern in $stateFiles) {
        $fullPath = Join-Path $WORKSPACE_ROOT $pattern
        $files = Get-ChildItem -Path $fullPath -Recurse -Force -ErrorAction SilentlyContinue
        
        foreach ($file in $files) {
            Write-ColorOutput "  Deleting: $($file.FullName)" -Color "Cyan"
            
            if (-not $DryRun) {
                try {
                    Remove-Item -Path $file.FullName -Recurse -Force
                    $deletedCount++
                }
                catch {
                    Write-Warning "  Failed to delete $($file.FullName): $_"
                }
            }
            else {
                Write-ColorOutput "  [DRY RUN] Would delete: $($file.FullName)" -Color "Cyan"
                $deletedCount++
            }
        }
    }
    
    if ($deletedCount -gt 0) {
        Write-Success "Deleted $deletedCount Terraform state file(s)"
    }
    else {
        Write-ColorOutput "ℹ️  No Terraform state files found" -Color "Yellow"
    }
}

function Show-CleanupSummary {
    param(
        [hashtable]$Results,
        [datetime]$StartTime
    )
    
    $duration = (Get-Date) - $StartTime
    
    Write-Header "🧹 Cleanup Summary"
    
    Write-ColorOutput "`nConfiguration:" -Color "Bold"
    Write-ColorOutput "  • Deployment Type: $DeploymentType" -Color "Cyan"
    Write-ColorOutput "  • Delete State: $DeleteState" -Color "Cyan"
    Write-ColorOutput "  • Cleanup Orphaned: $CleanupOrphaned" -Color "Cyan"
    Write-ColorOutput "  • Cleanup Time: $($duration.ToString('hh\:mm\:ss'))" -Color "Cyan"
    Write-ColorOutput "  • Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')" -Color "Cyan"
    
    Write-ColorOutput "`nJobs Status:" -Color "Bold"
    foreach ($job in $Results.Keys) {
        $status = $Results[$job]
        $color = if ($status -eq "Success") { "Green" } elseif ($status -eq "Skipped") { "Yellow" } else { "Red" }
        Write-ColorOutput "  • $job : $status" -Color $color
    }
    
    Write-Success "`n✅ Cleanup Complete"
    Write-ColorOutput "All specified resources have been processed." -Color "Cyan"
}

# ============================================================
# Main Execution
# ============================================================

try {
    $startTime = Get-Date
    $results = @{}
    
    Write-Header "PurpleCloud Local Cleanup Script"
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
    
    # Validate confirmation
    if (-not (Confirm-Destruction)) {
        exit 1
    }
    
    # Show warning
    Show-DestructionWarning
    
    # Determine which components to clean based on deployment type
    $cleanAzureAD = $DeploymentType -in @('all', 'cloud-only-basic', 'cloud-only-full', 'azure-ad-only')
    $cleanStorage = $DeploymentType -in @('all', 'cloud-only-full', 'storage-only')
    $cleanManagedIdentity = $DeploymentType -in @('all', 'cloud-only-full', 'managed-identity-only')
    
    # Execute cleanup
    if ($cleanAzureAD) {
        try {
            Remove-AzureADResources
            $results["Azure AD Cleanup"] = "Success"
        }
        catch {
            Write-ErrorMsg "Azure AD cleanup failed: $_"
            $results["Azure AD Cleanup"] = "Failed"
        }
    }
    else {
        $results["Azure AD Cleanup"] = "Skipped"
    }
    
    if ($cleanStorage) {
        try {
            Remove-StorageResources
            $results["Storage Cleanup"] = "Success"
        }
        catch {
            Write-ErrorMsg "Storage cleanup failed: $_"
            $results["Storage Cleanup"] = "Failed"
        }
    }
    else {
        $results["Storage Cleanup"] = "Skipped"
    }
    
    if ($cleanManagedIdentity) {
        try {
            Remove-ManagedIdentityResources
            $results["Managed Identity Cleanup"] = "Success"
        }
        catch {
            Write-ErrorMsg "Managed Identity cleanup failed: $_"
            $results["Managed Identity Cleanup"] = "Failed"
        }
    }
    else {
        $results["Managed Identity Cleanup"] = "Skipped"
    }
    
    # Clean orphaned resources
    if ($CleanupOrphaned) {
        try {
            Remove-OrphanedResources
            $results["Orphaned Resources Cleanup"] = "Success"
        }
        catch {
            Write-ErrorMsg "Orphaned resources cleanup failed: $_"
            $results["Orphaned Resources Cleanup"] = "Failed"
        }
    }
    else {
        $results["Orphaned Resources Cleanup"] = "Skipped"
    }
    
    # Delete state files
    if ($DeleteState) {
        try {
            Remove-TerraformState
            $results["State Deletion"] = "Success"
        }
        catch {
            Write-ErrorMsg "State deletion failed: $_"
            $results["State Deletion"] = "Failed"
        }
    }
    else {
        $results["State Deletion"] = "Skipped"
    }
    
    # Show summary
    Show-CleanupSummary -Results $results -StartTime $startTime
    
}
catch {
    Write-ErrorMsg "`n❌ Cleanup failed: $_"
    Write-ColorOutput $_.ScriptStackTrace -Color "Red"
    exit 1
}
finally {
    Set-Location $WORKSPACE_ROOT
}
