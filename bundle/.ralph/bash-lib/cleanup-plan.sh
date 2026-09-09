#!/usr/bin/env bash
set -euo pipefail
#
# Shared implementation for .ralph/cleanup-plan.sh (sourced by the entry script).
#
# Public interface:
#   cleanup_plan_usage -- print CLI help (optional script path for Usage line).
#   cleanup_plan_namespace_from_arg_or_env, cleanup_plan_validate_namespace -- resolve RALPH_ARTIFACT_NS / argv.
#   cleanup_plan_workspace_root -- resolve workspace and RALPH_PLAN_WORKSPACE_ROOT.
#   cleanup_plan_log_dir, cleanup_plan_legacy_plan_log_dir -- log directory paths.
#   cleanup_plan_session_dir, cleanup_plan_legacy_plan_session_dir -- session directory paths.
#   cleanup_plan_artifact_dir -- artifact tree for the namespace.
#   cleanup_plan_tool_results_dir -- stored MCP proxy tool results for the namespace.
#   cleanup_plan_delete_log_files, cleanup_plan_delete_artifact_dir -- destructive deletes.
#   cleanup_plan_delete_tool_results_dir -- remove tool-results/<namespace>/ tree.
#   cleanup_plan_remove_human_action_file -- remove workspace HUMAN_ACTION_REQUIRED.md when safe.

_CLEANUP_PLAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if ! declare -F graph_logs_resolve >/dev/null 2>&1; then
  # shellcheck source=graph/graph-logs.sh
  source "$_CLEANUP_PLAN_LIB_DIR/graph/graph-logs.sh"
fi

cleanup_plan_usage() {
  local script_path="${1:-.ralph/cleanup-plan.sh}"
  cat <<EOF
Usage: ${script_path} [OPTIONS] <artifact-namespace> [workspace]

Delete Ralph plan logs and artifacts scoped to one namespace.

Options:
  --runtime-config <namespace>  Restore stale runtime overlays (journals) for the namespace.
  --runtime-config --all        Restore stale runtime overlays for every namespace.
  -h, --help     Show this help.

When <artifact-namespace> is omitted, defaults to \$RALPH_ARTIFACT_NS.
When [workspace] is omitted, defaults to the parent of .ralph/.
EOF
}

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

