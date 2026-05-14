#!/usr/bin/env bash
# Disclaimer:
#   This shell script is provided "AS IS" to illustrate potential interactions with the Pentera API.
#   It is intended as a starting point for customers and is not an officially supported product.
#
#   * No Warranties: This script comes with no warranties of any kind, either expressed or implied.
#     This includes, but is not limited to, warranties of fitness for a particular purpose or merchantability.
#   * Support: No official support is provided for this script.
#     It may be updated periodically, but updates are not guaranteed.
#   * Liability: The authors and distributors of this script shall not be held liable for any damages arising from its use.
#     This includes direct, indirect, special, incidental, or consequential damages.
#   * Modifications: You are free to modify and adapt this script for your own purposes.
#     However, any modifications made are at your own risk.
#
#   By using this script, you acknowledge and accept the terms of this disclaimer.
#
# Requirements: bash 4+, curl, sed, coreutils (no jq / python / node).
# Typical Ubuntu server/desktop base install is enough if curl is present.
#
# Usage:
#   ./approve_actions.sh --all --interval-minutes 15 --duration-hours 3
#
# Configuration: pentera_api.conf in this directory.

set -euo pipefail

[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || {
  echo "This script requires bash 4 or newer." >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors (optional; disable with NO_COLOR=1)
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  _R=$'\033[0;31m' _G=$'\033[0;32m' _Y=$'\033[0;33m' _C=$'\033[0;36m' _M=$'\033[0;35m' _N=$'\033[0m'
else
  _R= _G= _Y= _C= _M= _N=
fi

_ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

# Timestamped log (stdout)
log_ts() {
  printf '[%s] %s\n' "$(_ts)" "$*"
}

# Timestamped log (stderr)
log_ts_err() {
  printf '[%s] %s\n' "$(_ts)" "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: approve_actions.sh --all --duration-hours <N> [--interval-minutes <M>]

  --all                 Run continuous approval (required; only mode supported)
  --duration-hours N   Total runtime in hours (required)
  --interval-minutes M Sleep between cycles (default: 1)
EOF
}

resolve_config_path() {
  if [[ -f "${SCRIPT_DIR}/pentera_api.conf" ]]; then
    readlink -f "${SCRIPT_DIR}/pentera_api.conf"
  else
    echo ""
  fi
}

load_config() {
  local path="$1"
  PENTERA_ADDRESS=""
  CLIENT_ID=""
  TGT=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    local key val
    key="${line%%=*}"
    val="${line#*=}"
    key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$key" in
      PENTERA_ADDRESS) PENTERA_ADDRESS="${val%/}" ;;
      CLIENT_ID)       CLIENT_ID="$val" ;;
      TGT)             TGT="$val" ;;
    esac
  done <"$path"
}

update_tgt_in_config() {
  local new_tgt="$1"
  local path="$2"
  local tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*TGT[[:space:]]*= ]]; then
      printf 'TGT = %s\n' "$new_tgt" >>"$tmp"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$path"
  mv "$tmp" "$path"
}

TOKEN=""

# --- Minimal JSON (bash only): root object key lookup, arrays, quoted strings, balanced {} / [] ---

_json_skip_ws_idx() {
  local s="$1"
  local i="${2:-0}" len="${#s}" c
  while [[ "$i" -lt "$len" ]]; do
    c="${s:i:1}"
    case "$c" in
      [[:space:]]) ((i++)) || true ;;
      *) break ;;
    esac
  done
  _json_i="$i"
}

