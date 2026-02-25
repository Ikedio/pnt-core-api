import csv
import requests
import json
import base64
import os
import urllib.parse
from requests.packages.urllib3.exceptions import InsecureRequestWarning

# Suppress SSL warnings for self-signed certs
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

CONFIG_PATH = "pentera_api.conf"

def get_config(path):
    config = {}
    if not os.path.exists(path):
        print(f"[-] Config file not found: {path}")
        return None
    with open(path, 'r') as f:
        for line in f:
            if '=' in line:
                key, value = line.split('=', 1)
                config[key.strip()] = value.strip()
    return config

def login(config):
    # Extract base address
    base_address = config['PENTERA_ADDRESS'].split('/')[0]
    # Corrected URL path to include /pentera/api/v1/
    login_url = f"https://{base_address}/pentera/api/v1/auth/login"
    
    payload = {
        "client_id": config['CLIENT_ID'],
        "tgt": config['TGT']
    }
    
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "Pentera-Batch-Cloner/1.0"
    }
    
    print(f"[*] Attempting login to: {login_url}")
    
    try:
        # Some Pentera versions are sensitive to the exact JSON format
        response = requests.post(login_url, json=payload, headers=headers, verify=False)
        if response.status_code == 400:
            print(f"[*] Status Code: {response.status_code}. Retrying with charset...")
            # Retry with explicit charset if first attempt fails
            headers["Content-Type"] = "application/json;charset=UTF-8"
            response = requests.post(login_url, json=payload, headers=headers, verify=False)
            print(f"[*] Retry Status Code: {response.status_code}")
            
        response.raise_for_status()
        data = response.json()
        if data.get("meta", {}).get("status") == "success":
            # Update TGT in config file if a new one is returned
            new_tgt = data.get("tgt")
            if new_tgt and new_tgt != config['TGT']:
                update_config_tgt(new_tgt)
            return data.get("token")
    except Exception as e:
        print(f"[-] Login failed: {e}")
        if hasattr(e, 'response') and e.response is not None:
             print(f"[*] Response Body: {e.response.text}")
    return None

def update_config_tgt(new_tgt):
    try:
        lines = []
        with open(CONFIG_PATH, 'r') as f:
            for line in f:
                if line.strip().startswith("TGT"):
                    lines.append(f"TGT = {new_tgt}\n")
                else:
                    lines.append(line)
        with open(CONFIG_PATH, 'w') as f:
            f.writelines(lines)
        print("[+] TGT updated in config file.")
    except Exception as e:
        print(f"[-] Failed to update TGT in config: {e}")


def parse_ips(ips_string):
    ranges = []
    # Using semicolon separator as requested for IP list in CSV
    ips = ips_string.split(';')
    for ip in ips:
        clean_ip = ip.strip()
        if '-' in clean_ip:
            parts = clean_ip.split('-')
            ranges.append({"fromIp": parts[0].strip(), "toIp": parts[1].strip()})
        else:
            ranges.append({"fromIp": clean_ip, "toIp": clean_ip})
    return {"ip_ranges": ranges}

