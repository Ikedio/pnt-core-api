# Pentera Old Tests Cleaner

Automatically deletes old Pentera test runs based on a configurable retention period. Available in both PowerShell and Python implementations with identical functionality.

## Features

- **Configurable retention period**: Delete tests older than N days
- **Dry-run mode**: Preview what would be deleted without making changes
- **Continuous mode**: Run as a service with configurable interval
- **One-shot mode**: Run once for scheduled task integration
- **Automatic TGT rotation**: Handles Pentera token refresh automatically
- **Comprehensive logging**: Both console and file logging

## Directory Structure

```
delete_old_tests/
├── ps/                          # PowerShell implementation
│   ├── DeleteOldTests.ps1       # Main script
│   └── pentera_api.conf.example # Example configuration
├── python/                      # Python implementation
│   ├── delete_old_tests.py      # Main script
│   ├── requirements.txt         # Python dependencies
│   ├── pentera-cleanup.service  # systemd service file
│   └── pentera_api.conf.example # Example configuration
└── README.md                    # This file
```

## Configuration

Both implementations use the same configuration file format (`pentera_api.conf`):

```
PENTERA_ADDRESS = 192.168.1.100:8181
CLIENT_ID = your-client-id-here
TGT = your-tgt-token-here
```

Copy the example file and fill in your Pentera API credentials:

```bash
# PowerShell
cp ps/pentera_api.conf.example ps/pentera_api.conf

# Python
cp python/pentera_api.conf.example python/pentera_api.conf
```

---

## PowerShell Version

### Requirements
- PowerShell 5.1+ (Windows) or PowerShell Core 7+ (Cross-platform)

### Usage

**One-shot cleanup (delete tests older than 30 days):**
```powershell
.\DeleteOldTests.ps1 -RetentionDays 30
```

**Dry-run (preview what would be deleted):**
```powershell
.\DeleteOldTests.ps1 -RetentionDays 30 -DryRun
```

**Continuous mode (runs every 24 hours):**
```powershell
.\DeleteOldTests.ps1 -RetentionDays 30 -Continuous -IntervalHours 24
```

**Custom configuration file:**
```powershell
.\DeleteOldTests.ps1 -RetentionDays 30 -ConfigPath "C:\path\to\pentera_api.conf"
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-RetentionDays` | int | 30 | Number of days to retain test runs |
| `-ConfigPath` | string | `pentera_api.conf` | Path to configuration file |
| `-Continuous` | switch | false | Run continuously instead of one-shot |
| `-IntervalHours` | double | 24 | Hours between cleanup cycles (continuous mode). Can be decimal (e.g., 0.5 for 30 min). |
| `-DryRun` | switch | false | Preview deletions without executing |
| `-LogPath` | string | `cleanup.log` | Path to log file |

### Running as a Windows Scheduled Task

1. Open Task Scheduler
2. Create a new task with these settings:
   - **Trigger**: Daily at desired time
   - **Action**: Start a program
     - Program: `powershell.exe`
     - Arguments: `-ExecutionPolicy Bypass -File "C:\path\to\DeleteOldTests.ps1" -RetentionDays 30`
   - **General**: Run whether user is logged on or not

### Running as a Windows Service (continuous mode)