# Read JSON string starting at index i (i points to opening "). Sets _json_i past closing ".
# Sets global _json_str_out to decoded string (no stdout — avoids subshell losing _json_i).
_json_read_string() {
  local j="$1" i="$2"
  local len="${#j}" c out="" esc=0
  ((i++)) || true
  while [[ "$i" -lt "$len" ]]; do
    c="${j:i:1}"
    ((i++)) || true
    if [[ "$esc" == 1 ]]; then
      case "$c" in
        n) out+=$'\n' ;;
        r) out+=$'\r' ;;
        t) out+=$'\t' ;;
        *) out+="$c" ;;
      esac
      esc=0
      continue
    fi
    if [[ "$c" == '\\' ]]; then
      esc=1
      continue
    fi
    if [[ "$c" == '"' ]]; then
      _json_i="$i"
      _json_str_out="$out"
      return 0
    fi
    out+="$c"
  done
  return 1
}

# Read one JSON value starting at i; sets globals _json_value (raw slice) and _json_i (past value).
_json_read_value_raw() {
  local j="$1" i="$2"
  local len="${#j}" c
  _json_skip_ws_idx "$j" "$i"
  i="$_json_i"
  [[ "$i" -lt "$len" ]] || return 1
  c="${j:i:1}"
  if [[ "$c" == '"' ]]; then
    local start="$i"
    _json_read_string "$j" "$i" || return 1
    _json_value="${j:start:_json_i-start}"
    return 0
  fi
  if [[ "$c" == '{' || "$c" == '[' ]]; then
    local start="$i" depth=0 oc="$c" cc in_str=0 esc=0 ch
    [[ "$c" == '{' ]] && cc='}' || cc=']'
    depth=1
    ((i++)) || true
    while [[ "$i" -lt "$len" && "$depth" -gt 0 ]]; do
      ch="${j:i:1}"
      ((i++)) || true
      if [[ "$in_str" == 1 ]]; then
        if [[ "$esc" == 1 ]]; then
          esc=0
        elif [[ "$ch" == '\\' ]]; then
          esc=1
        elif [[ "$ch" == '"' ]]; then
          in_str=0
        fi
        continue
      fi
      if [[ "$ch" == '"' ]]; then
        in_str=1
        esc=0
        continue
      fi
      if [[ "$ch" == '{' || "$ch" == '[' ]]; then
        ((depth++)) || true
      elif [[ "$ch" == '}' || "$ch" == ']' ]]; then
        ((depth--)) || true
      fi
    done
    [[ "$depth" == 0 ]] || return 1
    _json_i="$i"
    _json_value="${j:start:_json_i-start}"
    return 0
  fi
  # number, true, false, null
  local start="$i"
  while [[ "$i" -lt "$len" ]]; do
    ch="${j:i:1}"
    case "$ch" in
      [[:alnum:].eE+-]) ((i++)) || true ;;
      *) break ;;
    esac
  done
  _json_i="$i"
  _json_value="${j:start:_json_i-start}"
  return 0
}

# Get raw value of top-level key in a JSON object (root must be '{').
json_tl_get_raw() {
  local j="$1" want="$2"
  local len="${#j}" i c key got
  _json_skip_ws_idx "$j" 0
  i="$_json_i"
  [[ "$i" -lt "$len" && "${j:i:1}" == '{' ]] || return 1
  ((i++)) || true
  while [[ "$i" -lt "$len" ]]; do
    _json_skip_ws_idx "$j" "$i"
    i="$_json_i"
    c="${j:i:1}"
    if [[ "$c" == '}' ]]; then
      ((i++)) || true
      break
    fi
    [[ "$c" == '"' ]] || return 1
    _json_read_string "$j" "$i" || return 1
    key="$_json_str_out"
    i="$_json_i"
    _json_skip_ws_idx "$j" "$i"
    i="$_json_i"
    [[ "${j:i:1}" == ':' ]] || return 1
    ((i++)) || true
    _json_skip_ws_idx "$j" "$i"
    i="$_json_i"
    _json_read_value_raw "$j" "$i" || return 1
    got="$_json_value"
    i="$_json_i"
    if [[ "$key" == "$want" ]]; then
      printf '%s' "$got"
      return 0
    fi
    _json_skip_ws_idx "$j" "$i"
    i="$_json_i"
    if [[ "$i" -lt "$len" && "${j:i:1}" == ',' ]]; then
      ((i++)) || true
      continue
    fi
    if [[ "$i" -lt "$len" && "${j:i:1}" == '}' ]]; then
      break
    fi
    return 1
  done
  return 1
}

