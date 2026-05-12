# ================= Script Required Parameters =================
param (
    [Parameter(Mandatory = $true)]
    [string]$workspaceName,

    [Parameter(Mandatory = $true)]
    [string]$tenantId,

    [Parameter(Mandatory = $true)]
    [string]$subscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$clientId,

    [Parameter(Mandatory = $true)]
    [string]$servicePrincipalSecret,

    [Parameter(Mandatory = $true)]
    [ValidateSet("UserPrincipal", "ServicePrincipal")]
    [string]$principalType
)

# ================= GLOBAL VARIABLES =================
$global:baseUrl = "https://api.fabric.microsoft.com/v1"
$global:resourceUrl = "https://api.fabric.microsoft.com"
$global:fabricHeaders = @{}

# ================= AUTHENTICATION FUNCTIONS =================
function SetFabricHeaders {
    if ($principalType -eq "UserPrincipal") {
        $secureFabricToken = GetSecureTokenForUserPrincipal
    }
    elseif ($principalType -eq "ServicePrincipal") {
        $secureFabricToken = GetSecureTokenForServicePrincipal
    }
    else {
        throw "Invalid principal type."
    }

    $fabricToken = ConvertSecureStringToPlainText $secureFabricToken

    $global:fabricHeaders = @{
        'Content-Type'  = "application/json"
        'Authorization' = "Bearer $fabricToken"
    }
}

# ================ AUTH HELPER FUNCTIONS =================
# Get Secure Token for User Principal
function GetSecureTokenForUserPrincipal {
    Connect-AzAccount -TenantId $tenantId -Subscription $subscriptionId | Out-Null
    return (Get-AzAccessToken -AsSecureString -ResourceUrl $global:resourceUrl).Token
}

# Get Secure Token for Service Principal
function GetSecureTokenForServicePrincipal {
    if (-not $clientId -or -not $servicePrincipalSecret) {
        throw "clientId and servicePrincipalSecret are required for ServicePrincipal authentication."
    }

    $secureClientSecret = ConvertTo-SecureString $servicePrincipalSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($clientId, $secureClientSecret)

    Connect-AzAccount -ServicePrincipal -Credential $credential -TenantId $tenantId -Subscription $subscriptionId | Out-Null
    return (Get-AzAccessToken -AsSecureString -ResourceUrl $global:resourceUrl).Token
}

# Convert Secure String to Plain Text
function ConvertSecureStringToPlainText($secureString) {
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

# ================= FABRIC FUNCTIONS =================
function GetWorkspaceByName($workspaceName) {
    $url = "$global:baseUrl/workspaces"
    $workspaces = (Invoke-RestMethod -Headers $global:fabricHeaders -Uri $url -Method GET).value
    return $workspaces | Where-Object { $_.DisplayName -eq $workspaceName }
}

# ================= ERROR RESPONSE HANDLING =================
function GetErrorResponse($exception) {
    # Relevant only for PowerShell Core
    $errorResponse = $_.ErrorDetails.Message
 
    if(!$errorResponse) {
        # This is needed to support Windows PowerShell
        if (!$exception.Response) {
            return $exception.Message
        }
        $result = $exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($result)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $errorResponse = $reader.ReadToEnd();
    }
 
    return $errorResponse
}

# ================ MAIN CODE =================
try
{
    SetFabricHeaders

    $workspace = GetWorkspaceByName $workspaceName 
    
    # Verify the existence of the requested workspace
	if(!$workspace) {
	  Write-Host "A workspace with the requested name was not found." -ForegroundColor Red
	  return
	}
    Write-Host "Calling GET Status REST API to construct the request body for UpdateFromGit REST API."

    $gitStatusUrl = "$global:baseUrl/workspaces/$($workspace.Id)/git/status"
    $gitStatusResponse = Invoke-RestMethod -Headers $global:fabricHeaders -Uri $gitStatusUrl -Method GET

    # Update from Git
    Write-Host "Updating the workspace '$workspaceName' from Git."

    $updateFromGitUrl = "$global:baseUrl/workspaces/$($workspace.Id)/git/updateFromGit"

    $updateFromGitBody = @{ 
        remoteCommitHash = $gitStatusResponse.RemoteCommitHash
		workspaceHead = $gitStatusResponse.WorkspaceHead
        options = @{
            # Allows overwriting existing items if needed
            allowOverrideItems = $TRUE
        }
    } | ConvertTo-Json

    $updateFromGitResponse = Invoke-WebRequest -Headers $global:fabricHeaders -Uri $updateFromGitUrl -Method POST -Body $updateFromGitBody

    $operationId = $updateFromGitResponse.Headers['x-ms-operation-id']
    $retryAfter = $updateFromGitResponse.Headers['Retry-After']
    # Ensure $retryAfter is a single integer value
    if ($null -eq $retryAfter) {
        $retryAfterSeconds = 5 # Default fallback
    } elseif ($retryAfter -is [System.Array]) {
        $retryAfterSeconds = [int]$retryAfter[0]
    } else {
        $retryAfterSeconds = [int]$retryAfter
    }
    Write-Host "Long Running Operation ID: '$operationId' has been scheduled for updating the workspace '$workspaceName' from Git with a retry-after time of '$retryAfterSeconds' seconds." -ForegroundColor Green

    # Poll Long Running Operation
    $getOperationState = "$global:baseUrl/operations/$operationId"
    do
    {
        $operationState = Invoke-RestMethod -Headers $global:fabricHeaders -Uri $getOperationState -Method GET

        Write-Host "Update from Git operation status: $($operationState.Status)"

        if ($operationState.Status -in @("NotStarted", "Running")) {
            Start-Sleep -Seconds $retryAfterSeconds
        }
    } while($operationState.Status -in @("NotStarted", "Running"))

    if ($operationState.Status -eq "Failed") {
        Write-Host "Failed to update the workspace '$workspaceName' with content from Git. Error reponse: $($operationState.Error | ConvertTo-Json)" -ForegroundColor Red
        Write-Error $_
        exit 1
    }
    else{
        Write-Host "The workspace '$workspaceName' has been successfully updated with content from Git." -ForegroundColor Green
    }
}
catch {
    $exception = if ($error[0] -and $error[0].Exception) { $error[0].Exception } else { $_ }
    $errorResponse = GetErrorResponse($exception)
    Write-Host "Failed to update the workspace '$workspaceName' from Git. Error reponse: $errorResponse" -ForegroundColor Red
    Write-Error $exception
    exit 1
}