Use [NSSM](https://nssm.cc/) to wrap the script as a Windows service:

```cmd
nssm install PenteraCleanup powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\DeleteOldTests.ps1" -RetentionDays 30 -Continuous -IntervalHours 24
nssm start PenteraCleanup
```

---

## Python Version

### Requirements
- Python 3.7+
- `requests` library

### Installation

```bash
cd python

# Create virtual environment
python3 -m venv venv
source venv/bin/activate  # Linux/Mac
# or: venv\Scripts\activate  # Windows

# Install dependencies
pip install -r requirements.txt

# Copy and configure
cp pentera_api.conf.example pentera_api.conf
# Edit pentera_api.conf with your credentials
```

### Usage

**One-shot cleanup (delete tests older than 30 days):**
```bash
python delete_old_tests.py --retention-days 30
```

**Dry-run (preview what would be deleted):**
```bash
python delete_old_tests.py --retention-days 30 --dry-run
```

**Continuous mode (runs every 24 hours):**
```bash
python delete_old_tests.py --retention-days 30 --continuous --interval-hours 24
```

**Custom configuration and log file:**
```bash
python delete_old_tests.py --retention-days 30 --config /path/to/pentera_api.conf --log-file /var/log/pentera-cleanup.log
```

### Arguments

| Argument | Short | Default | Description |
|----------|-------|---------|-------------|
| `--retention-days` | `-r` | 30 | Number of days to retain test runs |
| `--config` | `-c` | `pentera_api.conf` | Path to configuration file |
| `--continuous` | | false | Run continuously instead of one-shot |
| `--interval-hours` | `-i` | 24 | Hours between cleanup cycles (continuous mode). Can be decimal (e.g., 0.5 for 30 min). |
| `--dry-run` | | false | Preview deletions without executing |
| `--log-file` | `-l` | `cleanup.log` | Path to log file |

### Running with cron (Linux)

Add to crontab for daily cleanup at 2 AM:

```bash
crontab -e
```

Add this line:
```
0 2 * * * /opt/pentera-cleanup/venv/bin/python /opt/pentera-cleanup/delete_old_tests.py --retention-days 30 >> /var/log/pentera-cleanup.log 2>&1
```

### Running as a systemd Service (Linux)

1. **Deploy the application:**
   ```bash
   sudo mkdir -p /opt/pentera-cleanup
   sudo cp delete_old_tests.py /opt/pentera-cleanup/
   sudo cp pentera_api.conf /opt/pentera-cleanup/
   
   cd /opt/pentera-cleanup
   sudo python3 -m venv venv
   sudo /opt/pentera-cleanup/venv/bin/pip install requests
   ```

2. **Create service user:**
   ```bash
   sudo useradd -r -s /bin/false pentera
   sudo chown -R pentera:pentera /opt/pentera-cleanup
   ```

3. **Install the service:**
   ```bash
   sudo cp pentera-cleanup.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable pentera-cleanup
   sudo systemctl start pentera-cleanup
   ```

4. **Manage the service:**
   ```bash
   sudo systemctl status pentera-cleanup   # Check status
   sudo systemctl stop pentera-cleanup     # Stop service
   sudo systemctl restart pentera-cleanup  # Restart service
   sudo journalctl -u pentera-cleanup -f   # View logs
   ```

---

## API Endpoints Used

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pentera/api/v1/testing_history` | GET | Fetch completed test runs within a time range |
| `/api/v1/taskRun/deleteBulk` | POST | Delete multiple test runs by ID |

### Testing History Request

The `testing_history` endpoint requires two query parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `start_timestamp` | float | Start of time range in Unix epoch time (milliseconds, decimal) |
| `end_timestamp` | float | End of time range in Unix epoch time (milliseconds, decimal) |

**Example request:**
```
GET https://172.26.186.100:8181/pentera/api/v1/testing_history?start_timestamp=1640017381279.516&end_timestamp=1740017381279.516
```

The scripts automatically calculate:
- `start_timestamp`: Set to year 2000 (in milliseconds) to capture all historical tests
- `end_timestamp`: Set to `(current_time - retention_days)` in milliseconds to get only tests eligible for deletion

### Delete Bulk Request Format

```json
{
  "taskRunsIds": ["id1", "id2", "id3"]
}
```

---

## Logging

Both implementations log to:
- **Console**: All messages with color coding (errors in red, warnings in yellow, success in green)
- **File**: `cleanup.log` in the script directory (configurable)

Example log output:
```
[2026-02-25 10:00:00] [INFO] Pentera Old Tests Cleaner starting...
[2026-02-25 10:00:00] [INFO] Configuration file: /opt/pentera-cleanup/pentera_api.conf
[2026-02-25 10:00:00] [INFO] Retention period: 30 days
[2026-02-25 10:00:00] [INFO] Mode: Continuous (every 24 hours)
[2026-02-25 10:00:00] [INFO] ==================================================
[2026-02-25 10:00:00] [INFO] Starting cleanup cycle (Retention: 30 days)
[2026-02-25 10:00:01] [INFO] Authenticating to: https://192.168.1.100:8181/pentera/api/v1/auth/login
[2026-02-25 10:00:02] [INFO] Authentication successful.
[2026-02-25 10:00:02] [INFO] Trying endpoint: /pentera/api/v1/testing_history
[2026-02-25 10:00:03] [INFO] Successfully retrieved 150 task runs from /pentera/api/v1/testing_history
[2026-02-25 10:00:03] [INFO] Found 45 task runs older than 30 days
[2026-02-25 10:00:03] [INFO] Preparing to delete 45 task runs...
[2026-02-25 10:00:04] [INFO] Successfully deleted 45 task runs.
[2026-02-25 10:00:04] [INFO] Cleanup cycle completed.
[2026-02-25 10:00:04] [INFO] Sleeping for 24 hours until next cycle...
```

---

## Troubleshooting

### Authentication Failures
- Verify `CLIENT_ID` and `TGT` are correct
- TGT tokens expire after 180 days; generate a new one from Pentera
- Check network connectivity to the Pentera server

### No Task Runs Found
- Verify the Pentera server has completed test runs
- Check that the API user has permission to view testing history

### Delete Failures
- Ensure the API user has delete permissions
- Some test runs may be protected or in use

### SSL Certificate Errors
- The scripts disable SSL verification by default for self-signed certificates
- For production, consider adding proper CA certificates

---

## Security Considerations

- Store `pentera_api.conf` with restricted permissions (`chmod 600`)
- Use a dedicated Pentera API user with minimal required permissions
- The TGT token is automatically rotated and updated in the config file
- Consider encrypting the configuration file in sensitive environments