# Decode a JSON string value raw token (leading "...) into plain text.
json_decode_string_token() {
  local token="$1"
  [[ "${token:0:1}" == '"' ]] || {
    printf '%s' "$token"
    return 0
  }
  _json_read_string "$token" 0 || return 1
  printf '%s' "$_json_str_out"
}

json_valid_root() {
  local j="$1"
  _json_skip_ws_idx "$j" 0
  local i="$_json_i" c
  [[ "$i" -lt "${#j}" ]] || return 1
  c="${j:i:1}"
  [[ "$c" == '{' || "$c" == '[' ]] || return 1
  return 0
}

json_build_login_body() {
  local cid="$1" tgt="$2" out=""
  json_escape_string "$cid"
  out="{\"client_id\":\"${json_esc_out}\""
  json_escape_string "$tgt"
  out+=",\"tgt\":\"${json_esc_out}\"}"
  printf '%s' "$out"
}

# Sets global json_esc_out
json_escape_string() {
  local s="$1"
  local r="" i ch len="${#s}"
  for ((i = 0; i < len; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      \\) r+='\\' ;;
      \") r+='\"' ;;
      $'\n') r+='\n' ;;
      $'\r') r+='\r' ;;
      $'\t') r+='\t' ;;
      *) r+="$ch" ;;
    esac
  done
  json_esc_out="$r"
}

json_meta_token_from_body() {
  local body="$1" meta_raw t
  meta_raw="$(json_tl_get_raw "$body" "meta" 2>/dev/null)" || return 0
  [[ "${meta_raw:0:1}" == '{' ]] || return 0
  t="$(json_tl_get_raw "$meta_raw" "token" 2>/dev/null)" || return 0
  [[ "${t:0:1}" == '"' ]] || return 0
  json_decode_string_token "$t"
}

json_login_parse_two_lines() {
  local body="$1" token tgt meta_raw
  token="$(json_tl_get_raw "$body" "token" 2>/dev/null)" || true
  tgt="$(json_tl_get_raw "$body" "tgt" 2>/dev/null)" || true
  if [[ -z "$token" || "$token" == 'null' ]]; then
    meta_raw="$(json_tl_get_raw "$body" "meta" 2>/dev/null)" || true
    if [[ -n "$meta_raw" && "${meta_raw:0:1}" == '{' ]]; then
      [[ -z "$token" || "$token" == 'null' ]] && token="$(json_tl_get_raw "$meta_raw" "token" 2>/dev/null)" || true
      [[ -z "$tgt" || "$tgt" == 'null' ]] && tgt="$(json_tl_get_raw "$meta_raw" "tgt" 2>/dev/null)" || true
    fi
  fi
  if [[ "${token:0:1}" == '"' ]]; then
    token="$(json_decode_string_token "$token")"
  fi
  if [[ "${tgt:0:1}" == '"' ]]; then
    tgt="$(json_decode_string_token "$tgt")"
  fi
  printf '%s\n%s\n' "${token:-}" "${tgt:-}"
}

json_task_runs_raw() {
  local full="$1"
  json_tl_get_raw "$full" "task_runs"
}

json_task_runs_count() {
  local full="$1" arr
  arr="$(json_task_runs_raw "$full" 2>/dev/null)" || {
    echo 0
    return 1
  }
  json_array_length "$arr"
}

json_task_runs_write_file() {
  local full="$1" path="$2" arr
  arr="$(json_task_runs_raw "$full" 2>/dev/null)" || return 1
  printf '%s\n' "$arr" >"$path"
}

json_pretty_stderr() {
  local body="$1"
  printf '%s\n' "$body" >&2
}

