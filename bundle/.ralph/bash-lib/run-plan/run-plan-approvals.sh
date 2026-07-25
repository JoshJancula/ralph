#!/usr/bin/env bash
#
# Watcher helper for operator approvals. Detects pending approval requests
# in the plan workspace security directory, keeps artifacts up to date, prompts
# on /dev/tty for interactive runs, and documents headless instructions.

if [[ -n "${RALPH_RUN_PLAN_APPROVALS_LOADED:-}" ]]; then
  return
fi
RALPH_RUN_PLAN_APPROVALS_LOADED=1

_RUN_PLAN_APPROVALS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$_RUN_PLAN_APPROVALS_LIB_DIR/bash-lib/mcp-proxy/mcp-proxy-approvals.sh"

RALPH_RUN_PLAN_APPROVALS_LAST_PENDING=""

ralph_run_plan_approvals_interactive_mode() {
  if [[ "${RALPH_RUN_PLAN_APPROVALS_FORCE_TTY:-0}" == "1" ]]; then
    return 0
  fi
  [[ -t 0 && -t 1 && -t 2 ]]
}

ralph_run_plan_approvals_tty_device() {
  printf '%s' "${RALPH_RUN_PLAN_APPROVALS_TTY_PATH:-/dev/tty}"
}

ralph_run_plan_approvals_artifact_dir() {
  local override="${RALPH_RUN_PLAN_APPROVALS_ARTIFACTS_DIR_OVERRIDE:-}"
  if [[ -n "$override" ]]; then
    mkdir -p "$override"
    printf '%s' "$override"
    return 0
  fi
  local root="${RALPH_PLAN_WORKSPACE_ROOT:-${WORKSPACE:-$(pwd)}/.ralph-workspace}"
  local ns="${RALPH_ARTIFACT_NS:-${RALPH_PLAN_KEY:-plan}}"
  local dir="$root/artifacts/$ns"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

ralph_run_plan_approvals_pending_request_ids() {
  local dir
  dir="$(ralph_mcp_approvals_dir 2>/dev/null)" || return 1
  local -a ids=()
  shopt -s nullglob
  for request in "$dir"/request.*.json; do
    [[ -f "$request" ]] || continue
    local id="${request##*/request.}"
    id="${id%.json}"
    ids+=("$id")
  done
  shopt -u nullglob
  if [[ "${#ids[@]}" -eq 0 ]]; then
    return 1
  fi
  mapfile -t ids < <(printf '%s\n' "${ids[@]}" | sort -u)
  printf '%s\n' "${ids[@]}"
}

ralph_run_plan_approvals_request_summary() {
  local request_id="${1:-}"
  [[ -n "$request_id" ]] || return 1
  local path
  path="$(ralph_mcp_approvals_request_path "$request_id")" || return 1
  [[ -f "$path" ]] || return 1
  jq -c '{
    id: (.id // ""),
    tool: (.tool // "(unknown tool)"),
    category: (.category // ""),
    reason: (.reason // "approval"),
    summary: (.arguments.summary // "(no summary)"),
    timestamp: (.timestamp // ""),
    expires_at: (.expires_at // ""),
    project_root: (.project_root // ""),
    agent_workspace: (.agent_workspace // "")
  }' "$path"
}

ralph_run_plan_approvals_collect_details() {
  local pending="$1"
  local -a out=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    local detail
    detail="$(ralph_run_plan_approvals_request_summary "$id")" || continue
    out+=("$detail")
  done <<< "$pending"
  printf '%s\n' "${out[@]}"
}

ralph_run_plan_approvals_remove_artifacts() {
  local dir
  dir="$(ralph_run_plan_approvals_artifact_dir 2>/dev/null || true)"
  [[ -n "$dir" ]] || return
  rm -f "$dir/APPROVAL-REQUIRED.md" "$dir/approvals.md"
}

ralph_run_plan_approvals_prompt_tty() {
  local pending="$1"
  local artifact_dir
  artifact_dir="$(ralph_run_plan_approvals_artifact_dir 2>/dev/null)" || return
  local requests_dir
  requests_dir="$(ralph_mcp_approvals_dir 2>/dev/null || true)"
  local message
  local short_list
  short_list="$(tr '\n' ' ' <<< "$pending" | sed -E 's/[[:space:]]+$//')"
  message=$(
    cat <<EOF
Operator approval pending for plan ${PLAN_PATH:-(unknown)}:
  Requests: ${short_list:-(id unavailable)}
  Decision files: ${requests_dir}/decision.<id>.json
  Headless artifact: ${artifact_dir}/APPROVAL-REQUIRED.md
  Approvals log: ${artifact_dir}/approvals.md
Complete by creating a decision file per request (decision=approve|deny + optional reason).
EOF
  )
  local tty
  tty="$(ralph_run_plan_approvals_tty_device)"
  if [[ -n "$tty" ]] && [[ -w "$tty" ]] 2>/dev/null; then
    printf '%s\n%s\n' "$message" "$(date '+%Y-%m-%d %H:%M:%S')" >>"$tty"
    return 0
  fi
  echo "$message" >&2
}

ralph_run_plan_approvals_write_artifacts() {
  local pending="$1"
  local artifact_dir
  artifact_dir="$(ralph_run_plan_approvals_artifact_dir 2>/dev/null)" || return 1
  local required_file="$artifact_dir/APPROVAL-REQUIRED.md"
  local log_file="$artifact_dir/approvals.md"
  local requests_dir
  requests_dir="$(ralph_mcp_approvals_dir 2>/dev/null || true)"
  local details
  details="$(ralph_run_plan_approvals_collect_details "$pending")"

  {
    echo "# Operator approval required"
    echo ""
    echo "Plan: ${PLAN_PATH:-(unknown plan)}"
    echo "Workspace: ${WORKSPACE:-}"
    echo ""
    echo "## Pending requests"
    while IFS= read -r detail; do
      [[ -n "$detail" ]] || continue
      local id tool category reason summary timestamp expires project_root agent_ws
      tool="$(jq -r '.tool' <<< "$detail")"
      id="$(jq -r '.id' <<< "$detail")"
      category="$(jq -r '.category' <<< "$detail")"
      reason="$(jq -r '.reason' <<< "$detail")"
      summary="$(jq -r '.summary' <<< "$detail" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g;s/^[[:space:]]+//;s/[[:space:]]+$//')"
      timestamp="$(jq -r '.timestamp' <<< "$detail")"
      expires="$(jq -r '.expires_at' <<< "$detail")"
      project_root="$(jq -r '.project_root' <<< "$detail")"
      agent_ws="$(jq -r '.agent_workspace' <<< "$detail")"
      cat <<REQ
- Request ID: $id
  Tool: $tool
  Category: ${category:-policy}
  Reason: ${reason:-(no reason)}
  Summary: ${summary:-(no summary)}
  Created: ${timestamp:-(unknown)}
  Expires: ${expires:-(unknown)}
  Project: ${project_root:-unset}
  Agent workspace: ${agent_ws:-unset}
  Decision file: $requests_dir/decision.$id.json
REQ
    done <<< "$details"
    echo ""
    echo "## Next steps"
    echo "1. Create ${requests_dir}/decision.<id>.json per request."
    echo "   Example: \$(printf '%s' '{\"id\":\"<request>\",\"decision\":\"approve\",\"reason\":\"approved\"}') > ${requests_dir}/decision.<request>.json"
    echo "2. Save the file; the watcher keeps emitting progress notifications every ${RALPH_APPROVAL_PROGRESS_INTERVAL:-10}s."
    echo "3. Once all decisions exist, the plan run continues automatically."
  } > "$required_file"

  {
    echo "# Approval log for ${PLAN_PATH:-(unknown plan)}"
    echo "Generated at $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    while IFS= read -r detail; do
      [[ -n "$detail" ]] || continue
      local id tool summary
      id="$(jq -r '.id' <<< "$detail")"
      tool="$(jq -r '.tool' <<< "$detail")"
      summary="$(jq -r '.summary' <<< "$detail" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g;s/^[[:space:]]+//;s/[[:space:]]+$//')"
      echo "- Request $id: $tool – ${summary:-(no summary)}"
    done <<< "$details"
  } > "$log_file"

  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "Wrote approval artifacts: $required_file $log_file"
  fi
}

ralph_run_plan_approvals_clear_previous() {
  if [[ -z "${RALPH_RUN_PLAN_APPROVALS_LAST_PENDING:-}" ]]; then
    return
  fi
  ralph_run_plan_approvals_remove_artifacts
  RALPH_RUN_PLAN_APPROVALS_LAST_PENDING=""
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "Approval watcher cleared artifacts"
  fi
}

ralph_run_plan_approvals_notify() {
  local pending="$1"
  ralph_run_plan_approvals_write_artifacts "$pending" || true
  if ralph_run_plan_approvals_interactive_mode; then
    ralph_run_plan_approvals_prompt_tty "$pending"
  fi
  if declare -F ralph_run_plan_log >/dev/null 2>&1; then
    ralph_run_plan_log "approval requests detected: $pending"
  fi
}

ralph_run_plan_approvals_check_pending() {
  if [[ "${RALPH_AGENT_TOOL_ACCESS:-}" != "ralph" ]]; then
    ralph_run_plan_approvals_clear_previous
    return 0
  fi
  if [[ "${RALPH_MCP_POLICY_VIOLATION_MODE:-fatal}" != "approve" ]]; then
    ralph_run_plan_approvals_clear_previous
    return 0
  fi
  local pending
  pending="$(ralph_run_plan_approvals_pending_request_ids 2>/dev/null)" || true
  if [[ -z "$pending" ]]; then
    ralph_run_plan_approvals_clear_previous
    return 0
  fi
  if [[ "$pending" == "${RALPH_RUN_PLAN_APPROVALS_LAST_PENDING:-}" ]]; then
    return 0
  fi
  RALPH_RUN_PLAN_APPROVALS_LAST_PENDING="$pending"
  ralph_run_plan_approvals_notify "$pending"
}
