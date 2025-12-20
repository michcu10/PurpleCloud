param(
    [Parameter(Mandatory = $true)]
    [string]$CsvFile,

    [Parameter(Mandatory = $true)]
    [string]$Password,

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

if (-not (Test-Path $CsvFile)) {
    if ($DryRun) {
        Write-ColorOutput "[DryRun] CSV file not found (expected if generation skipped). Continuing..." -Color "Yellow"
        exit 0
    }
    throw "CSV file not found: $CsvFile"
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

$users = Get-Content $CsvFile
Write-ColorOutput "Found $(($users.Count)) users to process" -Color "Cyan"
Write-ColorOutput "Starting parallel processing (ThrottleLimit: 20)..." -Color "Cyan"

# Helper function definition for parallel scope
# (We define a local logging function inside the loop instead)

$results = $users | ForEach-Object -Parallel {
    $line = $_
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    
    # helper for CSV format: Free Guy,freeguy,freeguy@domain.com
    $parts = $line -split ","
    if ($parts.Count -lt 3) { return }
    
    $displayName = $parts[0]
    $mailNickname = $parts[1]
    $userPrincipalName = $parts[2]

    # Bring in variables from parent scope
    $pass = $using:Password
    $headers = $using:headers
    $isDryRun = $using:DryRun

    # Redefine simple color output or usage since function scope sharing can be tricky across runspaces
    # simpler to just use Write-Host directly for thread safety in output
    function Write-ColorOutInThread {
        param([string]$Msg, [string]$Col)
        $c = @{ Reset = "`e[0m"; Red = "`e[31m"; Green = "`e[32m"; Yellow = "`e[33m" }
        Write-Host "$($c[$Col])$Msg$($c['Reset'])"
    }

    $body = @{
        accountEnabled    = $true
        displayName       = $displayName
        mailNickname      = $mailNickname
        userPrincipalName = $userPrincipalName
        passwordProfile   = @{
            forceChangePasswordNextSignIn = $false
            password                      = $pass
        }
        jobTitle          = "PurpleCloud-Managed"
    } | ConvertTo-Json -Depth 2 -Compress

    $uri = "https://graph.microsoft.com/v1.0/users"
    $resultObj = [PSCustomObject]@{ Status = "Failed"; UPN = $userPrincipalName }

    if ($isDryRun) {
        Write-Host "[DryRun] Create user: $userPrincipalName"
        $resultObj.Status = "Created"
    }
    else {
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -SkipHttpErrorCheck -StatusCodeVariable "status"
            
            if ($status -eq 201) {
                Write-ColorOutInThread -Msg "Created: $userPrincipalName" -Col "Green"
                $resultObj.Status = "Created"
            }
            elseif ($status -eq 400 -and $response.error.message -like "*already exists*") {
                Write-ColorOutInThread -Msg "Exists: $userPrincipalName" -Col "Yellow"
                $resultObj.Status = "Exists"
            }
            else {
                Write-ColorOutInThread -Msg "Failed: $userPrincipalName ($status)" -Col "Red"
                if ($response.error) {
                    Write-Host "  Error: $($response.error.message)" -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-ColorOutInThread -Msg "Error creating $userPrincipalName : $_" -Col "Red"
        }
    }
    
    return $resultObj

} -ThrottleLimit 20

# Calculate summaries from results
$failCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count
$createdCount = ($results | Where-Object { $_.Status -eq "Created" }).Count
$existsCount = ($results | Where-Object { $_.Status -eq "Exists" }).Count

Write-ColorOutput "`nSummary:" -Color "Cyan"
Write-ColorOutput "  Total Processed: $($results.Count)" -Color "Cyan"
Write-ColorOutput "  Created:         $createdCount" -Color "Green"
Write-ColorOutput "  Exists (Skipped):$existsCount" -Color "Yellow"
Write-ColorOutput "  Failed:          $failCount" -Color $(if ($failCount -gt 0) { "Red" }else { "Green" })