# Length of top-level JSON array (walks elements via json_array_get_raw).
json_array_length() {
  local a="$1" n=0
  while json_array_get_raw "$a" "$n" >/dev/null 2>&1; do
    ((n++)) || true
  done
  echo "$n"
}

# Get n-th raw element (0-based) of top-level array.
json_array_get_raw() {
  local a="$1" idx="$2"
  local len="${#a}" i cur=-1
  _json_skip_ws_idx "$a" 0
  i="$_json_i"
  [[ "$i" -lt "$len" && "${a:i:1}" == '[' ]] || return 1
  ((i++)) || true
  _json_skip_ws_idx "$a" "$i"
  i="$_json_i"
  if [[ "$i" -lt "$len" && "${a:i:1}" == ']' ]]; then
    return 1
  fi
  while [[ "$i" -lt "$len" ]]; do
    _json_skip_ws_idx "$a" "$i"
    i="$_json_i"
    if [[ "$i" -lt "$len" && "${a:i:1}" == ']' ]]; then
      return 1
    fi
    ((cur++)) || true
    if [[ "$cur" == "$idx" ]]; then
      _json_read_value_raw "$a" "$i" || return 1
      printf '%s' "$_json_value"
      return 0
    fi
    _json_read_value_raw "$a" "$i" || return 1
    i="$_json_i"
    _json_skip_ws_idx "$a" "$i"
    i="$_json_i"
    if [[ "$i" -lt "$len" && "${a:i:1}" == ',' ]]; then
      ((i++)) || true
      continue
    fi
    if [[ "$i" -lt "$len" && "${a:i:1}" == ']' ]]; then
      return 1
    fi
    return 1
  done
  return 1
}

json_tl_get_string() {
  local j="$1" key="$2" raw
  raw="$(json_tl_get_raw "$j" "$key" 2>/dev/null)" || {
    echo ""
    return 1
  }
  if [[ "${raw:0:1}" == '"' ]]; then
    json_decode_string_token "$raw"
    return 0
  fi
  # number / bool / null as string strip quotes n/a
  printf '%s' "$raw"
}

# From array of objects: latest running task_run_id (by start_timestamp max).
json_running_task_id() {
  local arr="$1" n i raw st id best_id="" best_st=""
  n="$(json_array_length "$arr" 2>/dev/null)" || {
    echo ""
    return 1
  }
  for ((i = 0; i < n; i++)); do
    raw="$(json_array_get_raw "$arr" "$i" 2>/dev/null)" || continue
    [[ "${raw:0:1}" == '{' ]] || continue
    st="$(json_tl_get_raw "$raw" "start_timestamp" 2>/dev/null)" || st="0"
    st="${st//\"/}"
    [[ "$st" =~ ^-?[0-9]+$ ]] || st="0"
    id="$(json_tl_get_raw "$raw" "task_run_id" 2>/dev/null)" || continue
    id="${id//\"/}"
    if [[ "$(json_tl_get_string "$raw" "status" 2>/dev/null)" == "running" ]]; then
      if [[ -z "$best_id" || "$st" -gt "$best_st" ]]; then
        best_st="$st"
        best_id="$id"
      fi
    fi
  done
  printf '%s' "$best_id"
}

json_running_task_name() {
  local arr="$1" tid="$2" n i raw id
  n="$(json_array_length "$arr" 2>/dev/null)" || {
    echo ""
    return 1
  }
  for ((i = 0; i < n; i++)); do
    raw="$(json_array_get_raw "$arr" "$i" 2>/dev/null)" || continue
    [[ "${raw:0:1}" == '{' ]] || continue
    id="$(json_tl_get_raw "$raw" "task_run_id" 2>/dev/null)" || continue
    id="${id//\"/}"
    if [[ "$id" == "$tid" ]]; then
      json_tl_get_string "$raw" "name" 2>/dev/null || echo ""
      return 0
    fi
  done
  echo ""
}

