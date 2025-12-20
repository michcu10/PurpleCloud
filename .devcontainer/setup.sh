#!/bin/bash

# Exit on any error
set -e

echo "🚀 Setting up Azure Development Environment..."

# Update package list
sudo apt-get update

# Install additional dependencies
sudo apt-get install -y \
    curl \
    wget \
    unzip \
    jq \
    ca-certificates \
    gnupg \
    lsb-release

# Install Bicep
echo "📦 Installing Bicep..."
curl -Lo bicep https://github.com/Azure/bicep/releases/latest/download/bicep-linux-x64
chmod +x ./bicep
sudo mv ./bicep /usr/local/bin/bicep

# Install Azure PowerShell modules
echo "🔧 Installing Azure PowerShell modules..."
pwsh -Command "Install-Module -Name Az -Repository PSGallery -Force -AllowClobber"
pwsh -Command "Install-Module -Name Az.Bicep -Repository PSGallery -Force -AllowClobber"

# Create Azure config directory if it doesn't exist
mkdir -p /home/vscode/.azure

# Set proper permissions
sudo chown -R vscode:vscode /home/vscode/.azure

# Create a helper script for service principal login
cat > /home/vscode/login-with-sp.sh << 'EOF'
#!/bin/bash

# Check if required environment variables are set
if [ -z "$AZURE_CLIENT_ID" ] || [ -z "$AZURE_CLIENT_SECRET" ] || [ -z "$AZURE_TENANT_ID" ]; then
    echo "❌ Error: Required environment variables not set."
    echo "Please set the following environment variables:"
    echo "  - AZURE_CLIENT_ID (Service Principal Client ID)"
    echo "  - AZURE_CLIENT_SECRET (Service Principal Client Secret)"
    echo "  - AZURE_TENANT_ID (Azure Tenant ID)"
    echo ""
    echo "You can also set AZURE_SUBSCRIPTION_ID if you want to set a default subscription."
    exit 1
fi

echo "🔐 Logging in with Service Principal..."
echo "Client ID: ${AZURE_CLIENT_ID:0:8}..."
echo "Tenant ID: $AZURE_TENANT_ID"

# Check Azure CLI version
echo "Azure CLI version:"
az version --query 'azure-cli' -o tsv

# Login with service principal (with better error handling)
echo "Attempting login..."
if az login --service-principal \
    --username "$AZURE_CLIENT_ID" \
    --password "$AZURE_CLIENT_SECRET" \
    --tenant "$AZURE_TENANT_ID" \
    --allow-no-subscriptions; then

    echo "✅ Login successful!"

    # Set subscription if provided
    if [ ! -z "$AZURE_SUBSCRIPTION_ID" ]; then
        echo "📋 Setting subscription to: $AZURE_SUBSCRIPTION_ID"
        if az account set --subscription "$AZURE_SUBSCRIPTION_ID"; then
            echo "✅ Subscription set successfully"
        else
            echo "⚠️  Warning: Could not set subscription. You may need to set it manually."
        fi
    fi

    # Show current account info
    echo "Current account:"
    if az account show --query "{name:name, id:id, tenantId:tenantId}" -o table 2>/dev/null; then
        echo "✅ Account information retrieved successfully"
    else
        echo "⚠️  Warning: Could not retrieve account information"
        echo "Available subscriptions:"
        az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o table
    fi
else
    echo "❌ Login failed!"
    echo ""
    echo "Troubleshooting tips:"
    echo "1. Verify your service principal credentials are correct"
    echo "2. Check that the service principal has the correct permissions"
    echo "3. Ensure the service principal hasn't expired"
    echo "4. Try logging in manually:"
    echo "   az login --service-principal --username YOUR_CLIENT_ID --password YOUR_CLIENT_SECRET --tenant YOUR_TENANT_ID"
    echo ""
    echo "For more debugging, try:"
    echo "   az login --service-principal --username YOUR_CLIENT_ID --password YOUR_CLIENT_SECRET --tenant YOUR_TENANT_ID --debug"
    exit 1
fi
EOF

chmod +x /home/vscode/login-with-sp.sh

