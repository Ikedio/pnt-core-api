# ------------------------- ADPA Active Directory User Exporter -------------------------
# Description:
#   Retrieves all ADPA tests from Pentera and extracts Active Directory user data
#   from the /api/v1/taskRun/{TaskID}/users/activeDirectoryUsers endpoint.
#   Exports results to CSV.
#
# Usage:
#   .\ExportADPAUsers.ps1
#   .\ExportADPAUsers.ps1 -ConfigPath "C:\Path\To\pentera_api.conf"
#   .\ExportADPAUsers.ps1 -OutputPath "C:\Path\To\output.csv"
#   .\ExportADPAUsers.ps1 -TaskId "specific-task-id"
# ---------------------------------------------------------------------------------------

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = (Join-Path $PSScriptRoot "pentera_api.conf"),

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = (Join-Path $PSScriptRoot "adpa_users_export.csv"),

    [Parameter(Mandatory=$false)]
    [string]$TaskId,

    [Parameter(Mandatory=$false)]
    [switch]$Discover,

    [Parameter(Mandatory=$false)]
    [string]$TestEndpoint,

    [Parameter(Mandatory=$false)]
    [switch]$Verbose_,

    [Parameter(Mandatory=$false)]
    [switch]$Json
)

# --- Configuration & Auth ---
# Disable SSL verification for all versions of PowerShell
if ($PSVersionTable.PSVersion.Major -le 5) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

# Force TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-Config($path) {
    if (!(Test-Path $path)) {
        Write-Error "Config file not found: $path"
        exit 1
    }
    $config = @{}
    Get-Content $path | Where-Object {$_ -match "="} | ForEach-Object {
        $key, $value = $_.Split("=", 2)
        $config[$key.Trim()] = $value.Trim()
    }
    return $config
}

function Update-ConfigTgt($ConfigPath, $NewTgt) {
    try {
        $content = Get-Content $ConfigPath
        $newContent = foreach ($line in $content) {
            if ($line -match "^TGT\s*=") {
                "TGT = $NewTgt"
            } else {
                $line
            }
        }
        $newContent | Set-Content $ConfigPath
        Write-Host "[+] TGT updated in config file." -ForegroundColor Gray
    } catch {
        Write-Host "[-] Failed to update TGT in config: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Login($config) {
    $rawAddress = $config["PENTERA_ADDRESS"]
    $penteraAddress = $rawAddress.Split("/")[0]
    $loginUri = "https://$penteraAddress/pentera/api/v1/auth/login"
    
    Write-Host "[*] Attempting login to: $loginUri" -ForegroundColor Gray

    $bodyObj = @{
        client_id = $config["CLIENT_ID"].Trim()
        tgt       = $config["TGT"].Trim()
    }
    $body = $bodyObj | ConvertTo-Json -Compress

    $params = @{
        Uri             = $loginUri
        Method          = "POST"
        Headers         = @{
            "Content-Type" = "application/json"
            "Accept"       = "application/json"
        }
        Body            = $body
        UseBasicParsing = $true
    }

    try {
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            $response = Invoke-RestMethod @params -SkipCertificateCheck
        } else {
            $rawResponse = Invoke-WebRequest @params
            $response = $rawResponse.Content | ConvertFrom-Json
        }
        
        if ($response.meta.status -eq "success") {
            $newTgt = $response.tgt
            if ($newTgt -and $newTgt -ne $config["TGT"]) {
                Update-ConfigTgt -ConfigPath $ConfigPath -NewTgt $newTgt
            }
            Write-Host "[+] Login successful." -ForegroundColor Green
            return $response.token
        } else {
            Write-Error "Login failed: $($response.meta.message)"
        }
    } catch {
        $statusCode = "Unknown"
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        Write-Error "Login failed (Status: $statusCode): $($_.Exception.Message)"
        
        if ($_.Exception.Response) {
            $responseStream = $_.Exception.Response.GetResponseStream()
            if ($responseStream) {
                $reader = New-Object System.IO.StreamReader($responseStream)
                $errorDetails = $reader.ReadToEnd()
                Write-Host "    Details: $errorDetails" -ForegroundColor Yellow
            }
        }
    }
    return $null
}

