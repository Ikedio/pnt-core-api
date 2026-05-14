# Disclaimer:
#   This PowerShell script is provided "AS IS" to illustrate potential interactions with the Pentera API.
#   It is intended as a starting point for customers and is not an officially supported product.
#
#   * No Warranties: This script comes with no warranties of any kind, either expressed or implied.
#     This includes, but is not limited to, warranties of fitness for a particular purpose or merchantability.
#   * Support: No official support is provided for this script.
#     It may be updated periodically, but updates are not guaranteed.
#   * Liability: The authors and distributors of this script shall not be held liable for any damages arising from its use.
#     This includes direct, indirect, special, incidental, or consequential damages.
#   * Modifications: You are free to modify and adapt this script for your own purposes.
#     However, any modifications made are at your own risk.
#
#   By using this script, you acknowledge and accept the terms of this disclaimer.
#
# Usage:
#   Import-Module .\approve_actions_v5.ps1
#   Approve-Actions -All -IntervalMinutes 15 -DurationHours 3

# -- Configuration --

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

$configPath = Join-Path $PSScriptRoot "pentera_api.conf"
$global:penteraAddress = $null
$global:clientId = $null
$global:tgt = $null
$global:token = $null

function Get-ConfigObject($configPath) {
    $config = @{}
    Get-Content $configPath | Where-Object {$_} | ForEach-Object {
        $key, $value = $_.Split("=")
        $config[$key.Trim()] = $value.Trim()
    }

    # Example: 192.168.20.30:8181/pentera/api/v1
    # We keep it as-is and append paths like /auth/login, /testing_history, etc.
    $global:penteraAddress = $config["PENTERA_ADDRESS"].TrimEnd('/')

    $global:clientId = $config["CLIENT_ID"]
    $global:tgt      = $config["TGT"]

    return $config
}

function Update-TGT($tgt) {
    $global:tgt = $tgt
    (Get-Content $configPath) |
        ForEach-Object { $_ -replace '^TGT\s*=.*', "TGT = $tgt" } |
        Set-Content $configPath
}

function Call-API($Method, $Endpoint, $OptionalBody, $OptionalContentType, $Raw) {
    if (-not $global:token) {
        Write-Host "[!] Token is empty. Did Login() succeed?" -ForegroundColor Red
    }

    $headers = @{
        "Accept"        = "application/json, text/plain, */*"
        # New API: token directly in Authorization header (no Basic/Base64)
        "Authorization" = $global:token
    }

    if ($OptionalContentType) {
        $headers["Content-Type"] = $OptionalContentType
    }

    $params = @{
        Uri     = "$Endpoint"
        Method  = "$Method"
        Headers = $headers
    }

    if ($OptionalBody) {
        $params.Body = $OptionalBody
    }

    try {
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            $response = Invoke-WebRequest @params -SkipCertificateCheck -ErrorAction Stop
        } else {
            $response = Invoke-WebRequest @params -ErrorAction Stop
        }

        if ($Raw) {
            return $response
        } else {
            $json = $response.Content | ConvertFrom-Json

            # If the server still returns a meta.token, keep it fresh
            if ($json.meta -and $json.meta.token) {
                $global:token = $json.meta.token
            }

            return $json
        }
    } catch {
        Write-Host "[!] API Call failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Login($Verbose) {
    if ($Verbose) {
        Write-Host "[*] Logging into Pentera API and generating token" -ForegroundColor Cyan
    }

    $config = Get-ConfigObject $configPath

    $loginParams = @{
        Uri         = "https://$penteraAddress/auth/login"
        Method      = "POST"
        Headers     = @{
            "Content-Type" = "application/json;charset=UTF-8"
            "Accept"       = "application/json, text/plain, */*"
        }
        Body        = (@{
            "client_id" = $global:clientId
            "tgt"       = $global:tgt
        } | ConvertTo-Json)
    }

    try {
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            $response = Invoke-WebRequest @loginParams -SkipCertificateCheck -ErrorAction Stop
        } else {
            $response = Invoke-WebRequest @loginParams -ErrorAction Stop
        }

        $jsonResponse = $response.Content | ConvertFrom-Json

        # New API usually returns { "tgt": "...", "token": "..." }
        $tgtFromResp   = $jsonResponse.tgt
        $tokenFromResp = $jsonResponse.token

        # Backwards compatibility: try meta.{tgt,token}
        if (-not $tgtFromResp   -and $jsonResponse.meta) { $tgtFromResp   = $jsonResponse.meta.tgt }
        if (-not $tokenFromResp -and $jsonResponse.meta) { $tokenFromResp = $jsonResponse.meta.token }

        if ($tokenFromResp) {
            $global:token = $tokenFromResp
            if ($tgtFromResp) {
                Update-TGT $tgtFromResp
            }
            if ($Verbose) {
                Write-Host "[+] Login succeeded, token acquired" -ForegroundColor Green
            }
        } else {
            Write-Host "[!] Login failed: token not found in response" -ForegroundColor Red
            $jsonResponse | ConvertTo-Json -Depth 5 | Write-Host
        }
    } catch {
        Write-Host "[!] Login error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Helper_Get-TestingHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$OutPath
    )

    if (-not $global:token) {
        Login($false)
    }

    Write-Host "[*] Fetching testing history (last 24 hours)"

    # Last 24 hours – adjust if you want a wider window
    $now       = Get-Date
    $yesterday = $now.AddDays(-1)

    $startMs = [int64]([DateTimeOffset]$yesterday).ToUnixTimeMilliseconds()
    $endMs   = [int64]([DateTimeOffset]$now).ToUnixTimeMilliseconds()

    $endpoint = "https://$penteraAddress/testing_history?start_timestamp=$startMs&end_timestamp=$endMs"

    $jsonResponse = Call-API -Endpoint $endpoint -Method "GET"

    if (-not $jsonResponse) {
        Write-Host "[!] /testing_history returned no data" -ForegroundColor Red
        return $null
    }

    if ($jsonResponse.task_runs) {
        $taskRuns = $jsonResponse.task_runs

        if ($OutPath) {
            $taskRuns | ConvertTo-Json -Depth 100 | Set-Content -Path $OutPath
            Write-Host ("[+] {0} total tasks fetched" -f $taskRuns.Count)
            Write-Host ("[+] Saved to {0}" -f $OutPath)
            return
        }

        return $taskRuns
    } else {
        Write-Host "[!] Unexpected response format from /testing_history" -ForegroundColor Yellow
        $jsonResponse | ConvertTo-Json -Depth 5 | Write-Host
        return $null
    }
}