cleanup_plan_tool_results_dir() {
  local workspace_root="$1"
  local namespace="$2"
  printf '%s/.ralph-workspace/tool-results/%s' "$workspace_root" "$namespace"
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

cleanup_plan_delete_tool_results_dir() {
  local tool_results_dir="$1"

  if [[ -d "$tool_results_dir" ]]; then
    rm -rf "$tool_results_dir"
    echo "Removed tool results in $tool_results_dir"
  else
    echo "Tool results directory does not exist: $tool_results_dir" >&2
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

# --- Graph-run retention ---------------------------------------------------
#
# Terminal run statuses that are safe to prune:
#   succeeded, failed, cancelled
# Non-terminal run statuses that must never be pruned:
#   running (scheduler is active), awaiting-ack (waiting on human checkpoint)
#
# Retention defaults (override via environment):
#   RALPH_GRAPH_RUN_MAX_AGE_DAYS=30  Prune terminal runs older than 30 days.
#   RALPH_GRAPH_RUN_MAX_COUNT=10     Keep at most 10 terminal runs per namespace.

# cleanup_plan_graph_runs_namespace_dir <workspace_root> <namespace>
# Prints the per-namespace graph-runs directory path.
cleanup_plan_graph_runs_namespace_dir() {
  local workspace_root="$1" namespace="$2"
  printf '%s/.ralph-workspace/graph-runs/%s' "$workspace_root" "$namespace"
}

# cleanup_plan_stage_outcomes_dir <workspace_root> <namespace>
# Prints the stage-outcomes directory path for the given namespace.
cleanup_plan_stage_outcomes_dir() {
  local workspace_root="$1" namespace="$2"
  printf '%s/.ralph-workspace/artifacts/%s/stage-outcomes' "$workspace_root" "$namespace"
}

# cleanup_plan_graph_run_is_terminal <run_json_path>
# Returns 0 when the run's status is succeeded, failed, or cancelled.
# Returns 1 for non-terminal statuses (running, awaiting-ack) or unreadable JSON.
cleanup_plan_graph_run_is_terminal() {
  local run_json="$1"
  [[ -f "$run_json" ]] || return 1
  local status
  status="$(jq -r '.status // empty' "$run_json" 2>/dev/null)" || return 1
  case "$status" in
    succeeded|failed|cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

# cleanup_plan_file_mtime <path>
# Prints the mtime of <path> as a Unix epoch integer.
# Tries macOS BSD stat first, then GNU stat.
# Epoch mtime, or 0 when it cannot be read.
#
# Probe GNU coreutils first. BSD `stat -c` fails cleanly and falls through, but
# GNU `stat -f` *succeeds* with filesystem info -- a multi-line "File: ..."
# block -- so the BSD-first order returns prose on Linux. Callers compare the
# result arithmetically, where `File` is then evaluated as a variable name and
# aborts the run under `set -u`. Validate the result rather than trusting the
# exit status alone.
cleanup_plan_file_mtime() {
  local path="$1" mtime=""
  mtime="$(stat -c %Y "$path" 2>/dev/null)" || mtime=""
  if [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
    mtime="$(stat -f %m "$path" 2>/dev/null)" || mtime=""
  fi
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  printf '%s\n' "$mtime"
}

# cleanup_plan_epoch_days_ago <days>
# Prints the Unix epoch N days in the past.
# Tries GNU date first, then macOS BSD date.
cleanup_plan_epoch_days_ago() {
  local days="$1"
  local epoch
  if epoch="$(date -d "$days days ago" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"
  elif epoch="$(date -v "-${days}d" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"
  else
    printf '0'
  fi
}

# cleanup_plan_prune_stage_outcomes_for_run <stage_outcomes_dir> <run_id>
# Removes stage-outcome JSON files whose name encodes <run_id>.
# Attempt IDs have the form <node_id>__<run_id>__<attempt_number>, so files
# are matched by the pattern *__<run_id>__*.json.
cleanup_plan_prune_stage_outcomes_for_run() {
  local stage_outcomes_dir="$1" run_id="$2"
  [[ -d "$stage_outcomes_dir" ]] || return 0
  local f removed=0
  for f in "$stage_outcomes_dir"/*__"${run_id}"__*.json; do
    [[ -f "$f" ]] || continue
    rm -f "$f"
    removed=$((removed + 1))
  done
  if [[ "$removed" -gt 0 ]]; then
    echo "Pruned $removed stage-outcome file(s) for run $run_id"
  fi
}

# cleanup_plan_prune_graph_runs <workspace_root> <namespace>
# Prunes terminal graph runs by age and by run count for the given namespace.
#
# Rules enforced:
#   - Never deletes the run pointed at by the latest symlink.
#   - Never deletes a run whose status is non-terminal (running or awaiting-ack).
#   - When a run is pruned, also removes its associated stage-outcome files.
#
# Retention defaults (override via environment):
#   RALPH_GRAPH_RUN_MAX_AGE_DAYS=30  Prune terminal runs older than 30 days.
#   RALPH_GRAPH_RUN_MAX_COUNT=10     Keep at most 10 terminal runs per namespace.
cleanup_plan_prune_graph_runs() {
  local workspace_root="$1" namespace="$2"
  local max_age_days="${RALPH_GRAPH_RUN_MAX_AGE_DAYS:-30}"
  local max_count="${RALPH_GRAPH_RUN_MAX_COUNT:-10}"

  local ns_dir stage_outcomes_dir
  ns_dir="$(cleanup_plan_graph_runs_namespace_dir "$workspace_root" "$namespace")"
  stage_outcomes_dir="$(cleanup_plan_stage_outcomes_dir "$workspace_root" "$namespace")"

  if [[ ! -d "$ns_dir" ]]; then
    return 0
  fi

  # Resolve the latest symlink target (basename of the run_id only).
  local latest_link="$ns_dir/latest"
  local latest_run_id=""
  if [[ -L "$latest_link" ]]; then
    latest_run_id="$(basename "$(readlink "$latest_link")")" || true
  fi

  # Collect run directories sorted newest-first by mtime.
  local run_ids=()
  local entry
  while IFS= read -r entry; do
    [[ "$entry" == "latest" ]] && continue
    [[ -d "$ns_dir/$entry" ]] || continue
    run_ids+=("$entry")
  done < <(ls -t1 "$ns_dir" 2>/dev/null || true)

  if [[ "${#run_ids[@]}" -eq 0 ]]; then
    return 0
  fi

  # Compute cutoff epoch for age-based pruning.
  local cutoff_epoch
  cutoff_epoch="$(cleanup_plan_epoch_days_ago "$max_age_days")"

  local run_id run_json should_prune run_mtime kept_terminal=0

  for run_id in "${run_ids[@]}"; do
    run_json="$ns_dir/$run_id/run.json"

    # Never prune the run pointed at by the latest symlink.
    if [[ -n "$latest_run_id" && "$run_id" == "$latest_run_id" ]]; then
      continue
    fi

    # Never prune non-terminal runs (running or awaiting-ack).
    if ! cleanup_plan_graph_run_is_terminal "$run_json"; then
      continue
    fi

    should_prune=0

    # Age-based: prune if the run directory is older than the cutoff.
    if [[ "$cutoff_epoch" -gt 0 ]]; then
      run_mtime="$(cleanup_plan_file_mtime "$ns_dir/$run_id")"
      if [[ "$run_mtime" -lt "$cutoff_epoch" ]]; then
        should_prune=1
      fi
    fi

    # Count-based: prune once we have retained max_count terminal runs.
    if [[ "$should_prune" -eq 0 && "$kept_terminal" -ge "$max_count" ]]; then
      should_prune=1
    fi

    if [[ "$should_prune" -eq 1 ]]; then
      rm -rf "$ns_dir/$run_id"
      echo "Pruned graph run: $run_id (namespace: $namespace)"
      cleanup_plan_prune_stage_outcomes_for_run "$stage_outcomes_dir" "$run_id"
    else
      kept_terminal=$((kept_terminal + 1))
    fi
  done
}
