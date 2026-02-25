# Pentera Core API - Comprehensive Documentation

This documentation provides a complete reference for the Pentera Core API, derived from the official Swagger specification. It serves as a guide for building applications and integrations with the Pentera platform.

## Table of Contents
1. [Authentication](#1-authentication)
2. [Testing History & Task Runs](#2-testing-history--task-runs)
3. [Testing Operations](#3-testing-operations)
4. [Testing Results](#4-testing-results)
5. [Nodes & Status](#5-nodes--status)
6. [Network Configuration](#6-network-configuration)
7. [Definitions & Objects](#7-definitions--objects)

---

## 1. Authentication

Pentera uses a two-step authentication process: Login to obtain a session token, followed by Token-based Authorization for all subsequent requests.

### Login
Exchange client credentials for a temporary session token and an updated TGT (Ticket Granting Ticket).

- **Endpoint:** `POST /pentera/api/v1/auth/login`
- **Request Body:**
  ```json
  {
    "client_id": "YOUR_CLIENT_ID",
    "tgt": "YOUR_CURRENT_TGT"
  }
  ```
- **Success Response (200 OK):**
  ```json
  {
    "meta": { "status": "success", "token": "...", "user": { ... } },
    "token": "SESSION_TOKEN",
    "tgt": "NEW_TGT"
  }
  ```
  *Note: The TGT is rotated upon each login and must be persisted for the next session. Tokens typically expire after 30 minutes.*

### Authorization Header
All subsequent API requests must include the session token in a Basic Auth header.

- **Header:** `Authorization: Basic [Base64(token:)]`
  *Note: The colon after the token is mandatory before Base64 encoding (e.g., `echo -n "token:" | base64`).*

---

## 2. Testing History & Task Runs

### Get Testing History
Retrieve metadata for test runs executed within a specified timeframe.

- **Endpoint:** `GET /pentera/api/v1/testing_history`
- **Required Query Parameters:**
  | Parameter | Type | Description |
  |-----------|------|-------------|
  | `start_timestamp` | float | Start of range (Unix epoch milliseconds, integer format recommended) |
  | `end_timestamp` | float | End of range (Unix epoch milliseconds, integer format recommended) |

- **Example:** `GET /testing_history?start_timestamp=1640017381279&end_timestamp=1740017381279`

### Delete Task Runs (Bulk)
Delete multiple test runs by their IDs.

- **Endpoint:** `POST /pentera/api/v1/taskRun/deleteBulk`
- **Request Body:**
  ```json
  {
    "taskRunsIds": ["id1", "id2", "id3"]
  }
  ```

### Recalculate Stats
Recalculate statistics for a task run if inconsistencies are found.
- **Endpoint:** `GET /pentera/api/v1/task_run/{task_run_id}/calculate_stats`

---

## 3. Testing Operations

### List Scenarios/Templates
Fetch metadata for all configured Testing Scenario templates.
- **Endpoint:** `GET /pentera/api/v1/testing_scenarios`

### Start a Scenario
Initiate a new test run based on a template.
- **Endpoint:** `POST /pentera/api/v1/task/{template_id}/start_run`

### Stop a Test Run
Stop an active test run and initiate the cleanup phase.
- **Endpoint:** `POST /pentera/api/v1/task_run/{task_run_id}/stop_run`

### Clone a Scenario
Create a new template by cloning an existing one with new IP ranges.
- **Endpoint:** `POST /pentera/api/v1/testing_scenario/{template_id}/clone`
- **Query Parameters:** `name`, `description`
- **Request Body:**
  ```json
  {
    "ip_ranges": [{"fromIp": "10.0.0.1", "toIp": "10.0.0.254"}],
    "exclude_ip_ranges": []
  }
  ```

### Silent Run Identification
Get prefix and postfix identifiers used for reducing noise in monitoring systems.
- **Endpoint:** `GET /pentera/api/v1/task_run/{task_run_id}/command_line_identification`

### Approvals Management
Manage manual approvals for actions during a test run.
- **List Approvals:** `GET /pentera/api/v1/task_run/{task_run_id}/approvals`
- **Approve Action:** `POST /pentera/api/v1/task_run/{task_run_id}/approve/{approval_id}`

---

## 4. Testing Results

### Get Achievements
List all milestones/achievements obtained during a specific task run.
- **Endpoint:** `GET /pentera/api/v1/task_run/{task_run_id}/achievements`

### Get Vulnerabilities
List all vulnerabilities validated during a specific task run.
- **Endpoint:** `GET /pentera/api/v1/task_run/{task_run_id}/vulnerabilities`

### Get Action Logs
Fetch the detailed log of all actions performed during a test.
- **Endpoint:** `GET /pentera/api/v1/task_run/{task_run_id}/actions_log`

### Get Hosts
List all hosts discovered and covered by a specific test run.
- **Endpoint:** `GET /pentera/api/v1/task_run/{task_run_id}/hosts`

### Get Asset Details
Fetch specific details for an asset (Host, Webdomain, etc.) within a task run.
- **Endpoint:** `GET /pentera/api/v1/task_run/{task_run_id}/target_details/{target_type}/{target_id}`

---

## 5. Nodes & Status

### Get Nodes Status
Fetch status for all deployed Pentera nodes (Remote Access, Cracking, etc.).
- **Endpoint:** `GET /pentera/api/v1/nodesStatus`

---

## 6. Network Configuration

### Proxy Exclusions
Manage the list of IPs and hostnames that bypass proxy routing.
- **Get Exclusions:** `GET /pentera/api/v1/administration/integrations/proxy/exclusions`
- **Set Exclusions:** `POST /pentera/api/v1/administration/integrations/proxy/exclusions`
  - **Body:** `{"ips": ["..."], "hostnames": ["..."]}`

---

## 7. Definitions & Objects

### TaskRun Object
| Property | Type | Description |
|----------|------|-------------|
| `task_run_id` | string | Unique ID for the test run |
| `start_timestamp` | float | Start time (ms) |
| `end_timestamp` | float | End time (ms) |
| `status` | string | `success`, `failed`, `running`, etc. |
| `score` | string | Overall cyber posture (A-C or %) |

### IPRange Object
```json
{
  "fromIp": "192.168.1.1",
  "toIp": "192.168.1.254"
}
```
