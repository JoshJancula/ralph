#!/usr/bin/env bash
# Start-time engine supervision and optional public viewer attach.
#
# After durable registry + immutable input + engine init, start either waits on
# the engine supervisor synchronously (non-TTY) or attaches the same public
# viewer used by `ralph workflow watch` while the supervisor runs in an
# isolated session. Viewer q/Ctrl-C never cancels the workflow; only
# `ralph workflow cancel` stops execution.
#
# Test seams:
#   RALPH_WORKFLOW_START_ASSUME_TTY=1       treat start as interactive TTY
#   RALPH_WORKFLOW_START_SKIP_SUPERVISOR=1  init only; do not run the engine
#   RALPH_WORKFLOW_START_SUPERVISOR_STUB    executable replacing the engine
#   RALPH_WORKFLOW_START_VIEWER_STUB        executable replacing the viewer

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_WORKFLOW_START_SUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WORKFLOW_START_RALPH_DIR="$(cd "$_WORKFLOW_START_SUP_DIR/../.." && pwd)"
# shellcheck source=./workflow-usage.sh
source "$_WORKFLOW_START_SUP_DIR/workflow-usage.sh"

# workflow_cli_start_should_attach_viewer
# True when start should attach the public viewer. Non-TTY stays synchronous.
workflow_cli_start_should_attach_viewer() {
  [[ "${RALPH_WORKFLOW_START_ASSUME_TTY:-0}" == "1" ]] && return 0
  [[ -t 0 && -t 1 ]]
}

# workflow_cli_start_print_reattach <run-id>
workflow_cli_start_print_reattach() {
  local run_id="${1:-}"
  [[ -n "$run_id" ]] || return 0
  printf 'Viewer detached; workflow continues under the recorded supervisor.\n' >&2
  printf 'Status: ralph workflow status %s\n' "$run_id" >&2
  printf 'Watch: ralph workflow watch %s\n' "$run_id" >&2
  printf 'Live logs: ralph workflow logs %s --stream combined --tail 200 --follow\n' "$run_id" >&2
  printf 'Agent logs: ralph workflow logs %s --stream agent --tail 200 --follow\n' "$run_id" >&2
  printf 'Actions: ralph workflow actions list %s\n' "$run_id" >&2
  printf "Artifacts: ralph workflow status %s --json | jq -r '.stages[] | .artifacts[]?'\n" "$run_id" >&2
  printf 'Usage: ralph usage --run %s\n' "$run_id" >&2
}

# workflow_cli_start_run_still_active <state-root> <run-id>
# True when the outer registry run is still marked running. Prefer the outer
# run.json state over diagnosis projection: early after dispatch the engine
# ledger can still say queued while the supervisor is live, and q-detach must
# not wait on that projection.
workflow_cli_start_run_still_active() {
  local state_root="${1:-}" run_id="${2:-}" outer state
  [[ -n "$state_root" && -n "$run_id" ]] || return 1
  if declare -F workflow_state_read >/dev/null 2>&1; then
    outer="$(workflow_state_read "$state_root" "$run_id" 2>/dev/null)" || return 1
    state="$(printf '%s' "$outer" | jq -r '.state // empty')"
    [[ "$state" == "running" ]]
    return $?
  fi
  return 1
}

