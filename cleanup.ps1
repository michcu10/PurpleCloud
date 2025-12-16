# PurpleCloud Zero Trust Lab Cleanup Script (PowerShell)
# This script safely destroys all Terraform resources
# Usage: .\cleanup.ps1 [options]

param(
    [switch]$All,
    [switch]$AzureAD,
    [switch]$ManagedIdentity,
    [switch]$Storage,
    [switch]$Orphaned,
    [switch]$DeleteState,
    [switch]$Force,
    [switch]$Help
)

# Color output functions
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )
    
    $prefix = switch ($Type) {
        "Success" { "[+]" }
        "Warning" { "[!]" }
        "Error" { "[-]" }
        "Info" { "[*]" }
        default { "[*]" }
    }
    
    $color = switch ($Type) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        "Info" { "Cyan" }
        default { "White" }
    }
    
    Write-Host "$prefix $Message" -ForegroundColor $color
}

# Check if Terraform is installed
function Test-Terraform {
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        Write-ColorOutput "Terraform is not installed. Please install Terraform first." "Error"
        Write-ColorOutput "Download from: https://www.terraform.io/downloads" "Info"
        exit 1
    }
    Write-ColorOutput "Terraform found: $(terraform version -json | ConvertFrom-Json | Select-Object -ExpandProperty terraform_version)" "Success"
}

# Check if Azure CLI is installed and logged in
function Test-AzureCLI {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-ColorOutput "Azure CLI not found. Orphaned resource cleanup will be skipped." "Warning"
        return $false
    }
    
    try {
        $null = az account show 2>$null
        Write-ColorOutput "Azure CLI authenticated" "Success"
        return $true
    }
    catch {
        Write-ColorOutput "Not logged into Azure CLI. Run 'az login' first." "Warning"
        return $false
    }
}

# Destroy a generator's resources
function Remove-GeneratorResources {
    param([string]$GeneratorPath)
    
    $generatorName = Split-Path $GeneratorPath -Leaf
    
    Write-Host ""
    Write-ColorOutput "========================================" "Info"
    Write-ColorOutput "Cleaning up $generatorName..." "Info"
    Write-ColorOutput "========================================" "Info"
    
    if (-not (Test-Path $GeneratorPath)) {
        Write-ColorOutput "Directory not found: $GeneratorPath" "Warning"
        return
    }
    
    Push-Location $GeneratorPath
    
    # Check if there are any .tf files
    $tfFiles = Get-ChildItem -Filter "*.tf" -ErrorAction SilentlyContinue
    if (-not $tfFiles) {
        Write-ColorOutput "No Terraform files found in $generatorName, skipping..." "Warning"
        Pop-Location
        return
    }
    
    # Check if terraform.tfstate exists
    if (-not (Test-Path "terraform.tfstate")) {
        Write-ColorOutput "No Terraform state found for $generatorName" "Warning"
        
        if (-not $Force) {
            $importState = Read-Host "Do you want to attempt to import existing state? (yes/no)"
            if ($importState -ne "yes") {
                Write-ColorOutput "Skipping $generatorName..." "Info"
                Pop-Location
                return
            }
        }
    }
    
    # Initialize Terraform
    Write-ColorOutput "Initializing Terraform..." "Info"
    $initResult = terraform init 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-ColorOutput "Failed to initialize Terraform for $generatorName" "Error"
        Write-ColorOutput $initResult "Error"
        Pop-Location
        return
    }
    
    # Show what will be destroyed
    Write-ColorOutput "Resources that will be destroyed:" "Warning"
    terraform show
    
    if (-not $Force) {
        Write-Host ""
        $confirm = Read-Host "Proceed with destroying $generatorName resources? (yes/no)"
        if ($confirm -ne "yes") {
            Write-ColorOutput "Skipping $generatorName..." "Info"
            Pop-Location
            return
        }
    }
    
    # Destroy resources
    Write-ColorOutput "Destroying $generatorName resources..." "Info"
    $destroyResult = terraform destroy -auto-approve 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-ColorOutput "$generatorName cleanup complete!" "Success"
    }
    else {
        Write-ColorOutput "Failed to destroy some $generatorName resources" "Error"
        Write-ColorOutput "You may need to manually delete resources in Azure Portal" "Warning"
        Write-ColorOutput $destroyResult "Error"
    }
    
    Pop-Location
}

# Clean up orphaned Azure resources
function Remove-OrphanedResources {
    if (-not (Test-AzureCLI)) {
        return
    }
    
    Write-Host ""
    Write-ColorOutput "========================================" "Info"
    Write-ColorOutput "Checking for orphaned Azure resources..." "Info"
    Write-ColorOutput "========================================" "Info"
    
    try {
        Write-ColorOutput "Searching for PurpleCloud resource groups..." "Info"
        $rgs = az group list --query "[?starts_with(name, 'PurpleCloud') || contains(name, 'ZeroTrust')].name" -o tsv
        
        if (-not $rgs) {
            Write-ColorOutput "No orphaned resource groups found." "Success"
            return
        }
        
        Write-ColorOutput "Found the following resource groups:" "Warning"
        $rgs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host ""
        
        if (-not $Force) {
            $confirm = Read-Host "Delete these resource groups? (yes/no)"
            if ($confirm -ne "yes") {
                Write-ColorOutput "Skipping orphaned resource cleanup" "Info"
                return
            }
        }
        
        $rgs | ForEach-Object {
            if ($_) {
                Write-ColorOutput "Deleting resource group: $_" "Info"
                az group delete --name $_ --yes --no-wait 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-ColorOutput "Deletion initiated for: $_" "Success"
                }
                else {
                    Write-ColorOutput "Failed to delete: $_" "Warning"
                }
            }
        }
        
        Write-ColorOutput "Resource group deletion initiated (running in background)" "Success"
        Write-ColorOutput "Use 'az group list' to check deletion progress" "Info"
    }
    catch {
        Write-ColorOutput "Error checking orphaned resources: $_" "Error"
    }
}

