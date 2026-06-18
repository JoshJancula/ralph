#!/usr/bin/env bash
# Operator approval request/decision storage for the unified MCP server.
# Twin copy: bash-lib/mcp-proxy/mcp-proxy-approvals.sh

if [[ -n "${RALPH_MCP_PROXY_APPROVALS_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_APPROVALS_LOADED=1

_APPROVALS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${RALPH_MCP_PROXY_POLICY_LOADED:-}" ]]; then
  # shellcheck source=/dev/null
  source "$_APPROVALS_LIB_DIR/mcp-proxy-policy.sh"
fi

RALPH_APPROVAL_TIMEOUT=${RALPH_APPROVAL_TIMEOUT:-120}
RALPH_APPROVAL_POLL_INTERVAL=${RALPH_APPROVAL_POLL_INTERVAL:-1}
RALPH_APPROVAL_PROGRESS_INTERVAL=${RALPH_APPROVAL_PROGRESS_INTERVAL:-10}

ralph_mcp_approvals_dir() {
  local plan_key="${1:-${RALPH_PLAN_KEY:-unknown}}"
  local sanitized security_dir dir canonical
  sanitized="$(ralph_mcp_policy_plan_key_safe "$plan_key")"
  security_dir="$(ralph_mcp_policy_security_dir)" || return 1
  dir="$security_dir/approvals/$sanitized"
  mkdir -p "$security_dir/approvals" "$dir" || return 1
  chmod 0700 "$security_dir/approvals" "$dir" 2>/dev/null || true
  canonical="$(ralph_mcp_policy_canonicalize_path "$dir")" || return 1
  case "$canonical" in
    "$security_dir/approvals"|"$security_dir/approvals"/*)
      printf '%s\n' "$canonical"
      return 0
      ;;
    *)
      printf 'Error: approvals path traversal detected for %s\n' "$plan_key" >&2
      return 1
      ;;
  esac
}

ralph_mcp_approvals_audit_log_path() {
  local dir
  dir="$(ralph_mcp_approvals_dir)" || return 1
  printf '%s/approvals.log\n' "$dir"
}

ralph_mcp_approvals_request_path() {
  local request_id="${1:-}"
  [[ -n "$request_id" ]] || return 1
  local dir
  dir="$(ralph_mcp_approvals_dir)" || return 1
  printf '%s/request.%s.json\n' "$dir" "$request_id"
}

ralph_mcp_approvals_decision_path() {
  local request_id="${1:-}"
  [[ -n "$request_id" ]] || return 1
  local dir
  dir="$(ralph_mcp_approvals_dir)" || return 1
  printf '%s/decision.%s.json\n' "$dir" "$request_id"
}

ralph_mcp_approvals_generate_id() {
  local tool="${1:-}"
  local arguments_json="${2:-}"
  local hash short_hash
  hash="$(ralph_mcp_policy_argument_hash "${tool}:${arguments_json}")"
  short_hash="${hash:0:8}"
  if [[ -z "$short_hash" ]]; then
    short_hash="$(printf '%s' "${tool}:${arguments_json}" | cksum | awk '{print $1}' | cut -c1-8)"
  fi
  printf '%s-%s\n' "$(date +%s)" "$short_hash"
}

ralph_mcp_approvals_atomic_write_json() {
  local target_path="${1:-}"
  local json="${2:-}"
  [[ -n "$target_path" && -n "$json" ]] || return 1
  local dir tmp
  dir="$(dirname "$target_path")"
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.approval.XXXXXX")" || return 1
  (
    umask 077
    jq -c '.' <<<"$json" >"$tmp"
  ) || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$target_path"
}

ralph_mcp_approvals_decision_file_owned_by_current_user() {
  local file="${1:-}"
  [[ -f "$file" ]] || return 1
  local current_uid owner_uid
  current_uid="$(id -u)"
  if owner_uid="$(stat -c '%u' "$file" 2>/dev/null)"; then
    :
  elif owner_uid="$(stat -f '%u' "$file" 2>/dev/null)"; then
    :
  else
    printf 'Warning: unable to determine owner of %s; rejecting approval decision for safety.\n' "$file" >&2
    return 1
  fi
  owner_uid="${owner_uid%%$'\n'*}"
  if [[ "$owner_uid" != "$current_uid" ]]; then
    printf 'Warning: %s is owned by UID %s but current UID is %s; ignoring decision to prevent injection.\n' \
      "$file" "$owner_uid" "$current_uid" >&2
    return 1
  fi
  return 0
}

ralph_mcp_approvals_write_request() {
  local tool="${1:-}"
  local category="${2:-policy}"
  local reason="${3:-violation}"
  local arguments_json="${4-}"
  if [[ -z "$arguments_json" ]]; then
    arguments_json='{}'
  fi
  local request_id="${5:-}"

  command -v jq >/dev/null 2>&1 || return 1
  [[ -n "$tool" ]] || return 1

  if [[ -z "$request_id" ]]; then
    request_id="$(ralph_mcp_approvals_generate_id "$tool" "$arguments_json")" || return 1
  fi

  local timeout_seconds="${RALPH_APPROVAL_TIMEOUT:-120}"
  local timestamp expires_at summary hash plan_key project_root agent_workspace
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  expires_at="$(date -u -v+"${timeout_seconds}S" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+${timeout_seconds} seconds" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
  if [[ -z "$expires_at" ]]; then
    expires_at="$(python3 -c 'import datetime, os; print((datetime.datetime.utcnow() + datetime.timedelta(seconds=int(os.environ.get("RALPH_APPROVAL_TIMEOUT", "120")))).strftime("%Y-%m-%dT%H:%M:%SZ"))' 2>/dev/null || true)"
  fi
  [[ -n "$expires_at" ]] || expires_at="$timestamp"

  plan_key="${RALPH_PLAN_KEY:-unknown}"
  project_root="${RALPH_PROJECT_ROOT:-${WORKSPACE:-}}"
  agent_workspace="${RALPH_AGENT_WORKSPACE:-${project_root}}"
  summary="$(ralph_mcp_policy_argument_summary "$arguments_json")"
  hash="$(ralph_mcp_policy_argument_hash "$arguments_json")"

  local request_json request_path
  request_json="$(
    jq -n -c \
      --arg id "$request_id" \
      --arg timestamp "$timestamp" \
      --arg plan_key "$plan_key" \
      --arg tool "$tool" \
      --arg category "$category" \
      --arg reason "$reason" \
      --arg summary "$summary" \
      --arg hash "$hash" \
      --arg arguments_json "$arguments_json" \
      --arg project_root "$project_root" \
      --arg agent_workspace "$agent_workspace" \
      --argjson timeout_seconds "$timeout_seconds" \
      --arg expires_at "$expires_at" \
      '{
        id: $id,
        timestamp: $timestamp,
        plan_key: $plan_key,
        tool: $tool,
        category: $category,
        reason: $reason,
        arguments: {summary: $summary, hash: $hash},
        arguments_json: $arguments_json,
        project_root: $project_root,
        agent_workspace: $agent_workspace,
        timeout_seconds: $timeout_seconds,
        expires_at: $expires_at
      }'
  )" || return 1

  request_path="$(ralph_mcp_approvals_request_path "$request_id")" || return 1
  ralph_mcp_approvals_atomic_write_json "$request_path" "$request_json" || return 1
  printf '%s\n' "$request_id"
}

ralph_mcp_approvals_read_request_json() {
  local request_id="${1:-}"
  local request_path
  request_path="$(ralph_mcp_approvals_request_path "$request_id")" || return 1
  [[ -f "$request_path" ]] || return 1
  cat "$request_path"
}

ralph_mcp_approvals_read_decision() {
  local request_id="${1:-}"
  local decision_path decision_json decision reason expected_id
  [[ -n "$request_id" ]] || return 1

  decision_path="$(ralph_mcp_approvals_decision_path "$request_id")" || return 1
  [[ -f "$decision_path" ]] || return 1
  ralph_mcp_approvals_decision_file_owned_by_current_user "$decision_path" || return 1

  decision_json="$(cat "$decision_path")"
  if ! jq -e '
    (.id | type) == "string" and length > 0
    and (.decision | type) == "string"
    and (.decision == "approve" or .decision == "deny")
  ' <<<"$decision_json" >/dev/null 2>&1; then
    printf 'Warning: invalid approval decision JSON in %s\n' "$decision_path" >&2
    return 1
  fi

  expected_id="$(jq -r '.id' <<<"$decision_json")"
  if [[ "$expected_id" != "$request_id" ]]; then
    printf 'Warning: decision id %s does not match request id %s\n' "$expected_id" "$request_id" >&2
    return 1
  fi

  decision="$(jq -r '.decision' <<<"$decision_json")"
  reason="$(jq -r '.reason // ""' <<<"$decision_json")"
  if [[ "$decision" == "approve" ]]; then
    printf 'approve\n'
  else
    printf 'deny\t%s\n' "$reason"
  fi
  return 0
}

ralph_mcp_approvals_wait_for_decision() {
  local request_id="${1:-}"
  local timeout_seconds="${2:-${RALPH_APPROVAL_TIMEOUT:-120}}"
  local poll_interval="${RALPH_APPROVAL_POLL_INTERVAL:-1}"
  local progress_interval="${RALPH_APPROVAL_PROGRESS_INTERVAL:-10}"
  local start elapsed last_progress decision_line

  [[ -n "$request_id" ]] || return 1
  start=$SECONDS
  last_progress=0

  while true; do
    if decision_line="$(ralph_mcp_approvals_read_decision "$request_id" 2>/dev/null)"; then
      printf '%s\n' "$decision_line"
      return 0
    fi

    elapsed=$((SECONDS - start))
    if (( elapsed >= timeout_seconds )); then
      return 1
    fi

    if (( progress_interval > 0 && elapsed - last_progress >= progress_interval )); then
      if declare -F ralph_mcp_approvals_on_progress >/dev/null 2>&1; then
        ralph_mcp_approvals_on_progress "$request_id" "$elapsed" "$timeout_seconds"
      fi
      last_progress=$elapsed
    fi

    sleep "$poll_interval"
  done
}

ralph_mcp_approvals_append_audit() {
  local audit_entry_json="${1:-}"
  local audit_path
  [[ -n "$audit_entry_json" ]] || return 1
  audit_path="$(ralph_mcp_approvals_audit_log_path)" || return 1
  jq -c '.' <<<"$audit_entry_json" >>"$audit_path"
}

ralph_mcp_approvals_finalize() {
  local request_id="${1:-}"
  local outcome="${2:-}"
  local reason="${3:-}"
  local decided_by="${4:-}"
  local request_json tool category request_reason timestamp audit_entry
  local request_path decision_path

  [[ -n "$request_id" && -n "$outcome" ]] || return 1

  request_json="$(ralph_mcp_approvals_read_request_json "$request_id" 2>/dev/null || printf '{}')"
  tool="$(jq -r '.tool // "unknown"' <<<"$request_json")"
  category="$(jq -r '.category // "policy"' <<<"$request_json")"
  request_reason="$(jq -r '.reason // ""' <<<"$request_json")"
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  audit_entry="$(
    jq -n -c \
      --arg timestamp "$timestamp" \
      --arg request_id "$request_id" \
      --arg outcome "$outcome" \
      --arg reason "$reason" \
      --arg decided_by "$decided_by" \
      --arg tool "$tool" \
      --arg category "$category" \
      --arg request_reason "$request_reason" \
      --argjson request "$request_json" \
      '{
        timestamp: $timestamp,
        request_id: $request_id,
        outcome: $outcome,
        reason: $reason,
        decided_by: $decided_by,
        tool: $tool,
        category: $category,
        request_reason: $request_reason,
        request: $request
      }'
  )" || return 1

  ralph_mcp_approvals_append_audit "$audit_entry" || return 1

  request_path="$(ralph_mcp_approvals_request_path "$request_id" 2>/dev/null || true)"
  decision_path="$(ralph_mcp_approvals_decision_path "$request_id" 2>/dev/null || true)"
  [[ -n "$request_path" && -f "$request_path" ]] && rm -f "$request_path"
  [[ -n "$decision_path" && -f "$decision_path" ]] && rm -f "$decision_path"
  return 0
}

ralph_mcp_proxy_set_scoped_approval() {
  local request_id="${1:-}"
  local tool="${2:-}"
  local category="${3:-boundary}"
  local reason="${4:-}"
  local arguments_json="${5-}"
  if [[ -z "$arguments_json" ]]; then
    arguments_json='{}'
  fi
  local hash

  [[ -n "$request_id" && -n "$tool" ]] || return 1
  hash="$(ralph_mcp_policy_argument_hash "$arguments_json")"
  RALPH_MCP_PROXY_SCOPED_APPROVAL_JSON="$(
    jq -n -c \
      --arg request_id "$request_id" \
      --arg tool "$tool" \
      --arg category "$category" \
      --arg reason "$reason" \
      --arg hash "$hash" \
      '{
        request_id: $request_id,
        tool: $tool,
        category: $category,
        reason: $reason,
        arguments_hash: $hash
      }'
  )"
  export RALPH_MCP_PROXY_SCOPED_APPROVAL_JSON
}

ralph_mcp_proxy_clear_scoped_approval() {
  unset RALPH_MCP_PROXY_SCOPED_APPROVAL_JSON
}

ralph_mcp_proxy_scoped_approval_allows() {
  local tool="${1:-}"
  local category="${2:-boundary}"
  local arguments_json="${3-}"
  if [[ -z "$arguments_json" ]]; then
    arguments_json='{}'
  fi
  local approved_tool approved_category approved_hash current_hash

  [[ -n "${RALPH_MCP_PROXY_SCOPED_APPROVAL_JSON:-}" ]] || return 1
  approved_tool="$(jq -r '.tool // ""' <<<"$RALPH_MCP_PROXY_SCOPED_APPROVAL_JSON")"
  approved_category="$(jq -r '.category // ""' <<<"$RALPH_MCP_PROXY_SCOPED_APPROVAL_JSON")"
  approved_hash="$(jq -r '.arguments_hash // ""' <<<"$RALPH_MCP_PROXY_SCOPED_APPROVAL_JSON")"
  current_hash="$(ralph_mcp_policy_argument_hash "$arguments_json")"
  [[ -n "$approved_hash" && "$tool" == "$approved_tool" && "$category" == "$approved_category" && "$current_hash" == "$approved_hash" ]]
}
