#!/usr/bin/env python3
"""
ADPA Active Directory User Exporter

Retrieves all ADPA tests from Pentera and extracts Active Directory user data
from the /api/v1/taskRun/{TaskID}/users/activeDirectoryUsers endpoint.
Exports results to CSV.

Usage:
    python export_adpa_users.py
    python export_adpa_users.py --config /path/to/pentera_api.conf
    python export_adpa_users.py --output /path/to/output.csv
    python export_adpa_users.py --task-id specific-task-id
"""

import argparse
import base64
import csv
import json
import os
import re
import sys
from datetime import datetime, timezone, timedelta
from typing import Optional

import requests
from requests.packages.urllib3.exceptions import InsecureRequestWarning

# Suppress SSL warnings for self-signed certs
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

DEFAULT_CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pentera_api.conf")
DEFAULT_OUTPUT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "adpa_users_export.csv")


class PenteraClient:
    """Client for interacting with Pentera API."""
    
    def __init__(self, config_path: str):
        self.config_path = config_path
        self.config = self._load_config(config_path)
        self.token = None
        self.base_url = None
        
    def _load_config(self, path: str) -> dict:
        """Load configuration from file."""
        if not os.path.exists(path):
            print(f"[-] Config file not found: {path}")
            sys.exit(1)
            
        config = {}
        with open(path, 'r') as f:
            for line in f:
                if '=' in line:
                    key, value = line.split('=', 1)
                    config[key.strip()] = value.strip()
        return config
    
    def _update_config_tgt(self, new_tgt: str):
        """Update TGT in config file."""
        try:
            lines = []
            with open(self.config_path, 'r') as f:
                for line in f:
                    if line.strip().startswith("TGT"):
                        lines.append(f"TGT = {new_tgt}\n")
                    else:
                        lines.append(line)
            with open(self.config_path, 'w') as f:
                f.writelines(lines)
            print("[+] TGT updated in config file.")
        except Exception as e:
            print(f"[-] Failed to update TGT in config: {e}")
    
    def _get_auth_headers(self) -> dict:
        """Build authorization headers."""
        auth_str = f"{self.token}:"
        encoded_auth = base64.b64encode(auth_str.encode()).decode()
        return {
            "Authorization": f"Basic {encoded_auth}",
            "Accept": "application/json",
            "Content-Type": "application/json"
        }
    
    def login(self) -> bool:
        """Authenticate with Pentera API."""
        base_address = self.config['PENTERA_ADDRESS'].split('/')[0]
        self.base_url = f"https://{base_address}"
        login_url = f"{self.base_url}/pentera/api/v1/auth/login"
        
        payload = {
            "client_id": self.config['CLIENT_ID'],
            "tgt": self.config['TGT']
        }
        
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
        
        print(f"[*] Attempting login to: {login_url}")
        
        try:
            response = requests.post(login_url, json=payload, headers=headers, verify=False)
            
            # Retry with charset if needed
            if response.status_code == 400:
                print(f"[*] Status Code: {response.status_code}. Retrying with charset...")
                headers["Content-Type"] = "application/json;charset=UTF-8"
                response = requests.post(login_url, json=payload, headers=headers, verify=False)
            
            response.raise_for_status()
            data = response.json()
            
            if data.get("meta", {}).get("status") == "success":
                self.token = data.get("token")
                
                # Update TGT if rotated
                new_tgt = data.get("tgt")
                if new_tgt and new_tgt != self.config['TGT']:
                    self._update_config_tgt(new_tgt)
                    self.config['TGT'] = new_tgt
                
                print("[+] Login successful.")
                return True
            else:
                print(f"[-] Login failed: {data.get('meta', {}).get('message', 'Unknown error')}")
                
        except Exception as e:
            print(f"[-] Login failed: {e}")
            if hasattr(e, 'response') and e.response is not None:
                print(f"[*] Response Body: {e.response.text}")
        
        return False
    
    def _api_request(self, endpoint: str, method: str = "GET", data: dict = None) -> dict:
        """Make API request with authentication."""
        url = f"{self.base_url}/pentera/api/v1/{endpoint}"
        headers = self._get_auth_headers()
        
        try:
            if method.upper() == "GET":
                response = requests.get(url, headers=headers, verify=False)
            elif method.upper() == "POST":
                response = requests.post(url, headers=headers, json=data, verify=False)
            else:
                raise ValueError(f"Unsupported method: {method}")
            
            response.raise_for_status()
            result = response.json()
            
            # Update token if provided in response
            if isinstance(result, dict) and result.get("meta", {}).get("token"):
                self.token = result["meta"]["token"]
            
            return result
            
        except requests.exceptions.HTTPError as e:
            print(f"[-] API request failed ({response.status_code}): {e}")
            if response.text:
                print(f"    Details: {response.text[:500]}")
            return None
        except Exception as e:
            print(f"[-] API request error: {e}")
            return None
    
    def _fetch_task_runs_from_endpoints(self) -> list:
        """Fetch task runs using GET /testing_history endpoint with timestamp parameters."""
        bases = [
            f"{self.base_url}/pentera/api/v1/testing_history",
            f"{self.base_url}/api/v1/testing_history",
        ]

        headers = self._get_auth_headers()

        query_variants = self._testing_history_query_variants()

        for base in bases:
            for q in query_variants:
                url = f"{base}?{q}"
                print(f"    [*] Trying: GET {url}")
                try:
                    response = requests.get(url, headers=headers, verify=False)
                    if response.status_code == 200:
                        data = response.json()
                        task_runs = self._extract_task_runs(data)
                        if task_runs:
                            print(f"    [+] Success - retrieved {len(task_runs)} task runs")
                            return task_runs
                    else:
                        print(f"    [-] Failed: Status {response.status_code}")
                except Exception as e:
                    print(f"    [-] Failed: {e}")

        return []

    @staticmethod
    def _testing_history_query_variants() -> list:
        """Query strings for GET testing_history (ms since epoch; include explicit .0 decimals)."""
        start2000 = int(datetime(2000, 1, 1, tzinfo=timezone.utc).timestamp() * 1000)
        end_plus1 = int((datetime.now(timezone.utc) + timedelta(days=1)).timestamp() * 1000)
        end_now = int(datetime.now(timezone.utc).timestamp() * 1000)
        start365 = int((datetime.now(timezone.utc) - timedelta(days=365)).timestamp() * 1000)
        return [
            f"start_timestamp={start2000}&end_timestamp={end_plus1}",
            f"start_timestamp={start2000}.0&end_timestamp={end_plus1}.0",
            f"start_timestamp={start2000}&end_timestamp={end_now}",
            f"start_timestamp={start2000}.0&end_timestamp={end_now}.0",
            f"start_timestamp={start365}&end_timestamp={end_now}",
            f"start_timestamp={start365}.0&end_timestamp={end_now}.0",
        ]
    
    def _extract_task_runs(self, response: dict) -> list:
        """Extract task runs from various response formats."""
        if isinstance(response, list):
            return response
        elif isinstance(response, dict):
            return (response.get("task_runs") or 
                   response.get("taskRuns") or 
                   response.get("testing_history") or
                   response.get("tasks") or [])
        return []

    @staticmethod
    def _is_likely_ad_user_row(obj) -> bool:
        if not isinstance(obj, dict):
            return False
        keys = set(obj.keys())
        hints = (
            "samAccountName", "userPrincipalName", "distinguishedName", "objectSid",
            "objectGUID", "DistinguishedName", "SamAccountName", "Username", "displayName", "mail",
        )
        if keys.intersection(hints):
            return True
        pat = re.compile(r"(samaccount|userprincipal|distinguished|objectsid|objectguid|accountname)", re.I)
        return any(pat.search(k) for k in keys)

    def _find_user_array_deep(self, node, depth: int = 0) -> list:
        if node is None or depth > 10:
            return []
        if isinstance(node, list) and len(node) > 0 and self._is_likely_ad_user_row(node[0]):
            return node
        if isinstance(node, dict):
            for v in node.values():
                found = self._find_user_array_deep(v, depth + 1)
                if found:
                    return found
        return []

    def _extract_users_from_payload(self, data) -> list:
        """Find user list inside varied API response shapes (nested wrappers)."""
        if data is None:
            return []
        if isinstance(data, list) and data:
            return data if self._is_likely_ad_user_row(data[0]) else []
        if not isinstance(data, dict):
            return []
        for key in (
            "users", "activeDirectoryUsers", "active_directory_users",
            "items", "results", "records", "content", "rows", "list", "values", "data",
        ):
            val = data.get(key)
            if isinstance(val, list) and len(val) > 0:
                if self._is_likely_ad_user_row(val[0]):
                    return val
            if isinstance(val, dict):
                nested = self._extract_users_from_payload(val)
                if nested:
                    return nested
        return self._find_user_array_deep(data)
    
    def get_task_runs(self, adpa_only: bool = True) -> list:
        """Get all task runs, optionally filtering for AdPasswordAssessment tests."""
        print("[*] Fetching ADPA task runs (AdPasswordAssessment)...")
        
        task_runs = self._fetch_task_runs_from_endpoints()
        
        if not task_runs:
            print("[-] Could not fetch task runs.")
            return []
        
        print(f"    [+] Retrieved {len(task_runs)} total task runs")
        
        if not adpa_only:
            print(f"[+] Found {len(task_runs)} task runs.")
            return task_runs
        
        print(f"    [*] Filtering for AdPasswordAssessment (singleActionType or name/type match)...")
        
        all_task_runs = []
        
        for task in task_runs:
            if self._is_adpa_task(task):
                all_task_runs.append(task)
        
        # If no ADPA tasks found, show available types
        if len(all_task_runs) == 0:
            print("[!] No AdPasswordAssessment tests found.")
            
            # Show available task types for debugging
            types = {}
            for task in task_runs:
                t = task.get("singleActionType") or task.get("type", "unknown")
                types[t] = types.get(t, 0) + 1
            
            print("    Available task types:")
            for t, count in sorted(types.items()):
                print(f"      - {t}: {count} tasks")
            
            print(f"[!] Including all {len(task_runs)} task runs...")
            return task_runs
        
        print(f"[+] Found {len(all_task_runs)} AdPasswordAssessment task runs.")
        return all_task_runs

    @staticmethod
    def _is_adpa_task(task: dict) -> bool:
        if task.get("singleActionType") == "AdPasswordAssessment":
            return True
        adpa_pattern = re.compile(r"AD Password|AdPassword|ADPA", re.IGNORECASE)
        task_type = str(task.get("type", ""))
        name = str(task.get("name") or task.get("taskRunName") or "")
        return bool(adpa_pattern.search(task_type) or adpa_pattern.search(name))

    def _fetch_api_v1_task_runs(self) -> list:
        """GET /api/v1/taskRun (POST pagination fallback)."""
        url = f"{self.base_url}/api/v1/taskRun"
        h = self._get_auth_headers()
        try:
            r = requests.get(url, headers=h, verify=False)
            if r.status_code == 200:
                data = r.json()
                tr = data.get("taskRuns") or data.get("task_runs") or []
                return tr if isinstance(tr, list) else []
            payload = {
                "offset": 0,
                "items_per_page": 500,
                "sort": {"direction": "DESC", "key": "startTime"},
                "filters": {},
                "unique_fields": ["state"],
            }
            r = requests.post(url, headers=h, json=payload, verify=False)
            if r.status_code == 200:
                data = r.json()
                tr = data.get("taskRuns") or data.get("task_runs") or []
                return tr if isinstance(tr, list) else []
        except Exception:
            pass
        return []

    def get_adpa_task_runs_from_api_v1_task_run(self) -> list:
        """When testing_history is unavailable: GET /api/v1/taskRun, filter ADPA runs."""
        print("[*] Fetching ADPA task runs from /api/v1/taskRun...")
        all_runs = self._fetch_api_v1_task_runs()
        if not all_runs:
            print("    [-] No task runs from /api/v1/taskRun")
            return []
        print(f"    [+] Loaded {len(all_runs)} task run(s)")
        out = [x for x in all_runs if self._is_adpa_task(x)]
        print(f"    [+] {len(out)} ADPA run(s) after filter")
        return out
    
    def get_active_directory_users(self, task_id: str) -> list:
        """Get Active Directory users for a specific task run."""
        print(f"    [*] Fetching AD users for task: {task_id}")

        # Many appliances expose POST only on /api/v1/taskRun/... (not under /pentera). Try that first.
        paths = [
            f"/api/v1/taskRun/{task_id}/users/activeDirectoryUsers",
            f"/api/v1/task_run/{task_id}/users/activeDirectoryUsers",
            f"/pentera/api/v1/taskRun/{task_id}/users/activeDirectoryUsers",
            f"/pentera/api/v1/task_run/{task_id}/users/activeDirectoryUsers",
        ]
        headers = self._get_auth_headers()
        payload = {
            "offset": 0,
            "items_per_page": 10000,
            "sort": {
                "direction": "ASC",
                "key": "passwordCrackedPhase"
            },
            "filters": {},
            "unique_fields": ["state"]
        }

        for path in paths:
            url = f"{self.base_url}{path}"
            for method in ("POST", "GET"):
                print(f"        [*] {method} {url}")
                try:
                    if method == "POST":
                        response = requests.post(url, headers=headers, json=payload, verify=False)
                    else:
                        response = requests.get(url, headers=headers, verify=False)
                    if response.status_code != 200:
                        continue
                    data = response.json()
                    users = self._extract_users_from_payload(data)
                    if isinstance(data, dict) and data.get("meta", {}).get("token"):
                        self.token = data["meta"]["token"]
                    if users:
                        print(f"        [+] Success! Found {len(users)} users")
                        return users
                except Exception as e:
                    print(f"        [-] Failed: {e}")

        print("        [-] No AD users from any known endpoint for this task.")
        return []


