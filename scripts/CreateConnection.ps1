param (
    [Parameter(Mandatory = $true)]
    [string]$workspaceName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("UserPrincipal", "ManagedIdentity", "ServicePrincipal")]
    [string]$principalType,

    [Parameter(Mandatory = $true)]
    [string]$tenantId,

    [Parameter(Mandatory = $true)]
    [string]$subscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$key,

    [Parameter(Mandatory = $true)]
    [string]$displayName,

    [Parameter(Mandatory = $true)]
    [string]$clientId,

    [Parameter(Mandatory = $true)]
    [string]$servicePrincipalSecret
)

# ================= GLOBAL VARIABLES =================
$global:baseUrl = "https://api.fabric.microsoft.com/v1"
$global:resourceUrl = "https://api.fabric.microsoft.com"
$global:fabricHeaders = @{}

# ================= CONNECTION PAYLOAD =================
$gitHubPATConnection = @{
    connectivityType = "ShareableCloud"
    displayName = $displayName
    connectionDetails = @{
        type = "GitHubSourceControl"
        creationMethod = "GitHubSourceControl.Contents"
    }
    credentialDetails = @{
        credentials = @{
            credentialType = "Key"
            key = $key
        }
    }
}

# ================= AUTH FUNCTIONS =================
function SetFabricHeaders {
    if ($principalType -eq "UserPrincipal") {
        $secureFabricToken = GetSecureTokenForUserPrincipal
    }
    elseif ($principalType -eq "ManagedIdentity") {
        $secureFabricToken = GetSecureTokenForManagedIdentity
    }
    elseif ($principalType -eq "ServicePrincipal") {
        $secureFabricToken = GetSecureTokenForServicePrincipal
    }
    else {
        throw "Invalid principal type."
    }

    $fabricToken = ConvertSecureStringToPlainText $secureFabricToken

    $global:fabricHeaders = @{
        "Content-Type"  = "application/json"
        "Authorization" = "Bearer $fabricToken"
    }
}

function GetSecureTokenForUserPrincipal {
    Connect-AzAccount -TenantId $tenantId -Subscription $subscriptionId | Out-Null
    return (Get-AzAccessToken -AsSecureString -ResourceUrl $global:resourceUrl).Token
}

function GetSecureTokenForManagedIdentity {
    Connect-AzAccount -Identity -TenantId $tenantId | Out-Null
    return (Get-AzAccessToken -AsSecureString -ResourceUrl $global:resourceUrl).Token
}

function GetSecureTokenForServicePrincipal {
    $secureSecret = ConvertTo-SecureString $servicePrincipalSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($clientId, $secureSecret)

    Connect-AzAccount -ServicePrincipal -TenantId $tenantId -Credential $credential | Out-Null
    return (Get-AzAccessToken -AsSecureString -ResourceUrl $global:resourceUrl).Token
}

function ConvertSecureStringToPlainText($secureString) {
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function GetErrorResponse($exception) {
    $errorResponse = $_.ErrorDetails.Message

    if (!$errorResponse) {
        if (!$exception.Response) {
            return $exception.Message
        }

        $result = $exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($result)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $errorResponse = $reader.ReadToEnd()
    }

    return $errorResponse
}

function GetWorkspaceByName($workspaceName) {
    $getWorkspacesUrl = "$global:baseUrl/workspaces"
    $workspaces = (Invoke-RestMethod -Headers $global:fabricHeaders -Uri $getWorkspacesUrl -Method GET).value
    return $workspaces | Where-Object { $_.DisplayName -eq $workspaceName }
}

# ================= MAIN EXECUTION =================
try {
    Write-Host "Authenticating to Microsoft Fabric..."
    SetFabricHeaders

    Write-Host "Creating connection with Git provider credentials..."

    $connectionsUrl = "$global:baseUrl/connections"
    $connectionBody = $gitHubPATConnection | ConvertTo-Json -Depth 10

    Write-Host "Creating connection: $displayName"

    $response = Invoke-RestMethod `
        -Headers $global:fabricHeaders `
        -Uri $connectionsUrl `
        -Method POST `
        -Body $connectionBody

    Write-Host "Connection created successfully! Connection ID: $($response.id)" -ForegroundColor Green
}
catch {
    $errorResponse = GetErrorResponse($_.Exception)
    Write-Host "Failed to create connection. Error response: $errorResponse" -ForegroundColor Red
    throw
}

if (-not $response -or -not $response.id) {
    throw "Connection creation failed. Cannot continue."
}

try {
    Write-Host "Authenticating again before workspace update..."
    SetFabricHeaders

    $workspace = GetWorkspaceByName $workspaceName

    if (!$workspace) {
        throw "Workspace '$workspaceName' not found."
    }

    Write-Host "Updating Git credentials for workspace '$workspaceName'..."

    $updateMyGitCredentialsUrl = "$global:baseUrl/workspaces/$($workspace.Id)/git/myGitCredentials"

    $updateMyGitCredentialsBody = @{
        gitCredentials = @{
            source = "ConfiguredConnection"
            connectionId = $response.id
        }
    } | ConvertTo-Json -Depth 5

    Write-Host "PATCH Payload:"
    Write-Host $updateMyGitCredentialsBody

    Invoke-RestMethod `
        -Headers $global:fabricHeaders `
        -Uri $updateMyGitCredentialsUrl `
        -Method PATCH `
        -Body $updateMyGitCredentialsBody

    Write-Host "Git credentials updated successfully for workspace '$workspaceName'." -ForegroundColor Green
}
catch {
    $errorResponse = GetErrorResponse($_.Exception)
    Write-Host "Failed to update Git credentials for workspace '$workspaceName'. Error response: $errorResponse" -ForegroundColor Red
    throw
}
