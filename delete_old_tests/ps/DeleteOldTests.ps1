# ------------------------- Pentera Old Tests Cleaner -------------------------
# Description:
#   Automatically deletes old Pentera test runs based on configurable retention.
#   Can run continuously as a service or as a one-shot scheduled task.
#
# Usage:
#   One-shot: .\DeleteOldTests.ps1 -RetentionDays 30
#   Continuous: .\DeleteOldTests.ps1 -RetentionDays 30 -Continuous -IntervalHours 24
#   Dry-run: .\DeleteOldTests.ps1 -RetentionDays 30 -DryRun
# -----------------------------------------------------------------------------

param(
    [Parameter(Mandatory=$false)]
    [int]$RetentionDays = 30,
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = (Join-Path $PSScriptRoot "pentera_api.conf"),
    
    [Parameter(Mandatory=$false)]
    [switch]$Continuous,
    
    [Parameter(Mandatory=$false)]
    [double]$IntervalHours = 24,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [string]$LogPath = (Join-Path $PSScriptRoot "cleanup.log")
)

# --- Logging ---
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
        "WARN"  { Write-Host $logLine -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logLine -ForegroundColor Green }
        default { Write-Host $logLine }
    }
    
    # File logging
    try {
        Add-Content -Path $LogPath -Value $logLine -ErrorAction SilentlyContinue
    } catch {}
}

# --- SSL Configuration ---
if ($PSVersionTable.PSVersion.Major -le 5) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Configuration ---
function Get-Config($path) {
    if (!(Test-Path $path)) {
        Write-Log "Config file not found: $path" -Level "ERROR"
        return $null
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
        Write-Log "TGT updated in config file."
    } catch {
        Write-Log "Failed to update TGT in config: $($_.Exception.Message)" -Level "WARN"
    }
}

# --- Authentication ---
function Get-AuthToken($config, $configPath) {
    $rawAddress = $config["PENTERA_ADDRESS"]
    $penteraAddress = $rawAddress.Split("/")[0]
    $loginUri = "https://$penteraAddress/pentera/api/v1/auth/login"
    
    Write-Log "Authenticating to: $loginUri"

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
                Update-ConfigTgt -ConfigPath $configPath -NewTgt $newTgt
                $config["TGT"] = $newTgt
            }
            Write-Log "Authentication successful."
            return $response.token
        } else {
            Write-Log "Login failed: $($response.meta.message)" -Level "ERROR"
        }
    } catch {
        $statusCode = "Unknown"
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        Write-Log "Login failed (Status: $statusCode): $($_.Exception.Message)" -Level "ERROR"
    }
    return $null
}

# --- API Requests ---
function Invoke-PenteraApi {
    param(
        [string]$BaseAddress,
        [string]$Endpoint,
        [string]$Method = "GET",
        [hashtable]$Headers,
        [object]$Body = $null
    )
    
    $uri = "https://$BaseAddress$Endpoint"
    
    $params = @{
        Uri             = $uri
        Method          = $Method
        Headers         = $Headers
        UseBasicParsing = $true
    }
    
    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params["ContentType"] = "application/json"
    }
    
    try {
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            $response = Invoke-RestMethod @params -SkipCertificateCheck
        } else {
            $rawResponse = Invoke-WebRequest @params
            $response = $rawResponse.Content | ConvertFrom-Json
        }
        return @{ Success = $true; Data = $response }
    } catch {
        $errorMsg = $_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $responseStream = $_.Exception.Response.GetResponseStream()
                if ($responseStream) {
                    $reader = New-Object System.IO.StreamReader($responseStream)
                    $errorMsg += " - Details: $($reader.ReadToEnd())"
                }
            } catch {}
        }
        return @{ Success = $false; Error = $errorMsg }
    }
}

