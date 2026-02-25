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
from datetime import datetime

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
        # The /testing_history endpoint requires start_timestamp and end_timestamp
        # as milliseconds since Unix Epoch
        start_timestamp = int(datetime(2020, 1, 1).timestamp() * 1000)
        end_timestamp = int((datetime.now().timestamp() + 86400) * 1000)  # +1 day
        
        # Try endpoints - /api/v1/ without /pentera prefix based on AD users endpoint pattern
        endpoints = [
            f"{self.base_url}/api/v1/testing_history?start_timestamp={start_timestamp}&end_timestamp={end_timestamp}",
            f"{self.base_url}/pentera/api/v1/testing_history?start_timestamp={start_timestamp}&end_timestamp={end_timestamp}"
        ]
        
        headers = self._get_auth_headers()
        
        for url in endpoints:
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
        
        print(f"    [*] Filtering for AdPasswordAssessment tests...")
        
        # Filter for AD Password Strength Assessment (ADPA) tests
        # Swagger shows type: "Targeted Testing - AD Password Strength Assessment"
        all_task_runs = []
        adpa_pattern = re.compile(r'AD Password|AdPassword|ADPA', re.IGNORECASE)
        
        for task in task_runs:
            task_type = str(task.get("type", ""))
            name = str(task.get("name", ""))
            
            # Match AD Password Assessment tests
            if adpa_pattern.search(task_type) or adpa_pattern.search(name):
                all_task_runs.append(task)
        
        # If no ADPA tasks found, show available types
        if len(all_task_runs) == 0:
            print("[!] No AdPasswordAssessment tests found.")
            
            # Show available task types for debugging
            types = {}
            for task in task_runs:
                t = task.get("type", "unknown")
                types[t] = types.get(t, 0) + 1
            
            print("    Available task types:")
            for t, count in sorted(types.items()):
                print(f"      - {t}: {count} tasks")
            
            print(f"[!] Including all {len(task_runs)} task runs...")
            return task_runs
        
        print(f"[+] Found {len(all_task_runs)} AdPasswordAssessment task runs.")
        return all_task_runs
    
    def get_active_directory_users(self, task_id: str) -> list:
        """Get Active Directory users for a specific task run."""
        print(f"    [*] Fetching AD users for task: {task_id}")
        
        # Endpoint: POST /api/v1/taskRun/{TaskID}/users/activeDirectoryUsers
        # Requires JSON body with pagination parameters
        url = f"{self.base_url}/api/v1/taskRun/{task_id}/users/activeDirectoryUsers"
        
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
        
        print(f"        [*] POST {url}")
        
        try:
            response = requests.post(url, headers=headers, json=payload, verify=False)
            
            if response.status_code == 200:
                data = response.json()
                
                # Extract users from response
                users = None
                if isinstance(data, list):
                    users = data
                elif isinstance(data, dict):
                    users = (data.get("users") or 
                            data.get("activeDirectoryUsers") or 
                            data.get("active_directory_users") or 
                            data.get("data") or [])
                
                if users:
                    print(f"        [+] Success! Found {len(users)} users")
                    return users
            else:
                print(f"        [-] Failed: Status {response.status_code}")
                if response.text:
                    print(f"            Details: {response.text[:200]}")
        except Exception as e:
            print(f"        [-] Failed: {e}")
        
        return []


def flatten_value(value) -> str:
    """Flatten complex values for CSV export."""
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
        "task_id", "task_name", "username", "displayName", "samAccountName",
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
                row[col] = flatten_value(value)
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
        
        for task in task_runs:
            # Swagger shows field is "task_run_id"
            task_id = task.get("task_run_id") or task.get("id") or task.get("task_id") or task.get("taskId")
            task_name = task.get("name") or task.get("task_name") or "Unknown"
            
            if not task_id:
                print("    [-] Skipping task with no ID")
                continue
            
            users = client.get_active_directory_users(task_id)
            
            for user in users:
                user["task_id"] = task_id
                user["task_name"] = task_name
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
