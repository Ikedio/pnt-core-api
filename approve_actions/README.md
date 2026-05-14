# Approve actions (Pentera API examples)

This folder contains **example** scripts that poll the Pentera API, detect a **running** task from recent testing history, fetch **pending** approvals for that task, and **approve** them in a loop for a fixed duration. They are intended as a starting point for automation (for example unattended test runs that require approval gates).

## Disclaimer

These scripts are provided **as is**, without warranties or official support. See the header comments in each script for the full disclaimer. Use and modify them at your own risk.

## Layout

| Path | Description |
|------|-------------|
| `sh/approve_actions.sh` | Bash implementation (bash 4+, `curl`, `sed`, coreutils; no `jq`). |
| `sh/pentera_api.conf.example` | Example configuration (copy and edit). |
| `ps/approve_actions.ps1` | PowerShell module-style script with `Approve-Actions` and helpers. |
| `ps/pentera_api.conf` | Configuration file read by the PowerShell script (create from the example if missing). |

The Bash script looks for `pentera_api.conf` in **`sh/`** first, then falls back to **`ps/pentera_api.conf`** (same key format as PowerShell).

## Configuration

Create or edit `pentera_api.conf` with three keys (spaces around `=` are fine; lines starting with `#` are ignored in the Bash parser):

```ini
PENTERA_ADDRESS = 192.168.1.100:8181/pentera/api/v1
CLIENT_ID = <your client id>
TGT = <your initial ticket-granting token>
```

- **PENTERA_ADDRESS**: Host and base API path, **without** a `https://` prefix (the scripts prepend `https://`). Example shape: `host:port/pentera/api/v1`.
- **CLIENT_ID** / **TGT**: Used for `POST .../auth/login`. On successful login, **TGT** may be rewritten in the config file with an updated value.

Protect these files like any credential material; do not commit real secrets.

## TLS certificates

Both implementations skip TLS server certificate validation (Bash uses `curl -k`; PowerShell sets a permissive callback and uses `SkipCertificateCheck` where supported). That matches many lab deployments but is **not** appropriate for production without hardening.

## Bash (`sh/approve_actions.sh`)

**Requirements:** bash 4 or newer, `curl`, `sed`, coreutils.

Optional: set `NO_COLOR=1` to disable ANSI colors.

**Usage:**

```bash
chmod +x sh/approve_actions.sh
./sh/approve_actions.sh --all --duration-hours 3 --interval-minutes 15
```

- `--all` — Required; enables the continuous approval loop (the only supported mode).
- `--duration-hours N` — Required; total runtime in hours.
- `--interval-minutes M` — Optional; sleep between polling cycles (default: `1`).

**Help:** `./sh/approve_actions.sh --help`

## PowerShell (`ps/approve_actions.ps1`)

**Usage:** From the `ps` directory, dot-source the script so its functions are available, then call `Approve-Actions`:

```powershell
cd ps
. .\approve_actions.ps1
Approve-Actions -All -DurationHours 3 -IntervalMinutes 15
```

On some PowerShell versions you can use `Import-Module .\approve_actions.ps1` instead of dot-sourcing; behavior depends on your execution policy and how the file is loaded.

- `-All` — Required (only mode supported).
- `-DurationHours` — Mandatory total runtime in hours.
- `-IntervalMinutes` — Optional; default `1`.

The module also exposes helpers such as `Login`, `Get-RunningTaskId`, and `Helper_Get-TestingHistory` for experimentation.

## Behavior summary

1. Log in via `POST /auth/login` using `CLIENT_ID` and `TGT`; store the session token for subsequent calls.
2. Poll `GET /testing_history` over roughly the last 24 hours and pick the newest task run with `status` equal to `running`.
3. For that task, `GET /task_run/{task_run_id}/approvals` and collect items with `status` equal to `pending` (using `approval_id` as the identifier).
4. For each pending approval, `POST /task_run/{task_run_id}/approve/{approval_id}`.
5. Sleep for the configured interval and repeat until the duration elapses, then print a short summary (cycles and total approvals).

If no running task exists, the loop still sleeps and retries until the duration ends.