function Get-AuthHeaders($token) {
    $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($token):"))
    return @{
        "Authorization" = "Basic $encodedToken"
        "Accept"        = "application/json"
        "Content-Type"  = "application/json"
    }
}

function Invoke-PenteraApi {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers,
        [string]$Body = $null
    )
    
    $params = @{
        Uri             = $Uri
        Method          = $Method
        Headers         = $Headers
        UseBasicParsing = $true
    }
    
    if ($Body) {
        $params["Body"] = $Body
        $params["ContentType"] = "application/json"
    }
    
    try {
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            $response = Invoke-RestMethod @params -SkipCertificateCheck
        } else {
            $rawResponse = Invoke-WebRequest @params
            $response = $rawResponse.Content | ConvertFrom-Json
        }
        return $response
    } catch {
        $statusCode = "Unknown"
        $errorDetails = ""
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $responseStream = $_.Exception.Response.GetResponseStream()
            if ($responseStream) {
                $reader = New-Object System.IO.StreamReader($responseStream)
                $errorDetails = $reader.ReadToEnd()
            }
        }
        Write-Host "[-] API call failed (Status: $statusCode): $($_.Exception.Message)" -ForegroundColor Red
        if ($errorDetails) {
            Write-Host "    Details: $errorDetails" -ForegroundColor Yellow
        }
        return $null
    }
}

function Get-ADPATaskRuns($penteraAddress, $headers) {
    Write-Host "[*] Fetching ADPA task runs (AD Password Strength Assessment)..." -ForegroundColor Cyan
    
    $allTaskRuns = @()
    $taskRuns = $null
    
    # The /testing_history endpoint requires start_timestamp and end_timestamp
    # as milliseconds since Unix Epoch
    $startTimestamp = [long]((Get-Date "2020-01-01").ToUniversalTime() - (Get-Date "1970-01-01")).TotalMilliseconds
    $endTimestamp = [long]((Get-Date).AddDays(1).ToUniversalTime() - (Get-Date "1970-01-01")).TotalMilliseconds
    
    # Try endpoints - /api/v1/ without /pentera prefix based on AD users endpoint pattern
    $endpoints = @(
        "https://$penteraAddress/api/v1/testing_history?start_timestamp=$startTimestamp&end_timestamp=$endTimestamp",
        "https://$penteraAddress/pentera/api/v1/testing_history?start_timestamp=$startTimestamp&end_timestamp=$endTimestamp"
    )
    
    $response = $null
    foreach ($testingHistoryUri in $endpoints) {
        Write-Host "    [*] Trying: GET $testingHistoryUri" -ForegroundColor Gray
        $response = Invoke-PenteraApi -Uri $testingHistoryUri -Method "GET" -Headers $headers
        if ($response) {
            Write-Host "    [+] Success!" -ForegroundColor Green
            break
        }
    }
    
    if ($response) {
        # Extract task runs from response - swagger says it returns "task_runs" array
        if ($response.task_runs) { $taskRuns = $response.task_runs }
        elseif ($response.testing_history) { $taskRuns = $response.testing_history }
        elseif ($response.taskRuns) { $taskRuns = $response.taskRuns }
        elseif ($response -is [array]) { $taskRuns = $response }
    }
    
    if (!$taskRuns -or $taskRuns.Count -eq 0) {
        Write-Host "[-] Could not fetch testing history." -ForegroundColor Red
        return @()
    }
    
    Write-Host "    [*] Filtering for AD Password Strength Assessment tests..." -ForegroundColor Gray
    
    # Filter for AD Password Strength Assessment (ADPA) tests
    # According to swagger, the type is "Targeted Testing - AD Password Strength Assessment"
    foreach ($task in $taskRuns) {
        $taskType = if ($task.type) { $task.type } else { "" }
        $name = if ($task.name) { $task.name } else { "" }
        
        # Include AD Password Assessment tests (various naming patterns)
        if ($taskType -match "AD Password|AdPassword|ADPA" -or 
            $name -match "AD Password|AdPassword|ADPA") {
            $allTaskRuns += $task
        }
    }
    
    # If no ADPA filter matched, show available types
    if ($allTaskRuns.Count -eq 0) {
        Write-Host "[!] No AD Password Assessment tests found." -ForegroundColor Yellow
        
        # Show available task types for debugging
        $types = @{}
        foreach ($task in $taskRuns) {
            $t = if ($task.type) { $task.type } else { "unknown" }
            if (!$types.ContainsKey($t)) { $types[$t] = 0 }
            $types[$t]++
        }
        Write-Host "    Available task types:" -ForegroundColor Gray
        foreach ($t in $types.Keys) {
            Write-Host "      - $t : $($types[$t]) tasks" -ForegroundColor Gray
        }
        
        Write-Host "[!] Including all $($taskRuns.Count) task runs..." -ForegroundColor Yellow
        $allTaskRuns = $taskRuns
    }
    
    Write-Host "[+] Found $($allTaskRuns.Count) task runs to process." -ForegroundColor Green
    return $allTaskRuns
}

