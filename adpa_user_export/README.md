# ADPA Active Directory User Exporter

Retrieves all ADPA (Active Directory Penetration Assessment) tests from Pentera and extracts Active Directory user data from the `/api/v1/taskRun/{TaskID}/users/activeDirectoryUsers` endpoint. Exports results to CSV.

## Features

- Authenticates with Pentera API using client credentials
- Automatically rotates and persists TGT tokens
- Fetches all ADPA-related task runs
- Extracts Active Directory user data from each task
- Exports consolidated results to CSV with proper formatting
- Supports single task queries and batch processing

## Directory Structure

```
adpa_user_export/
├── README.md
├── ps/                              # PowerShell implementation
│   ├── ExportADPAUsers.ps1
│   ├── pentera_api.conf             # Your config (create from example)
│   └── pentera_api.conf.example
└── python/                          # Python implementation
    ├── export_adpa_users.py
    ├── requirements.txt
    ├── pentera_api.conf             # Your config (create from example)
    └── pentera_api.conf.example
```

## Configuration

Create a `pentera_api.conf` file in the respective folder (ps/ or python/) with your credentials:

```
PENTERA_ADDRESS = your-pentera-server:8181
CLIENT_ID = your-client-id-here
TGT = your-tgt-token-here
```

You can copy from the `.example` file and fill in your values.

## PowerShell Usage

```powershell
# Basic usage (uses default config and output paths)
.\ExportADPAUsers.ps1

# Specify custom config file
.\ExportADPAUsers.ps1 -ConfigPath "C:\Path\To\pentera_api.conf"

# Specify custom output file
.\ExportADPAUsers.ps1 -OutputPath "C:\Path\To\output.csv"

# Query a specific task ID only
.\ExportADPAUsers.ps1 -TaskId "abc123-def456-789"

# Combine options
.\ExportADPAUsers.ps1 -ConfigPath ".\config.conf" -OutputPath ".\users.csv"
```

### PowerShell Requirements

- PowerShell 5.1+ (Windows) or PowerShell Core 6+ (cross-platform)
- No external modules required

## Python Usage

```bash
# Install dependencies
cd python
pip install -r requirements.txt

# Basic usage
python export_adpa_users.py

# Specify custom config file
python export_adpa_users.py --config /path/to/pentera_api.conf

# Specify custom output file
python export_adpa_users.py --output /path/to/output.csv

# Query a specific task ID only
python export_adpa_users.py --task-id abc123-def456-789

# Include ALL tasks (not just ADPA-specific)
python export_adpa_users.py --all-tasks

# Combine options
python export_adpa_users.py -c ./config.conf -o ./users.csv
```

### Python Requirements

- Python 3.7+
- requests library

## Output Format

The exported CSV includes all Active Directory user properties returned by the API, with the following columns prioritized:

| Column | Description |
|--------|-------------|
| task_id | ID of the task run |
| task_name | Name of the task/scenario |
| username | User's username |
| displayName | User's display name |
| samAccountName | SAM account name |
| userPrincipalName | User principal name (UPN) |
| email | Email address |
| distinguishedName | LDAP distinguished name |
| domain | Domain name |
| enabled | Whether account is enabled |
| lastLogon | Last logon timestamp |
| passwordLastSet | Password last set timestamp |
| memberOf | Group memberships (semicolon-separated) |

Additional columns may be included based on the data returned by your Pentera instance.

## API Endpoint

This tool uses the following Pentera API endpoint:

```
GET /pentera/api/v1/taskRun/{TaskID}/users/activeDirectoryUsers
```

*Note: The script automatically tries both `/api/v1/` and `/pentera/api/v1/` prefixes for compatibility.*

## Security Notes

- The tool disables SSL certificate verification for self-signed certificates (common in internal Pentera deployments)
- Config files contain sensitive credentials - protect them appropriately
- TGT tokens are automatically rotated and updated in the config file

## Troubleshooting

### Authentication Failed
- Verify your CLIENT_ID and TGT are correct
- TGT tokens expire; generate a new one from Pentera UI if needed
- Check network connectivity to the Pentera server

### No ADPA Tests Found
- The tool filters for tasks with "ADPA", "ActiveDirectory", or "AD" in their type or name
- Use `--all-tasks` (Python) to include all task runs regardless of type

### Empty User Results
- Not all task runs may have Active Directory user data
- Verify the task has completed and discovered AD users