def format_pentera_unix_epoch(value) -> Optional[str]:
    """Unix time in seconds or milliseconds -> UTC string yyyy-MM-dd HH:mm:ss UTC."""
    if value is None or value == "":
        return None
    try:
        if isinstance(value, str):
            s = value.strip()
            if not re.match(r"^-?\d+(\.\d+)?$", s):
                return None
            n = float(s)
        elif isinstance(value, (int, float)):
            n = float(value)
        else:
            return None
        if n <= 0:
            return None
        if n >= 1_000_000_000_000:
            sec = round(n) / 1000.0
        else:
            sec = float(round(n))
        dt = datetime.fromtimestamp(sec, tz=timezone.utc)
        return dt.strftime("%Y-%m-%d %H:%M:%S") + " UTC"
    except (ValueError, OSError, OverflowError):
        return None


def _is_timestamp_column_name(name: str) -> bool:
    if not name:
        return False
    n = name.lower()
    explicit = {
        "lastlogon", "passwordlastset", "pwdlastset", "badpasswordtime",
        "lastlogontimestamp", "accountexpires", "whencreated", "whenchanged",
        "lastlogoff", "badpwdtime",
    }
    if n in explicit:
        return True
    if re.search(r"(timestamp|logon|expires)$", n):
        return True
    if n.startswith("pwd") and "set" in n:
        return True
    return False