# --- Core Logic ---
function Get-OldTaskRuns {
    param(
        [string]$BaseAddress,
        [hashtable]$Headers,
        [int]$RetentionDays
    )
    
    # Calculate time range for the API query
    # start_timestamp: A long time ago (e.g., year 2000) to capture all old tests
    # end_timestamp: The cutoff date (tests older than this will be deleted)
    # Timestamps must be integers in Unix epoch milliseconds (no decimals)
    $cutoffDate = (Get-Date).AddDays(-$RetentionDays)
    $cutoffTimestamp = [int64]([DateTimeOffset]$cutoffDate).ToUnixTimeMilliseconds()
    
    # Start from a very old date to capture all historical tests
    $startDate = [DateTime]::new(2000, 1, 1)
    $startTimestamp = [int64]([DateTimeOffset]$startDate).ToUnixTimeMilliseconds()
    
    Write-Log "Querying tests from $($startDate.ToString('yyyy-MM-dd')) to $($cutoffDate.ToString('yyyy-MM-dd'))"
    Write-Log "Timestamp range: start_timestamp=$startTimestamp, end_timestamp=$cutoffTimestamp"
    
    # Fetch testing history with required timestamp parameters
    # Try both endpoint patterns - /api/v1/ without /pentera prefix first
    $endpoints = @(
        "/api/v1/testing_history?start_timestamp=$startTimestamp&end_timestamp=$cutoffTimestamp",
        "/pentera/api/v1/testing_history?start_timestamp=$startTimestamp&end_timestamp=$cutoffTimestamp"
    )
    
    $taskRuns = @()
    $success = $false
    
    foreach ($endpoint in $endpoints) {
        Write-Log "Trying endpoint: $($endpoint.Split('?')[0])"
        $result = Invoke-PenteraApi -BaseAddress $BaseAddress -Endpoint $endpoint -Method "GET" -Headers $Headers
        
        if ($result.Success) {
            $data = $result.Data
            
            # Handle different response structures
            if ($data.task_runs) {
                $taskRuns = $data.task_runs
            } elseif ($data.testing_history) {
                $taskRuns = $data.testing_history
            } elseif ($data -is [array]) {
                $taskRuns = $data
            }
            
            Write-Log "Successfully retrieved $($taskRuns.Count) task runs"
            $success = $true
            break
        } else {
            Write-Log "Endpoint $($endpoint.Split('?')[0]) failed: $($result.Error)" -Level "WARN"
        }
    }
    
    if (-not $success) {
        Write-Log "All testing_history endpoints failed" -Level "ERROR"
        return @()
    }
    
    if ($taskRuns.Count -eq 0) {
        Write-Log "No task runs found in the specified time range." -Level "WARN"
        return @()
    }
    
    Write-Log "Found $($taskRuns.Count) task runs older than $RetentionDays days (cutoff: $($cutoffDate.ToString('yyyy-MM-dd')))"
    return $taskRuns
}

function Remove-TaskRuns {
    param(
        [string]$BaseAddress,
        [hashtable]$Headers,
        [array]$TaskRuns,
        [switch]$DryRun
    )
    
    if ($TaskRuns.Count -eq 0) {
        Write-Log "No task runs to delete."
        return
    }
    
    # Extract task run IDs
    $taskRunIds = @()
    foreach ($run in $TaskRuns) {
        $id = $run.task_run_id
        if (-not $id) { $id = $run.id }
        if (-not $id) { $id = $run.taskRunId }
        if ($id) {
            $taskRunIds += $id
        }
    }
    
    if ($taskRunIds.Count -eq 0) {
        Write-Log "Could not extract any task run IDs." -Level "WARN"
        return
    }
    
    Write-Log "Preparing to delete $($taskRunIds.Count) task runs..."
    
    if ($DryRun) {
        Write-Log "[DRY-RUN] Would delete the following task run IDs:" -Level "WARN"
        foreach ($id in $taskRunIds) {
            Write-Log "  - $id"
        }
        return
    }
    
    # Delete in bulk using the deleteBulk endpoint
    $body = @{
        taskRunsIds = $taskRunIds
    }
    
    # Try both endpoint patterns
    $endpoints = @(
        "/api/v1/taskRun/deleteBulk",
        "/pentera/api/v1/taskRun/deleteBulk"
    )
    
    foreach ($endpoint in $endpoints) {
        Write-Log "Attempting bulk delete via: $endpoint"
        $result = Invoke-PenteraApi -BaseAddress $BaseAddress -Endpoint $endpoint -Method "POST" -Headers $Headers -Body $body
        
        if ($result.Success) {
            Write-Log "Successfully deleted $($taskRunIds.Count) task runs." -Level "SUCCESS"
            
            # Update token if provided
            if ($result.Data.meta.token) {
                $newToken = $result.Data.meta.token
                $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($newToken):"))
                $Headers["Authorization"] = "Basic $encodedToken"
            }
            return
        } else {
            Write-Log "Endpoint $endpoint failed: $($result.Error)" -Level "WARN"
        }
    }
    
    Write-Log "All delete endpoints failed. Task runs were NOT deleted." -Level "ERROR"
}

