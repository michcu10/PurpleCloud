# Troubleshooting Guide

## Recent Fixes (December 17, 2025)

### Azure AD Deployment Issues

#### Issues Addressed
1. **Provider Inconsistency Error** - Directory role assignments failing with "Root resource was present, but now absent"
2. **Group Timeout Errors** - Groups (Sales_Team, Executive_Team, Marketing_Team) timing out during display_name updates
3. **Azure AD Replication Delays** - Resources created but not immediately available for subsequent operations

#### Solutions Implemented

##### 1. Added Wait Times for Directory Role Assignments
- **Problem**: Directory roles were being assigned immediately after activation, causing the provider to not find the resource
- **Solution**: Added 30-second wait times (`time_sleep` resources) after each directory role activation
- **Affected Roles**:
  - Application Administrator
  - Privileged Role Administrator
  - Global Administrator

##### 2. Increased Group Operation Timeouts
- **Problem**: Groups were timing out at 45 minutes during Azure AD replication
- **Solution**: Increased timeouts to 60 minutes for all group operations (create, update, read, delete)
- **Additional Change**: Added `lifecycle { ignore_changes = [owners] }` to prevent unnecessary updates

##### 3. Added Explicit Dependencies
- **Problem**: Terraform was trying to create resources before dependencies were ready
- **Solution**: Added explicit `depends_on` blocks to ensure proper resource creation order

##### 4. Implemented Retry Logic in GitHub Actions
- **Problem**: Transient Azure AD issues causing workflow failures
- **Solution**: Added automatic retry mechanism (3 attempts with 60-second delays)
- **Benefit**: Handles temporary network issues and Azure AD backend delays

## Common Issues and Solutions

### Issue: "Provider produced inconsistent result after apply"

**Symptoms:**
```
Error: Provider produced inconsistent result after apply
When applying changes to azuread_directory_role_assignment.assign_ga,
provider "provider[\"registry.terraform.io/hashicorp/azuread\"]" produced an
unexpected new value: Root resource was present, but now absent.
```

**Root Cause:** Azure AD directory role was created but not yet replicated when Terraform tried to create the assignment.

**Solution:** The code now includes wait times after directory role activation. If you still encounter this:
1. Re-run the workflow - it often succeeds on the second attempt
2. Check Azure AD service health: https://status.azure.com/
3. Verify your service principal has proper permissions

### Issue: Group Update Timeouts

**Symptoms:**
```
Error: Waiting for update of `display_name` for group with object ID "..."
timeout while waiting for state to become 'Done' (last state: 'Waiting', timeout: 45m)
```

**Root Cause:** Azure AD backend experiencing delays in replicating group changes.

**Solutions:**
1. **Automated**: The workflow now retries automatically up to 3 times
2. **Manual Investigation**:
   ```bash
   # Check if the group was actually created in Azure
   az ad group list --filter "startswith(displayName,'MngEnvMCAP')"
   
   # Check the group's current state
   az ad group show --group <group-object-id>
   ```

3. **If groups exist but Terraform state is inconsistent**:
   ```bash
   cd generators/azure_ad
   terraform refresh
   terraform apply
   ```

### Issue: Terraform State Corruption

**Symptoms:** Resources exist in Azure but Terraform doesn't know about them.

**Solution:**
1. Download the state artifact from the failed GitHub Actions run
2. Extract the `terraform.tfstate` file
3. Import existing resources:
   ```bash
   # For a user
   terraform import azuread_user.user1 <user-object-id>
   
   # For a group
   terraform import azuread_group.Users <group-object-id>
   
   # For a directory role assignment
   terraform import azuread_directory_role_assignment.assign_ga <assignment-id>
   ```

## Performance Optimization

### Reducing Deployment Time

1. **Reduce User Count**: For testing, use fewer users (e.g., `-c 20` instead of `-c 100`)
2. **Reduce App Count**: Fewer applications = faster deployment
3. **Disable Privileged Roles**: If not needed for your test, skip `-aa -pra -ga` flags

### Monitoring Deployment Progress

The workflow now provides detailed logs. Watch for these indicators:

- ✅ **Good**: `azuread_user.user1: Creation complete after 2s`
- ✅ **Good**: `azuread_group.Users: Creation complete after 1m42s`
- ⚠️ **Warning**: `Still creating... [45m0s elapsed]` - Near timeout, may succeed
- ❌ **Error**: `timeout while waiting for state to become 'Done'` - Will retry

## Checking Deployment Status

### Via GitHub Actions UI
1. Go to Actions tab
2. Click on your workflow run
3. Expand "Terraform Apply - Azure AD" step
4. Look for resource creation messages

### Via Azure Portal
1. Navigate to Azure Active Directory
2. Check Users, Groups, and Applications sections
3. Verify resources match expected counts

### Via Azure CLI
```bash
# List all users in your tenant
az ad user list --query "[].displayName" -o table

# List all groups
az ad group list --query "[?startswith(displayName,'MngEnvMCAP')].[displayName,objectId]" -o table

# List all applications
az ad app list --query "[?startswith(displayName,'MngEnvMCAP')].[displayName,appId]" -o table

# Check specific group members
az ad group member list --group <group-name> --query "[].displayName" -o table
```

## Prevention Best Practices

1. **Test with Small Deployments First**: Use 20 users, 3 apps, 2 groups for initial testing
2. **Monitor Azure Service Health**: Check https://status.azure.com/ before large deployments
3. **Use Off-Peak Hours**: Deploy during periods of lower Azure AD activity
4. **Keep Terraform State Backed Up**: The workflow automatically saves state as artifacts
5. **Version Control Your Changes**: Always commit Terraform changes before re-running

## Getting Help

If issues persist after trying the above solutions:

1. **Check the logs**: Download the full workflow logs from GitHub Actions
2. **Verify permissions**: Ensure your service principal has:
   - `Application.ReadWrite.All`
   - `Group.ReadWrite.All`
   - `User.Read.All`
   - `RoleManagement.ReadWrite.Directory`
3. **Review Azure AD audit logs**: Check for any denied operations
4. **Open an issue**: Include the workflow run ID and relevant error messages

## Manual Cleanup

If you need to clean up resources manually:

```bash
# Delete all users created by the script
az ad user list --query "[?startswith(userPrincipalName,'<your-prefix>')].objectId" -o tsv | \
  xargs -I {} az ad user delete --id {}

# Delete all groups
az ad group list --query "[?startswith(displayName,'<your-prefix>')].objectId" -o tsv | \
  xargs -I {} az ad group delete --id {}

# Delete all apps
az ad app list --query "[?startswith(displayName,'<your-prefix>')].appId" -o tsv | \
  xargs -I {} az ad app delete --id {}
```

## Changes Summary

### Files Modified
1. **generators/azure_ad/azure_ad.py**:
   - Added `time_sleep` resources for directory role replication
   - Added explicit `depends_on` for role assignments
   - Increased group timeouts from 45m to 60m
   - Added lifecycle ignore_changes for group owners

2. **.github/workflows/deploy-zero-trust-lab.yml**:
   - Implemented automatic retry logic (3 attempts)
   - Increased lock timeout from 20m to 30m
   - Added plan refresh between retries

### Testing the Changes
```bash
# Generate a small test deployment
cd generators/azure_ad
python3 azure_ad.py -c 10 -u test.onmicrosoft.com --apps 2 --groups 2 -aa

# Review generated Terraform
cat users.tf
cat apps.tf  
cat groups.tf

# Look for the new time_sleep resources
grep -A 5 "time_sleep" *.tf
```
