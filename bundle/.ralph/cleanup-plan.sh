#!/usr/bin/env bash
# Delete Ralph plan logs and artifacts scoped to one namespace.
#
# Usage:
#   .ralph/cleanup-plan.sh [OPTIONS] <artifact-namespace> [workspace]
#     Removes `.ralph-workspace/logs/<namespace>/plan-runner-*` files, `.ralph-workspace/sessions/<namespace>/`,
#     legacy `.ralph-workspace/logs/<namespace>/` plan-runner files if present, legacy `.ralph-workspace/sessions/<namespace>/` if present,
#     `.ralph-workspace/artifacts/<namespace>/`, and `.ralph-workspace/tool-results/<namespace>/`.
#     Defaults to `$RALPH_ARTIFACT_NS` if the namespace argument is empty.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/bash-lib/cleanup-plan.sh"
# shellcheck source=bash-lib/runtime-overlay/runtime-overlay.sh
source "$SCRIPT_DIR/bash-lib/runtime-overlay/runtime-overlay.sh"

cleanup_plan_run_namespace_cleanup() {
  local workspace_root="$1"
  local namespace="$2"

  local log_dir legacy_log_dir session_dir legacy_session_dir
  log_dir="$(cleanup_plan_log_dir "$workspace_root" "$namespace")"
  legacy_log_dir="$(cleanup_plan_legacy_plan_log_dir "$workspace_root" "$namespace")"
  session_dir="$(cleanup_plan_session_dir "$workspace_root" "$namespace")"
  legacy_session_dir="$(cleanup_plan_legacy_plan_session_dir "$workspace_root" "$namespace")"

  local artifact_dir tool_results_dir
  artifact_dir="$(cleanup_plan_artifact_dir "$workspace_root" "$namespace")"
  tool_results_dir="$(cleanup_plan_tool_results_dir "$workspace_root" "$namespace")"

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
  cleanup_plan_delete_tool_results_dir "$tool_results_dir"
  cleanup_plan_remove_human_action_file "$workspace_root"
}

main() {
  local script_name="$0"
  local run_runtime_config_cleanup=0
  local runtime_config_namespace=""
  local runtime_config_all=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        cleanup_plan_usage "$script_name"
        exit 0
        ;;
      --runtime-config)
        run_runtime_config_cleanup=1
        shift
        if [[ "${1:-}" == "--all" ]]; then
          runtime_config_all=1
          shift
        else
          runtime_config_namespace="${1:-}"
          if [[ -z "$runtime_config_namespace" ]]; then
            echo "Missing namespace for --runtime-config" >&2
            cleanup_plan_usage "$script_name"
            exit 1
          fi
          shift
        fi
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Unknown option: $1" >&2
        cleanup_plan_usage "$script_name"
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  local namespace_arg="${1:-}"
  shift || true
  local workspace_arg="${1:-}"
  if [[ "$run_runtime_config_cleanup" -eq 1 && -z "$workspace_arg" && -n "$namespace_arg" && -n "$runtime_config_namespace" ]]; then
    workspace_arg="$namespace_arg"
    namespace_arg=""
  fi
  local namespace_default="${runtime_config_namespace:-${RALPH_ARTIFACT_NS:-}}"
  local namespace

  namespace="$(cleanup_plan_namespace_from_arg_or_env "$namespace_arg" "$namespace_default")"

  local run_plan_cleanup=0

  if cleanup_plan_validate_namespace "$namespace"; then
    run_plan_cleanup=1
  fi

  if [[ "$run_plan_cleanup" -eq 0 ]]; then
    cleanup_plan_usage "$script_name"
    exit 1
  fi

  local workspace_root
  workspace_root="$(cleanup_plan_workspace_root "$SCRIPT_DIR" "$workspace_arg")"

  if [[ "$run_plan_cleanup" -eq 1 ]]; then
    cleanup_plan_run_namespace_cleanup "$workspace_root" "$namespace"
  fi

  if [[ "$run_runtime_config_cleanup" -eq 1 ]]; then
    local runtime_config_filter="$runtime_config_namespace"
    if [[ "$runtime_config_all" -eq 1 ]]; then
      runtime_config_filter=""
    fi
    local runtime_overlay_output
    if runtime_overlay_output="$(runtime_overlay_restore_stale_runs "$workspace_root" "$runtime_config_filter")"; then
      if [[ -n "$runtime_overlay_output" ]]; then
        printf '%s\n' "$runtime_overlay_output"
      fi
    else
      echo "Runtime overlay cleanup failed" >&2
      exit 1
    fi
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