# Delete Terraform state files
function Remove-TerraformState {
    Write-Host ""
    Write-ColorOutput "========================================" "Warning"
    Write-ColorOutput "Delete Terraform State Files" "Warning"
    Write-ColorOutput "========================================" "Warning"
    Write-ColorOutput "This will delete all Terraform state files!" "Warning"
    Write-ColorOutput "You will NOT be able to manage resources with Terraform after this." "Warning"
    Write-Host ""
    
    if (-not $Force) {
        $confirm = Read-Host "Are you sure? Type 'DELETE' to confirm"
        if ($confirm -ne "DELETE") {
            Write-ColorOutput "Skipping state file deletion" "Info"
            return
        }
    }
    
    Write-ColorOutput "Deleting Terraform state files..." "Info"
    
    $stateFiles = Get-ChildItem -Path "generators\" -Recurse -Include "terraform.tfstate*","*.tfplan" -ErrorAction SilentlyContinue
    $terraformDirs = Get-ChildItem -Path "generators\" -Recurse -Directory -Filter ".terraform" -ErrorAction SilentlyContinue
    
    $stateFiles | Remove-Item -Force -ErrorAction SilentlyContinue
    $terraformDirs | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-ColorOutput "Terraform state files deleted!" "Success"
}

# Show help
function Show-Help {
    Write-Host @"

PurpleCloud Zero Trust Lab Cleanup Script
==========================================

Usage:
  .\cleanup.ps1 [options]

Options:
  -All              Clean up all resources (Azure AD + Managed Identity + Storage)
  -AzureAD          Clean up Azure AD resources only
  -ManagedIdentity  Clean up Managed Identity resources only
  -Storage          Clean up Storage resources only
  -Orphaned         Check for and delete orphaned Azure resource groups
  -DeleteState      Delete all Terraform state files
  -Force            Skip confirmation prompts
  -Help             Show this help message

Examples:
  .\cleanup.ps1 -All
  .\cleanup.ps1 -AzureAD -Storage
  .\cleanup.ps1 -All -Orphaned -DeleteState -Force
  .\cleanup.ps1 -Orphaned

Notes:
  - Terraform must be installed and in your PATH
  - Azure CLI is optional but recommended for orphaned resource cleanup
  - Use -Force to skip confirmation prompts (use with caution!)

"@ -ForegroundColor Cyan
    exit 0
}

# Main execution
function Main {
    # Show help if requested
    if ($Help) {
        Show-Help
    }
    
    # Show usage if no parameters
    if (-not ($All -or $AzureAD -or $ManagedIdentity -or $Storage -or $Orphaned -or $DeleteState)) {
        Write-ColorOutput "PurpleCloud Zero Trust Lab Cleanup Script" "Info"
        Write-Host ""
        Write-Host "No options specified. Use -Help to see available options." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Quick examples:" -ForegroundColor Cyan
        Write-Host "  .\cleanup.ps1 -All              # Clean everything" -ForegroundColor White
        Write-Host "  .\cleanup.ps1 -AzureAD          # Clean Azure AD only" -ForegroundColor White
        Write-Host "  .\cleanup.ps1 -Orphaned         # Check for orphaned resources" -ForegroundColor White
        Write-Host "  .\cleanup.ps1 -Help             # Show full help" -ForegroundColor White
        Write-Host ""
        exit 0
    }
    
    # Check prerequisites
    Test-Terraform
    
    Write-Host ""
    Write-ColorOutput "========================================" "Info"
    Write-ColorOutput "PurpleCloud Zero Trust Lab Cleanup" "Info"
    Write-ColorOutput "Location: $(Get-Location)" "Info"
    Write-ColorOutput "========================================" "Info"
    
    # Execute based on parameters
    if ($All -or $AzureAD) {
        Remove-GeneratorResources "generators\azure_ad"
    }
    
    if ($All -or $ManagedIdentity) {
        Remove-GeneratorResources "generators\managed_identity"
    }
    
    if ($All -or $Storage) {
        Remove-GeneratorResources "generators\storage"
    }
    
    if ($All -or $Orphaned) {
        Remove-OrphanedResources
    }
    
    if ($All -or $DeleteState) {
        Remove-TerraformState
    }
    
    Write-Host ""
    Write-ColorOutput "========================================" "Success"
    Write-ColorOutput "Cleanup process complete!" "Success"
    Write-ColorOutput "========================================" "Success"
    Write-Host ""
}

# Run the script
Main