function Get-ActiveDirectoryUsers($penteraAddress, $headers, $taskId, $debugMode, $saveRawJson) {
    Write-Host "    [*] Fetching AD users for task: $taskId" -ForegroundColor Gray
    
    # Endpoint: POST /api/v1/taskRun/{TaskID}/users/activeDirectoryUsers
    # Requires JSON body with pagination parameters
    $usersUri = "https://$penteraAddress/api/v1/taskRun/$taskId/users/activeDirectoryUsers"
    
    $bodyObj = @{
        offset = 0
        items_per_page = 10000
        sort = @{
            direction = "ASC"
            key = "passwordCrackedPhase"
        }
        filters = @{}
        unique_fields = @("state")
    }
    $body = $bodyObj | ConvertTo-Json -Depth 10 -Compress
    
    Write-Host "        [*] POST $usersUri" -ForegroundColor Gray
    
    $response = Invoke-PenteraApi -Uri $usersUri -Method "POST" -Headers $headers -Body $body
    
    if ($response) {
        # Save full raw JSON response if requested
        if ($saveRawJson) {
            $rawJsonPath = Join-Path $PSScriptRoot "raw_response_$taskId.json"
            $response | ConvertTo-Json -Depth 20 | Out-File -FilePath $rawJsonPath -Encoding UTF8
            Write-Host "        [+] Full raw response saved to: $rawJsonPath" -ForegroundColor Green
        }
        
        # Debug: show full response structure
        if ($debugMode) {
            Write-Host "        [DEBUG] Response keys: $($response.PSObject.Properties.Name -join ', ')" -ForegroundColor Magenta
            $responseJson = $response | ConvertTo-Json -Depth 5 -Compress
            if ($responseJson.Length -gt 500) {
                Write-Host "        [DEBUG] Response (truncated): $($responseJson.Substring(0, 500))..." -ForegroundColor Magenta
            } else {
                Write-Host "        [DEBUG] Response: $responseJson" -ForegroundColor Magenta
            }
        }
        
        # Extract users from response - try all possible keys
        $users = $null
        if ($response.users) { $users = $response.users }
        elseif ($response.activeDirectoryUsers) { $users = $response.activeDirectoryUsers }
        elseif ($response.active_directory_users) { $users = $response.active_directory_users }
        elseif ($response.data) { $users = $response.data }
        elseif ($response.items) { $users = $response.items }
        elseif ($response.results) { $users = $response.results }
        elseif ($response -is [array]) { $users = $response }
        
        # Update token if provided
        if ($response.meta -and $response.meta.token) {
            $script:currentToken = $response.meta.token
        }
        
        if ($users -and $users.Count -gt 0) {
            Write-Host "        [+] Success! Found $($users.Count) users" -ForegroundColor Green
            return $users
        } else {
            Write-Host "        [!] Response received but no users extracted" -ForegroundColor Yellow
            if ($debugMode) {
                Write-Host "        [DEBUG] Check the response structure above" -ForegroundColor Magenta
            }
        }
    }
    
    return @()
}

