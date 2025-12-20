param(
    [Parameter(Mandatory=$true)]
    [string]$CsvFile,

    [Parameter(Mandatory=$false)]
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

if (-not (Test-Path $CsvFile)) {
    Write-ColorOutput "CSV file not found: $CsvFile. Cannot clean up specific users." -Color "Yellow"
    exit 0
}

# Get Access Token
Write-ColorOutput "Getting Graph API Access Token..." -Color "Cyan"
if ($DryRun) {
    Write-ColorOutput "[DryRun] Would request access token"
    $headers = @{}
} else {
    try {
        $token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
        if (-not $token) { throw "Failed to get access token" }
        $headers = @{
            "Authorization" = "Bearer $token"
            "Content-Type"  = "application/json"
        }
    } catch {
        throw "Failed to authenticate. Ensure 'az login' is run: $_"
    }
}

# Read Users
$users = Get-Content $CsvFile
Write-ColorOutput "Found $(($users.Count)) users to process" -Color "Cyan"

$successCount = 0
$failCount = 0

foreach ($line in $users) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    
    # helper for CSV format: Free Guy,freeguy,freeguy@domain.com
    $parts = $line -split ","
    if ($parts.Count -lt 3) { continue }
    
    $userPrincipalName = $parts[2]
    $uri = "https://graph.microsoft.com/v1.0/users/$userPrincipalName"

    if ($DryRun) {
        Write-Host "[DryRun] Delete user: $userPrincipalName"
        $successCount++
    } else {
        try {
            Invoke-RestMethod -Uri $uri -Method Delete -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable "status" -ErrorVariable "requestError" | Out-Null
            
            if ($status -eq 204) {
                Write-ColorOutput "Deleted: $userPrincipalName" -Color "Green"
                $successCount++
            } elseif ($status -eq 404) {
                Write-ColorOutput "Not Found (already deleted): $userPrincipalName" -Color "Yellow"
            } else {
                 Write-ColorOutput "Failed to delete: $userPrincipalName ($status)" -Color "Red"
                 $failCount++
            }
        } catch {
            Write-ColorOutput "Error deleting $userPrincipalName : $_" -Color "Red"
            $failCount++
        }
    }
}

Write-ColorOutput "`nSummary:" -Color "Cyan"
Write-ColorOutput "  Deleted: $successCount" -Color "Green"
Write-ColorOutput "  Failed:  $failCount" -Color $(if($failCount -gt 0){"Red"}else{"Green"})