# workflow_cli_start_project_outer_from_engine <mode> <state-root> <run-id>
# Best-effort projection of a finished supervisor onto the outer registry.
workflow_cli_start_project_outer_from_engine() {
  local mode="${1:-}" state_root="${2:-}" run_id="${3:-}"
  local run_dir outer_state graph_status public_state eng_state

  run_dir="$(workflow_state_run_dir "$state_root" "$run_id" 2>/dev/null)" || return 0
  if [[ "$mode" == "dependency" ]]; then
    local pointer graph_run
    pointer="$(workflow_dep_resolve_pointer "$state_root" "$run_id" 2>/dev/null)" || return 0
    graph_run="$(printf '%s' "$pointer" | jq -r '.statePath // empty')"
    [[ -n "$graph_run" && -f "$graph_run/run.json" ]] || return 0
    graph_status="$(jq -r '.status // empty' "$graph_run/run.json" 2>/dev/null || true)"
    [[ -n "$graph_status" && "$graph_status" != "running" ]] || return 0
    public_state="$(workflow_dep_map_run_status "$graph_status" 2>/dev/null || true)"
    [[ -n "$public_state" ]] || return 0
    workflow_state_clear_owner_and_set_state "$state_root" "$run_id" "$public_state" 2>/dev/null || true
    return 0
  fi

  if [[ -f "$run_dir/engine/run.json" ]]; then
    eng_state="$(jq -r '.state // empty' "$run_dir/engine/run.json" 2>/dev/null || true)"
    case "$eng_state" in
      succeeded|failed|cancelled|waiting|blocked)
        workflow_state_clear_owner_and_set_state "$state_root" "$run_id" "$eng_state" 2>/dev/null || true
        ;;
    esac
  fi
}

# workflow_cli_start_run_supervisor <mode> <state-root> <run-id> <workspace> <input-path>
# Foreground engine supervisor. Preserves exit 0/1/3.
workflow_cli_start_run_supervisor() {
  local mode="${1:-}" state_root="${2:-}" run_id="${3:-}" workspace="${4:-}" input_path="${5:-}"
  local run_dir rc=0 pointer namespace graph_run frozen_graph

  if [[ -n "${RALPH_WORKFLOW_START_SUPERVISOR_STUB:-}" ]]; then
    if [[ ! -x "${RALPH_WORKFLOW_START_SUPERVISOR_STUB}" && ! -f "${RALPH_WORKFLOW_START_SUPERVISOR_STUB}" ]]; then
      echo "Error: RALPH_WORKFLOW_START_SUPERVISOR_STUB is not executable: $RALPH_WORKFLOW_START_SUPERVISOR_STUB" >&2
      return 1
    fi
    bash "${RALPH_WORKFLOW_START_SUPERVISOR_STUB}" "$mode" "$run_id" "$state_root" "$workspace" "$input_path"
    return $?
  fi

  [[ -n "$mode" && -n "$state_root" && -n "$run_id" && -n "$workspace" && -n "$input_path" ]] || {
    echo "Error: workflow_cli_start_run_supervisor requires mode state-root run-id workspace input-path" >&2
    return 1
  }
  run_dir="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  export RALPH_WORKFLOW_RUN_ID="$run_id"
  export RALPH_WORKFLOW_REGISTRY_RUN="$run_dir"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  export RALPH_PROJECT_ROOT="${RALPH_PROJECT_ROOT:-$workspace}"
  export RALPH_AGENT_WORKSPACE="${RALPH_AGENT_WORKSPACE:-$workspace}"

  if [[ "$mode" == "sequential" ]]; then
    bash "$_WORKFLOW_START_RALPH_DIR/orchestrator.sh" \
      --orchestration "$input_path" \
      "$workspace" || rc=$?
    workflow_cli_start_project_outer_from_engine "$mode" "$state_root" "$run_id"
    return "$rc"
  fi

  if ! declare -F workflow_dep_resolve_pointer >/dev/null 2>&1; then
    # shellcheck source=./workflow-engine-dependency.sh
    source "$_WORKFLOW_START_SUP_DIR/workflow-engine-dependency.sh"
  fi
  if ! declare -F graph_schedule_run >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-schedule.sh
    source "$_WORKFLOW_START_SUP_DIR/../graph/graph-schedule.sh"
  fi

  pointer="$(workflow_dep_resolve_pointer "$state_root" "$run_id")" || return 1
  namespace="$(printf '%s' "$pointer" | jq -r '.namespace')"
  graph_run="$(printf '%s' "$pointer" | jq -r '.statePath')"
  frozen_graph="$graph_run/graph.json"
  [[ -f "$frozen_graph" ]] || {
    echo "Error: frozen graph missing for $run_id: $frozen_graph" >&2
    return 1
  }
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  _workflow_dep_ensure_graph_state_root "$state_root" "$namespace" "$run_id"

  # Foreground sync path only: viewer-attached starts isolate the supervisor in
  # a new session, so terminal Ctrl-C never reaches this process. Here we keep
  # the existing Dependency checkpoint/cancel policy for operator signals.
  _workflow_cli_start_dep_signal() {
    local signal="${1:-INT}"
    trap '' INT TERM HUP
    if [[ "$signal" == "TERM" || "$signal" == "HUP" ]]; then
      workflow_dep_operator_cancel "$RALPH_WORKFLOW_REGISTRY_RUN" "$state_root" || true
    fi
    if declare -F _graph_schedule_cancel_inflight_children >/dev/null 2>&1; then
      _graph_schedule_cancel_inflight_children || true
    fi
    if [[ "$signal" == "INT" ]]; then
      workflow_dep_operator_interrupt_checkpoint "$RALPH_WORKFLOW_REGISTRY_RUN" "$state_root" || true
    fi
    workflow_usage_print_run_report "$state_root" "$run_id" "$workspace" || true
    case "$signal" in
      INT) exit 130 ;;
      TERM) exit 143 ;;
      HUP) exit 129 ;;
      *) exit 1 ;;
    esac
  }
  trap '_workflow_cli_start_dep_signal INT' INT
  trap '_workflow_cli_start_dep_signal TERM' TERM
  trap '_workflow_cli_start_dep_signal HUP' HUP
  graph_schedule_run "$frozen_graph" "$run_id" "$workspace" "$graph_run" || rc=$?
  trap - INT TERM HUP
  workflow_cli_start_project_outer_from_engine "$mode" "$state_root" "$run_id"
  return "$rc"
}