def batch_clone(csv_path, config, token):
    base_address = config['PENTERA_ADDRESS'].split('/')[0]
    
    # Auth header: Basic [Base64(token:)]
    auth_str = f"{token}:"
    encoded_auth = base64.b64encode(auth_str.encode()).decode()
    headers = {
        "Authorization": f"Basic {encoded_auth}",
        "Content-Type": "application/json",
        "Accept": "application/json"
    }

    # Identify all CSV files in the target directory
    if os.path.isdir(csv_path):
        csv_files = [os.path.join(csv_path, f) for f in os.listdir(csv_path) if f.lower().endswith('.csv')]
    elif os.path.isfile(csv_path):
        csv_files = [csv_path]
    else:
        print(f"[-] Path not found: {csv_path}")
        return

    if not csv_files:
        print(f"[-] No CSV files found in: {csv_path}")
        return

    for file_path in csv_files:
        file_name = os.path.basename(file_path)
        # Scenario name from file name (without extension)
        scenario_name = os.path.splitext(file_name)[0]
        
        print(f"[*] Processing file: {file_name} -> Scenario Name: {scenario_name}")

        with open(file_path, mode='r', encoding='utf-8') as f:
            # Expected format: NO HEADER, single row with 4 columns:
            # Column 0: templateid
            # Column 1: nomecliente
            # Column 2: codiceapplicazione
            # Column 3: ips
            reader = csv.reader(f, delimiter=',')
            
            for row in reader:
                if not row or len(row) < 4:
                    continue
                    
                template_id = row[0].strip()
                
                # Description from column 1 (nomecliente) and 2 (codiceapplicazione)
                client_name = row[1].strip()
                app_code = row[2].strip()
                description = f"{client_name}_{app_code}"
                
                # IPs from column 3 (ips)
                ips = row[3].strip()
                
                print(f"    [>] Cloning Template: {template_id} | Description: {description}")
                
                encoded_name = urllib.parse.quote(scenario_name)
                encoded_desc = urllib.parse.quote(description)
                clone_url = f"https://{base_address}/pentera/api/v1/testing_scenario/{template_id}/clone?name={encoded_name}&description={encoded_desc}"
                
                body = parse_ips(ips)
                
                try:
                    response = requests.post(clone_url, headers=headers, json=body, verify=False)
                    if response.status_code == 200:
                        res_data = response.json()
                        new_id = res_data.get("template", {}).get("id")
                        print(f"    [+] Success! New Scenario ID: {new_id}")
                        
                        # Update token for next call if provided in meta
                        new_token = res_data.get("meta", {}).get("token")
                        if new_token:
                            auth_str = f"{new_token}:"
                            encoded_auth = base64.b64encode(auth_str.encode()).decode()
                            headers["Authorization"] = f"Basic {encoded_auth}"
                    else:
                        print(f"    [-] Failed to clone: {response.status_code} - {response.text}")
                except Exception as e:
                    print(f"    [-] Error during request: {e}")

if __name__ == "__main__":
    import sys
    import argparse
    
    parser = argparse.ArgumentParser(description="Pentera Batch Scenario Cloner")
    parser.add_argument("csv_file", nargs="?", default="scenarios.csv", help="CSV file for batch cloning")
    parser.add_argument("--extract", action="store_true", help="Extract existing scenario IDs to a CSV file")
    
    args = parser.parse_args()
    
    cfg = get_config(CONFIG_PATH)
    if cfg:
        token = login(cfg)
        if token:
            if args.extract:
                # Extract mode
                base_address = cfg['PENTERA_ADDRESS'].split('/')[0]
                # Using the agnostic documentation endpoint for scenarios
                scenarios_url = f"https://{base_address}/pentera/api/v1/testing_scenarios"
                
                auth_str = f"{token}:"
                encoded_auth = base64.b64encode(auth_str.encode()).decode()
                headers = {
                    "Authorization": f"Basic {encoded_auth}",
                    "Accept": "application/json"
                }
                
                print(f"[*] Fetching existing scenarios from: {scenarios_url}")
                try:
                    response = requests.get(scenarios_url, headers=headers, verify=False)
                    response.raise_for_status()
                    data = response.json()
                    
                    # DEBUG: Print the structure of the response
                    # print(f"DEBUG: Response data: {json.dumps(data, indent=2)}")
                    
                    # Handle different possible response structures
                    if isinstance(data, list):
                        scenarios = data
                    elif isinstance(data, dict):
                        # Try common keys
                        scenarios = data.get("testing_scenarios") or data.get("scenarios") or data.get("templates") or data.get("task_templates") or []
                    else:
                        scenarios = []
                    
                    # If still empty, try the API v1 templates endpoint as fallback
                    if not scenarios:
                        templates_url = f"https://{base_address}/pentera/api/v1/templates"
                        print(f"[*] testing_scenarios empty, trying fallback: {templates_url}")
                        response = requests.get(templates_url, headers=headers, verify=False)
                        if response.status_code == 200:
                            data = response.json()
                            scenarios = data if isinstance(data, list) else data.get("templates", [])
                    
                    extract_file = "extracted_scenarios.csv"
                    with open(extract_file, 'w', encoding='utf-8') as f:
                        f.write("template_id,name,description,type\n")
                        for s in scenarios:
                            # Try both 'template_id' and 'id' as Pentera uses both in different endpoints
                            s_id = s.get("template_id") or s.get("id") or ""
                            s_name = s.get("name", "")
                            s_desc = s.get("description", "")
                            s_type = s.get("type", "")
                            # Using comma separator as requested for this file
                            f.write(f"{s_id},{s_name},{s_desc},{s_type}\n")
                    
                    print(f"[+] Successfully extracted {len(scenarios)} scenarios to {extract_file}")
                except Exception as e:
                    print(f"[-] Failed to extract scenarios: {e}")
            else:
                # Batch clone mode
                batch_clone(args.csv_file, cfg, token)
        else:
            print("[-] Authentication failed.")
