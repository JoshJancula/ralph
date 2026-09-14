#!/usr/bin/env bash
# Run-scoped workflow usage reporting. Read-only and best-effort: reporting
# must never change the workflow command's original exit status.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_WORKFLOW_USAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WORKFLOW_USAGE_RALPH_DIR="$(cd "$_WORKFLOW_USAGE_LIB_DIR/../.." && pwd)"

# workflow_usage_print_run_report <state-root> <run-id> <workspace>
workflow_usage_print_run_report() {
  local state_root="${1:-}" run_id="${2:-}" workspace="${3:-}"
  local run_file mode usage_root artifact_ns report_state report_label

  [[ "${RALPH_WORKFLOW_USAGE_REPORT:-1}" != "0" ]] || return 0
  [[ -n "$state_root" && -n "$run_id" && -n "$workspace" ]] || return 0
  run_file="$state_root/workflow-runs/$run_id/run.json"
  [[ -f "$run_file" && ! -L "$run_file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  mode="$(jq -r '.mode // empty' "$run_file" 2>/dev/null || true)"
  case "$mode" in
    dependency)
      usage_root="$(jq -r '.engine.statePath // empty' "$run_file" 2>/dev/null || true)"
      usage_root="${usage_root:+$usage_root/logs}"
      ;;
    sequential)
      artifact_ns="$(jq -r '.artifactNamespace // empty' "$run_file" 2>/dev/null || true)"
      usage_root="${artifact_ns:+$state_root/logs/$artifact_ns}"
      ;;
    *) return 0 ;;
  esac
  [[ -n "$usage_root" && -d "$usage_root" ]] || return 0
  [[ -n "$(find "$usage_root" -type f -name plan-usage-summary.json -print -quit 2>/dev/null)" ]] || return 0

  report_state="$(jq -r '.state // "unknown"' "$run_file" 2>/dev/null || echo unknown)"
  if [[ "$report_state" == "running" ]]; then
    report_label="partial; workflow continues"
  else
    report_label="$report_state"
  fi
  printf '\nWorkflow session usage: %s (%s)\n' "$run_id" "$report_label"
  bash "$_WORKFLOW_USAGE_RALPH_DIR/usage-report.sh" \
    --workspace "$workspace" \
    --state-root "$state_root" \
    --run "$run_id" || true
}