function Export-UsersToCsv($allUsers, $outputPath) {
    if ($allUsers.Count -eq 0) {
        Write-Host "[-] No users to export." -ForegroundColor Yellow
        return
    }
    
    # Determine all unique property names from all user objects
    $allProperties = @{}
    foreach ($user in $allUsers) {
        if ($user -is [PSCustomObject] -or $user -is [hashtable]) {
            $user.PSObject.Properties | ForEach-Object {
                $allProperties[$_.Name] = $true
            }
        }
    }
    
    # Define base columns we always want first
    $baseColumns = @("task_id", "task_name", "username", "displayName", "samAccountName", 
                     "userPrincipalName", "email", "distinguishedName", "domain", 
                     "enabled", "lastLogon", "passwordLastSet", "memberOf")
    
    # Build final column list
    $columns = @()
    foreach ($col in $baseColumns) {
        if ($allProperties.ContainsKey($col)) {
            $columns += $col
            $allProperties.Remove($col)
        }
    }
    # Add remaining columns
    $columns += $allProperties.Keys | Sort-Object
    
    # Create CSV content
    $csvContent = @()
    
    # Header row
    $csvContent += ($columns -join ",")
    
    # Data rows
    foreach ($user in $allUsers) {
        $row = @()
        foreach ($col in $columns) {
            $value = ""
            if ($user.PSObject.Properties[$col]) {
                $value = $user.$col
                # Handle arrays (like memberOf groups)
                if ($value -is [array]) {
                    $value = ($value -join "; ")
                }
                # Escape quotes and wrap in quotes if contains comma/newline
                $value = $value -replace '"', '""'
                if ($value -match '[,"\n\r]') {
                    $value = "`"$value`""
                }
            }
            $row += $value
        }
        $csvContent += ($row -join ",")
    }
    
    $csvContent | Out-File -FilePath $outputPath -Encoding UTF8
    Write-Host "[+] Exported $($allUsers.Count) users to: $outputPath" -ForegroundColor Green
}

function Invoke-DiscoverEndpoints($penteraAddress, $headers, $sampleTaskId) {
    Write-Host "[*] Discovering available API endpoints..." -ForegroundColor Cyan
    Write-Host ""
    
    # Timestamps in milliseconds since Unix Epoch (as per swagger)
    $startTimestamp = [long]((Get-Date "2020-01-01").ToUniversalTime() - (Get-Date "1970-01-01")).TotalMilliseconds
    $endTimestamp = [long]((Get-Date).AddDays(1).ToUniversalTime() - (Get-Date "1970-01-01")).TotalMilliseconds
    
    $endpointsToTest = @(
        # Testing History - try without /pentera prefix first (based on AD users endpoint pattern)
        @{ Uri = "https://$penteraAddress/api/v1/testing_history?start_timestamp=$startTimestamp&end_timestamp=$endTimestamp"; Method = "GET"; Description = "Testing History (/api/v1)" },
        @{ Uri = "https://$penteraAddress/pentera/api/v1/testing_history?start_timestamp=$startTimestamp&end_timestamp=$endTimestamp"; Method = "GET"; Description = "Testing History (/pentera/api/v1)" },
        # Scenarios (known working)
        @{ Uri = "https://$penteraAddress/pentera/api/v1/testing_scenarios"; Method = "GET"; Description = "Testing Scenarios (v1)" }
    )
    
    # Add AD users endpoint tests if a sample task ID is provided
    if ($sampleTaskId) {
        $adUserEndpoints = @(
            # AD Users - try the pattern that works for achievements/hosts
            @{ Uri = "https://$penteraAddress/pentera/api/v1/task_run/$sampleTaskId/users/activeDirectoryUsers"; Method = "GET"; Description = "AD Users GET (/pentera/api/v1/task_run)" },
            @{ Uri = "https://$penteraAddress/pentera/api/v1/task_run/$sampleTaskId/users/activeDirectoryUsers"; Method = "POST"; Description = "AD Users POST (/pentera/api/v1/task_run)" },
            @{ Uri = "https://$penteraAddress/pentera/api/v1/task_run/$sampleTaskId/activeDirectoryUsers"; Method = "GET"; Description = "AD Users direct GET" },
            # Other task_run endpoints from swagger (confirmed working)
            @{ Uri = "https://$penteraAddress/pentera/api/v1/task_run/$sampleTaskId/achievements"; Method = "GET"; Description = "Achievements (swagger)" },
            @{ Uri = "https://$penteraAddress/pentera/api/v1/task_run/$sampleTaskId/hosts"; Method = "GET"; Description = "Hosts (swagger)" }
        )
        $endpointsToTest += $adUserEndpoints
    }
    
    foreach ($ep in $endpointsToTest) {
        Write-Host "Testing: $($ep.Description)" -ForegroundColor White
        Write-Host "    $($ep.Method) $($ep.Uri)" -ForegroundColor Gray
        
        try {
            $params = @{
                Uri             = $ep.Uri
                Method          = $ep.Method
                Headers         = $headers
                UseBasicParsing = $true
            }
            
            if ($PSVersionTable.PSVersion.Major -gt 5) {
                $response = Invoke-RestMethod @params -SkipCertificateCheck
            } else {
                $rawResponse = Invoke-WebRequest @params
                $response = $rawResponse.Content | ConvertFrom-Json
            }
            
            Write-Host "    [OK] Status: 200" -ForegroundColor Green
            
            # Show response structure
            if ($response -is [array]) {
                Write-Host "    Response: Array with $($response.Count) items" -ForegroundColor Cyan
                if ($response.Count -gt 0) {
                    Write-Host "    First item keys: $($response[0].PSObject.Properties.Name -join ', ')" -ForegroundColor Gray
                }
            } else {
                Write-Host "    Response keys: $($response.PSObject.Properties.Name -join ', ')" -ForegroundColor Cyan
                # Check for common wrapper keys
                foreach ($key in @("task_runs", "taskRuns", "testing_history", "tasks", "scenarios", "templates", "testing_scenarios", "users", "activeDirectoryUsers")) {
                    $val = $response.$key
                    if ($val -and $val.Count -gt 0) {
                        Write-Host "    '$key' contains $($val.Count) items" -ForegroundColor Green
                        if ($val[0]) {
                            Write-Host "    First item keys: $($val[0].PSObject.Properties.Name -join ', ')" -ForegroundColor Gray
                        }
                    }
                }
            }
        } catch {
            $statusCode = "Unknown"
            $errorBody = ""
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                try {
                    $responseStream = $_.Exception.Response.GetResponseStream()
                    if ($responseStream) {
                        $reader = New-Object System.IO.StreamReader($responseStream)
                        $errorBody = $reader.ReadToEnd()
                    }
                } catch {}
            }
            Write-Host "    [FAIL] Status: $statusCode - $($_.Exception.Message)" -ForegroundColor Red
            if ($errorBody) {
                Write-Host "    Response: $errorBody" -ForegroundColor Yellow
            }
        }
        Write-Host ""
    }
    
    Write-Host "Discovery complete. Use -TaskId with a specific task ID if you know one." -ForegroundColor Cyan
}

function Get-ScenariosWithTaskIds($penteraAddress, $headers) {
    Write-Host "[*] Fetching scenarios to find task IDs..." -ForegroundColor Cyan
    
    # Use the known working endpoint
    $scenariosUri = "https://$penteraAddress/pentera/api/v1/testing_scenarios"
    
    $response = Invoke-PenteraApi -Uri $scenariosUri -Method "GET" -Headers $headers
    
    if (!$response) {
        # Fallback to templates
        $scenariosUri = "https://$penteraAddress/pentera/api/v1/templates"
        $response = Invoke-PenteraApi -Uri $scenariosUri -Method "GET" -Headers $headers
    }
    
    if (!$response) {
        return @()
    }
    
    $scenarios = $null
    if ($response.testing_scenarios) { $scenarios = $response.testing_scenarios }
    elseif ($response.scenarios) { $scenarios = $response.scenarios }
    elseif ($response.templates) { $scenarios = $response.templates }
    elseif ($response -is [array]) { $scenarios = $response }
    
    if (!$scenarios) {
        return @()
    }
    
    Write-Host "    [+] Found $($scenarios.Count) scenarios" -ForegroundColor Green
    
    # Extract task runs from scenarios if available
    $allTaskRuns = @()
    foreach ($scenario in $scenarios) {
        # Check if scenario has last_task_run_id or similar
        $taskId = $scenario.last_task_run_id
        if (!$taskId) { $taskId = $scenario.lastTaskRunId }
        if (!$taskId) { $taskId = $scenario.task_run_id }
        
        if ($taskId) {
            $allTaskRuns += @{
                id = $taskId
                name = $scenario.name
                type = $scenario.type
                template_id = if ($scenario.template_id) { $scenario.template_id } else { $scenario.id }
            }
        }
    }
    
    if ($allTaskRuns.Count -gt 0) {
        Write-Host "    [+] Extracted $($allTaskRuns.Count) task run IDs from scenarios" -ForegroundColor Green
    }
    
    return $allTaskRuns
}

# --- Main Execution ---
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  ADPA Active Directory User Exporter  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$config = Get-Config $ConfigPath
$token = Login $config

if (!$token) {
    Write-Host "[-] Could not authenticate. Exiting." -ForegroundColor Red
    exit 1
}

$script:currentToken = $token
$headers = Get-AuthHeaders $token
$penteraAddress = $config["PENTERA_ADDRESS"].Split("/")[0]

# Discovery mode
if ($Discover) {
    Invoke-DiscoverEndpoints -penteraAddress $penteraAddress -headers $headers -sampleTaskId $TestEndpoint
    exit 0
}

$allUsers = @()

if ($TaskId) {
    # Single task mode
    Write-Host "[*] Processing single task: $TaskId" -ForegroundColor Cyan
    $users = Get-ActiveDirectoryUsers -penteraAddress $penteraAddress -headers $headers -taskId $TaskId -debugMode $Verbose_ -saveRawJson $Json
    foreach ($user in $users) {
        # Add task context
        $user | Add-Member -NotePropertyName "task_id" -NotePropertyValue $TaskId -Force
        $user | Add-Member -NotePropertyName "task_name" -NotePropertyValue "Manual Query" -Force
        $allUsers += $user
    }
    Write-Host "    [+] Found $($users.Count) AD users." -ForegroundColor Green
} else {
    # Batch mode - try to get all ADPA tests
    $taskRuns = Get-ADPATaskRuns -penteraAddress $penteraAddress -headers $headers
    
    # Fallback: try to get task IDs from scenarios
    if ($taskRuns.Count -eq 0) {
        Write-Host "[*] Trying fallback: extracting task IDs from scenarios..." -ForegroundColor Yellow
        $taskRuns = Get-ScenariosWithTaskIds -penteraAddress $penteraAddress -headers $headers
    }
    
    if ($taskRuns.Count -eq 0) {
        Write-Host ""
        Write-Host "[-] Could not retrieve any task runs." -ForegroundColor Red
        Write-Host ""
        Write-Host "Try one of these options:" -ForegroundColor Yellow
        Write-Host "  1. Run with -Discover to see available API endpoints" -ForegroundColor White
        Write-Host "  2. Run with -TaskId <id> if you know a specific task run ID" -ForegroundColor White
        Write-Host ""
        exit 1
    }
    
    foreach ($task in $taskRuns) {
        # Swagger shows field is "task_run_id"
        $taskId = $task.task_run_id
        if (!$taskId) { $taskId = $task.id }
        if (!$taskId) { $taskId = $task.task_id }
        if (!$taskId) { $taskId = $task.taskId }
        
        $taskName = $task.name
        if (!$taskName) { $taskName = $task.task_name }
        
        if (!$taskId) {
            Write-Host "    [-] Skipping task with no ID" -ForegroundColor Yellow
            continue
        }
        
        # Refresh headers with latest token
        $headers = Get-AuthHeaders $script:currentToken
        
        $users = Get-ActiveDirectoryUsers -penteraAddress $penteraAddress -headers $headers -taskId $taskId -debugMode $Verbose_ -saveRawJson $Json
        
        foreach ($user in $users) {
            # Add task context to each user record
            $user | Add-Member -NotePropertyName "task_id" -NotePropertyValue $taskId -Force
            $user | Add-Member -NotePropertyName "task_name" -NotePropertyValue $taskName -Force
            $allUsers += $user
        }
        
        if ($users.Count -gt 0) {
            Write-Host "    [+] Found $($users.Count) AD users in task: $taskName" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "[*] Total AD users collected: $($allUsers.Count)" -ForegroundColor Cyan

# Export to CSV
Export-UsersToCsv -allUsers $allUsers -outputPath $OutputPath

# Also export to JSON if requested
if ($Json) {
    $jsonPath = $OutputPath -replace '\.csv$', '.json'
    if ($jsonPath -eq $OutputPath) {
        $jsonPath = "$OutputPath.json"
    }
    $allUsers | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
    Write-Host "[+] Exported to JSON: $jsonPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "[+] Export complete!" -ForegroundColor Green
