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

# Unix epoch milliseconds (UTC). Avoids (Get-Date "1970-01-01") local-time bugs in PS 5.1.
function Get-UnixMillisecondsUtc {
    param(
        [Parameter(Mandatory=$true)][DateTimeOffset]$Instant
    )
    return [long]$Instant.ToUnixTimeMilliseconds()
}

function Get-TestingHistoryQueryTimestamps {
    # Pentera expects start/end in ms since epoch; swagger type is number/double.
    $start = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $end = [DateTimeOffset]::UtcNow.AddDays(1)
    $startMs = Get-UnixMillisecondsUtc -Instant $start
    $endMs = Get-UnixMillisecondsUtc -Instant $end
    return @{
        IntStart = $startMs
        IntEnd   = $endMs
        # Must contain a decimal point - [string]([double]n) drops ".0" and repeats int form.
        FloatStart = "{0}.0" -f $startMs
        FloatEnd   = "{0}.0" -f $endMs
    }
}

function Get-TestingHistoryQueryStringVariants {
    <#
      Several appliances reject certain ranges or require float-style query params.
      Try: wide window, explicit .0 decimals, end=now (no +1d), and last-365d narrow window.
    #>
    $start2000 = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $endPlus1  = [DateTimeOffset]::UtcNow.AddDays(1)
    $endNow    = [DateTimeOffset]::UtcNow
    $start365  = [DateTimeOffset]::UtcNow.AddDays(-365)
    $s2000 = Get-UnixMillisecondsUtc -Instant $start2000
    $eP1   = Get-UnixMillisecondsUtc -Instant $endPlus1
    $eNow  = Get-UnixMillisecondsUtc -Instant $endNow
    $s365  = Get-UnixMillisecondsUtc -Instant $start365

    return @(
        "start_timestamp=$s2000&end_timestamp=$eP1",
        "start_timestamp=$s2000.0&end_timestamp=$eP1.0",
        "start_timestamp=$s2000&end_timestamp=$eNow",
        "start_timestamp=$s2000.0&end_timestamp=$eNow.0",
        "start_timestamp=$s365&end_timestamp=$eNow",
        "start_timestamp=$s365.0&end_timestamp=$eNow.0"
    )
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

function Test-IsLikelyAdUserObject($obj) {
    if ($null -eq $obj) { return $false }
    if ($obj -isnot [PSCustomObject] -and $obj -isnot [hashtable]) { return $false }
    $names = if ($obj -is [PSCustomObject]) {
        @($obj.PSObject.Properties | ForEach-Object { $_.Name })
    } else {
        @($obj.Keys)
    }
    foreach ($n in $names) {
        if ($n -match '^(samAccountName|userPrincipalName|distinguishedName|objectSid|objectGUID|DistinguishedName|SamAccountName|Username|displayName|mail)$') {
            return $true
        }
        if ($n -match '(?i)(samaccount|userprincipal|distinguished|objectsid|objectguid|accountname)') {
            return $true
        }
    }
    return $false
}

function Find-ActiveDirectoryUserArrayDeep($node, [int]$depth) {
    if ($null -eq $node -or $depth -gt 10) { return $null }
    if ($node -is [array] -and $node.Count -gt 0) {
        if (Test-IsLikelyAdUserObject $node[0]) { return $node }
        return $null
    }
    if ($node -is [PSCustomObject]) {
        foreach ($p in $node.PSObject.Properties) {
            $found = Find-ActiveDirectoryUserArrayDeep $p.Value ($depth + 1)
            if ($found) { return $found }
        }
    }
    elseif ($node -is [hashtable]) {
        foreach ($k in $node.Keys) {
            $found = Find-ActiveDirectoryUserArrayDeep $node[$k] ($depth + 1)
            if ($found) { return $found }
        }
    }
    return $null
}

function Extract-ActiveDirectoryUsersFromResponse($response) {
    if ($null -eq $response) { return $null }
    if ($response -is [array] -and $response.Count -gt 0) {
        if (Test-IsLikelyAdUserObject $response[0]) { return $response }
    }

    $candidates = @(
        { param($r) $r.users },
        { param($r) $r.activeDirectoryUsers },
        { param($r) $r.active_directory_users },
        { param($r) $r.items },
        { param($r) $r.results },
        { param($r) $r.records },
        { param($r) $r.content },
        { param($r) $r.rows },
        { param($r) $r.list },
        { param($r) $r.values },
        { param($r) $r.data }
    )
    foreach ($getter in $candidates) {
        try {
            $val = & $getter $response
            if ($val -is [array] -and $val.Count -gt 0) {
                if (Test-IsLikelyAdUserObject $val[0]) { return $val }
            }
            if ($val -is [PSCustomObject] -or $val -is [hashtable]) {
                $nested = Extract-ActiveDirectoryUsersFromResponse $val
                if ($nested -and $nested.Count -gt 0) { return $nested }
            }
        } catch {}
    }
    return (Find-ActiveDirectoryUserArrayDeep $response 0)
}

function Test-IsAdpaTaskOrScenario($obj) {
    if ($null -eq $obj) { return $false }
    $sat = $obj.singleActionType
    if ($sat -eq "AdPasswordAssessment") { return $true }
    $taskType = if ($obj.type) { $obj.type } else { "" }
    # Scenario uses name; /api/v1/taskRun uses taskRunName
    $dispName = if ($obj.name) { $obj.name } elseif ($obj.taskRunName) { $obj.taskRunName } else { "" }
    # Many builds omit singleActionType; UI shows type e.g. "Targeted Testing - AD Password Strength Assessment"
    if ($taskType -match "AD Password|AdPassword|ADPA" -or $dispName -match "AD Password|AdPassword|ADPA") {
        return $true
    }
    return $false
}

function Get-ADPATaskRuns($penteraAddress, $headers) {
    Write-Host "[*] Fetching ADPA task runs (AD Password Strength Assessment)..." -ForegroundColor Cyan
    
    $allTaskRuns = @()
    $taskRuns = $null
    
    # /testing_history - see DOCUMENTATION.md; try several query shapes (float, narrow window).
    $queryVariants = Get-TestingHistoryQueryStringVariants
    $bases = @(
        "https://$penteraAddress/pentera/api/v1/testing_history",
        "https://$penteraAddress/api/v1/testing_history"
    )
    
    $response = $null
    foreach ($base in $bases) {
        foreach ($q in $queryVariants) {
            $testingHistoryUri = "$base`?$q"
            Write-Host "    [*] Trying: GET $testingHistoryUri" -ForegroundColor Gray
            $response = Invoke-PenteraApi -Uri $testingHistoryUri -Method "GET" -Headers $headers
            if ($response) {
                Write-Host "    [+] Success!" -ForegroundColor Green
                break
            }
        }
        if ($response) { break }
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
    
    Write-Host "    [*] Filtering for ADPA (singleActionType AdPasswordAssessment or name/type hints)..." -ForegroundColor Gray
    
    foreach ($task in $taskRuns) {
        if (Test-IsAdpaTaskOrScenario $task) {
            $allTaskRuns += $task
        }
    }
    
    # If no ADPA filter matched, show available types
    if ($allTaskRuns.Count -eq 0) {
        Write-Host "[!] No AD Password Assessment tests found." -ForegroundColor Yellow
        
        # Show available task types for debugging
        $types = @{}
        foreach ($task in $taskRuns) {
            $t = if ($task.singleActionType) { $task.singleActionType } elseif ($task.type) { $task.type } else { "unknown" }
            if (!$types.ContainsKey($t)) { $types[$t] = 0 }
            $types[$t]++
        }
        Write-Host "    Available singleActionType / type values:" -ForegroundColor Gray
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
    
    # DOCUMENTATION/swagger use /pentera/api/v1 + /task_run/... but many builds expose AD users only
    # on the legacy mount: /api/v1/taskRun/... (POST). Your 405/404 on /pentera/... + 200 on /api/v1/taskRun confirms this.
    $pathTemplates = @(
        "/api/v1/taskRun/{0}/users/activeDirectoryUsers",
        "/api/v1/task_run/{0}/users/activeDirectoryUsers",
        "/pentera/api/v1/taskRun/{0}/users/activeDirectoryUsers",
        "/pentera/api/v1/task_run/{0}/users/activeDirectoryUsers"
    )
    
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
    $savedRaw = $false
    
    foreach ($tpl in $pathTemplates) {
        $rel = $tpl -f $taskId
        $usersUri = "https://$penteraAddress$rel"
        
        Write-Host "        [*] POST $usersUri" -ForegroundColor Gray
        $response = Invoke-PenteraApi -Uri $usersUri -Method "POST" -Headers $headers -Body $body
        
        if (-not $response) {
            Write-Host "        [*] GET $usersUri" -ForegroundColor Gray
            $response = Invoke-PenteraApi -Uri $usersUri -Method "GET" -Headers $headers
        }
        
        if ($response) {
            if ($saveRawJson -and -not $savedRaw) {
                $rawJsonPath = Join-Path $PSScriptRoot "raw_response_$taskId.json"
                $response | ConvertTo-Json -Depth 20 | Out-File -FilePath $rawJsonPath -Encoding UTF8
                Write-Host "        [+] Full raw response saved to: $rawJsonPath" -ForegroundColor Green
                $savedRaw = $true
            }
            if ($debugMode) {
                Write-Host "        [DEBUG] Response keys: $($response.PSObject.Properties.Name -join ', ')" -ForegroundColor Magenta
                $responseJson = $response | ConvertTo-Json -Depth 5 -Compress
                if ($responseJson.Length -gt 500) {
                    Write-Host "        [DEBUG] Response (truncated): $($responseJson.Substring(0, 500))..." -ForegroundColor Magenta
                } else {
                    Write-Host "        [DEBUG] Response: $responseJson" -ForegroundColor Magenta
                }
            }
            if ($response.meta -and $response.meta.token) {
                $script:currentToken = $response.meta.token
            }
            $users = Extract-ActiveDirectoryUsersFromResponse $response
            if ($users -and $users.Count -gt 0) {
                Write-Host "        [+] Success! Found $($users.Count) users" -ForegroundColor Green
                return $users
            }
            Write-Host "        [!] No users in this response shape; trying next path..." -ForegroundColor Yellow
        }
    }
    
    Write-Host "        [-] No AD users returned from any known endpoint for this task." -ForegroundColor Red
    return @()
}

function Format-PenteraUnixEpoch($Value) {
    <# Converts Unix time in seconds or milliseconds to UTC string yyyy-MM-dd HH:mm:ss UTC. #>
    if ($null -eq $Value -or $Value -eq '') { return $null }
    $s = $Value -as [string]
    if ($s -notmatch '^-?\d+(\.\d+)?$') { return $null }
    try {
        $n = [double]$Value
        if ($n -le 0) { return $null }
        if ($n -ge 1000000000000) {
            $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([long][math]::Round($n))
        } else {
            $dt = [DateTimeOffset]::FromUnixTimeSeconds([long][math]::Round($n))
        }
        return $dt.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss") + " UTC"
    } catch {
        return $null
    }
}

function Test-IsTimestampColumnName([string]$Name) {
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    $n = $Name.ToLowerInvariant()
    $explicit = @(
        'lastlogon','passwordlastset','pwdlastset','badpasswordtime','lastlogontimestamp','accountexpires',
        'whencreated','whenchanged','lastlogoff','badpwdtime'
    )
    if ($explicit -contains $n) { return $true }
    if ($n -match '(timestamp|logon|expires)$') { return $true }
    if ($n -match '^pwd' -and $n -match 'set') { return $true }
    return $false
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
    $baseColumns = @("task_id", "task_name", "template_id", "username", "displayName", "samAccountName", 
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
                elseif (Test-IsTimestampColumnName $col) {
                    $readable = Format-PenteraUnixEpoch $value
                    if ($readable) { $value = $readable }
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

function Get-ApiV1TaskRunList($penteraAddress, $headers) {
    <# Returns task run objects from /api/v1/taskRun (GET, or POST with pagination if GET fails). #>
    $url = "https://$penteraAddress/api/v1/taskRun"
    Write-Host "[*] GET $url" -ForegroundColor DarkGray
    $resp = Invoke-PenteraApi -Uri $url -Method "GET" -Headers $headers
    if ($resp) {
        if ($resp.taskRuns) { return @($resp.taskRuns) }
        if ($resp.task_runs) { return @($resp.task_runs) }
    }
    $bodyObj = @{
        offset = 0
        items_per_page = 500
        sort = @{ direction = "DESC"; key = "startTime" }
        filters = @{}
        unique_fields = @("state")
    }
    $body = $bodyObj | ConvertTo-Json -Depth 10 -Compress
    Write-Host "[*] POST $url (pagination fallback)" -ForegroundColor DarkGray
    $resp = Invoke-PenteraApi -Uri $url -Method "POST" -Headers $headers -Body $body
    if ($resp) {
        if ($resp.taskRuns) { return @($resp.taskRuns) }
        if ($resp.task_runs) { return @($resp.task_runs) }
    }
    return @()
}

function Show-DiscoverAdpaTaskRuns($penteraAddress, $headers) {
    Write-Host "=== ADPA task runs (GET /api/v1/taskRun) ===" -ForegroundColor Cyan
    Write-Host "ADPA runs: singleActionType = AdPasswordAssessment and/or type/name heuristics on taskRunName." -ForegroundColor Gray
    Write-Host "Use taskRunId with -TaskId for export (not templateId)." -ForegroundColor Gray
    Write-Host ""
    
    $allTaskRuns = @(Get-ApiV1TaskRunList -penteraAddress $penteraAddress -headers $headers)
    if ($allTaskRuns.Count -eq 0) {
        Write-Host "[-] Could not load /api/v1/taskRun." -ForegroundColor Red
        Write-Host ""
        return
    }
    Write-Host "[+] Loaded $($allTaskRuns.Count) task run(s)." -ForegroundColor Green
    $adpa = @($allTaskRuns | Where-Object { Test-IsAdpaTaskOrScenario $_ })
    Write-Host "ADPA runs (matched): $($adpa.Count)" -ForegroundColor Green
    Write-Host ""
    if ($adpa.Count -eq 0) {
        Write-Host "  (none matched ADPA heuristics)" -ForegroundColor Yellow
        Write-Host ""
        return
    }
    $sorted = @($adpa | Sort-Object { [double]($_.startTime) } -Descending)
    foreach ($r in $sorted) {
        Write-Host "  taskRunId=$($r.taskRunId)" -ForegroundColor White
        Write-Host "    taskRunName: $($r.taskRunName)" -ForegroundColor Gray
        Write-Host "    templateId: $($r.templateId)" -ForegroundColor Gray
        Write-Host "    singleActionType: $($r.singleActionType)" -ForegroundColor Gray
        $st = Format-PenteraUnixEpoch $r.startTime
        $et = Format-PenteraUnixEpoch $r.endTime
        $stDisp = if ($st) { "$st (unix $($r.startTime))" } else { "$($r.startTime)" }
        $etDisp = if ($et) { "$et (unix $($r.endTime))" } else { "$($r.endTime)" }
        Write-Host "    status: $($r.status)  startTime: $stDisp" -ForegroundColor DarkGray
        Write-Host "    endTime: $etDisp" -ForegroundColor DarkGray
        Write-Host ""
    }
}

function Invoke-TestingHistoryDiscoverProbe($penteraAddress, $headers) {
    Write-Host '=== testing_history [optional] often HTTP 400 for API clients ===' -ForegroundColor Cyan
    $qh = Get-TestingHistoryQueryStringVariants
    $probeUrl = "https://$penteraAddress/pentera/api/v1/testing_history?$($qh[0])"
    Write-Host "[*] Single probe: GET $probeUrl" -ForegroundColor Gray
    
    $params = @{
        Uri             = $probeUrl
        Method          = "GET"
        Headers         = $headers
        UseBasicParsing = $true
    }
    try {
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            $response = Invoke-RestMethod @params -SkipCertificateCheck
        } else {
            $rawResponse = Invoke-WebRequest @params
            $response = $rawResponse.Content | ConvertFrom-Json
        }
        $n = 0
        if ($response.task_runs) { $n = $response.task_runs.Count }
        elseif ($response.taskRuns) { $n = $response.taskRuns.Count }
        Write-Host "[OK] testing_history returned 200 - task_runs count: $n" -ForegroundColor Green
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
        Write-Host "[SKIP] testing_history failed ($statusCode). This is common - batch listing uses GET /api/v1/taskRun instead." -ForegroundColor Yellow
        if ($errorBody) {
            Write-Host "    Server message: $errorBody" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

function Invoke-DiscoverEndpoints($penteraAddress, $headers, $sampleTaskId) {
    Write-Host "[*] Discovering API usage for ADPA export..." -ForegroundColor Cyan
    Write-Host ""
    
    Show-DiscoverAdpaTaskRuns -penteraAddress $penteraAddress -headers $headers
    Invoke-TestingHistoryDiscoverProbe -penteraAddress $penteraAddress -headers $headers
    
    $endpointsToTest = [System.Collections.ArrayList]::new()
    
    $discoverAdBody = (@{
        offset = 0
        items_per_page = 10000
        sort = @{ direction = "ASC"; key = "passwordCrackedPhase" }
        filters = @{}
        unique_fields = @("state")
    } | ConvertTo-Json -Depth 10 -Compress)
    
    if ($sampleTaskId) {
        $adUserEndpoints = @(
            @{ Uri = "https://$penteraAddress/api/v1/taskRun/$sampleTaskId/users/activeDirectoryUsers"; Method = "POST"; Body = $discoverAdBody; Description = "AD Users POST /api/v1/taskRun (often the working route)" },
            @{ Uri = "https://$penteraAddress/api/v1/task_run/$sampleTaskId/users/activeDirectoryUsers"; Method = "POST"; Body = $discoverAdBody; Description = "AD Users POST /api/v1/task_run" },
            @{ Uri = "https://$penteraAddress/pentera/api/v1/task_run/$sampleTaskId/users/activeDirectoryUsers"; Method = "POST"; Body = $discoverAdBody; Description = "AD Users POST /pentera/task_run" },
            @{ Uri = "https://$penteraAddress/pentera/api/v1/taskRun/$sampleTaskId/users/activeDirectoryUsers"; Method = "POST"; Body = $discoverAdBody; Description = "AD Users POST /pentera/taskRun" },
            @{ Uri = "https://$penteraAddress/pentera/api/v1/task_run/$sampleTaskId/achievements"; Method = "GET"; Description = "Achievements (swagger)" },
            @{ Uri = "https://$penteraAddress/pentera/api/v1/task_run/$sampleTaskId/hosts"; Method = "GET"; Description = "Hosts (swagger)" }
        )
        foreach ($x in $adUserEndpoints) { [void]$endpointsToTest.Add($x) }
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
            if ($ep.Body) {
                $params["Body"] = $ep.Body
                $params["ContentType"] = "application/json"
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
    
    if ($endpointsToTest.Count -eq 0) {
        Write-Host 'Tip: run -Discover -TaskId <task-run-id> to probe password export URLs.' -ForegroundColor Cyan
    } else {
        Write-Host "Probe complete. Use -TaskId with a task run ID for password export (see ADPA task runs above)." -ForegroundColor Cyan
    }
}

function Get-ADPATaskRunsFromApiV1TaskRun($penteraAddress, $headers) {
    Write-Host "[*] Fetching ADPA task runs from /api/v1/taskRun..." -ForegroundColor Cyan
    $all = @(Get-ApiV1TaskRunList -penteraAddress $penteraAddress -headers $headers)
    if ($all.Count -eq 0) {
        Write-Host "[-] No task runs from /api/v1/taskRun." -ForegroundColor Red
        return @()
    }
    Write-Host "    [+] Loaded $($all.Count) task run(s)" -ForegroundColor Green
    $adpa = @($all | Where-Object { Test-IsAdpaTaskOrScenario $_ })
    Write-Host "    [+] $($adpa.Count) ADPA run(s) after filter" -ForegroundColor Green
    if ($adpa.Count -eq 0) {
        Write-Host '    [!] No runs matched ADPA heuristics - run an ADPA test or use -TaskId.' -ForegroundColor Yellow
    }
    return @($adpa)
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

# Discovery mode (-TaskId or -TestEndpoint supplies a sample task run ID for AD user probes)
if ($Discover) {
    $discoverSampleId = $TaskId
    if ($TestEndpoint) { $discoverSampleId = $TestEndpoint }
    Invoke-DiscoverEndpoints -penteraAddress $penteraAddress -headers $headers -sampleTaskId $discoverSampleId
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
        $taskRuns = Get-ADPATaskRunsFromApiV1TaskRun -penteraAddress $penteraAddress -headers $headers
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
        # testing_history often returns camelCase (taskRunId, taskRunName, templateId); swagger uses snake_case
        $taskId = $task.taskRunId
        if (!$taskId) { $taskId = $task.task_run_id }
        if (!$taskId) { $taskId = $task.id }
        if (!$taskId) { $taskId = $task.task_id }
        if (!$taskId) { $taskId = $task.taskId }
        
        $taskName = $task.taskRunName
        if (!$taskName) { $taskName = $task.name }
        if (!$taskName) { $taskName = $task.task_name }
        
        $templateId = $task.templateId
        if (!$templateId) { $templateId = $task.template_id }
        
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
            if ($templateId) {
                $user | Add-Member -NotePropertyName "template_id" -NotePropertyValue $templateId -Force
            }
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
