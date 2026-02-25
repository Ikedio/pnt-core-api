# Batch Scenario Cloner

This application allows for the batch creation of new Pentera Testing Scenarios by cloning an existing "template" scenario and updating its name and IP ranges.

## Folder Structure
- `/ps`: PowerShell implementation.
- `/python`: Python implementation.
- `scenarios.csv`: Input file for batch processing.

## Input Format (scenarios.csv)
The application expects a CSV file with a semicolon (`;`) delimiter and the following columns:
`id;name;ips`

- **id**: The ID of the existing Testing Scenario (template) to clone.
- **name**: The name for the new scenario.
- **ips**: A comma-separated list of IP addresses or ranges.

### Example
```csv
1234;BB di Test; 192.168.178.1, 192.168.178.3, 192.168.178.4
61a64c40e1c9b9f68a24853b;Production Scan; 10.0.0.1-10.0.0.254
```

## Usage Instructions

### Python Implementation
Located in `/python`.

#### 1. Setup
```bash
cd /services/core_api/clone_scenarios_batch/python
# Create and activate virtual environment
python3 -m venv venv
source venv/bin/activate
# Install dependencies
pip install -r requirements.txt
```

#### 2. Extraction Mode
Extract existing scenario IDs to prepare your CSV:
```bash
python batch_clone.py --extract
```
This creates `extracted_scenarios.csv` with `template_id;name;description;type;ips`.

#### 3. Batch Clone Mode
Prepare your `scenarios.csv` and run:
```bash
python batch_clone.py scenarios.csv
```

---

### PowerShell Implementation
Located in `/ps`.

#### 1. Extraction Mode
```powershell
cd /services/core_api/clone_scenarios_batch/ps
.\BatchCloneScenarios.ps1 -Extract
```
This creates `extracted_scenarios.csv` in the current folder.

#### 2. Batch Clone Mode
```powershell
.\BatchCloneScenarios.ps1 -CsvPath "scenarios.csv"
```

---

## API Endpoint Used
`POST /pentera/api/v1/testing_scenario/{template_id}/clone`

*Note: The script automatically tries both `/api/v1/` and `/pentera/api/v1/` prefixes for compatibility.*

### Query Parameters
- `name`: Name for the new scenario.
- `description`: Description for the new scenario (defaults to "Cloned via Batch Script").

### Body (JSON)
```json
{
  "ip_ranges": [
    {
      "fromIp": "192.168.178.1",
      "toIp": "192.168.178.1"
    },
    ...
  ]
}
```

## Authentication
The application uses the Pentera API authentication flow:
1. Login via `/auth/login` using `client_id` and `tgt`.
2. Use the returned `token` in the `Authorization` header for the clone request:
   `Authorization: Basic [Base64(token:)]`