# Create PowerShell version of the login script
cat > /home/vscode/login-with-sp.ps1 << 'EOF'
# Check if required environment variables are set
if (-not $env:AZURE_CLIENT_ID -or -not $env:AZURE_CLIENT_SECRET -or -not $env:AZURE_TENANT_ID) {
    Write-Host "❌ Error: Required environment variables not set." -ForegroundColor Red
    Write-Host "Please set the following environment variables:" -ForegroundColor Yellow
    Write-Host "  - AZURE_CLIENT_ID (Service Principal Client ID)" -ForegroundColor Yellow
    Write-Host "  - AZURE_CLIENT_SECRET (Service Principal Client Secret)" -ForegroundColor Yellow
    Write-Host "  - AZURE_TENANT_ID (Azure Tenant ID)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "You can also set AZURE_SUBSCRIPTION_ID if you want to set a default subscription." -ForegroundColor Yellow
    exit 1
}

Write-Host "🔐 Logging in with Service Principal..." -ForegroundColor Green
Write-Host "Client ID: $($env:AZURE_CLIENT_ID.Substring(0,8))..." -ForegroundColor Cyan
Write-Host "Tenant ID: $env:AZURE_TENANT_ID" -ForegroundColor Cyan

# Check Azure PowerShell version
Write-Host "Azure PowerShell version:" -ForegroundColor Cyan
Get-Module -Name Az -ListAvailable | Select-Object Name, Version | Format-Table

