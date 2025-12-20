# Local Testing Scripts for PurpleCloud Deployments

This directory contains local debugging versions of the GitHub Actions deployment and cleanup workflows. These scripts allow you to test deployments and cleanup operations locally without needing to push to GitHub Actions.

## Overview

These scripts replicate the GitHub Actions workflows for local execution:

- **`local-deploy.ps1`** - Simulates the deployment workflow
- **`local-cleanup.ps1`** - Simulates the cleanup workflow

## Prerequisites

Before using these scripts, ensure you have the following installed:

1. **Azure CLI** - [Install guide](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
2. **Terraform** (v1.5.0 or later) - [Download](https://www.terraform.io/downloads)
3. **Python** (v3.8 or later) - [Download](https://www.python.org/downloads/)
4. **Python faker module** - `pip install faker`

### Authentication Setup

These scripts use **Service Principal authentication** (same as GitHub Actions) via a `.env` file.

#### Step 1: Create Service Principal

If you haven't already created a Service Principal for GitHub Actions, create one:

```powershell
# Login to Azure
az login

# Set your subscription
az account set --subscription "YOUR_SUBSCRIPTION_ID"

# Create service principal
az ad sp create-for-rbac `
  --name "PurpleCloud-GitHub-Actions" `
  --role "Owner" `
  --scopes /subscriptions/YOUR_SUBSCRIPTION_ID `
  --sdk-auth
```

**Save the output!** You'll need these values for your `.env` file.

#### Step 2: Configure .env File

1. Copy the example environment file:
   ```powershell
   Copy-Item .\build-tests\.env.example .\build-tests\.env
   ```

2. Edit `.env` and fill in your Service Principal credentials:
   ```bash
   ARM_CLIENT_ID=<clientId from sp output>
   ARM_CLIENT_SECRET=<clientSecret from sp output>
   ARM_SUBSCRIPTION_ID=<subscriptionId from sp output>
   ARM_TENANT_ID=<tenantId from sp output>
   ```

3. **Important**: The `.env` file is in `.gitignore` - never commit it to git!

#### Step 3: Grant Required Permissions

**Required Azure Permissions:**
- Subscription Owner role (for resource creation)
- Global Administrator role (for Azure AD operations)
- Microsoft Graph API permissions (for user/app creation)

See the main [GITHUB_ACTIONS.md](../GITHUB_ACTIONS.md) guide for detailed permission setup instructions.

**Pro Tip**: Use the **same Service Principal** for both GitHub Actions and local testing to ensure consistent behavior!

## Usage

### Deploy Resources Locally

#### Basic Cloud-Only Deployment

```powershell
.\build-tests\local-deploy.ps1 `
    -DeploymentType cloud-only-basic `
    -UpnSuffix "yourcompany.onmicrosoft.com"
```

#### Full Deployment with All Features

```powershell
.\build-tests\local-deploy.ps1 `
    -DeploymentType cloud-only-full `
    -UpnSuffix "yourcompany.onmicrosoft.com" `
    -UserCount 150 `
    -AppCount 10 `
    -LabName "MyZeroTrustLab" `
    -AzureLocation eastus `
    -EnablePrivilegedRoles
```

#### Azure AD Only

```powershell
.\build-tests\local-deploy.ps1 `
    -DeploymentType azure-ad-only `
    -UpnSuffix "test.onmicrosoft.com" `
    -UserCount 50 `
    -AppCount 5
```

#### Storage Only

```powershell
.\build-tests\local-deploy.ps1 `
    -DeploymentType storage-only `
    -UpnSuffix "test.onmicrosoft.com" `
    -LabName "StorageTest" `
    -AzureLocation westus
```

#### Managed Identity Only

```powershell
.\build-tests\local-deploy.ps1 `
    -DeploymentType managed-identity-only `
    -UpnSuffix "test.onmicrosoft.com" `
    -LabName "IdentityTest"
```

### Dry Run Mode

Test what would be deployed without making changes:

```powershell
.\build-tests\local-deploy.ps1 `
    -DeploymentType cloud-only-full `
    -UpnSuffix "test.onmicrosoft.com" `
    -DryRun
```

### Cleanup Resources Locally

#### Clean All Resources

```powershell
.\build-tests\local-cleanup.ps1 `
    -DeploymentType all `
    -ConfirmDestroy "DESTROY"
```

#### Clean Specific Component

```powershell
.\build-tests\local-cleanup.ps1 `
    -DeploymentType azure-ad-only `
    -ConfirmDestroy "DESTROY"
```

#### Full Cleanup (including state and orphaned resources)

```powershell
.\build-tests\local-cleanup.ps1 `
    -DeploymentType all `
    -ConfirmDestroy "DESTROY" `
    -CleanupOrphaned `
    -DeleteState
```

#### Force Cleanup (skip confirmations)

```powershell
.\build-tests\local-cleanup.ps1 `
    -DeploymentType all `
    -ConfirmDestroy "DESTROY" `
    -Force
```

#### Dry Run Cleanup

```powershell
.\build-tests\local-cleanup.ps1 `
    -DeploymentType all `
    -ConfirmDestroy "DESTROY" `
    -DryRun
```

## Parameters

### local-deploy.ps1 Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-DeploymentType` | Yes | - | Type of deployment (cloud-only-basic, cloud-only-full, azure-ad-only, storage-only, managed-identity-only) |
| `-UpnSuffix` | Yes | - | UPN suffix for users (e.g., company.onmicrosoft.com) |
| `-UserCount` | No | 100 | Number of Azure AD users to create |
| `-AppCount` | No | 7 | Number of Azure AD applications to create |
| `-EnablePrivilegedRoles` | No | $true | Enable privileged role assignments |
| `-LabName` | No | ZeroTrustLab | Name for the lab resources |
| `-AzureLocation` | No | eastus | Azure region (eastus, westus, centralus, etc.) |
| `-DryRun` | No | $false | Show what would be done without executing |
| `-SkipPrerequisiteCheck` | No | $false | Skip prerequisite validation |

### local-cleanup.ps1 Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-DeploymentType` | Yes | - | Type of deployment to clean (all, cloud-only-basic, cloud-only-full, azure-ad-only, storage-only, managed-identity-only) |
| `-ConfirmDestroy` | Yes* | - | Type "DESTROY" to confirm deletion |
| `-DeleteState` | No | $false | Delete Terraform state files |
| `-CleanupOrphaned` | No | $true | Clean up orphaned resource groups |
| `-Force` | No | $false | Skip confirmation prompts |
| `-DryRun` | No | $false | Show what would be done without executing |

*Required unless `-Force` is used

## Deployment Types

| Type | Azure AD | Storage | Managed Identity | Description |
|------|----------|---------|------------------|-------------|
| `cloud-only-basic` | ✓ | ✗ | ✗ | Azure AD users, apps, and groups only |
| `cloud-only-full` | ✓ | ✓ | ✓ | Complete cloud-only lab (recommended) |
| `azure-ad-only` | ✓ | ✗ | ✗ | Identity testing only |
| `managed-identity-only` | ✗ | ✓ | ✓ | Managed identity and RBAC testing |
| `storage-only` | ✗ | ✓ | ✗ | Storage access control testing |

## Examples

### Complete Workflow Example

```powershell
# 1. Deploy a full lab
.\build-tests\local-deploy.ps1 `
    -DeploymentType cloud-only-full `
    -UpnSuffix "mycompany.onmicrosoft.com" `
    -UserCount 200 `
    -LabName "ProdTest"

# 2. Test your audit scripts
# ... run your Zero Trust testing ...

# 3. Clean up everything
.\build-tests\local-cleanup.ps1 `
    -DeploymentType all `
    -ConfirmDestroy "DESTROY" `
    -CleanupOrphaned `
    -DeleteState
```

### Quick Test Cycle

```powershell
# Deploy minimal setup for quick testing
.\build-tests\local-deploy.ps1 `
    -DeploymentType azure-ad-only `
    -UpnSuffix "test.onmicrosoft.com" `
    -UserCount 20 `
    -AppCount 3

# Clean up when done
.\build-tests\local-cleanup.ps1 `
    -DeploymentType azure-ad-only `
    -ConfirmDestroy "DESTROY"
```

### Debugging Failed Deployment

```powershell
# Try dry run first to validate configuration
.\build-tests\local-deploy.ps1 `
    -DeploymentType cloud-only-full `
    -UpnSuffix "test.onmicrosoft.com" `
    -DryRun

# If dry run looks good, deploy for real
.\build-tests\local-deploy.ps1 `
    -DeploymentType cloud-only-full `
    -UpnSuffix "test.onmicrosoft.com"
```

## Features

### local-deploy.ps1 Features

- ✅ **Service Principal authentication** - Uses .env file (matches GitHub Actions)
- ✅ **Prerequisite checking** - Validates Azure CLI, Terraform, Python installation
- ✅ **Color-coded output** - Easy to read progress and status
- ✅ **Retry logic** - Automatic retries for transient Azure AD failures
- ✅ **Dry run mode** - Test without making changes
- ✅ **Deployment summary** - Complete report of created resources
- ✅ **Error handling** - Detailed error messages with stack traces

### local-cleanup.ps1 Features

- ✅ **Service Principal authentication** - Uses .env file (matches GitHub Actions)
- ✅ **Safety checks** - Requires explicit "DESTROY" confirmation
- ✅ **Orphan detection** - Finds and cleans PurpleCloud resource groups
- ✅ **State cleanup** - Optionally removes Terraform state files
- ✅ **Async deletion** - Uses Azure async deletion for speed
- ✅ **Cleanup summary** - Status report for all operations
- ✅ **Force mode** - Skip confirmations for automation

## Troubleshooting

### Common Issues

#### ".env file not found"

**Error message:**
```
.env file not found at: C:\temp\PurpleCloud\build-tests\.env
```

**Solution:**
```powershell
# Copy the example file
Copy-Item .\build-tests\.env.example .\build-tests\.env

# Edit .env and add your Service Principal credentials
notepad .\build-tests\.env
```

#### "Azure CLI not installed"

**Solution:**
```powershell
# Download and install Azure CLI from:
# https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
```

#### "Azure authentication failed"

**Error message:**
```
Azure login failed
```

**Solution:**
```powershell
# Verify your .env file has correct credentials
Get-Content .\build-tests\.env

# Test Service Principal manually
az login --service-principal `
  -u <ARM_CLIENT_ID> `
  -p <ARM_CLIENT_SECRET> `
  --tenant <ARM_TENANT_ID>
```

#### "Terraform not found"

**Solution:**
```powershell
# Download Terraform from: https://www.terraform.io/downloads
# Extract to a directory in your PATH
terraform --version  # Verify installation
```

#### "faker module not installed"

**Solution:**
```powershell
pip install faker
python -c "import faker; print(faker.__version__)"  # Verify
```

#### "UPN suffix domain not verified"

**Error message:**
```
The domain portion of the userPrincipalName property is invalid
```

**Solution:**
```powershell
# Use your tenant's default domain
az account show --query "tenantDefaultDomain" -o tsv

# Or list all verified domains
az rest --method GET `
  --uri "https://graph.microsoft.com/v1.0/domains" `
  --query "value[?isVerified].id" -o tsv

# Use one of these verified domains as -UpnSuffix
```

#### "Insufficient privileges"

**Solution:**
- Ensure you have Global Administrator role in Azure AD
- Verify Microsoft Graph API permissions are granted
- Check you have Subscription Owner role

See [GITHUB_ACTIONS.md](../GITHUB_ACTIONS.md) for detailed permission setup.

### Getting Debug Information

Enable verbose Terraform output:

```powershell
$env:TF_LOG = "DEBUG"
.\build-tests\local-deploy.ps1 -DeploymentType azure-ad-only -UpnSuffix "test.onmicrosoft.com"
```

Check Azure activity logs:

```powershell
# View recent Azure operations
az monitor activity-log list --max-events 50 -o table
```

## Differences from GitHub Actions

These local scripts replicate the GitHub Actions workflows with some differences:

| Feature | GitHub Actions | Local Scripts |
|---------|----------------|---------------|
| **State Storage** | Artifacts (30 days) | Local files in generator directories |
| **Credentials** | GitHub Secrets | .env file (same Service Principal) |
| **Parallelization** | Multiple jobs | Sequential execution |
| **Auto-destroy** | Scheduled workflow | Manual cleanup required |
| **Logs** | GitHub UI | Terminal output |
| **Environment** | Ubuntu runner | Local Windows/PowerShell |

## Best Practices

1. **Use the same Service Principal** as GitHub Actions for consistent testing
2. **Never commit .env file** - it contains secrets
3. **Always use dry run first** for new configurations
4. **Use verified domains** for UPN suffix (preferably .onmicrosoft.com)
5. **Start small** with azure-ad-only before full deployments
6. **Clean up promptly** to avoid unnecessary Azure costs
7. **Review output carefully** for errors or warnings
8. **Test in development** subscription first
9. **Rotate SP secrets regularly** (every 90 days recommended)

## Security Considerations

- **Never commit .env file** - It's in .gitignore, keep it that way!
- **Protect Service Principal secrets** - Same security as production credentials
- **Use same SP as GitHub Actions** - Ensures consistent permissions
- **Review permissions** before deploying
- **Monitor costs** - Use Azure Cost Management
- **Clean up regularly** - Don't leave test resources running
- **Use least privilege** - Only grant necessary permissions
- **Rotate secrets regularly** - Update .env and GitHub Secrets together

## Cost Management

Estimated costs for cloud-only-full deployment:

| Duration | Estimated Cost (East US) |
|----------|-------------------------|
| 1 hour | ~$0.02 |
| 8 hours | ~$0.16 |
| 24 hours | ~$0.50 |

**Cost optimization tips:**
- Clean up immediately after testing
- Use cloud-only deployments (no VMs)
- Choose cheaper regions (East US, Central US)
- Monitor with Azure Cost Management

## Next Steps

After successful local testing:

1. ✅ Deploy to GitHub Actions using [GITHUB_ACTIONS.md](../GITHUB_ACTIONS.md)
2. ✅ Configure GitHub Secrets
3. ✅ Set up automated deployments
4. ✅ Enable auto-destroy for temporary labs

## Support

For issues or questions:

1. Check [TROUBLESHOOTING.md](../TROUBLESHOOTING.md)
2. Review [GITHUB_ACTIONS.md](../GITHUB_ACTIONS.md)
3. Open an issue in the repository

---

**Happy Testing! 🚀**