json_approvals_array_raw() {
  local full="$1"
  json_tl_get_raw "$full" "approvals"
}

# Build JSON array of approval_id for pending items from approvals array.
json_pending_approval_ids_array() {
  local arr="$1" n i raw ids="" first=1 aid
  n="$(json_array_length "$arr" 2>/dev/null)" || {
    echo "[]"
    return 0
  }
  printf '['
  for ((i = 0; i < n; i++)); do
    raw="$(json_array_get_raw "$arr" "$i" 2>/dev/null)" || continue
    [[ "${raw:0:1}" == '{' ]] || continue
    if [[ "$(json_tl_get_string "$raw" "status" 2>/dev/null)" != "pending" ]]; then
      continue
    fi
    aid="$(json_tl_get_raw "$raw" "approval_id" 2>/dev/null)" || continue
    [[ -n "$aid" ]] || continue
    if [[ "$first" == 1 ]]; then
      first=0
    else
      printf ','
    fi
    printf '%s' "$aid"
  done
  printf ']\n'
  return 0
}

json_array_length_simple() {
  local arr="$1"
  json_array_length "$arr"
}

json_template_success() {
  local body="$1" tpl succ root_succ
  # New API: top-level "success": true (no "template" object)
  root_succ="$(json_tl_get_raw "$body" "success" 2>/dev/null)" || root_succ=""
  if [[ "$root_succ" == "true" ]]; then
    echo "true"
    return 0
  fi
  # Legacy: template.success
  tpl="$(json_tl_get_raw "$body" "template" 2>/dev/null)" || {
    echo "false"
    return 0
  }
  [[ "${tpl:0:1}" == '{' ]] || {
    echo "false"
    return 0
  }
  succ="$(json_tl_get_raw "$tpl" "success" 2>/dev/null)" || {
    echo "false"
    return 0
  }
  if [[ "$succ" == "true" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

refresh_token_from_body() {
  local body="$1" t
  t="$(json_meta_token_from_body "$body" 2>/dev/null)" || true
  if [[ -n "$t" && "$t" != "null" ]]; then
    TOKEN="$t"
  fi
}

call_api() {
  local method="$1"
  local endpoint="$2"
  local optional_body="${3:-}"
  local optional_content_type="${4:-}"
  local attempt=0 out http_code ec body

  while [[ "$attempt" -lt 2 ]]; do
    ((attempt++)) || true

    if [[ -z "${TOKEN:-}" ]]; then
      echo "${_R}[!] Token is empty. Did login succeed?${_N}" >&2
    fi

    local -a curl_args=(-sS -k)
    curl_args+=(-H "Accept: application/json, text/plain, */*")
    curl_args+=(-H "Authorization: ${TOKEN}")
    if [[ -n "$optional_content_type" ]]; then
      curl_args+=(-H "Content-Type: ${optional_content_type}")
    fi
    curl_args+=(-X "$method" "$endpoint")
    if [[ -n "$optional_body" ]]; then
      curl_args+=(-d "$optional_body")
    fi

    out="$(mktemp)"
    http_code="$(curl "${curl_args[@]}" -o "$out" -w '%{http_code}')" && ec=0 || ec=$?
    http_code="${http_code//$'\r'/}"
    if [[ "$ec" -ne 0 ]]; then
      echo "${_R}[!] API call failed: curl error (exit ${ec})${_N}" >&2
      [[ -f "$out" ]] && cat "$out" >&2 || true
      rm -f "$out"
      echo "null"
      return 1
    fi
    body="$(cat "$out")"
    rm -f "$out"

    if [[ "${http_code:-000}" -ge 400 ]]; then
      if [[ "$http_code" == "401" ]] && [[ "$attempt" -eq 1 ]] && [[ -n "${CONFIG_PATH:-}" ]]; then
        log_ts_err "HTTP 401 - session expired; re-login and retrying once..."
        if login 0 "$CONFIG_PATH"; then
          continue
        fi
      fi
      echo "${_R}[!] API call failed: HTTP ${http_code}${_N}" >&2
      echo "$body" >&2 || true
      echo "null"
      return 1
    fi

    refresh_token_from_body "$body"
    echo "$body"
    return 0
  done

  echo "null"
  return 1
}

login() {
  local verbose="${1:-0}"
  local config_path="$2"

  if [[ "$verbose" == "1" ]]; then
    echo "${_C}[$( _ts )] [*] Logging into Pentera API and generating token${_N}"
  fi

  load_config "$config_path"

  local login_body
  login_body="$(json_build_login_body "$CLIENT_ID" "$TGT")"

  local url="https://${PENTERA_ADDRESS}/auth/login"
  local resp http_code
  resp="$(mktemp)"
  http_code="$(curl -sS -k -o "$resp" -w '%{http_code}' \
    -H "Content-Type: application/json;charset=UTF-8" \
    -H "Accept: application/json, text/plain, */*" \
    -X POST "$url" \
    -d "$login_body")" || true

  if [[ "$http_code" -ge 400 ]] || [[ ! -s "$resp" ]]; then
    echo "${_R}[!] Login error: HTTP ${http_code}${_N}" >&2
    cat "$resp" >&2 || true
    rm -f "$resp"
    return 1
  fi

  local body
  body="$(cat "$resp")"
  rm -f "$resp"

  if ! json_valid_root "$body"; then
    echo "${_R}[!] Login failed: invalid JSON response${_N}" >&2
    json_pretty_stderr "$body"
    return 1
  fi

  local tgt_from_resp token_from_resp _lp
  _lp="$(json_login_parse_two_lines "$body")" || true
  token_from_resp="${_lp%%$'\n'*}"
  tgt_from_resp="${_lp#*$'\n'}"
  tgt_from_resp="${tgt_from_resp%$'\n'}"

  if [[ -n "$token_from_resp" && "$token_from_resp" != "null" ]]; then
    TOKEN="$token_from_resp"
    if [[ -n "$tgt_from_resp" && "$tgt_from_resp" != "null" ]]; then
      update_tgt_in_config "$tgt_from_resp" "$config_path"
      TGT="$tgt_from_resp"
    fi
    if [[ "$verbose" == "1" ]]; then
      echo "${_G}[$( _ts )] [+] Login succeeded, token acquired${_N}"
    fi
  else
    echo "${_R}[!] Login failed: token not found in response${_N}" >&2
    json_pretty_stderr "$body"
    return 1
  fi
}

helper_get_testing_history() {
  local out_path="${1:-}"

  if [[ -z "${TOKEN:-}" ]]; then
    login 0 "$CONFIG_PATH" || return 1
  fi

  log_ts_err "Fetching testing history (last 24 hours)"

  local now_ms yesterday_ms
  now_ms="$(($(date +%s) * 1000))"
  yesterday_ms=$((now_ms - 86400000))

  local endpoint="https://${PENTERA_ADDRESS}/testing_history?start_timestamp=${yesterday_ms}&end_timestamp=${now_ms}"
  local json_response
  json_response="$(call_api GET "$endpoint" "" "")"

  if [[ "$json_response" == "null" ]] || ! json_valid_root "$json_response"; then
    echo "${_R}[!] /testing_history returned no data${_N}" >&2
    echo "null"
    return 1
  fi

  local task_runs_line
  if task_runs_line="$(json_task_runs_raw "$json_response" 2>/dev/null)"; then
    [[ "${task_runs_line:0:1}" == '[' ]] || {
      echo "${_Y}[!] Unexpected response format from /testing_history${_N}" >&2
      json_pretty_stderr "$json_response"
      echo "null"
      return 1
    }
    if [[ -n "$out_path" ]]; then
      if ! json_task_runs_write_file "$json_response" "$out_path"; then
        echo "${_R}[!] /testing_history: could not write task_runs${_N}" >&2
        echo "null"
        return 1
      fi
      local count
      count="$(json_task_runs_count "$json_response" 2>/dev/null)" || count=0
      echo "${_G}[$( _ts )] [+] ${count} total tasks fetched${_N}"
      echo "${_G}[$( _ts )] [+] Saved to ${out_path}${_N}"
      return 0
    fi
    printf '%s\n' "$task_runs_line"
  else
    echo "${_Y}[!] Unexpected response format from /testing_history${_N}" >&2
    json_pretty_stderr "$json_response"
    echo "null"
    return 1
  fi
}

get_running_task_id() {
  local task_runs_json
  task_runs_json="$(helper_get_testing_history "")"

  if [[ "$task_runs_json" == "null" ]] || [[ -z "$task_runs_json" ]]; then
    echo "${_R}[$( _ts )] [!] No task runs found!${_N}" >&2
    echo ""
    return 1
  fi

  local running_id
  running_id="$(json_running_task_id "$task_runs_json")"

  if [[ -n "$running_id" && "$running_id" != "null" ]]; then
    local name
    name="$(json_running_task_name "$task_runs_json" "$running_id")"
    echo "${_G}[$( _ts )] [+] Found running task: ${name} (${running_id})${_N}" >&2
    echo "$running_id"
  else
    echo "${_Y}[$( _ts )] [!] No running tasks found!${_N}" >&2
    echo ""
    return 1
  fi
}

helper_get_approvals() {
  local task_id="$1"
  local endpoint="https://${PENTERA_ADDRESS}/task_run/${task_id}/approvals"
  local json_response
  json_response="$(call_api GET "$endpoint" "" "")"

  local approvals_line
  if approvals_line="$(json_approvals_array_raw "$json_response" 2>/dev/null)"; then
    [[ "${approvals_line:0:1}" == '[' ]] || {
      echo "${_R}[!] Failed to fetch approvals or unexpected format${_N}" >&2
      json_pretty_stderr "$json_response"
      echo "null"
      return 1
    }
    printf '%s\n' "$approvals_line"
  else
    echo "${_R}[!] Failed to fetch approvals or unexpected format${_N}" >&2
    if [[ "$json_response" != "null" ]]; then
      json_pretty_stderr "$json_response"
    fi
    echo "null"
    return 1
  fi
}

helper_execute_actions() {
  local task_id="$1"
  local ids_json="$2"

  local count
  count="$(json_array_length_simple "$ids_json" 2>/dev/null)" || count=0
  if [[ "$count" -eq 0 ]]; then
    echo "${_Y}[$( _ts )] [*] No action IDs to approve${_N}"
    return 0
  fi

  echo "${_M}[$( _ts )] [*] Approving actions via /task_run/{task_run_id}/approve/{approval_id}...${_N}"

  local i id endpoint resp success raw_id
  for ((i = 0; i < count; i++)); do
    raw_id="$(json_array_get_raw "$ids_json" "$i" 2>/dev/null)" || continue
    id="${raw_id//\"/}"
    endpoint="https://${PENTERA_ADDRESS}/task_run/${task_id}/approve/${id}"
    resp="$(call_api POST "$endpoint" "" "")"
    success="$(json_template_success "$resp")"
    if [[ "$success" == "true" ]]; then
      echo "${_G}[$( _ts )] [+] Approved action ${id}${_N}"
    else
      echo "${_R}[$( _ts )] [!] Failed to approve action ${id}${_N}" >&2
      json_pretty_stderr "$resp"
    fi
  done
}

approve_actions_loop() {
  local interval_minutes="$1"
  local duration_hours="$2"

  login 1 "$CONFIG_PATH" || {
    echo "${_R}[!] Login failed; exiting.${_N}" >&2
    exit 1
  }

  log_ts "Starting continuous approval loop (every ${interval_minutes} min for ${duration_hours} h)."

  local total_runtime_seconds interval_seconds elapsed_seconds total_approved cycles
  total_runtime_seconds=$((duration_hours * 3600))
  interval_seconds=$((interval_minutes * 60))
  elapsed_seconds=0
  total_approved=0
  cycles=0

  while [[ "$elapsed_seconds" -lt "$total_runtime_seconds" ]]; do
    log_ts "--- Check (cycle $((cycles + 1))) - elapsed ${elapsed_seconds}s / ${total_runtime_seconds}s, approved so far: ${total_approved} ---"
    log_ts "Checking for running task..."
    local task_id
    task_id="$(get_running_task_id || true)"

    if [[ -n "$task_id" ]]; then
      log_ts "Running task found: $task_id"
      local approvals_json
      approvals_json="$(helper_get_approvals "$task_id" || echo "null")"

      local action_ids_json
      if [[ "$approvals_json" != "null" ]]; then
        action_ids_json="$(json_pending_approval_ids_array "$approvals_json" 2>/dev/null)" || action_ids_json='[]'
      else
        action_ids_json="[]"
      fi

      local n
      n="$(json_array_length_simple "$action_ids_json" 2>/dev/null)" || n=0
      if [[ "$n" -eq 0 ]]; then
        log_ts "No pending approvals found."
      else
        log_ts "Approving ${n} actions..."
        helper_execute_actions "$task_id" "$action_ids_json"
        total_approved=$((total_approved + n))
      fi
    else
      log_ts "No running task found. Will check again in ${interval_minutes} minute(s)."
    fi

    cycles=$((cycles + 1))
    log_ts "Cycle ${cycles} done. Sleeping ${interval_minutes} minute(s) (${interval_seconds}s); no API calls until sleep ends."
    sleep "$interval_seconds" || true
    elapsed_seconds=$((elapsed_seconds + interval_seconds))
    log_ts "Sleep finished; resuming."
  done

  echo ""
  log_ts "======================= Approval Summary ======================="
  log_ts "Total cycles run       : $cycles"
  log_ts "Total actions approved : $total_approved"
  local _finished_at
  _finished_at="$(_ts)"
  log_ts "Finished at            : ${_finished_at}"
}

main() {
  for _a in "$@"; do
    if [[ "$_a" == "-h" || "$_a" == "--help" ]]; then
      usage
      exit 0
    fi
  done

  if ! command -v curl >/dev/null 2>&1; then
    echo "${_R}[!] curl is required (install: apt install curl)${_N}" >&2
    exit 1
  fi

  local all_flag=0 interval_minutes=1 duration_hours=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all_flag=1; shift ;;
      --interval-minutes=*) interval_minutes="${1#*=}"; shift ;;
      --interval-minutes) interval_minutes="$2"; shift 2 ;;
      --duration-hours=*) duration_hours="${1#*=}"; shift ;;
      --duration-hours) duration_hours="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1 ;;
    esac
  done

  if [[ "$all_flag" -ne 1 ]]; then
    echo "Only the '--all' option is supported."
    exit 1
  fi
  if [[ -z "$duration_hours" ]] || ! [[ "$duration_hours" =~ ^[0-9]+$ ]]; then
    echo "${_R}[!] --duration-hours <positive integer> is required${_N}" >&2
    usage >&2
    exit 1
  fi
  if ! [[ "$interval_minutes" =~ ^[0-9]+$ ]] || [[ "$interval_minutes" -lt 1 ]]; then
    echo "${_R}[!] --interval-minutes must be a positive integer${_N}" >&2
    exit 1
  fi

  CONFIG_PATH="$(resolve_config_path)"
  if [[ -z "$CONFIG_PATH" ]]; then
    echo "${_R}[!] pentera_api.conf not found (expected in ${SCRIPT_DIR} or ${SCRIPT_DIR}/../ps/)${_N}" >&2
    exit 1
  fi

  approve_actions_loop "$interval_minutes" "$duration_hours"
}

main "$@"