# workflow_cli_start_launch_supervisor_session <mode> <state-root> <run-id>
#   <workspace> <input-path> <log-abs> <exit-file>
# Launch the supervisor in a new session so viewer Ctrl-C / parent exit cannot
# cancel it. Prints the session-leader pid on stdout.
workflow_cli_start_launch_supervisor_session() {
  local mode="$1" state_root="$2" run_id="$3" workspace="$4" input_path="$5"
  local log_abs="$6" exit_file="$7"
  local helper pid

  mkdir -p "$(dirname -- "$log_abs")" "$(dirname -- "$exit_file")" || return 1
  : >"$log_abs" || return 1

  helper="$(mktemp "${TMPDIR:-/tmp}/ralph-wf-start-sup.XXXXXX")" || return 1
  cat >"$helper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source $(printf '%q' "$_WORKFLOW_START_SUP_DIR/workflow-start-supervise.sh")
# Re-source engine libs the supervisor path needs when stub is unset.
if [[ -z "\${RALPH_WORKFLOW_START_SUPERVISOR_STUB:-}" ]]; then
  # shellcheck source=/dev/null
  source $(printf '%q' "$_WORKFLOW_START_SUP_DIR/workflow-state.sh")
  # shellcheck source=/dev/null
  source $(printf '%q' "$_WORKFLOW_START_SUP_DIR/workflow-engine-dependency.sh")
  # shellcheck source=/dev/null
  source $(printf '%q' "$_WORKFLOW_START_SUP_DIR/workflow-engine-sequential.sh")
fi
rc=0
workflow_cli_start_run_supervisor \\
  $(printf '%q' "$mode") \\
  $(printf '%q' "$state_root") \\
  $(printf '%q' "$run_id") \\
  $(printf '%q' "$workspace") \\
  $(printf '%q' "$input_path") || rc=\$?
printf '%s\\n' "\$rc" >$(printf '%q' "$exit_file")
exit "\$rc"
EOF
  chmod +x "$helper"

  # New session: Ctrl-C to the viewer process group never reaches the supervisor.
  # Prefer in-process os.setsid so the tracked pid is the session leader.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys
os.setsid()
os.execv("/bin/bash", ["bash", sys.argv[1]])
' "$helper" >>"$log_abs" 2>&1 &
    pid=$!
  elif command -v setsid >/dev/null 2>&1; then
    setsid bash "$helper" >>"$log_abs" 2>&1 &
    pid=$!
  else
    # Last resort: ignore terminal signals in a subshell (cancel still uses
    # recorded engine ownership / tree kill, not this wrapper's TERM ignore).
    (
      trap '' INT HUP
      bash "$helper"
    ) >>"$log_abs" 2>&1 &
    pid=$!
  fi

  # Drop the helper after launch; the child has already exec'd or opened it.
  # Keep the file until the child starts to avoid a race on slow hosts.
  ( sleep 1; rm -f "$helper" ) >/dev/null 2>&1 &

  printf '%s\n' "$pid"
}

