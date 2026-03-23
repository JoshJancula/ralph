#!/usr/bin/env bash
# Delete Ralph plan logs and artifacts scoped to one namespace.
#
# Usage:
#   .ralph/cleanup-plan.sh <artifact-namespace> [workspace]
#     Removes `.ralph-workspace/logs/<namespace>/plan-runner-*` files, `.ralph-workspace/sessions/<namespace>/`,
#     legacy `.ralph-workspace/logs/<namespace>/` plan-runner files if present, legacy `.ralph-workspace/sessions/<namespace>/` if present,
#     and `.ralph-workspace/artifacts/<namespace>/`.
#     Defaults to `$RALPH_ARTIFACT_NS` if the namespace argument is empty.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/bash-lib/cleanup-plan.sh"

cleanup_plan_usage() {
  echo "Usage: $0 <artifact-namespace> [workspace]" >&2
}

main() {
  local namespace_arg="${1:-}"
  shift || true
  local workspace_arg="${1:-}"
  local namespace

  namespace="$(cleanup_plan_namespace_from_arg_or_env "$namespace_arg" "${RALPH_ARTIFACT_NS:-}")"

  if ! cleanup_plan_validate_namespace "$namespace"; then
    cleanup_plan_usage
    exit 1
  fi

  local workspace_root
  workspace_root="$(cleanup_plan_workspace_root "$SCRIPT_DIR" "$workspace_arg")"

  local log_dir legacy_log_dir session_dir legacy_session_dir
  log_dir="$(cleanup_plan_log_dir "$workspace_root" "$namespace")"
  legacy_log_dir="$(cleanup_plan_legacy_plan_log_dir "$workspace_root" "$namespace")"
  session_dir="$(cleanup_plan_session_dir "$workspace_root" "$namespace")"
  legacy_session_dir="$(cleanup_plan_legacy_plan_session_dir "$workspace_root" "$namespace")"

  local artifact_dir
  artifact_dir="$(cleanup_plan_artifact_dir "$workspace_root" "$namespace")"

  cleanup_plan_delete_log_files "$log_dir"
  if [[ -d "$legacy_log_dir" ]]; then
    cleanup_plan_delete_log_files "$legacy_log_dir"
  fi
  if [[ -d "$session_dir" ]]; then
    rm -rf "$session_dir"
    echo "Removed session directory $session_dir"
  fi
  if [[ -d "$legacy_session_dir" && "$legacy_session_dir" != "$session_dir" ]]; then
    rm -rf "$legacy_session_dir"
    echo "Removed legacy session directory $legacy_session_dir"
  fi
  cleanup_plan_delete_artifact_dir "$artifact_dir"
  cleanup_plan_remove_human_action_file "$workspace_root"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