function Invoke-Cleanup {
    param(
        [hashtable]$Config,
        [string]$ConfigPath,
        [int]$RetentionDays,
        [switch]$DryRun
    )
    
    Write-Log "=========================================="
    Write-Log "Starting cleanup cycle (Retention: $RetentionDays days)"
    
    # Authenticate
    $token = Get-AuthToken -config $Config -configPath $ConfigPath
    if (-not $token) {
        Write-Log "Authentication failed. Skipping this cycle." -Level "ERROR"
        return $false
    }
    
    # Prepare headers
    $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($token):"))
    $headers = @{
        "Authorization" = "Basic $encodedToken"
        "Accept"        = "application/json"
        "Content-Type"  = "application/json"
    }
    
    $baseAddress = $Config["PENTERA_ADDRESS"].Split("/")[0]
    
    # Get old task runs
    $oldRuns = Get-OldTaskRuns -BaseAddress $baseAddress -Headers $headers -RetentionDays $RetentionDays
    
    # Delete them
    if ($DryRun) {
        Remove-TaskRuns -BaseAddress $baseAddress -Headers $headers -TaskRuns $oldRuns -DryRun
    } else {
        Remove-TaskRuns -BaseAddress $baseAddress -Headers $headers -TaskRuns $oldRuns
    }
    
    Write-Log "Cleanup cycle completed."
    Write-Log "=========================================="
    return $true
}

# --- Main Execution ---
Write-Log "Pentera Old Tests Cleaner starting..."
Write-Log "Configuration file: $ConfigPath"
Write-Log "Retention period: $RetentionDays days"
Write-Log "Mode: $(if ($Continuous) { 'Continuous (every ' + $IntervalHours + ' hours)' } else { 'One-shot' })"
if ($DryRun) {
    Write-Log "*** DRY-RUN MODE - No deletions will be performed ***" -Level "WARN"
}

$config = Get-Config $ConfigPath
if (-not $config) {
    Write-Log "Failed to load configuration. Exiting." -Level "ERROR"
    exit 1
}

if ($Continuous) {
    Write-Log "Starting continuous cleanup service..."
    
    # Handle graceful shutdown
    $running = $true
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        $script:running = $false
        Write-Log "Received shutdown signal. Stopping..."
    }
    
    while ($running) {
        try {
            # Reload config each cycle to pick up any TGT updates
            $config = Get-Config $ConfigPath
            if ($config) {
                Invoke-Cleanup -Config $config -ConfigPath $ConfigPath -RetentionDays $RetentionDays -DryRun:$DryRun
            }
        } catch {
            Write-Log "Error during cleanup cycle: $($_.Exception.Message)" -Level "ERROR"
        }
        
        if ($running) {
            Write-Log "Sleeping for $IntervalHours hours until next cycle..."
            Start-Sleep -Seconds ($IntervalHours * 3600)
        }
    }
    
    Write-Log "Continuous service stopped."
} else {
    # One-shot mode
    $result = Invoke-Cleanup -Config $config -ConfigPath $ConfigPath -RetentionDays $RetentionDays -DryRun:$DryRun
    if (-not $result) {
        exit 1
    }
}

Write-Log "Pentera Old Tests Cleaner finished."