# workflow_cli_start_attach_viewer <state-root> <run-id>
# Run the public viewer; returns its exit code (0, 130, or other).
workflow_cli_start_attach_viewer() {
  local state_root="${1:-}" run_id="${2:-}" rc=0
  if [[ -n "${RALPH_WORKFLOW_START_VIEWER_STUB:-}" ]]; then
    bash "${RALPH_WORKFLOW_START_VIEWER_STUB}" "$run_id" "$state_root" || rc=$?
    return "$rc"
  fi
  if ! declare -F workflow_operator_watch >/dev/null 2>&1; then
    # shellcheck source=./workflow-operator-view.sh
    source "$_WORKFLOW_START_SUP_DIR/workflow-operator-view.sh"
  fi
  workflow_operator_watch "$state_root" "$run_id" 0 || rc=$?
  return "$rc"
}

# workflow_cli_start_supervise_with_viewer <mode> <state-root> <run-id>
#   <workspace> <input-path>
# Background the engine supervisor in an isolated session, attach the public
# viewer, and map exits:
#   viewer idle through completion -> engine 0/1/3
#   q detach (viewer 0 while still running) -> 0 + reattach guidance
#   Ctrl-C (viewer 130) -> 130 + reattach guidance
#   viewer crash -> 0 + reattach guidance (supervisor keeps ownership)
workflow_cli_start_supervise_with_viewer() {
  local mode="${1:-}" state_root="${2:-}" run_id="${3:-}" workspace="${4:-}" input_path="${5:-}"
  local run_dir log_abs exit_file supervisor_pid=0 viewer_rc=0 engine_rc=0
  local start_detached=0

  run_dir="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  mkdir -p "$run_dir/logs" || return 1
  log_abs="$run_dir/logs/supervisor.log"
  exit_file="$run_dir/logs/supervisor.exit"

  supervisor_pid="$(workflow_cli_start_launch_supervisor_session \
    "$mode" "$state_root" "$run_id" "$workspace" "$input_path" \
    "$log_abs" "$exit_file")" || return 1
  printf '%s\n' "$supervisor_pid" >"$run_dir/logs/supervisor.pid"

  workflow_cli_start_viewer_on_signal() {
    start_detached=1
  }
  trap 'workflow_cli_start_viewer_on_signal' INT TERM
  workflow_cli_start_attach_viewer "$state_root" "$run_id" || viewer_rc=$?
  trap - INT TERM

  if [[ "$viewer_rc" -eq 130 || "$start_detached" -eq 1 ]]; then
    workflow_cli_start_print_reattach "$run_id"
    return 130
  fi

  if [[ "$viewer_rc" -ne 0 ]]; then
    printf 'Workflow viewer exited with status %s; the run continues under the recorded supervisor.\n' \
      "$viewer_rc" >&2
    workflow_cli_start_print_reattach "$run_id"
    return 0
  fi

  # viewer_rc == 0: q-detach while running, or idle (terminal / persisted wait).
  if workflow_cli_start_run_still_active "$state_root" "$run_id"; then
    workflow_cli_start_print_reattach "$run_id"
    return 0
  fi

  # Idle: wait for the supervisor to finish and preserve its exit.
  if kill -0 "$supervisor_pid" 2>/dev/null; then
    wait "$supervisor_pid" 2>/dev/null || true
  fi
  # Poll briefly for the exit file: the session leader may exit a moment
  # before the helper flushes supervisor.exit on a slow FS.
  local waited=0
  while [[ ! -f "$exit_file" && "$waited" -lt 50 ]]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if [[ -f "$exit_file" ]]; then
    engine_rc="$(tr -d '[:space:]' <"$exit_file" 2>/dev/null || echo 1)"
  else
    engine_rc=1
  fi
  [[ "$engine_rc" =~ ^[0-9]+$ ]] || engine_rc=1

  return "$engine_rc"
}

