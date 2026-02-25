# Pentera Core API - Agnostic Documentation

This documentation provides an agnostic view of the Pentera Core API, derived from the `PenteraPS_API` project. It serves as a reference for building applications that integrate with Pentera.

## Table of Contents
1. [Authentication](#authentication)
2. [Testing History & Tasks](#testing-history--tasks)
3. [Vulnerabilities & Achievements](#vulnerabilities--achievements)
4. [Hosts & Nodes](#hosts--nodes)
5. [Scenarios & Templates](#scenarios--templates)
6. [User Management](#user-management)
7. [Audit & Logs](#audit--logs)
8. [Attack Bridges](#attack-bridges)

---

## Authentication

Pentera uses a two-step authentication process: Login and Token-based Authorization.

### 1. Login
Exchange credentials for a temporary token and an updated TGT (Ticket Granting Ticket).

- **Endpoint:** `POST /auth/login`
- **Body:**
  ```json
  {
    "client_id": "YOUR_CLIENT_ID",
    "tgt": "YOUR_CURRENT_TGT"
  }
  ```
- **Response:**
  ```json
  {
    "meta": { "status": "success" },
    "token": "SESSION_TOKEN",
    "tgt": "NEW_TGT"
  }
  ```
  *Note: The TGT is rotated upon each login and should be persisted for the next session.*

### 2. Authorization Header
Subsequent requests must include the session token in a Basic Auth header.

- **Header:** `Authorization: Basic [Base64(token:)]`
  *Note: The colon after the token is required for Basic Auth format.*

---

## Testing History & Tasks

### Get Testing History
Retrieve a list of past and current task runs within a specified time range.

- **Endpoint:** `GET /pentera/api/v1/testing_history`
- **Required Query Parameters:**
  | Parameter | Type | Description |
  |-----------|------|-------------|
  | `start_timestamp` | int | Start of time range in Unix epoch milliseconds (integer, no decimals) |
  | `end_timestamp` | int | End of time range in Unix epoch milliseconds (integer, no decimals) |

- **Example Request:**
  ```
  GET https://192.168.1.100:8181/pentera/api/v1/testing_history?start_timestamp=1640017381279&end_timestamp=1740017381279
  ```

- **Alternative (POST with pagination):** `POST /api/v1/taskRun`
- **Body (Optional Pagination):**
  ```json
  {
    "offset": 0,
    "items_per_page": 10000
  }
  ```

### Delete Task Runs (Bulk)
Delete multiple task runs by their IDs.

- **Endpoint:** `POST /api/v1/taskRun/deleteBulk`
- **Body:**
  ```json
  {
    "taskRunsIds": ["id1", "id2", "id3"]
  }
  ```

### Get Task Run Statistics
- **Endpoint:** `GET /api/v1/taskRun/{taskId}/stats`

### Stop a Task Run
- **Endpoint:** `POST /task_run/{taskId}/stop_run`

### Export Task History
- **Endpoint:** `POST /api/v1/taskRun/export`
- **Body:**
  ```json
  {
    "task_run_ids": ["id1", "id2"],
    "password": "encryption_password"
  }
  ```

---

## Vulnerabilities & Achievements

### Get Achievements
List achievements (milestones) for a specific task run.
- **Endpoint:** `GET /task_run/{taskId}/achievements`

### Get Vulnerabilities
List vulnerabilities found during a task run.
- **Endpoint:** `GET /task_run/{taskId}/vulnerabilities`
- **Alternative (API v1):** `GET /api/v1/taskRun/{taskId}/vulnerability`

---

## Hosts & Nodes

### Get Hosts
List hosts involved in a specific task run.
- **Endpoint:** `GET /task_run/{taskId}/hosts`

### Get Nodes (RAN/Cracking)
List Pentera nodes (Remote Access Nodes or Cracking Nodes).
- **Endpoint:** `GET /api/v1/nodes`

### Create a Node
- **Endpoint:** `POST /api/v1/nodes/createNode`

---

## Scenarios & Templates

### List Scenarios/Templates
- **Endpoint:** `GET /api/v1/templates`
- **Alternative:** `GET /testing_scenarios`

### Start a Scenario
- **Endpoint:** `POST /task/{scenarioId}/start_run`

### Clone a Scenario
- **Endpoint:** `POST /testing_scenario/{scenarioId}/clone?name={name}&description={description}`

---

## User Management

### List Users
- **Endpoint:** `GET /api/v1/userManagement`

### Create/Update User
- **Endpoint:** `POST /api/v1/userManagement`
- **Body:**
  ```json
  {
    "username": "...",
    "password": "...",
    "role": "ADMIN|VIEWER|...",
    "email": "..."
  }
  ```

---

## Audit & Logs

### Get Audit Log
- **Endpoint:** `GET /api/v1/auditLog`

### Get Actions Log
- **Endpoint:** `GET /task_run/{taskId}/actions_log`

---

## Attack Bridges

### List Attack Bridges
- **Endpoint:** `GET /api/v1/nodes/ANIFiles/details`

### Download Attack Bridge File
- **Endpoint:** `GET /api/v1/nodes/ANIFile/{id}`
- **Response:** Base64 encoded executable bytes.