# Login with service principal (with better error handling)
Write-Host "Attempting login..." -ForegroundColor Yellow
try {
    $credential = New-Object PSCredential($env:AZURE_CLIENT_ID, (ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force))
    Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $env:AZURE_TENANT_ID -ErrorAction Stop

    Write-Host "✅ Login successful!" -ForegroundColor Green

    # Set subscription if provided
    if ($env:AZURE_SUBSCRIPTION_ID) {
        Write-Host "📋 Setting subscription to: $env:AZURE_SUBSCRIPTION_ID" -ForegroundColor Green
        try {
            Set-AzContext -SubscriptionId $env:AZURE_SUBSCRIPTION_ID -ErrorAction Stop
            Write-Host "✅ Subscription set successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "⚠️  Warning: Could not set subscription. You may need to set it manually." -ForegroundColor Yellow
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # Show current account info
    Write-Host "Current account:" -ForegroundColor Green
    try {
        Get-AzContext | Select-Object Name, Account, Subscription, Tenant | Format-Table
        Write-Host "✅ Account information retrieved successfully" -ForegroundColor Green
    }
    catch {
        Write-Host "⚠️  Warning: Could not retrieve account information" -ForegroundColor Yellow
        Write-Host "Available subscriptions:" -ForegroundColor Cyan
        Get-AzSubscription | Select-Object Name, Id, State | Format-Table
    }
}
catch {
    Write-Host "❌ Login failed!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Troubleshooting tips:" -ForegroundColor Yellow
    Write-Host "1. Verify your service principal credentials are correct" -ForegroundColor White
    Write-Host "2. Check that the service principal has the correct permissions" -ForegroundColor White
    Write-Host "3. Ensure the service principal hasn't expired" -ForegroundColor White
    Write-Host "4. Try logging in manually:" -ForegroundColor White
    Write-Host "   Connect-AzAccount -ServicePrincipal -Credential YOUR_CREDENTIAL -Tenant YOUR_TENANT_ID" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "For more debugging, try:" -ForegroundColor Yellow
    Write-Host "   Connect-AzAccount -ServicePrincipal -Credential YOUR_CREDENTIAL -Tenant YOUR_TENANT_ID -Debug" -ForegroundColor Cyan
    exit 1
}
EOF

# Create a .env.example file
cat > /home/vscode/.env.example << 'EOF'
# Azure Service Principal Configuration
# Copy this file to .env and fill in your values

# Required: Service Principal Client ID
AZURE_CLIENT_ID=your-service-principal-client-id

# Required: Service Principal Client Secret
AZURE_CLIENT_SECRET=your-service-principal-client-secret

# Required: Azure Tenant ID
AZURE_TENANT_ID=your-azure-tenant-id

# Optional: Azure Subscription ID (if you want to set a default subscription)
AZURE_SUBSCRIPTION_ID=your-subscription-id

# Optional: Azure Resource Group (for convenience)
AZURE_RESOURCE_GROUP=your-resource-group-name

# Optional: Azure Location (for convenience)
AZURE_LOCATION=eastus
EOF

# Create a service principal creation guide
cat > /home/vscode/create-service-principal.md << 'EOF'
# Creating a Service Principal for Azure Dev Container

## Quick Commands

### 1. Get Your Subscription ID
```bash
az account show --query id -o tsv
```

### 2. Create Service Principal with Subscription Scope (Recommended)
```bash
az ad sp create-for-rbac \
  --name "dev-container-sp" \
  --role "Contributor" \
  --scopes "/subscriptions/YOUR_SUBSCRIPTION_ID"
```

### 3. Create Service Principal with Resource Group Scope (More Restrictive)
```bash
az ad sp create-for-rbac \
  --name "dev-container-sp" \
  --role "Contributor" \
  --scopes "/subscriptions/YOUR_SUBSCRIPTION_ID/resourceGroups/YOUR_RESOURCE_GROUP"
```

### 4. Create Service Principal with Reader Role (Read-Only)
```bash
az ad sp create-for-rbac \
  --name "dev-container-sp-reader" \
  --role "Reader" \
  --scopes "/subscriptions/YOUR_SUBSCRIPTION_ID"
```

## Output Format
The command will output JSON like this:
```json
{
  "appId": "12345678-1234-1234-1234-123456789012",
  "displayName": "dev-container-sp",
  "password": "your-secret-password",
  "tenant": "12345678-1234-1234-1234-123456789012"
}
```

## Security Notes
- Save the password immediately - it won't be shown again
- Use the most restrictive scope possible for your needs
- Consider using resource group scope instead of subscription scope
- Regularly rotate service principal secrets
EOF

# Create a README for the dev container
cat > /home/vscode/README.md << 'EOF'
# Azure Development Container

This dev container is configured with Azure CLI, Azure PowerShell, and Bicep for Azure development.

## 🛠️ Installed Tools

- **Azure CLI**: Latest version
- **Azure PowerShell**: Latest version with Az modules
- **Bicep**: Latest version
- **Git**: Latest version

## 🔐 Authentication

### Using Service Principal

1. **Create a service principal** (if you don't have one):
   ```bash
   # Get your subscription ID first
   az account show --query id -o tsv

   # Create service principal with subscription scope
   az ad sp create-for-rbac \
     --name "dev-container-sp" \
     --role "Contributor" \
     --scopes "/subscriptions/YOUR_SUBSCRIPTION_ID"
   ```

2. Set up your environment variables:
   ```bash
   cp .env.example .env
   # Edit .env with your service principal details
   ```

3. Login using the provided script:
   ```bash
   # Using bash
   ./login-with-sp.sh

   # Using PowerShell
   pwsh -File login-with-sp.ps1
   ```

### Required Environment Variables

- `AZURE_CLIENT_ID`: Your service principal client ID
- `AZURE_CLIENT_SECRET`: Your service principal client secret
- `AZURE_TENANT_ID`: Your Azure tenant ID
- `AZURE_SUBSCRIPTION_ID`: (Optional) Your Azure subscription ID

### Service Principal Scopes

**Subscription Scope** (recommended for development):
```bash
--scopes "/subscriptions/12345678-1234-1234-1234-123456789012"
```

**Resource Group Scope** (more restrictive):
```bash
--scopes "/subscriptions/12345678-1234-1234-1234-123456789012/resourceGroups/my-dev-rg"
```

## 📁 Useful Commands

```bash
# Check Azure CLI version
az version

# Check Bicep version
bicep --version

# Check PowerShell version
pwsh --version

# List Azure subscriptions
az account list

# Get current context
az account show
```

## 🔧 VS Code Extensions

The following extensions are automatically installed:
- Azure CLI Tools
- PowerShell
- Bicep
- Docker
- JSON Tools

## 📝 Notes

- Azure configuration is persisted in `/home/vscode/.azure`
- The container mounts your local Azure config directory for persistence
- Both bash and PowerShell terminals are available
EOF

echo "✅ Setup complete!"
echo ""
echo "🔧 Available tools:"
echo "  - Azure CLI: $(az version --query 'azure-cli' -o tsv)"
echo "  - Bicep: $(bicep --version)"
echo "  - PowerShell: $(pwsh --version)"
echo ""
echo "📖 Check /home/vscode/README.md for usage instructions"
echo "🔐 Use ./login-with-sp.sh to authenticate with your service principal"
echo "📋 Check /home/vscode/create-service-principal.md for service principal creation guide"