# workflow_cli_start_render_current_status <state-root> <run-id>
# Keep the authoritative current/terminal outcome at the bottom of start
# output. The detailed usage report can be many screens long, so rendering the
# status before it leaves the answer invisible when an operator returns later.
workflow_cli_start_render_current_status() {
  local state_root="${1:-}" run_id="${2:-}" status_json=""
  if ! declare -F workflow_operator_view_load >/dev/null 2>&1; then
    return 0
  fi
  if status_json="$(workflow_operator_view_load "$state_root" "$run_id" 2>/dev/null)"; then
    printf '\n' >&2
    workflow_operator_render_status "$status_json" stderr || true
  fi
}

# workflow_cli_start_after_dispatch <mode> <state-root> <run-id> <workspace> <input-path>
# Shared post-dispatch path for start: optional skip, TTY attach, or sync wait.
# Prints the start banner, then supervises. Returns the public start exit code.
workflow_cli_start_after_dispatch() {
  local mode="${1:-}" state_root="${2:-}" run_id="${3:-}" workspace="${4:-}" input_path="${5:-}"
  local entry_kind="${6:-}" task_text="${7:-}" task_provenance="${8:-}" workflow_id="${9:-}"
  local start_record rc=0

  if ! declare -F workflow_operator_render_start >/dev/null 2>&1; then
    # shellcheck source=./workflow-operator-view.sh
    source "$_WORKFLOW_START_SUP_DIR/workflow-operator-view.sh"
  fi

  start_record="$(jq -cn \
    --arg runId "$run_id" \
    --arg workflowId "${workflow_id:-}" \
    --arg mode "$mode" \
    --arg entryKind "${entry_kind:-}" \
    --arg task "${task_text:-}" \
    --arg taskProvenance "${task_provenance:-}" \
    '{runId:$runId, workflowId:(if $workflowId == "" then null else $workflowId end),
      mode:$mode, entryKind:$entryKind, task:$task, taskProvenance:$taskProvenance, state:"running"}')"
  printf '\n'
  workflow_operator_render_start "$start_record"

  # Init-only seams: registry + engine ledgers exist; no supervisor ownership.
  if [[ -n "${RALPH_WORKFLOW_START_ENGINE_STUB:-}" ]]; then
    return 0
  fi
  if [[ "${RALPH_WORKFLOW_START_SKIP_SUPERVISOR:-0}" == "1" ]]; then
    return 0
  fi

  if workflow_cli_start_should_attach_viewer; then
    workflow_cli_start_supervise_with_viewer \
      "$mode" "$state_root" "$run_id" "$workspace" "$input_path" || rc=$?
    workflow_usage_print_run_report "$state_root" "$run_id" "$workspace" || true
    workflow_cli_start_render_current_status "$state_root" "$run_id"
    return "$rc"
  fi

  workflow_cli_start_run_supervisor \
    "$mode" "$state_root" "$run_id" "$workspace" "$input_path" || rc=$?
  workflow_usage_print_run_report "$state_root" "$run_id" "$workspace" || true
  workflow_cli_start_render_current_status "$state_root" "$run_id"
  return "$rc"
}
