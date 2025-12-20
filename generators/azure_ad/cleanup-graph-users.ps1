param(
    [Parameter(Mandatory = $true, ParameterSetName = "CsvMode")]
    [string]$CsvFile,

    [Parameter(Mandatory = $true, ParameterSetName = "TaggedMode")]
    [switch]$CleanupAllTagged,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-ColorOutput {
    param([string]$Message, [string]$Color = "Reset")
    $colors = @{
        Reset = "`e[0m"; Red = "`e[31m"; Green = "`e[32m"; Yellow = "`e[33m"; Cyan = "`e[36m"
    }
    Write-Host "$($colors[$Color])$Message$($colors['Reset'])"
}

if ($PsCmdlet.ParameterSetName -eq "CsvMode" -and -not (Test-Path $CsvFile)) {
    Write-ColorOutput "CSV file not found: $CsvFile. Cannot clean up specific users." -Color "Yellow"
    exit 0
}

# Get Access Token
Write-ColorOutput "Getting Graph API Access Token..." -Color "Cyan"
if ($DryRun) {
    Write-ColorOutput "[DryRun] Would request access token"
    $headers = @{}
}
else {
    try {
        $token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
        if (-not $token) { throw "Failed to get access token" }
        $headers = @{
            "Authorization" = "Bearer $token"
            "Content-Type"  = "application/json"
        }
    }
    catch {
        throw "Failed to authenticate. Ensure 'az login' is run: $_"
    }
}

$usersToDelete = @()

if ($CleanupAllTagged) {
    Write-ColorOutput "Searching for users with jobTitle 'PurpleCloud-Managed'..." -Color "Cyan"
    
    if ($DryRun) {
        # Mock users for dry run
        $usersToDelete = @("user1@domain.com", "user2@domain.com")
        Write-ColorOutput "[DryRun] Found $(($usersToDelete.Count)) tagged users" -Color "Cyan"
    }
    else {
        $uri = "https://graph.microsoft.com/v1.0/users?`$filter=jobTitle eq 'PurpleCloud-Managed'&`$select=userPrincipalName"
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
            if ($response.value) {
                $usersToDelete = $response.value | ForEach-Object { $_.userPrincipalName }
            }
            Write-ColorOutput "Found $(($usersToDelete.Count)) tagged users" -Color "Cyan"
        }
        catch {
            throw "Failed to query tagged users: $_"
        }
    }
}
else {
    # Read Users from CSV
    $lines = Get-Content $CsvFile
    Write-ColorOutput "Found $(($lines.Count)) lines in CSV" -Color "Cyan"
    
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split ","
        if ($parts.Count -lt 3) { continue }
        $usersToDelete += $parts[2]
    }
}

$successCount = 0
$failCount = 0

foreach ($userPrincipalName in $usersToDelete) {
    $uri = "https://graph.microsoft.com/v1.0/users/$userPrincipalName"

    if ($DryRun) {
        Write-Host "[DryRun] Delete user: $userPrincipalName"
        $successCount++
    }
    else {
        try {
            Invoke-RestMethod -Uri $uri -Method Delete -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable "status" -ErrorVariable "requestError" | Out-Null
            
            if ($status -eq 204) {
                Write-ColorOutput "Deleted: $userPrincipalName" -Color "Green"
                $successCount++
            }
            elseif ($status -eq 404) {
                Write-ColorOutput "Not Found (already deleted): $userPrincipalName" -Color "Yellow"
            }
            else {
                Write-ColorOutput "Failed to delete: $userPrincipalName ($status)" -Color "Red"
                $failCount++
            }
        }
        catch {
            Write-ColorOutput "Error deleting $userPrincipalName : $_" -Color "Red"
            $failCount++
        }
    }
}

Write-ColorOutput "`nSummary:" -Color "Cyan"
Write-ColorOutput "  Deleted: $successCount" -Color "Green"
Write-ColorOutput "  Failed:  $failCount" -Color $(if ($failCount -gt 0) { "Red" }else { "Green" })
