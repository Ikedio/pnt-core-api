# ------------------------- Batch Scenario Cloner ------------------------- 
# Description: 
#   Clones Pentera scenarios in batch from CSV files.
#
# Usage:
#   .\BatchCloneScenarios.ps1 -CsvPath "C:\Path\To\CSVs"
# -------------------------------------------------------------------------

param(
    [Parameter(Mandatory=$false)]
    [string]$CsvPath,
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = (Join-Path $PSScriptRoot "pentera_api.conf"),

    [Parameter(Mandatory=$false)]
    [switch]$Extract
)

# --- Configuration & Auth ---
# Disable SSL verification for all versions of PowerShell
if ($PSVersionTable.PSVersion.Major -le 5) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Get-Config($path) {
    if (!(Test-Path $path)) {
        Write-Error "Config file not found: $path"
        exit
    }
    $config = @{}
    Get-Content $path | Where-Object {$_ -match "="} | ForEach-Object {
        $key, $value = $_.Split("=", 2)
        $config[$key.Trim()] = $value.Trim()
    }
    return $config
}

function Login($config) {
    # Extract base address
    $rawAddress = $config["PENTERA_ADDRESS"]
    $penteraAddress = $rawAddress.Split("/")[0]
    $loginUri = "https://$penteraAddress/pentera/api/v1/auth/login"
    
    # Debug: Show the URL being called
    Write-Host "[*] Attempting login to: $loginUri" -ForegroundColor Gray

    $bodyObj = @{
        client_id = $config["CLIENT_ID"].Trim()
        tgt       = $config["TGT"].Trim()
    }
    # Use -Compress and ensure no BOM or extra formatting
    $body = $bodyObj | ConvertTo-Json -Compress
    
    # Force TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
            # Windows PowerShell 5.1 fallback
            $rawResponse = Invoke-WebRequest @params
            $response = $rawResponse.Content | ConvertFrom-Json
        }
        
        if ($response.meta.status -eq "success") {
            $newTgt = $response.tgt
            if ($newTgt -and $newTgt -ne $config["TGT"]) {
                Update-ConfigTgt -ConfigPath $global:currentConfigPath -NewTgt $newTgt
            }
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

# --- Parsing IPs ---
function Convert-IpsToJson($ipsString) {
    $ranges = @()
    # Using semicolon separator as requested for IP list in CSV
    $ips = $ipsString.Split(";")
    foreach ($ip in $ips) {
        $cleanIp = $ip.Trim()
        if ($cleanIp -match "-") {
            $parts = $cleanIp.Split("-")
            $ranges += @{ fromIp = $parts[0].Trim(); toIp = $parts[1].Trim() }
        } else {
            $ranges += @{ fromIp = $cleanIp; toIp = $cleanIp }
        }
    }
    return @{ ip_ranges = $ranges }
}

# --- Main Execution ---
$global:currentConfigPath = $ConfigPath
$config = Get-Config $ConfigPath
$token = Login $config

if (!$token) {
    Write-Host "[-] Could not authenticate. Exiting." -ForegroundColor Red
    exit
}

$encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($token):"))
$headers = @{
    "Authorization" = "Basic $encodedToken"
    "Accept"        = "application/json"
}

$penteraAddress = $config["PENTERA_ADDRESS"].Split("/")[0]

if ($Extract) {
    Write-Host "[*] Extracting existing scenarios..." -ForegroundColor Cyan
    $scenariosUri = "https://$penteraAddress/pentera/api/v1/testing_scenarios"
    
    try {
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            $response = Invoke-RestMethod -Uri $scenariosUri -Method Get -Headers $headers -SkipCertificateCheck
        } else {
            $response = Invoke-RestMethod -Uri $scenariosUri -Method Get -Headers $headers
        }
        $scenarios = $null
        
        if ($response.testing_scenarios) { $scenarios = $response.testing_scenarios }
        elseif ($response.scenarios) { $scenarios = $response.scenarios }
        elseif ($response.templates) { $scenarios = $response.templates }
        elseif ($response -is [array]) { $scenarios = $response }

        # Fallback to /templates if empty
        if (!$scenarios -or $scenarios.Count -eq 0) {
            Write-Host "[*] testing_scenarios empty, trying fallback: /templates" -ForegroundColor Gray
            $templatesUri = "https://$penteraAddress/pentera/api/v1/templates"
            if ($PSVersionTable.PSVersion.Major -gt 5) {
                $response = Invoke-RestMethod -Uri $templatesUri -Method Get -Headers $headers -SkipCertificateCheck
            } else {
                $response = Invoke-RestMethod -Uri $templatesUri -Method Get -Headers $headers
            }
            if ($response.templates) { $scenarios = $response.templates }
            elseif ($response -is [array]) { $scenarios = $response }
        }

        if ($scenarios) {
            $extractFile = Join-Path $PSScriptRoot "extracted_scenarios.csv"
            "template_id,name,description,type" | Out-File -FilePath $extractFile -Encoding utf8
            foreach ($s in $scenarios) {
                $s_id = $s.template_id
                if (!$s_id) { $s_id = $s.id }
                "$($s_id),$($s.name),$($s.description),$($s.type)" | Out-File -FilePath $extractFile -Encoding utf8 -Append
            }
            Write-Host "[+] Successfully extracted $($scenarios.Count) scenarios to $extractFile" -ForegroundColor Green
        } else {
            Write-Host "[-] No scenarios found." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[-] Failed to extract scenarios: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit
}

if (!$CsvPath) {
    Write-Host "[-] Please provide -CsvPath (file or directory) or use -Extract mode." -ForegroundColor Red
    exit
}

if (!(Test-Path $CsvPath)) {
    Write-Error "Path not found: $CsvPath"
    exit
}

# Identify all CSV files
$csvFiles = @()
if (Test-Path $CsvPath -PathType Container) {
    $csvFiles = Get-ChildItem -Path $CsvPath -Filter "*.csv"
} else {
    $csvFiles = Get-Item -Path $CsvPath
}

if ($csvFiles.Count -eq 0) {
    Write-Host "[-] No CSV files found in: $CsvPath" -ForegroundColor Yellow
    exit
}

foreach ($file in $csvFiles) {
    # Scenario name from file name (without extension)
    $scenarioName = $file.BaseName
    Write-Host "[*] Processing file: $($file.Name) -> Scenario Name: $scenarioName" -ForegroundColor Cyan

    # Read CSV with comma delimiter
    # Expected columns: templateid, nomecliente, codiceapplicazione, ips
    $rows = Import-Csv -Path $file.FullName -Delimiter ","

    foreach ($row in $rows) {
        # Skip if templateid is literal "templateid" or empty (header safety)
        if (!$row.templateid -or $row.templateid -eq "templateid") { continue }
        
        $templateId = $row.templateid.Trim()
        
        # Description from column B (nomecliente) and C (codiceapplicazione)
        $description = "$($row.nomecliente.Trim())_$($row.codiceapplicazione.Trim())"
        
        # IPs from column D (ips)
        $ips = $row.ips.Trim()
        
        Write-Host "    [>] Cloning Template: $templateId | Description: $description" -ForegroundColor Gray
        
        $cloneUri = "https://$penteraAddress/pentera/api/v1/testing_scenario/$($templateId)/clone?name=$([uri]::EscapeDataString($scenarioName))&description=$([uri]::EscapeDataString($description))"
        $bodyJson = Convert-IpsToJson $ips | ConvertTo-Json -Depth 10
        
        try {
            if ($PSVersionTable.PSVersion.Major -gt 5) {
                $response = Invoke-RestMethod -Uri $cloneUri -Method Post -Headers $headers -Body $bodyJson -ContentType "application/json" -SkipCertificateCheck
            } else {
                $rawResponse = Invoke-WebRequest -Uri $cloneUri -Method Post -Headers $headers -Body $bodyJson -ContentType "application/json" -UseBasicParsing
                $response = $rawResponse.Content | ConvertFrom-Json
            }
            Write-Host "    [+] Success! New Scenario ID: $($response.template.id)" -ForegroundColor Green
            
            # Update token for next call if provided in meta
            if ($response.meta.token) {
                $encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($response.meta.token):"))
                $headers["Authorization"] = "Basic $encodedToken"
            }
        } catch {
            Write-Host "    [-] Failed to clone: $($_.Exception.Message)" -ForegroundColor Red
            if ($_.Exception.Response) {
                $responseStream = $_.Exception.Response.GetResponseStream()
                if ($responseStream) {
                    $reader = New-Object System.IO.StreamReader($responseStream)
                    Write-Host "        Details: $($reader.ReadToEnd())" -ForegroundColor Yellow
                }
            }
        }
    }
}