function Get-RunningTaskId {
    $taskRuns = Helper_Get-TestingHistory
    if (-not $taskRuns) {
        Write-Host "[!] No task runs found!" -ForegroundColor Red
        return $null
    }

    # New API: status, start_timestamp, task_run_id, name
    $runningTask = $taskRuns |
        Where-Object { $_.status -eq "running" } |
        Sort-Object start_timestamp -Descending |
        Select-Object -First 1

    if ($runningTask) {
        Write-Host "[+] Found running task: $($runningTask.name) ($($runningTask.task_run_id))" -ForegroundColor Green
        return $runningTask.task_run_id
    } else {
        Write-Host "[!] No running tasks found!" -ForegroundColor Yellow
        return $null
    }
}

function Helper_Get-Approvals {
    param([string]$TaskId)

    $Endpoint = "https://$penteraAddress/task_run/$TaskId/approvals"
    $jsonResponse = Call-API -Endpoint $Endpoint -Method "GET"

    if ($jsonResponse -and $jsonResponse.approvals) {
        return $jsonResponse.approvals
    } else {
        Write-Host "[!] Failed to fetch approvals or unexpected format" -ForegroundColor Red
        if ($jsonResponse) {
            $jsonResponse | ConvertTo-Json -Depth 5 | Write-Host
        }
        return $null
    }
}

function Helper_Execute-Actions {
    param(
        [string]$TaskId,
        [array]$actionIds
    )

    if (-not $actionIds -or $actionIds.Count -eq 0) {
        Write-Host "[*] No action IDs to approve" -ForegroundColor Yellow
        return
    }

    Write-Host "[*] Approving actions via /task_run/{task_run_id}/approve/{approval_id}..." -ForegroundColor Magenta

    foreach ($id in $actionIds) {
        $Endpoint = "https://$penteraAddress/task_run/$TaskId/approve/$id"
        $jsonResponse = Call-API -Endpoint $Endpoint -Method "POST"

        $approved = $false
        if ($jsonResponse) {
            if ($jsonResponse.PSObject.Properties['success'] -and $jsonResponse.success -eq $true) {
                $approved = $true
            } elseif ($jsonResponse.template -and $jsonResponse.template.success) {
                $approved = $true
            }
        }
        if ($approved) {
            Write-Host "[+] Approved action $id" -ForegroundColor Green
        } else {
            Write-Host "[!] Failed to approve action $id" -ForegroundColor Red
            if ($jsonResponse) {
                $jsonResponse | ConvertTo-Json -Depth 5 | Write-Host
            }
        }
    }
}

function Approve-Actions {
    [CmdletBinding()]
    param(
        [Parameter()] [switch]$All,
        [int]$IntervalMinutes = 1,
        [Parameter(Mandatory = $true)] [int]$DurationHours
    )

    if (-not $All) {
        Write-Host "Only the '-All' option is supported."
        return
    }

    Login($true)

    Write-Host "Starting continuous approval loop..."

    $totalRuntimeSeconds = $DurationHours * 3600
    $intervalSeconds = $IntervalMinutes * 60
    $elapsedSeconds = 0
    $totalApproved = 0
    $cycles = 0

    while ($elapsedSeconds -lt $totalRuntimeSeconds) {
        Write-Host ""
        Write-Host "Checking for running task..."
        $TaskId = Get-RunningTaskId

        if ($TaskId) {
            Write-Host "Running task found: $TaskId"
            try {
                $actionsIds = @()
                $approvals = Helper_Get-Approvals $TaskId

                if ($approvals) {
                    foreach ($item in $approvals) {
                        # New API fields: status + approval_id
                        if ($item.status -eq "pending") {
                            $actionsIds += $item.approval_id
                        }
                    }
                }

                if ($actionsIds.Count -eq 0) {
                    Write-Host "No pending approvals found."
                } else {
                    Write-Host "Approving $($actionsIds.Count) actions..."
                    Helper_Execute-Actions -TaskId $TaskId -actionIds $actionsIds
                    $totalApproved += $actionsIds.Count
                }
            } catch {
                Write-Host "Error: $($_.Exception.Message)"
            }
        } else {
            Write-Host "No running task found. Will check again in $IntervalMinutes minutes..."
        }

        $cycles++
        Start-Sleep -Seconds $intervalSeconds
        $elapsedSeconds += $intervalSeconds
    }

    Write-Host ""
    Write-Host "======================="
    Write-Host "   Approval Summary"
    Write-Host "======================="
    Write-Host "Total cycles run       : $cycles"
    Write-Host "Total actions approved : $totalApproved"
    Write-Host "Finished at            : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}
