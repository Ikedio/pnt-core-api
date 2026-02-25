#!/usr/bin/env python3
"""
Pentera Old Tests Cleaner

Automatically deletes old Pentera test runs based on configurable retention.
Can run continuously as a daemon/service or as a one-shot scheduled task.

Usage:
    One-shot:   python delete_old_tests.py --retention-days 30
    Continuous: python delete_old_tests.py --retention-days 30 --continuous --interval-hours 24
    Dry-run:    python delete_old_tests.py --retention-days 30 --dry-run
"""

import argparse
import base64
import json
import logging
import os
import signal
import sys
import time
from datetime import datetime, timedelta
from typing import Optional, Dict, List, Any

import requests
from requests.packages.urllib3.exceptions import InsecureRequestWarning

# Suppress SSL warnings for self-signed certs
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)


class PenteraCleanupClient:
    """Client for Pentera API to manage test cleanup operations."""
    
    def __init__(self, config_path: str, logger: logging.Logger):
        self.config_path = config_path
        self.logger = logger
        self.config: Dict[str, str] = {}
        self.token: Optional[str] = None
        self.base_url: str = ""
        
    def load_config(self) -> bool:
        """Load configuration from file."""
        if not os.path.exists(self.config_path):
            self.logger.error(f"Config file not found: {self.config_path}")
            return False
            
        self.config = {}
        with open(self.config_path, 'r') as f:
            for line in f:
                if '=' in line:
                    key, value = line.split('=', 1)
                    self.config[key.strip()] = value.strip()
        
        required_keys = ['PENTERA_ADDRESS', 'CLIENT_ID', 'TGT']
        for key in required_keys:
            if key not in self.config:
                self.logger.error(f"Missing required config key: {key}")
                return False
                
        return True
    
    def _update_config_tgt(self, new_tgt: str) -> None:
        """Update TGT in the configuration file."""
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
            self.config['TGT'] = new_tgt
            self.logger.info("TGT updated in config file.")
        except Exception as e:
            self.logger.warning(f"Failed to update TGT in config: {e}")
    
    def login(self) -> bool:
        """Authenticate with the Pentera API."""
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
        
        self.logger.info(f"Authenticating to: {login_url}")
        
        try:
            response = requests.post(login_url, json=payload, headers=headers, verify=False, timeout=30)
            response.raise_for_status()
            data = response.json()
            
            if data.get("meta", {}).get("status") == "success":
                self.token = data.get("token")
                new_tgt = data.get("tgt")
                if new_tgt and new_tgt != self.config['TGT']:
                    self._update_config_tgt(new_tgt)
                self.logger.info("Authentication successful.")
                return True
            else:
                self.logger.error(f"Login failed: {data.get('meta', {}).get('message', 'Unknown error')}")
        except requests.exceptions.RequestException as e:
            self.logger.error(f"Login failed: {e}")
            if hasattr(e, 'response') and e.response is not None:
                self.logger.error(f"Response: {e.response.text}")
        
        return False
    
    def _get_auth_headers(self) -> Dict[str, str]:
        """Get headers with current authentication token."""
        auth_str = f"{self.token}:"
        encoded_auth = base64.b64encode(auth_str.encode()).decode()
        return {
            "Authorization": f"Basic {encoded_auth}",
            "Accept": "application/json"
        }
    
    def _api_request(self, endpoint: str, method: str = "GET", data: dict = None, params: dict = None) -> Dict[str, Any]:
        """Make an API request and handle token refresh."""
        # Ensure endpoint doesn't start with a slash if base_url ends with one
        if endpoint.startswith('/') and self.base_url.endswith('/'):
            url = f"{self.base_url.rstrip('/')}{endpoint}"
        else:
            url = f"{self.base_url}{endpoint}"
            
        headers = self._get_auth_headers()
        
        self.logger.debug(f"Request URL: {url}")
        
        try:
            if method.upper() == "GET":
                # Use the URL as is, since it might already contain query parameters
                # Explicitly set verify=False and headers to match curl exactly
                response = requests.get(url, headers=headers, params=params, verify=False, timeout=60)
            elif method.upper() == "POST":
                # Add Content-Type only for POST requests
                headers["Content-Type"] = "application/json"
                response = requests.post(url, headers=headers, json=data, verify=False, timeout=60)
            else:
                raise ValueError(f"Unsupported HTTP method: {method}")
            
            self.logger.debug(f"Final URL: {response.url}")
            
            # Log the response if it fails
            if response.status_code != 200:
                self.logger.warning(f"Request to {response.url} failed with status {response.status_code}")
                self.logger.warning(f"Response body: {response.text}")
                
            response.raise_for_status()
            result = response.json()
            
            # Update token if provided in response
            if isinstance(result, dict) and result.get("meta", {}).get("token"):
                self.token = result["meta"]["token"]
            
            return {"success": True, "data": result}
            
        except requests.exceptions.RequestException as e:
            error_msg = str(e)
            if hasattr(e, 'response') and e.response is not None:
                error_msg += f" - Response: {e.response.text}"
            return {"success": False, "error": error_msg}
    
    def get_testing_history(self, start_timestamp: int, end_timestamp: int) -> List[Dict[str, Any]]:
        """Fetch testing history within the specified time range.
        
        Args:
            start_timestamp: Start of time range in Unix epoch milliseconds
            end_timestamp: End of time range in Unix epoch milliseconds
        """
        # Build endpoint with query string directly - integers without decimals
        # This matches the curl command that works
        endpoint = f"/pentera/api/v1/testing_history?start_timestamp={int(start_timestamp)}&end_timestamp={int(end_timestamp)}"
        
        self.logger.info(f"Time range: start_timestamp={int(start_timestamp)}, end_timestamp={int(end_timestamp)}")
        self.logger.info(f"Trying endpoint: /pentera/api/v1/testing_history")
        
        # Pass None for params since we've already included them in the endpoint string
        result = self._api_request(endpoint, "GET", params=None)
        
        if result["success"]:
            data = result["data"]
            
            # Handle different response structures
            if isinstance(data, dict):
                task_runs = (
                    data.get("task_runs") or 
                    data.get("testing_history") or 
                    data.get("taskRuns") or
                    []
                )
            elif isinstance(data, list):
                task_runs = data
            else:
                task_runs = []
            
            self.logger.info(f"Successfully retrieved {len(task_runs)} task runs")
            return task_runs
        else:
            self.logger.warning(f"Endpoint failed: {result['error']}")
        
        self.logger.error("testing_history endpoint failed")
        return []
    
    def get_old_task_runs(self, retention_days: int) -> List[Dict[str, Any]]:
        """Get task runs older than the retention period.
        
        Uses the testing_history API with start_timestamp and end_timestamp
        to query only tests within the deletion window.
        """
        # Calculate time range for the API query
        # start_timestamp: A long time ago (e.g., year 2000) to capture all old tests
        # end_timestamp: The cutoff date (tests older than this will be deleted)
        # Timestamps must be integers in Unix epoch milliseconds
        cutoff_date = datetime.now() - timedelta(days=retention_days)
        end_timestamp = int(cutoff_date.timestamp() * 1000)  # Pentera uses milliseconds (integer)
        
        # Start from a very old date to capture all historical tests
        start_date = datetime(2000, 1, 1)
        start_timestamp = int(start_date.timestamp() * 1000)
        
        self.logger.info(f"Querying tests from {start_date.strftime('%Y-%m-%d')} to {cutoff_date.strftime('%Y-%m-%d %H:%M:%S')}")
        
        task_runs = self.get_testing_history(start_timestamp, end_timestamp)
        
        self.logger.info(f"Found {len(task_runs)} task runs older than {retention_days} days")
        return task_runs
    
    def delete_task_runs(self, task_runs: List[Dict[str, Any]], dry_run: bool = False) -> bool:
        """Delete the specified task runs."""
        if not task_runs:
            self.logger.info("No task runs to delete.")
            return True
        
        # Extract task run IDs
        task_run_ids = []
        for run in task_runs:
            run_id = (
                run.get("task_run_id") or 
                run.get("taskRunId") or
                run.get("id")
            )
            if run_id:
                task_run_ids.append(run_id)
        
        if not task_run_ids:
            self.logger.warning("Could not extract any task run IDs.")
            return False
        
        self.logger.info(f"Preparing to delete {len(task_run_ids)} task runs...")
        
        if dry_run:
            self.logger.warning("[DRY-RUN] Would delete the following task run IDs:")
            for run_id in task_run_ids:
                self.logger.info(f"  - {run_id}")
            return True
        
        # Delete in bulk
        payload = {"taskRunsIds": task_run_ids}
        
        # Try both endpoint patterns
        endpoints = [
            "/api/v1/taskRun/deleteBulk",
            "/pentera/api/v1/taskRun/deleteBulk"
        ]
        
        for endpoint in endpoints:
            self.logger.info(f"Attempting bulk delete via: {endpoint}")
            result = self._api_request(endpoint, "POST", payload)
            
            if result["success"]:
                self.logger.info(f"Successfully deleted {len(task_run_ids)} task runs.")
                return True
            else:
                self.logger.warning(f"Endpoint {endpoint} failed: {result['error']}")
        
        self.logger.error("All delete endpoints failed. Task runs were NOT deleted.")
        return False


