# GitHub Actions Automation - PurpleCloud Zero Trust Lab

This guide explains how to automate deployment and cleanup of your PurpleCloud Zero Trust Lab using GitHub Actions.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Initial Setup](#initial-setup)
- [Deployment Options](#deployment-options)
- [Using GitHub Actions](#using-github-actions)
- [Local Cleanup Scripts](#local-cleanup-scripts)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before using GitHub Actions automation, you need:

1. **Azure Subscription** with sufficient permissions
2. **GitHub Repository** (fork or clone PurpleCloud)
3. **Azure Service Principal** with appropriate roles
4. **Git LFS** installed (for large files in the repository)

---

## Initial Setup

### Step 1: Create Azure Service Principal

Create a Service Principal with the necessary permissions:

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

**Important:** Save the JSON output - you'll need it in the next step.

The output should look like:
```json
{
  "clientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "clientSecret": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "activeDirectoryEndpointUrl": "https://login.microsoftonline.com",
  "resourceManagerEndpointUrl": "https://management.azure.com/",
  "activeDirectoryGraphResourceId": "https://graph.windows.net/",
  "sqlManagementEndpointUrl": "https://management.core.windows.net:8443/",
  "galleryEndpointUrl": "https://gallery.azure.com/",
  "managementEndpointUrl": "https://management.core.windows.net/"
}
```

### Step 2: Configure Service Principal Permissions

#### For Azure AD Operations

Assign additional permissions for Azure AD:

```powershell
# Get the Service Principal Object ID
$SP_OBJECT_ID = az ad sp list --display-name "PurpleCloud-GitHub-Actions" --query "[0].id" -o tsv

# Assign Global Administrator role (required for Azure AD user/app creation)
# Note: You must be a Global Administrator to run this
az rest --method POST `
  --uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" `
  --body "{`"principalId`": `"$SP_OBJECT_ID`", `"roleDefinitionId`": `"62e90394-69f5-4237-9190-012177145e10`", `"directoryScopeId`": `"/`"}"
```

#### For Microsoft Graph API

Add Microsoft Graph API permissions:

```powershell
# Get Service Principal App ID
$APP_ID = az ad sp list --display-name "PurpleCloud-GitHub-Actions" --query "[0].appId" -o tsv

# Add Graph API permissions
az ad app permission add `
  --id $APP_ID `
  --api 00000003-0000-0000-c000-000000000000 `
  --api-permissions `
    1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9=Role `
    df021288-bdef-4463-88db-98f22de89214=Role `
    62a82d76-70ea-41e2-9197-370581804d09=Role

# Grant admin consent
az ad app permission admin-consent --id $APP_ID
```

**Permissions Added:**
- `Application.ReadWrite.All` - Create/manage applications
- `User.ReadWrite.All` - Create/manage users
- `Group.ReadWrite.All` - Create/manage groups

#### For Sentinel (Optional)

If using the Sentinel generator, add special permission for Azure AD diagnostic settings:

```powershell
az role assignment create `
  --assignee-principal-type ServicePrincipal `
  --assignee-object-id $SP_OBJECT_ID `
  --scope "/providers/Microsoft.aadiam" `
  --role "b24988ac-6180-42a0-ab88-20f7382dd24c"
```

### Step 3: Configure GitHub Secrets

Add the following secrets to your GitHub repository:

1. Go to your GitHub repository
2. Navigate to **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret** and add each of these:

| Secret Name | Value | Description |
|-------------|-------|-------------|
| `AZURE_CLIENT_ID` | From JSON output | Service Principal Client ID |
| `AZURE_CLIENT_SECRET` | From JSON output | Service Principal Client Secret |
| `AZURE_SUBSCRIPTION_ID` | From JSON output | Azure Subscription ID |
| `AZURE_TENANT_ID` | From JSON output | Azure Tenant ID |

**Screenshot guide:**
```
Settings → Secrets and variables → Actions → New repository secret
```

---

## Deployment Options

The GitHub Actions workflow supports several deployment types optimized for Zero Trust testing:

### Cloud-Only Deployments (No VMs)

#### 1. **cloud-only-basic**
- Azure AD users (100 default)
- Azure AD applications (7 default)
- Azure AD groups (4 default)
- Optional privileged role assignments

**Best for:** Pure identity and access testing

#### 2. **cloud-only-full** (Recommended)
- Everything in `cloud-only-basic`
- Azure Storage Account with containers and blobs
- Azure Key Vault with secrets, keys, and certificates
- User-Assigned Managed Identity (Owner role)
- System-Assigned Managed Identity
- File shares with sample data

**Best for:** Comprehensive Zero Trust audit scenarios

### Individual Component Deployments

#### 3. **azure-ad-only**
- Only Azure AD users, apps, and groups
- Ideal for identity-focused testing

#### 4. **managed-identity-only**
- Managed identities with RBAC
- Storage and Key Vault resources
- Testing managed identity permissions

#### 5. **storage-only**
- Storage accounts and containers
- Testing data access controls

---

## Using GitHub Actions

### Deploy a Lab Environment

1. Go to the **Actions** tab in your GitHub repository
2. Select **"Deploy Zero Trust Lab"** workflow
3. Click **"Run workflow"**
4. Configure the deployment:

**Example Configuration for Cloud-Only Testing:**
```yaml
Deployment Type: cloud-only-full
User Count: 150
App Count: 10
UPN Suffix: yourcompany.com
Enable Privileged Roles: ✓ (checked)
Lab Name: ZeroTrustAudit
Azure Location: eastus
Auto-destroy Hours: 8 (0 for manual cleanup)
```

5. Click **"Run workflow"**

### Monitor Deployment

- Watch the workflow progress in the Actions tab
- Each step shows real-time logs
- Deployment typically takes 10-15 minutes
- Check the workflow summary for deployment details

### Deployment Summary

After deployment completes, you'll see a summary with:
- Deployment ID
- Resource groups created
- Number of users/apps created
- Timestamp
- Next steps

---

## Clean Up Resources

### Option 1: GitHub Actions Cleanup (Recommended)

1. Go to **Actions** tab
2. Select **"Cleanup Zero Trust Lab"** workflow
3. Click **"Run workflow"**
4. Configure cleanup:

```yaml
Deployment Type: all (or specific component)
Confirm Destroy: DESTROY
Delete State: ✓ (recommended)
Cleanup Orphaned: ✓ (recommended)
```

5. Click **"Run workflow"**

**Important:** You must type `DESTROY` exactly to confirm deletion.

### Option 2: Local Cleanup Scripts

#### Linux/Mac (Bash)

```bash
# Make the script executable
chmod +x cleanup.sh

# Run interactive cleanup
./cleanup.sh

# Or use directly with menu options:
# 1 - Clean Azure AD only
# 2 - Clean Managed Identity only
# 3 - Clean Storage only
# 4 - Clean ALL resources
# 5 - Check for orphaned resources
# 6 - Delete Terraform state files
# 7 - Full cleanup (everything)
```

#### Windows (PowerShell)

```powershell
# Run with specific options
.\cleanup.ps1 -All

# Clean specific components
.\cleanup.ps1 -AzureAD -Storage

# Full cleanup without prompts
.\cleanup.ps1 -All -Orphaned -DeleteState -Force

# Check orphaned resources only
.\cleanup.ps1 -Orphaned

# Show help
.\cleanup.ps1 -Help
```

**PowerShell Parameters:**
- `-All` - Clean all resources
- `-AzureAD` - Clean Azure AD only
- `-ManagedIdentity` - Clean Managed Identity only
- `-Storage` - Clean Storage only
- `-Orphaned` - Check for orphaned resource groups
- `-DeleteState` - Delete Terraform state files
- `-Force` - Skip confirmation prompts
- `-Help` - Show help message

---

## Workflow Details

### Deploy Workflow Features

- **Parallel Execution:** Independent resources deploy simultaneously
- **State Management:** Terraform state saved as artifacts (30-day retention)
- **Error Handling:** Continue-on-error for resilient deployments
- **Auto-Destroy:** Optional scheduled cleanup after X hours
- **Resource Tracking:** Captures all created resource groups
- **Detailed Logging:** Complete deployment logs available

### Cleanup Workflow Features

- **Safety Checks:** Requires explicit "DESTROY" confirmation
- **Orphan Detection:** Finds PurpleCloud resource groups not in Terraform state
- **State Cleanup:** Optionally removes all Terraform state artifacts
- **Parallel Cleanup:** Destroys resources concurrently for speed
- **Async Deletion:** Azure resource groups deleted in background

---

## Example Usage Scenarios

### Scenario 1: Quick Identity Audit

```yaml
# Deploy
Deployment Type: azure-ad-only
User Count: 50
App Count: 5
UPN Suffix: testcompany.com
Enable Privileged Roles: Yes

# Test your audit script
# Run Zero Trust audit tools
# Check for overprivileged identities

# Cleanup
Deployment Type: azure-ad-only
Confirm Destroy: DESTROY
```

### Scenario 2: Full Zero Trust Lab (8 hours)

```yaml
# Deploy
Deployment Type: cloud-only-full
User Count: 200
App Count: 10
UPN Suffix: megacorp.com
Enable Privileged Roles: Yes
Auto-destroy Hours: 8

# Runs for 8 hours then auto-cleans
```

### Scenario 3: Managed Identity Testing

```yaml
# Deploy
Deployment Type: managed-identity-only
Lab Name: ManagedIdentityTest
UPN Suffix: company.com

# Test RBAC and managed identity permissions
# Audit Key Vault access
# Check storage permissions

# Cleanup manually when done
```

---

## Cost Management

### Estimated Costs (cloud-only-full)

Based on East US pricing (December 2025):

| Resource | Estimated Cost/Hour | Estimated Cost/Day |
|----------|---------------------|-------------------|
| Azure AD (Free Tier) | $0 | $0 |
| Storage Account | ~$0.01 | ~$0.24 |
| Key Vault | ~$0.01 | ~$0.24 |
| Managed Identities | $0 | $0 |
| **Total** | **~$0.02/hour** | **~$0.50/day** |

### Cost Optimization Tips

1. **Use Auto-Destroy:** Set `auto_destroy_hours` to automatically clean up
2. **Choose Regions Wisely:** East US and Central US are typically cheaper
3. **Cloud-Only Deployments:** Avoid VM-based generators for cost savings
4. **Monitor Usage:** Check Azure Cost Management regularly
5. **Clean Up Promptly:** Don't forget to run cleanup after testing

---

## Troubleshooting

### Common Issues

#### 1. "Authentication Failed"

**Problem:** Terraform can't authenticate with Azure

**Solution:**
```powershell
# Verify secrets are set correctly
# Check service principal permissions
az login
az account show
```

#### 2. "Insufficient Privileges"

**Problem:** Service Principal lacks permissions

**Solution:**
- Ensure Global Administrator role is assigned
- Verify Graph API permissions are granted
- Check subscription Owner role

#### 3. "Resource Already Exists"

**Problem:** Previous deployment wasn't fully cleaned

**Solution:**
```powershell
# Check for orphaned resources
.\cleanup.ps1 -Orphaned

# Or manually delete in Azure Portal
az group list --query "[?starts_with(name, 'PurpleCloud')]"
az group delete --name <resource-group-name> --yes
```

#### 4. "Terraform State Conflicts"

**Problem:** Multiple deployments using same state

**Solution:**
- Each workflow run creates a unique state artifact
- Download specific state artifact if needed
- Or delete all state and redeploy

#### 5. "Workflow Fails on User Creation"

**Problem:** UPN suffix doesn't match tenant

**Solution:**
- Use your verified domain (e.g., `company.onmicrosoft.com`)
- Or add custom domain to Azure AD first
- Check tenant domain: 
  ```powershell
  az account show --query "tenantDefaultDomain"
  ```

### Getting Help

If you encounter issues:

1. **Check workflow logs** in GitHub Actions tab
2. **Review Azure Activity Log** in Azure Portal
3. **Verify service principal permissions**
4. **Check Terraform state** for conflicts
5. **Open an issue** in the PurpleCloud repository

---

## Security Best Practices

### Secrets Management

- **Never commit secrets** to your repository
- **Rotate secrets regularly** (every 90 days recommended)
- **Use environment protection** in GitHub for production
- **Enable secret scanning** in repository settings
- **Audit secret usage** in GitHub Actions logs

### Service Principal Security

- **Principle of Least Privilege:** Only grant necessary permissions
- **Conditional Access:** Apply policies to service principals
- **Monitor Activity:** Review sign-in logs regularly
- **Limit Scope:** Use resource group scoped permissions when possible
- **Rotate Credentials:** Change secrets every 90 days

### Cleanup Verification

Always verify cleanup completion:

```powershell
# Check for remaining resources
az group list --query "[?starts_with(name, 'PurpleCloud')]" -o table

# Check for orphaned managed identities
az identity list -o table

# Check for orphaned applications
az ad app list --query "[?displayName contains 'PurpleCloud']" -o table
```

---

## Advanced Configuration

### Customizing Deployment

Edit `.github/workflows/deploy-zero-trust-lab.yml` to:

- Add custom Terraform variables
- Modify deployment timeouts
- Add post-deployment scripts
- Integrate with other tools

### Adding Custom Resources

Create custom Terraform in generator directories:

```powershell
cd generators/azure_ad
# Edit users.tf or create custom_rbac.tf
# Commit changes
# GitHub Actions will use updated Terraform
```

### Integration with CI/CD

Example: Trigger on Pull Request

```yaml
on:
  pull_request:
    branches: [main]
  workflow_dispatch:
```

---

## Quick Reference

### GitHub Actions Workflows

| Workflow | File | Purpose |
|----------|------|---------|
| Deploy Zero Trust Lab | `deploy-zero-trust-lab.yml` | Deploy resources |
| Cleanup Zero Trust Lab | `cleanup-resources.yml` | Destroy resources |

### Cleanup Scripts

| Platform | Script | Usage |
|----------|--------|-------|
| Linux/Mac | `cleanup.sh` | `./cleanup.sh` |
| Windows | `cleanup.ps1` | `.\cleanup.ps1 -All` |

### Deployment Types

| Type | Azure AD | Storage | Managed ID | VMs |
|------|----------|---------|------------|-----|
| cloud-only-basic | ✓ | ✗ | ✗ | ✗ |
| cloud-only-full | ✓ | ✓ | ✓ | ✗ |
| azure-ad-only | ✓ | ✗ | ✗ | ✗ |
| managed-identity-only | ✗ | ✓ | ✓ | ✗ |
| storage-only | ✗ | ✓ | ✗ | ✗ |

---

## Next Steps

1. ✅ Complete the [Initial Setup](#initial-setup)
2. ✅ Configure GitHub Secrets
3. ✅ Run your first deployment with `cloud-only-basic`
4. ✅ Test your Zero Trust audit scripts
5. ✅ Clean up resources
6. ✅ Deploy `cloud-only-full` for comprehensive testing

**Happy Testing! 🚀**

For more information, see the main [PurpleCloud README](../README.md).
