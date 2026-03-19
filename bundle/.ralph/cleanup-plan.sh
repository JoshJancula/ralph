#!/usr/bin/env bash
# Delete Ralph plan logs and artifacts scoped to one namespace.
#
# Usage:
#   .ralph/cleanup-plan.sh <artifact-namespace> [workspace]
#     Removes `.agents/logs/<namespace>/plan-runner-*` files and `.agents/artifacts/<namespace>/`.
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

  local log_dir
  log_dir="$(cleanup_plan_log_dir "$workspace_root" "$namespace")"

  local artifact_dir
  artifact_dir="$(cleanup_plan_artifact_dir "$workspace_root" "$namespace")"

  cleanup_plan_delete_log_files "$log_dir"
  cleanup_plan_delete_artifact_dir "$artifact_dir"
  cleanup_plan_remove_human_action_file "$workspace_root"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