def flatten_value(value, column: Optional[str] = None) -> str:
    """Flatten complex values for CSV export; formats known timestamp columns."""
    if column and _is_timestamp_column_name(column):
        readable = format_pentera_unix_epoch(value)
        if readable:
            return readable
    if value is None:
        return ""
    if isinstance(value, list):
        return "; ".join(str(v) for v in value)
    if isinstance(value, dict):
        return json.dumps(value)
    return str(value)


def export_to_csv(users: list, output_path: str):
    """Export users to CSV file."""
    if not users:
        print("[-] No users to export.")
        return
    
    # Collect all unique keys from all user objects
    all_keys = set()
    for user in users:
        if isinstance(user, dict):
            all_keys.update(user.keys())
    
    # Define preferred column order
    preferred_order = [
        "task_id", "task_name", "template_id", "username", "displayName", "samAccountName",
        "userPrincipalName", "email", "distinguishedName", "domain",
        "enabled", "lastLogon", "passwordLastSet", "memberOf"
    ]
    
    # Build final column list with preferred columns first
    columns = []
    for col in preferred_order:
        if col in all_keys:
            columns.append(col)
            all_keys.discard(col)
    
    # Add remaining columns alphabetically
    columns.extend(sorted(all_keys))
    
    # Write CSV
    with open(output_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=columns, extrasaction='ignore')
        writer.writeheader()
        
        for user in users:
            row = {}
            for col in columns:
                value = user.get(col, "")
                row[col] = flatten_value(value, col)
            writer.writerow(row)
    
    print(f"[+] Exported {len(users)} users to: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="ADPA Active Directory User Exporter",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python export_adpa_users.py
    python export_adpa_users.py --config /path/to/pentera_api.conf
    python export_adpa_users.py --output /path/to/output.csv
    python export_adpa_users.py --task-id abc123-def456
        """
    )
    
    parser.add_argument(
        "--config", "-c",
        default=DEFAULT_CONFIG_PATH,
        help="Path to Pentera API config file (default: pentera_api.conf in script directory)"
    )
    
    parser.add_argument(
        "--output", "-o",
        default=DEFAULT_OUTPUT_PATH,
        help="Output CSV file path (default: adpa_users_export.csv in script directory)"
    )
    
    parser.add_argument(
        "--task-id", "-t",
        help="Specific task ID to query (optional, queries all ADPA tests if not specified)"
    )
    
    parser.add_argument(
        "--all-tasks",
        action="store_true",
        help="Include all tasks, not just ADPA-specific tests"
    )
    
    args = parser.parse_args()
    
    print("========================================")
    print("  ADPA Active Directory User Exporter  ")
    print("========================================")
    print()
    
    # Initialize client and login
    client = PenteraClient(args.config)
    if not client.login():
        print("[-] Could not authenticate. Exiting.")
        sys.exit(1)
    
    all_users = []
    
    if args.task_id:
        # Single task mode
        print(f"[*] Processing single task: {args.task_id}")
        users = client.get_active_directory_users(args.task_id)
        
        for user in users:
            user["task_id"] = args.task_id
            user["task_name"] = "Manual Query"
            all_users.append(user)
        
        print(f"    [+] Found {len(users)} AD users.")
    else:
        # Batch mode - get all ADPA tests
        task_runs = client.get_task_runs(adpa_only=not args.all_tasks)
        if not task_runs and not args.all_tasks:
            task_runs = client.get_adpa_task_runs_from_api_v1_task_run()

        for task in task_runs:
            # testing_history often uses camelCase: taskRunId, taskRunName, templateId
            task_id = (
                task.get("taskRunId") or task.get("task_run_id")
                or task.get("id") or task.get("task_id") or task.get("taskId")
            )
            task_name = (
                task.get("taskRunName") or task.get("name") or task.get("task_name") or "Unknown"
            )
            template_id = task.get("templateId") or task.get("template_id")
            
            if not task_id:
                print("    [-] Skipping task with no ID")
                continue
            
            users = client.get_active_directory_users(task_id)
            
            for user in users:
                user["task_id"] = task_id
                user["task_name"] = task_name
                if template_id:
                    user["template_id"] = template_id
                all_users.append(user)
            
            if users:
                print(f"    [+] Found {len(users)} AD users in task: {task_name}")
    
    print()
    print(f"[*] Total AD users collected: {len(all_users)}")
    
    export_to_csv(all_users, args.output)
    
    print()
    print("[+] Export complete!")


if __name__ == "__main__":
    main()
