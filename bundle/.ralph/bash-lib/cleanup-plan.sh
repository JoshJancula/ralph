#!/usr/bin/env bash
set -euo pipefail
#
# Shared implementation for .ralph/cleanup-plan.sh (sourced by the entry script).
#
# Public interface:
#   cleanup_plan_namespace_from_arg_or_env, cleanup_plan_validate_namespace -- resolve RALPH_ARTIFACT_NS / argv.
#   cleanup_plan_workspace_root -- resolve workspace and RALPH_PLAN_WORKSPACE_ROOT.
#   cleanup_plan_log_dir, cleanup_plan_legacy_plan_log_dir -- log directory paths.
#   cleanup_plan_session_dir, cleanup_plan_legacy_plan_session_dir -- session directory paths.
#   cleanup_plan_artifact_dir -- artifact tree for the namespace.
#   cleanup_plan_delete_log_files, cleanup_plan_delete_artifact_dir -- destructive deletes.
#   cleanup_plan_remove_human_action_file -- remove workspace HUMAN_ACTION_REQUIRED.md when safe.

cleanup_plan_namespace_from_arg_or_env() {
  local arg="${1:-}"
  local fallback="${2:-}"
  if [[ -n "$arg" ]]; then
    printf '%s' "$arg"
  else
    printf '%s' "$fallback"
  fi
}

cleanup_plan_validate_namespace() {
  local namespace="${1:-}"
  [[ -n "$namespace" ]]
}

cleanup_plan_workspace_root() {
  local script_dir="$1"
  local workspace_arg="${2:-}"

  if [[ -n "$workspace_arg" ]]; then
    (cd "$workspace_arg" && pwd)
  else
    (cd "$script_dir/../" && pwd)
  fi
}

cleanup_plan_log_dir() {
  local workspace_root="$1"
  local namespace="$2"
  printf '%s/.ralph-workspace/logs/%s' "$workspace_root" "$namespace"
}

cleanup_plan_legacy_plan_log_dir() {
  local workspace_root="$1"
  local namespace="$2"
  printf '%s/.ralph-workspace/logs/%s' "$workspace_root" "$namespace"
}

cleanup_plan_session_dir() {
  local workspace_root="$1"
  local namespace="$2"
  printf '%s/.ralph-workspace/sessions/%s' "$workspace_root" "$namespace"
}

cleanup_plan_legacy_plan_session_dir() {
  local workspace_root="$1"
  local namespace="$2"
  printf '%s/.ralph-workspace/sessions/%s' "$workspace_root" "$namespace"
}

cleanup_plan_artifact_dir() {
  local workspace_root="$1"
  local namespace="$2"
  printf '%s/.ralph-workspace/artifacts/%s' "$workspace_root" "$namespace"
}

cleanup_plan_delete_log_files() {
  local log_dir="$1"

  if [[ -d "$log_dir" ]]; then
    find "$log_dir" -maxdepth 1 -type f -name 'plan-runner-*' -delete
    find "$log_dir" -maxdepth 1 -type f -name '.plan-runner-exit.*' -delete
    echo "Cleaned logs in $log_dir"
  else
    echo "Log directory does not exist: $log_dir" >&2
  fi
}

cleanup_plan_delete_artifact_dir() {
  local artifact_dir="$1"

  if [[ -d "$artifact_dir" ]]; then
    rm -rf "$artifact_dir"
    echo "Removed artifacts in $artifact_dir"
  else
    echo "Artifact directory does not exist: $artifact_dir" >&2
  fi
}

cleanup_plan_remove_human_action_file() {
  local workspace_root="$1"
  local human_file="$workspace_root/HUMAN_ACTION_REQUIRED.md"

  if [[ -f "$human_file" ]]; then
    rm -f "$human_file"
    echo "Removed human action file: $human_file"
  else
    echo "Human action file not found: $human_file"
  fi
}
