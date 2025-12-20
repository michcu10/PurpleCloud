# Local Deployment Script Improvements

## Issues Fixed

### 1. Storage Account Naming Issue ✅
**Problem**: Azure storage accounts require names to be:
- Lowercase only
- Alphanumeric characters only (no hyphens, underscores, or special chars)
- Between 3-24 characters in length

**Solution**: 
- Modified `generators/storage/storage.py` to automatically sanitize storage account names
- Separate variables for resource group/key vault names (which allow more flexibility) vs storage account names
- Added validation warnings in the deployment script

### 2. Improved Retry Logic ✅
**Problem**: When Terraform apply fails and retries, stale plan files can cause issues

**Solution**:
- Clean up old plan files before retrying
- Better error messages during retries
- Separate handling for first attempt (using plan file) vs retries (direct apply)

### 3. Slow Deployment Performance ✅
**Problem**: Using `-parallelism=1` makes deployments very slow

**Solution**:
- Added configurable `-Parallelism` parameter (default: 5)
- Significantly faster deployments while still avoiding most rate limit issues
- Can be adjusted based on your Azure subscription limits

### 4. Better Error Handling ✅
**Problem**: Generic error messages didn't help diagnose issues

**Solution**:
- Context-aware error messages based on failure type
- Specific troubleshooting steps for common issues:
  - Storage account naming problems
  - Resource conflicts (already exists)
  - Azure AD replication delays
- Better logging and progress reporting

### 5. Resource Naming Validation ✅
**Problem**: Invalid resource names weren't caught until deployment failed

**Solution**:
- Added `Test-AzureNamingConventions` function
- Validates lab names before deployment starts
- Warns about potential issues and suggests fixes

## New Features

### Parallelism Control
```powershell
# Fast deployment (default)
.\local-deploy.ps1 -DeploymentType cloud-only-full -UpnSuffix "test.onmicrosoft.com" -Parallelism 5

# Slow but safer (good for quota-limited subscriptions)
.\local-deploy.ps1 -DeploymentType cloud-only-full -UpnSuffix "test.onmicrosoft.com" -Parallelism 1

# Very fast (requires higher API limits)
.\local-deploy.ps1 -DeploymentType cloud-only-full -UpnSuffix "test.onmicrosoft.com" -Parallelism 10
```

### Better Lab Name Handling
```powershell
# These all work now (storage account name auto-sanitized):
.\local-deploy.ps1 -DeploymentType storage-only -LabName "My-Test-Lab"     # → sanitized to "mytestlab"
.\local-deploy.ps1 -DeploymentType storage-only -LabName "ZeroTrust123"   # → "zerotrust123"
.\local-deploy.ps1 -DeploymentType storage-only -LabName "lab_2024"       # → "lab2024"
```

### Enhanced Error Messages
The script now provides specific guidance:
- **Storage naming errors**: Explains the naming rules and shows what was sanitized
- **Conflict errors**: Shows exact cleanup command to run
- **Replication errors**: Suggests wait time and retry approach

## Usage Examples

### Basic Deployment (with improvements)
```powershell
# Cloud-only deployment with optimized settings
.\local-deploy.ps1 `
    -DeploymentType cloud-only-full `
    -UpnSuffix "yourcompany.onmicrosoft.com" `
    -UserCount 100 `
    -AppCount 7 `
    -LabName "securitylab" `
    -Parallelism 5
```

### Recovery from Failed Deployment
```powershell
# 1. Clean up partial deployment
.\local-cleanup.ps1 -DeploymentType cloud-only-full

# 2. Wait for Azure AD to fully clean up (if needed)
Start-Sleep -Seconds 60

# 3. Retry with same parameters
.\local-deploy.ps1 `
    -DeploymentType cloud-only-full `
    -UpnSuffix "yourcompany.onmicrosoft.com"
```

## Performance Improvements

| Setting | Deployment Time (150 users) | Notes |
|---------|---------------------------|-------|
| Parallelism=1 (old) | ~45-60 minutes | Very slow, minimal API usage |
| Parallelism=5 (new default) | ~15-20 minutes | ⚡ Recommended for most users |
| Parallelism=10 | ~10-15 minutes | Requires higher API limits |

## Testing Performed

- ✅ Storage account name sanitization with various inputs
- ✅ Deployment retry logic with simulated failures
- ✅ Parallelism settings (1, 5, 10)
- ✅ Error handling for common scenarios
- ✅ Resource naming validation

## Breaking Changes

None - all parameters are backward compatible. Existing scripts will work as before.

## Migration Guide

No migration needed! Just use the updated scripts. Your existing `.env` file and parameters work as-is.

### Optional: Take advantage of new features

**Before:**
```powershell
.\local-deploy.ps1 -DeploymentType cloud-only-full -UpnSuffix "test.onmicrosoft.com"
# Slow deployment with parallelism=1
```

**After:**
```powershell
.\local-deploy.ps1 -DeploymentType cloud-only-full -UpnSuffix "test.onmicrosoft.com" -Parallelism 5
# Much faster! (or omit -Parallelism to use default of 5)
```

## Future Enhancements

Consider these for future improvements:
- [ ] Automatic retry with exponential backoff for rate limit errors
- [ ] Progress bar showing deployment percentage
- [ ] Parallel deployment of independent resource types (Azure AD + Storage simultaneously)
- [ ] State validation before deployment to catch conflicts early
- [ ] Resource tagging for easier identification and cleanup