class CleanupService:
    """Service wrapper for running cleanup operations."""
    
    def __init__(self, config_path: str, retention_days: int, 
                 continuous: bool = False, interval_hours: float = 24.0,
                 dry_run: bool = False, log_path: str = None):
        self.config_path = config_path
        self.retention_days = retention_days
        self.continuous = continuous
        self.interval_hours = interval_hours
        self.dry_run = dry_run
        self.running = True
        
        # Setup logging
        self.logger = self._setup_logging(log_path)
        
        # Setup signal handlers for graceful shutdown
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
    
    def _setup_logging(self, log_path: str = None) -> logging.Logger:
        """Configure logging to both console and file."""
        logger = logging.getLogger("PenteraCleanup")
        logger.setLevel(logging.INFO)
        
        # Console handler
        console_handler = logging.StreamHandler()
        console_handler.setLevel(logging.INFO)
        console_format = logging.Formatter('[%(asctime)s] [%(levelname)s] %(message)s', 
                                          datefmt='%Y-%m-%d %H:%M:%S')
        console_handler.setFormatter(console_format)
        logger.addHandler(console_handler)
        
        # File handler
        if log_path:
            try:
                file_handler = logging.FileHandler(log_path)
                file_handler.setLevel(logging.INFO)
                file_handler.setFormatter(console_format)
                logger.addHandler(file_handler)
            except Exception as e:
                logger.warning(f"Could not setup file logging: {e}")
        
        return logger
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully."""
        self.logger.info(f"Received signal {signum}. Initiating graceful shutdown...")
        self.running = False
    
    def run_cleanup_cycle(self) -> bool:
        """Execute a single cleanup cycle."""
        self.logger.info("=" * 50)
        self.logger.info(f"Starting cleanup cycle (Retention: {self.retention_days} days)")
        
        client = PenteraCleanupClient(self.config_path, self.logger)
        
        # Load/reload config
        if not client.load_config():
            self.logger.error("Failed to load configuration. Skipping this cycle.")
            return False
        
        # Authenticate
        if not client.login():
            self.logger.error("Authentication failed. Skipping this cycle.")
            return False
        
        # Get old task runs
        old_runs = client.get_old_task_runs(self.retention_days)
        
        # Delete them
        success = client.delete_task_runs(old_runs, self.dry_run)
        
        self.logger.info("Cleanup cycle completed.")
        self.logger.info("=" * 50)
        
        return success
    
    def run(self):
        """Main entry point for the service."""
        self.logger.info("Pentera Old Tests Cleaner starting...")
        self.logger.info(f"Configuration file: {self.config_path}")
        self.logger.info(f"Retention period: {self.retention_days} days")
        mode = f"Continuous (every {self.interval_hours} hours)" if self.continuous else "One-shot"
        self.logger.info(f"Mode: {mode}")
        
        if self.dry_run:
            self.logger.warning("*** DRY-RUN MODE - No deletions will be performed ***")
        
        if self.continuous:
            self.logger.info("Starting continuous cleanup service...")
            
            while self.running:
                try:
                    self.run_cleanup_cycle()
                except Exception as e:
                    self.logger.error(f"Error during cleanup cycle: {e}")
                
                if self.running:
                    self.logger.info(f"Sleeping for {self.interval_hours} hours until next cycle...")
                    # Sleep in small increments to allow for graceful shutdown
                    sleep_seconds = int(self.interval_hours * 3600)
                    for _ in range(sleep_seconds):
                        if not self.running:
                            break
                        time.sleep(1)
            
            self.logger.info("Continuous service stopped.")
        else:
            # One-shot mode
            success = self.run_cleanup_cycle()
            if not success:
                sys.exit(1)
        
        self.logger.info("Pentera Old Tests Cleaner finished.")


def main():
    parser = argparse.ArgumentParser(
        description="Pentera Old Tests Cleaner - Automatically delete old test runs",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  One-shot cleanup (delete tests older than 30 days):
    python delete_old_tests.py --retention-days 30

  Continuous mode (check every 24 hours):
    python delete_old_tests.py --retention-days 30 --continuous --interval-hours 24

  Dry-run (see what would be deleted):
    python delete_old_tests.py --retention-days 30 --dry-run
        """
    )
    
    parser.add_argument(
        "--retention-days", "-r",
        type=int,
        default=30,
        help="Number of days to retain test runs (default: 30)"
    )
    
    parser.add_argument(
        "--config", "-c",
        type=str,
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "pentera_api.conf"),
        help="Path to configuration file (default: pentera_api.conf in script directory)"
    )
    
    parser.add_argument(
        "--continuous",
        action="store_true",
        help="Run continuously instead of one-shot"
    )
    
    parser.add_argument(
        "--interval-hours", "-i",
        type=float,
        default=24.0,
        help="Hours between cleanup cycles in continuous mode (default: 24). Can be a decimal (e.g., 0.5 for 30 minutes)."
    )
    
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be deleted without actually deleting"
    )
    
    parser.add_argument(
        "--log-file", "-l",
        type=str,
        default=None,
        help="Path to log file (default: cleanup.log in script directory)"
    )
    
    args = parser.parse_args()
    
    # Default log file path
    if args.log_file is None:
        args.log_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cleanup.log")
    
    service = CleanupService(
        config_path=args.config,
        retention_days=args.retention_days,
        continuous=args.continuous,
        interval_hours=args.interval_hours,
        dry_run=args.dry_run,
        log_path=args.log_file
    )
    
    service.run()


if __name__ == "__main__":
    main()
