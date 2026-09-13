#!/usr/bin/env bash
# Sequential-mode engine ledger under <registry-run>/engine/.
#
# Persists run.json, events.jsonl, and stages/<id>.json matching
# workflow-sequential-{run,stage,event}.schema.json. Journals stage
# transitions before/after orchestrator stage execution without changing
# ordinary orchestration order or failure semantics.
#
# Does not invoke runtimes, models, or public CLI verbs.

if [[ -n "${RALPH_WORKFLOW_ENGINE_SEQUENTIAL_LOADED:-}" ]]; then
  return 0
fi
RALPH_WORKFLOW_ENGINE_SEQUENTIAL_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_WORKFLOW_SEQ_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F workflow_state_read >/dev/null 2>&1; then
  # shellcheck source=./workflow-state.sh
  source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-state.sh"
fi

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$_WORKFLOW_SEQ_SCRIPT_DIR/../atomic-json.sh"
fi

if ! declare -F graph_heartbeat_parse_iso_to_epoch >/dev/null 2>&1; then
  # shellcheck source=../graph/graph-heartbeat.sh
  source "$_WORKFLOW_SEQ_SCRIPT_DIR/../graph/graph-heartbeat.sh"
fi

if ! declare -F workflow_action_waiting_resume_class >/dev/null 2>&1; then
  # shellcheck source=./workflow-actions.sh
  source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-actions.sh"
fi

WORKFLOW_SEQ_PUBLIC_STATES=(
  queued running waiting blocked stale failed cancelled succeeded
)
WORKFLOW_SEQ_EVENT_SCHEMA_VERSION=1
# Heartbeat TTL for Sequential owner liveness (tests may override).
WORKFLOW_SEQ_OWNER_TTL_SECONDS="${WORKFLOW_SEQ_OWNER_TTL_SECONDS:-60}"

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

# workflow_seq_engine_dir <registry-run>
workflow_seq_engine_dir() {
  local registry_run="${1:-}"
  [[ -n "$registry_run" ]] || {
    echo "Error: workflow_seq_engine_dir requires registry-run" >&2
    return 1
  }
  case "$registry_run" in
    /*) ;;
    *)
      echo "Error: registry-run must be absolute: $registry_run" >&2
      return 1
      ;;
  esac
  printf '%s/engine\n' "${registry_run%/}"
}

# workflow_seq_run_file <registry-run>
workflow_seq_run_file() {
  local engine_dir
  engine_dir="$(workflow_seq_engine_dir "$1")" || return 1
  printf '%s/run.json\n' "$engine_dir"
}

# workflow_seq_events_file <registry-run>
workflow_seq_events_file() {
  local engine_dir
  engine_dir="$(workflow_seq_engine_dir "$1")" || return 1
  printf '%s/events.jsonl\n' "$engine_dir"
}

# workflow_seq_stages_dir <registry-run>
workflow_seq_stages_dir() {
  local engine_dir
  engine_dir="$(workflow_seq_engine_dir "$1")" || return 1
  printf '%s/stages\n' "$engine_dir"
}

# workflow_seq_stage_file <registry-run> <stage-id>
workflow_seq_stage_file() {
  local registry_run="$1" stage_id="$2" stages_dir
  [[ -n "$stage_id" ]] || {
    echo "Error: workflow_seq_stage_file requires stage-id" >&2
    return 1
  }
  stages_dir="$(workflow_seq_stages_dir "$registry_run")" || return 1
  printf '%s/%s.json\n' "$stages_dir" "$stage_id"
}

# workflow_seq_engine_active [registry-run]
# True when Sequential engine/run.json exists for the registry run.
workflow_seq_engine_active() {
  local registry_run="${1:-${RALPH_WORKFLOW_REGISTRY_RUN:-}}"
  local run_file
  [[ -n "$registry_run" ]] || return 1
  run_file="$(workflow_seq_run_file "$registry_run")" || return 1
  [[ -f "$run_file" && ! -L "$run_file" ]]
}

_workflow_seq_now_iso() {
  if [[ -n "${WORKFLOW_SEQ_FIXED_NOW:-${WORKFLOW_STATE_FIXED_NOW:-}}" ]]; then
    printf '%s\n' "${WORKFLOW_SEQ_FIXED_NOW:-$WORKFLOW_STATE_FIXED_NOW}"
    return 0
  fi
  graph_state_now_iso
}

_workflow_seq_file_sha256() {
  local path="$1"
  if declare -F _workflow_state_file_sha256 >/dev/null 2>&1; then
    _workflow_state_file_sha256 "$path"
    return $?
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

_workflow_seq_atomic_write_json() {
  local target_path="$1"; shift
  local jq_filter="$1"; shift
  if [[ "${WORKFLOW_STATE_SKIP_FSYNC:-0}" == "1" ]] || [[ "${WORKFLOW_SEQ_SKIP_FSYNC:-0}" == "1" ]]; then
    _workflow_state_atomic_write_json "$target_path" "$jq_filter" "$@"
    return $?
  fi
  ralph_atomic_write_json "$target_path" "$jq_filter" "$@"
}

_workflow_seq_null_owner_json() {
  jq -cn '{
    pid: null,
    hostname: null,
    processStartId: null,
    heartbeatAt: null
  }'
}

_workflow_seq_live_owner_json() {
  local pid hostname process_start_id heartbeat_at
  pid="$(graph_state_supervisor_pid)"
  hostname="$(graph_state_owner_hostname)"
  process_start_id="$(graph_state_owner_process_start_id)"
  heartbeat_at="$(graph_state_heartbeat_now)"
  jq -cn \
    --argjson pid "$( [[ "$pid" =~ ^[0-9]+$ ]] && printf '%s' "$pid" || printf 'null' )" \
    --arg hostname "$hostname" \
    --arg processStartId "$process_start_id" \
    --arg heartbeatAt "$heartbeat_at" \
    '{
      pid: $pid,
      hostname: (if $hostname == "" then null else $hostname end),
      processStartId: (if $processStartId == "" then null else $processStartId end),
      heartbeatAt: (if $heartbeatAt == "" then null else $heartbeatAt end)
    }'
}

# ---------------------------------------------------------------------------
# Transition matrix (public workflow states)
# ---------------------------------------------------------------------------

# workflow_seq_validate_stage_transition <from> <to>
# Empty from (first write) and same-state are always legal. Terminal
# succeeded/cancelled have no outgoing transition other than themselves.
workflow_seq_validate_stage_transition() {
  local from="${1:-}" to="${2:-}"
  [[ -n "$to" ]] || return 1
  [[ -z "$from" || "$from" == "$to" ]] && return 0
  case "$from" in
    queued)
      case "$to" in running|waiting|blocked|stale|cancelled|failed) return 0 ;; *) return 1 ;; esac
      ;;
    running)
      case "$to" in succeeded|failed|waiting|blocked|stale|cancelled) return 0 ;; *) return 1 ;; esac
      ;;
    waiting)
      case "$to" in running|queued|blocked|stale|cancelled|failed|succeeded) return 0 ;; *) return 1 ;; esac
      ;;
    blocked)
      case "$to" in queued|running|cancelled|stale) return 0 ;; *) return 1 ;; esac
      ;;
    stale)
      case "$to" in queued|running|cancelled|failed) return 0 ;; *) return 1 ;; esac
      ;;
    failed)
      case "$to" in queued|running|cancelled) return 0 ;; *) return 1 ;; esac
      ;;
    succeeded|cancelled)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# workflow_seq_validate_run_transition <from> <to>
# Same public enum matrix as stages.
workflow_seq_validate_run_transition() {
  workflow_seq_validate_stage_transition "$@"
}

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

# workflow_seq_append_event --registry-run ... --event ... --new-state ...
#   [--run-id ...] [--stage-id ...] [--prior-state ...] [--details-json ...]
workflow_seq_append_event() {
  local registry_run="" event="" new_state="" run_id="" stage_id="" prior_state=""
  local details_json="{}"
  local events_file seq now row tmp

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --event) event="${2:-}"; shift 2 ;;
      --new-state) new_state="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --stage-id) stage_id="${2:-}"; shift 2 ;;
      --prior-state) prior_state="${2:-}"; shift 2 ;;
      --details-json) details_json="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_seq_append_event argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$registry_run" || -z "$event" || -z "$new_state" ]]; then
    echo "Error: workflow_seq_append_event requires --registry-run --event --new-state" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  if ! printf '%s' "$details_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: --details-json must be a JSON object" >&2
    return 1
  fi

  events_file="$(workflow_seq_events_file "$registry_run")" || return 1
  mkdir -p "$(dirname -- "$events_file")" || return 1
  touch "$events_file" || return 1

  if [[ -z "$run_id" ]]; then
    run_id="${RALPH_WORKFLOW_RUN_ID:-}"
  fi
  if [[ -z "$run_id" ]]; then
    run_id="$(basename -- "$(dirname -- "$(workflow_seq_engine_dir "$registry_run")")")"
  fi

  seq=0
  if [[ -s "$events_file" ]]; then
    seq="$(awk 'NF { n++ } END { print n+0 }' "$events_file")"
  fi
  now="$(_workflow_seq_now_iso)"

  row="$(jq -cn \
    --argjson schemaVersion "$WORKFLOW_SEQ_EVENT_SCHEMA_VERSION" \
    --argjson sequence "$seq" \
    --arg timestamp "$now" \
    --arg runId "$run_id" \
    --arg stageId "$stage_id" \
    --arg event "$event" \
    --arg priorState "$prior_state" \
    --arg newState "$new_state" \
    --argjson details "$details_json" \
    '{
      schemaVersion: $schemaVersion,
      sequence: $sequence,
      timestamp: $timestamp,
      runId: $runId,
      stageId: (if $stageId == "" then null else $stageId end),
      event: $event,
      priorState: (if $priorState == "" then null else $priorState end),
      newState: $newState,
      details: $details
    }')" || return 1

  tmp="$(mktemp "${events_file}.XXXXXX")" || return 1
  if [[ -s "$events_file" ]]; then
    cat "$events_file" >"$tmp" || { rm -f "$tmp"; return 1; }
  fi
  printf '%s\n' "$row" >>"$tmp" || { rm -f "$tmp"; return 1; }
  if ! mv -f "$tmp" "$events_file"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# workflow_seq_engine_logs_dir <registry-run>
workflow_seq_engine_logs_dir() {
  local registry_run="$1"
  local engine_dir
  engine_dir="$(workflow_seq_engine_dir "$registry_run")" || return 1
  printf '%s/logs\n' "$engine_dir"
}

# workflow_seq_stage_log_rel <stage-id> <attempt-n> <public-stream>
# Prints relative path(s) under the engine directory.
workflow_seq_stage_log_rel() {
  local stage_id="$1" attempt_n="$2" public_stream="$3"
  if ! declare -F ralph_orchestrator_stage_log_rel >/dev/null 2>&1; then
    # shellcheck source=../orchestrator/orchestrator-logging.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/../orchestrator/orchestrator-logging.sh"
  fi
  if ! declare -F workflow_logs_validate_public_stream >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-logs.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/../graph/graph-logs.sh"
  fi
  workflow_logs_validate_public_stream "$public_stream" || return 1
  if ! [[ "$attempt_n" =~ ^[0-9]+$ ]]; then
    echo "Error: workflow logs --attempt must be a non-negative integer" >&2
    return 1
  fi
  case "$public_stream" in
    agent)
      ralph_orchestrator_stage_log_rel "$stage_id" "$attempt_n" agent
      ;;
    supervisor)
      ralph_orchestrator_stage_log_rel "$stage_id" "$attempt_n" runner
      ;;
    combined)
      ralph_orchestrator_stage_log_rel "$stage_id" "$attempt_n" runner
      ralph_orchestrator_stage_log_rel "$stage_id" "$attempt_n" agent
      ;;
  esac
}

# workflow_seq_supervisor_log_rel
workflow_seq_supervisor_log_rel() {
  if ! declare -F ralph_orchestrator_supervisor_log_rel >/dev/null 2>&1; then
    # shellcheck source=../orchestrator/orchestrator-logging.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/../orchestrator/orchestrator-logging.sh"
  fi
  ralph_orchestrator_supervisor_log_rel
}

# workflow_seq_stage_log_select <registry-run> <stage-id> <attempt-n> <public-stream>
# Prints absolute readable log file paths (newline-separated).
workflow_seq_stage_log_select() {
  local registry_run="$1" stage_id="$2" attempt_n="$3" public_stream="$4"
  local engine_dir rel abs
  engine_dir="$(workflow_seq_engine_dir "$registry_run")" || return 1
  while IFS= read -r rel || [[ -n "$rel" ]]; do
    [[ -n "$rel" ]] || continue
    abs="$engine_dir/$rel"
    if [[ -f "$abs" && ! -L "$abs" ]]; then
      printf '%s\n' "$abs"
    fi
  done < <(workflow_seq_stage_log_rel "$stage_id" "$attempt_n" "$public_stream")
}

# workflow_seq_stage_attempt_log_dir <registry-run> <stage-id> <attempt-n>
# Absolute contained directory for a stage attempt's runner/agent logs under
# engine/logs/stages/<stage>/attempt-<n>/.
workflow_seq_stage_attempt_log_dir() {
  local registry_run="$1" stage_id="$2" attempt_n="$3"
  local engine_dir rel
  engine_dir="$(workflow_seq_engine_dir "$registry_run")" || return 1
  if ! [[ "$attempt_n" =~ ^[1-9][0-9]*$|^0$ ]]; then
    echo "Error: sequential stage log attempt must be a non-negative integer" >&2
    return 1
  fi
  case "$stage_id" in
    ""|*/*|*\\*|*..*|*$'\n'*|*$'\r'*)
      echo "Error: sequential stage log stage-id is not a usable path component" >&2
      return 1
      ;;
  esac
  if ! declare -F ralph_orchestrator_stage_log_rel >/dev/null 2>&1; then
    # shellcheck source=../orchestrator/orchestrator-logging.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/../orchestrator/orchestrator-logging.sh"
  fi
  rel="$(ralph_orchestrator_stage_log_rel "$stage_id" "$attempt_n" agent)" || return 1
  printf '%s/%s\n' "$engine_dir" "$(dirname -- "$rel")"
}

# workflow_seq_prepare_stage_logs <registry-run> <stage-id> <attempt-n>
# Creates contained regular files for runner.log and agent.log. Prints the
# absolute attempt log directory. Does not follow symlinks or escape engine/.
workflow_seq_prepare_stage_logs() {
  local registry_run="$1" stage_id="$2" attempt_n="$3"
  local engine_dir log_dir runner agent prefix
  engine_dir="$(workflow_seq_engine_dir "$registry_run")" || return 1
  log_dir="$(workflow_seq_stage_attempt_log_dir "$registry_run" "$stage_id" "$attempt_n")" || return 1
  prefix="$engine_dir/logs/stages/"
  case "$log_dir" in
    "$prefix"*) ;;
    *)
      echo "Error: sequential stage log dir escapes engine logs/stages: $log_dir" >&2
      return 1
      ;;
  esac
  if [[ -L "$log_dir" || -L "$(dirname -- "$log_dir")" ]]; then
    echo "Error: sequential stage log path is a symlink: $log_dir" >&2
    return 1
  fi
  mkdir -p "$log_dir" || return 1
  runner="$log_dir/runner.log"
  agent="$log_dir/agent.log"
  if [[ -L "$runner" || -L "$agent" ]]; then
    echo "Error: sequential stage log file is a symlink under $log_dir" >&2
    return 1
  fi
  : >>"$runner" || return 1
  : >>"$agent" || return 1
  printf '%s\n' "$log_dir"
}

# workflow_seq_export_stage_log_dir <log-dir>
# Publish the Sequential attempt log directory so run-plan writes agent.log
# via RALPH_GRAPH_NODE_LOG_DIR (same contract Dependency uses under
# logs/nodes/) and orchestrator tees runner output to runner.log.
workflow_seq_export_stage_log_dir() {
  local log_dir="${1:-}"
  [[ -n "$log_dir" && -d "$log_dir" && ! -L "$log_dir" ]] || return 1
  export RALPH_SEQ_STAGE_LOG_DIR="$log_dir"
  export RALPH_GRAPH_NODE_LOG_DIR="$log_dir"
  export RALPH_GRAPH_NODE_LOG_PATH="$log_dir/runner.log"
  return 0
}

# workflow_seq_clear_stage_log_dir_exports
# Drop Sequential-owned log-dir exports after a stage attempt finishes.
workflow_seq_clear_stage_log_dir_exports() {
  if [[ -n "${RALPH_SEQ_STAGE_LOG_DIR:-}" ]]; then
    unset RALPH_SEQ_STAGE_LOG_DIR
    unset RALPH_GRAPH_NODE_LOG_DIR
    unset RALPH_GRAPH_NODE_LOG_PATH
  fi
  return 0
}

# workflow_seq_read_event_lines <registry-run>
workflow_seq_read_event_lines() {
  local registry_run="$1" events_file
  events_file="$(workflow_seq_events_file "$registry_run")" || return 1
  [[ -f "$events_file" && ! -L "$events_file" ]] || return 0
  cat "$events_file"
}

# workflow_seq_project_events <registry-run>
workflow_seq_project_events() {
  local registry_run="$1" line
  local -a rows=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || continue
    rows+=("$line")
  done < <(workflow_seq_read_event_lines "$registry_run")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "${rows[@]}" | jq -sc '.'
}

# ---------------------------------------------------------------------------
# Stage documents
# ---------------------------------------------------------------------------

# Build the null/zero seed object for inline, non-plan-backed, and approval stages.
_workflow_seq_seed_stage_json() {
  local stage_id="$1" index="$2" wave_json="${3:-null}" now="$4"
  jq -cn \
    --arg id "$stage_id" \
    --argjson index "$index" \
    --argjson wave "$wave_json" \
    --arg createdAt "$now" \
    --arg updatedAt "$now" \
    '{
      id: $id,
      index: $index,
      state: "queued",
      attempt: 0,
      planPath: null,
      planRunId: null,
      planSourceKind: null,
      planSourceStageId: null,
      originalPlanPath: null,
      sourcePlanPath: null,
      controlPlanPath: null,
      currentTodoId: null,
      wave: $wave,
      terminalResult: null,
      blocker: null,
      completedTodos: 0,
      totalTodos: 0,
      artifacts: [],
      createdAt: $createdAt,
      updatedAt: $updatedAt
    }'
}

# workflow_seq_read_stage <registry-run> <stage-id>
workflow_seq_read_stage() {
  local path
  path="$(workflow_seq_stage_file "$1" "$2")" || return 1
  [[ -f "$path" ]] || {
    echo "Error: sequential stage state missing: $path" >&2
    return 1
  }
  cat "$path"
}

# workflow_seq_read_run <registry-run>
workflow_seq_read_run() {
  local path
  path="$(workflow_seq_run_file "$1")" || return 1
  [[ -f "$path" ]] || {
    echo "Error: sequential engine run.json missing: $path" >&2
    return 1
  }
  cat "$path"
}

# workflow_seq_write_stage --registry-run ... --stage-id ... --state ...
#   [--attempt N] [--index N] [--wave N|null] [--plan-path ...] ...
#   [--artifacts-json ...] [--blocker-json ...] [--terminal-result ...]
#   [--event-name ...] [--details-json ...] [--skip-transition-check]
#
# Validates the stage transition (unless skipped), atomically rewrites the
# stage file, and appends a stage-state-changed event (or --event-name).
workflow_seq_write_stage() {
  local registry_run="" stage_id="" state=""
  local attempt="" index="" wave="__keep__"
  local plan_path="__keep__" plan_run_id="__keep__" plan_source_kind="__keep__"
  local plan_source_stage_id="__keep__" original_plan_path="__keep__"
  local source_plan_path="__keep__" control_plan_path="__keep__"
  local current_todo_id="__keep__" terminal_result="__keep__"
  local completed_todos="" total_todos=""
  local artifacts_json="__keep__" blocker_json="__keep__"
  local event_name="stage-state-changed" details_json="{}"
  local skip_transition_check=0
  local stage_file prior raw now prior_state

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --stage-id) stage_id="${2:-}"; shift 2 ;;
      --state) state="${2:-}"; shift 2 ;;
      --attempt) attempt="${2:-}"; shift 2 ;;
      --index) index="${2:-}"; shift 2 ;;
      --wave) wave="${2:-}"; shift 2 ;;
      --plan-path) plan_path="${2:-}"; shift 2 ;;
      --plan-run-id) plan_run_id="${2:-}"; shift 2 ;;
      --plan-source-kind) plan_source_kind="${2:-}"; shift 2 ;;
      --plan-source-stage-id) plan_source_stage_id="${2:-}"; shift 2 ;;
      --original-plan-path) original_plan_path="${2:-}"; shift 2 ;;
      --source-plan-path) source_plan_path="${2:-}"; shift 2 ;;
      --control-plan-path) control_plan_path="${2:-}"; shift 2 ;;
      --current-todo-id) current_todo_id="${2:-}"; shift 2 ;;
      --terminal-result) terminal_result="${2:-}"; shift 2 ;;
      --completed-todos) completed_todos="${2:-}"; shift 2 ;;
      --total-todos) total_todos="${2:-}"; shift 2 ;;
      --artifacts-json) artifacts_json="${2:-}"; shift 2 ;;
      --blocker-json) blocker_json="${2:-}"; shift 2 ;;
      --event-name) event_name="${2:-}"; shift 2 ;;
      --details-json) details_json="${2:-}"; shift 2 ;;
      --skip-transition-check) skip_transition_check=1; shift ;;
      *)
        echo "Error: unknown workflow_seq_write_stage argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$registry_run" || -z "$stage_id" || -z "$state" ]]; then
    echo "Error: workflow_seq_write_stage requires --registry-run --stage-id --state" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1

  stage_file="$(workflow_seq_stage_file "$registry_run" "$stage_id")" || return 1
  if [[ ! -f "$stage_file" ]]; then
    echo "Error: sequential stage file missing (init engine first): $stage_file" >&2
    return 1
  fi
  prior="$(cat "$stage_file")" || return 1
  prior_state="$(printf '%s' "$prior" | jq -r '.state // empty')"

  if [[ "$skip_transition_check" -ne 1 ]]; then
    if ! workflow_seq_validate_stage_transition "$prior_state" "$state"; then
      echo "Error: illegal sequential stage transition for $stage_id: ${prior_state:-<none>} -> $state" >&2
      return 1
    fi
  fi

  now="$(_workflow_seq_now_iso)"
  raw="$(printf '%s' "$prior" | jq -c \
    --arg state "$state" \
    --arg updatedAt "$now" \
    --arg attempt "$attempt" \
    --arg index "$index" \
    --arg wave "$wave" \
    --arg planPath "$plan_path" \
    --arg planRunId "$plan_run_id" \
    --arg planSourceKind "$plan_source_kind" \
    --arg planSourceStageId "$plan_source_stage_id" \
    --arg originalPlanPath "$original_plan_path" \
    --arg sourcePlanPath "$source_plan_path" \
    --arg controlPlanPath "$control_plan_path" \
    --arg currentTodoId "$current_todo_id" \
    --arg terminalResult "$terminal_result" \
    --arg completedTodos "$completed_todos" \
    --arg totalTodos "$total_todos" \
    --arg artifactsJson "$artifacts_json" \
    --arg blockerJson "$blocker_json" \
    '
    .state = $state
    | .updatedAt = $updatedAt
    | if $attempt != "" then .attempt = ($attempt | tonumber) else . end
    | if $index != "" then .index = ($index | tonumber) else . end
    | if $wave == "__keep__" then .
      elif $wave == "" or $wave == "null" then .wave = null
      else .wave = ($wave | tonumber) end
    | if $planPath == "__keep__" then .
      elif $planPath == "" or $planPath == "null" then .planPath = null
      else .planPath = $planPath end
    | if $planRunId == "__keep__" then .
      elif $planRunId == "" or $planRunId == "null" then .planRunId = null
      else .planRunId = $planRunId end
    | if $planSourceKind == "__keep__" then .
      elif $planSourceKind == "" or $planSourceKind == "null" then .planSourceKind = null
      else .planSourceKind = $planSourceKind end
    | if $planSourceStageId == "__keep__" then .
      elif $planSourceStageId == "" or $planSourceStageId == "null" then .planSourceStageId = null
      else .planSourceStageId = $planSourceStageId end
    | if $originalPlanPath == "__keep__" then .
      elif $originalPlanPath == "" or $originalPlanPath == "null" then .originalPlanPath = null
      else .originalPlanPath = $originalPlanPath end
    | if $sourcePlanPath == "__keep__" then .
      elif $sourcePlanPath == "" or $sourcePlanPath == "null" then .sourcePlanPath = null
      else .sourcePlanPath = $sourcePlanPath end
    | if $controlPlanPath == "__keep__" then .
      elif $controlPlanPath == "" or $controlPlanPath == "null" then .controlPlanPath = null
      else .controlPlanPath = $controlPlanPath end
    | if $currentTodoId == "__keep__" then .
      elif $currentTodoId == "" or $currentTodoId == "null" then .currentTodoId = null
      else .currentTodoId = $currentTodoId end
    | if $terminalResult == "__keep__" then .
      elif $terminalResult == "" or $terminalResult == "null" then .terminalResult = null
      else .terminalResult = $terminalResult end
    | if $completedTodos != "" then .completedTodos = ($completedTodos | tonumber) else . end
    | if $totalTodos != "" then .totalTodos = ($totalTodos | tonumber) else . end
    | if $artifactsJson == "__keep__" then .
      else .artifacts = ($artifactsJson | fromjson) end
    | if $blockerJson == "__keep__" then .
      elif $blockerJson == "" or $blockerJson == "null" then .blocker = null
      else .blocker = ($blockerJson | fromjson) end
    ')" || return 1

  _workflow_seq_atomic_write_json "$stage_file" '$doc' --argjson doc "$raw" || return 1

  workflow_seq_append_event \
    --registry-run "$registry_run" \
    --event "$event_name" \
    --new-state "$state" \
    --stage-id "$stage_id" \
    --prior-state "$prior_state" \
    --details-json "$details_json" || return 1
  return 0
}

# workflow_seq_update_run --registry-run ... [--state ...] [--current-stage-ids-json ...]
#   [--loop-iterations N] [--completed-waves N] [--owner-json ...] [--event-name ...]
#   [--details-json ...] [--skip-transition-check]
workflow_seq_update_run() {
  local registry_run="" state="" current_stage_ids_json="__keep__"
  local loop_iterations="" completed_waves="" owner_json="__keep__"
  local event_name="" details_json="{}"
  local skip_transition_check=0
  local run_file prior prior_state now raw

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --state) state="${2:-}"; shift 2 ;;
      --current-stage-ids-json) current_stage_ids_json="${2:-}"; shift 2 ;;
      --loop-iterations) loop_iterations="${2:-}"; shift 2 ;;
      --completed-waves) completed_waves="${2:-}"; shift 2 ;;
      --owner-json) owner_json="${2:-}"; shift 2 ;;
      --event-name) event_name="${2:-}"; shift 2 ;;
      --details-json) details_json="${2:-}"; shift 2 ;;
      --skip-transition-check) skip_transition_check=1; shift ;;
      *)
        echo "Error: unknown workflow_seq_update_run argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$registry_run" ]] || {
    echo "Error: workflow_seq_update_run requires --registry-run" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  run_file="$(workflow_seq_run_file "$registry_run")" || return 1
  prior="$(cat "$run_file")" || return 1
  prior_state="$(printf '%s' "$prior" | jq -r '.state // empty')"

  if [[ -n "$state" && "$skip_transition_check" -ne 1 ]]; then
    if ! workflow_seq_validate_run_transition "$prior_state" "$state"; then
      echo "Error: illegal sequential run transition: ${prior_state:-<none>} -> $state" >&2
      return 1
    fi
  fi

  now="$(_workflow_seq_now_iso)"
  raw="$(printf '%s' "$prior" | jq -c \
    --arg state "$state" \
    --arg updatedAt "$now" \
    --arg currentIds "$current_stage_ids_json" \
    --arg loopIterations "$loop_iterations" \
    --arg completedWaves "$completed_waves" \
    --arg ownerJson "$owner_json" \
    '
    .updatedAt = $updatedAt
    | if $state != "" then .state = $state else . end
    | if $currentIds == "__keep__" then .
      else .currentStageIds = ($currentIds | fromjson) end
    | if $loopIterations != "" then .loopIterations = ($loopIterations | tonumber) else . end
    | if $completedWaves != "" then .completedWaves = ($completedWaves | tonumber) else . end
    | if $ownerJson == "__keep__" then .
      elif $ownerJson == "" or $ownerJson == "null" then .owner = null
      else .owner = ($ownerJson | fromjson) end
    ')" || return 1

  _workflow_seq_atomic_write_json "$run_file" '$doc' --argjson doc "$raw" || return 1

  if [[ -n "$event_name" && -n "$state" ]]; then
    workflow_seq_append_event \
      --registry-run "$registry_run" \
      --event "$event_name" \
      --new-state "$state" \
      --prior-state "$prior_state" \
      --details-json "$details_json" || return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Init
# ---------------------------------------------------------------------------

# Resolve wave index for a stage id from an orch JSON file, or print null.
_workflow_seq_wave_for_stage() {
  local orch_file="$1" stage_id="$2"
  [[ -f "$orch_file" ]] || {
    printf 'null\n'
    return 0
  }
  jq -r --arg id "$stage_id" '
    (.parallelStages // []) as $waves
    | if ($waves | length) == 0 then "null"
      else
        (reduce range(0; $waves | length) as $i
          ({found: null};
            if .found != null then .
            else
              (($waves[$i] | if type == "string" then split(",") else . end)
                | map(gsub("^\\s+|\\s+$";""))
                | index($id)) as $pos
              | if $pos != null then .found = $i else . end
            end)
          | if .found == null then "null" else (.found | tostring) end)
      end
  ' "$orch_file"
}

# workflow_seq_init_engine --registry-run ... --input-file ...
#   [--run-id ...] [--owner-json ...] [--state queued]
#
# Creates engine/{run.json,events.jsonl,stages/<id>.json}. Stage seeds use
# exact null/zero plan-progress fields (inline / non-plan-backed / approval).
workflow_seq_init_engine() {
  local registry_run="" input_file="" run_id="" owner_json="" state="queued"
  local engine_dir stages_dir run_file events_file
  local input_sha now stage_count i stage_id wave_json seed owner_eff

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --input-file) input_file="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --owner-json) owner_json="${2:-}"; shift 2 ;;
      --state) state="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_seq_init_engine argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$registry_run" || -z "$input_file" ]]; then
    echo "Error: workflow_seq_init_engine requires --registry-run --input-file" >&2
    return 1
  fi
  [[ -f "$input_file" && ! -L "$input_file" ]] || {
    echo "Error: input file must be a regular non-symlink file: $input_file" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  if [[ -z "$run_id" ]]; then
    run_id="${RALPH_WORKFLOW_RUN_ID:-$(basename -- "$registry_run")}"
  fi
  if [[ -z "$owner_json" ]]; then
    owner_json="$(_workflow_seq_null_owner_json)"
  fi

  engine_dir="$(workflow_seq_engine_dir "$registry_run")" || return 1
  stages_dir="$(workflow_seq_stages_dir "$registry_run")" || return 1
  run_file="$(workflow_seq_run_file "$registry_run")" || return 1
  events_file="$(workflow_seq_events_file "$registry_run")" || return 1

  if [[ -e "$run_file" ]]; then
    echo "Error: sequential engine already initialized: $run_file" >&2
    return 1
  fi

  mkdir -p "$engine_dir" "$stages_dir" || return 1
  input_sha="$(_workflow_seq_file_sha256 "$input_file")" || return 1
  now="$(_workflow_seq_now_iso)"

  _workflow_seq_atomic_write_json "$run_file" \
    '{
      inputSha256: $sha,
      state: $state,
      currentStageIds: [],
      loopIterations: 0,
      completedWaves: 0,
      owner: $owner,
      createdAt: $createdAt,
      updatedAt: $updatedAt
    }' \
    --arg sha "$input_sha" \
    --arg state "$state" \
    --argjson owner "$owner_json" \
    --arg createdAt "$now" \
    --arg updatedAt "$now" || return 1

  : >"$events_file" || return 1

  stage_count="$(jq '.stages | length' "$input_file" 2>/dev/null || echo 0)"
  [[ "$stage_count" =~ ^[0-9]+$ ]] || stage_count=0
  i=0
  while [[ "$i" -lt "$stage_count" ]]; do
    stage_id="$(jq -r ".stages[$i].id // empty" "$input_file")"
    if [[ -z "$stage_id" ]]; then
      echo "Error: orchestration stage at index $i missing id" >&2
      return 1
    fi
    wave_json="$(_workflow_seq_wave_for_stage "$input_file" "$stage_id")"
    seed="$(_workflow_seq_seed_stage_json "$stage_id" "$i" "$wave_json" "$now")" || return 1
    _workflow_seq_atomic_write_json "$(workflow_seq_stage_file "$registry_run" "$stage_id")" \
      '$doc' --argjson doc "$seed" || return 1
    i=$((i + 1))
  done

  workflow_seq_append_event \
    --registry-run "$registry_run" \
    --run-id "$run_id" \
    --event "run-created" \
    --new-state "$state" \
    --prior-state "" \
    --details-json "$(jq -cn --arg sha "$input_sha" '{inputSha256:$sha}')" || return 1

  printf '%s\n' "$engine_dir"
}

# ---------------------------------------------------------------------------
# Orchestrator journal hooks (before / after existing stage execution)
# ---------------------------------------------------------------------------

# Resolve stage type label for event details only (not stored on stage JSON).
_workflow_seq_stage_type_label() {
  local stage_json="${1:-}"
  local t
  t="$(printf '%s' "$stage_json" | jq -r '.type // empty' 2>/dev/null)" || t=""
  if [[ -n "$t" ]]; then
    printf '%s\n' "$t"
    return 0
  fi
  if printf '%s' "$stage_json" | jq -e '.planner | type == "object"' >/dev/null 2>&1; then
    printf 'planner\n'
    return 0
  fi
  if printf '%s' "$stage_json" | jq -e '(.planFrom // "") != ""' >/dev/null 2>&1; then
    printf 'plan-from\n'
    return 0
  fi
  if printf '%s' "$stage_json" | jq -e '(.plan // .planFile // "") != ""' >/dev/null 2>&1; then
    printf 'plan-file\n'
    return 0
  fi
  printf 'inline\n'
}

# workflow_seq_journal_stage_before <registry-run> <stage-id> <stage-index>
#   <stage-json> <loop-iter> [wave]
#
# Marks the stage running, updates run currentStageIds / loopIterations / owner,
# and appends before-stage events. No-op when the Sequential engine is inactive.
workflow_seq_journal_stage_before() {
  local registry_run="${1:-}" stage_id="${2:-}" stage_index="${3:-0}"
  local stage_json="${4:-}" loop_iter="${5:-0}" wave="${6:-}"
  local details attempt owner_json current_ids wave_arg stage_type

  [[ -n "$registry_run" && -n "$stage_id" ]] || return 0
  workflow_seq_engine_active "$registry_run" || return 0

  stage_type="$(_workflow_seq_stage_type_label "$stage_json")"
  attempt="$(workflow_seq_read_stage "$registry_run" "$stage_id" | jq -r '.attempt // 0')"
  attempt=$((attempt + 1))
  owner_json="$(_workflow_seq_live_owner_json)"
  current_ids="$(jq -cn --arg id "$stage_id" '[$id]')"
  details="$(jq -cn \
    --arg type "$stage_type" \
    --argjson index "${stage_index:-0}" \
    --argjson loopIteration "${loop_iter:-0}" \
    --argjson attempt "$attempt" \
    '{stageType:$type,index:$index,loopIteration:$loopIteration,attempt:$attempt,phase:"before"}')"

  wave_arg=()
  if [[ -n "$wave" && "$wave" != "null" ]]; then
    wave_arg=(--wave "$wave")
  fi

  workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id "$stage_id" \
    --state running \
    --attempt "$attempt" \
    --index "${stage_index:-0}" \
    "${wave_arg[@]}" \
    --terminal-result null \
    --event-name stage-started \
    --details-json "$details" || return 1

  workflow_seq_update_run \
    --registry-run "$registry_run" \
    --state running \
    --current-stage-ids-json "$current_ids" \
    --loop-iterations "${loop_iter:-0}" \
    --owner-json "$owner_json" \
    --event-name run-status-changed \
    --details-json "$(jq -cn --arg id "$stage_id" '{reason:"stage-started",stageId:$id}')" || return 1

  # Publish common run/stage/attempt identity for OPERATOR_INPUT capability binding.
  local run_id
  run_id="$(jq -r '.runId // empty' "$registry_run/run.json" 2>/dev/null || true)"
  export RALPH_WORKFLOW_REGISTRY_RUN="$registry_run"
  [[ -n "$run_id" ]] && export RALPH_WORKFLOW_RUN_ID="$run_id"
  export RALPH_WORKFLOW_STAGE_ID="$stage_id"
  export RALPH_WORKFLOW_STAGE_ATTEMPT="${stage_id}-${attempt}"

  # Contained public logs: engine/logs/stages/<stage>/attempt-<n>/{runner,agent}.log
  # Mirror Dependency's RALPH_GRAPH_NODE_LOG_DIR handoff so run-plan writes
  # agent.log here and orchestrator can tee runner output to runner.log.
  local log_dir=""
  if log_dir="$(workflow_seq_prepare_stage_logs "$registry_run" "$stage_id" "$attempt")"; then
    workflow_seq_export_stage_log_dir "$log_dir" || true
  else
    echo "Warning: sequential stage log prepare failed for $stage_id attempt $attempt" >&2
  fi
  return 0
}

# workflow_seq_journal_stage_after <registry-run> <stage-id> <exit-code>
#   [stage-json] [artifacts-json]
#
# Records terminal succeeded/failed (or waiting on exit 3) without altering
# the caller's exit code. No-op when the Sequential engine is inactive.
workflow_seq_journal_stage_after() {
  local registry_run="${1:-}" stage_id="${2:-}" exit_code="${3:-1}"
  local stage_json="${4:-}" artifacts_json="${5:-}"
  local new_state terminal details stage_type owner_json art_args=()

  [[ -n "$registry_run" && -n "$stage_id" ]] || return 0
  workflow_seq_engine_active "$registry_run" || return 0

  case "$exit_code" in
    0)
      new_state="succeeded"
      terminal="succeeded"
      ;;
    3)
      new_state="waiting"
      terminal=""
      ;;
    *)
      new_state="failed"
      terminal="failed"
      ;;
  esac

  stage_type="$(_workflow_seq_stage_type_label "$stage_json")"
  details="$(jq -cn \
    --arg type "$stage_type" \
    --argjson exitCode "${exit_code:-1}" \
    --arg phase after \
    '{stageType:$type,exitCode:$exitCode,phase:$phase}')"

  if [[ -n "$artifacts_json" ]]; then
    art_args=(--artifacts-json "$artifacts_json")
  fi

  if [[ -n "$terminal" ]]; then
    workflow_seq_write_stage \
      --registry-run "$registry_run" \
      --stage-id "$stage_id" \
      --state "$new_state" \
      --terminal-result "$terminal" \
      "${art_args[@]}" \
      --event-name stage-finished \
      --details-json "$details" || return 1
  else
    local blocker_args=()
    if [[ "$exit_code" -eq 3 && -n "${RALPH_WORKFLOW_STAGE_BLOCKER_JSON:-}" ]]; then
      blocker_args=(--blocker-json "$RALPH_WORKFLOW_STAGE_BLOCKER_JSON")
    fi
    workflow_seq_write_stage \
      --registry-run "$registry_run" \
      --stage-id "$stage_id" \
      --state "$new_state" \
      --terminal-result null \
      "${blocker_args[@]}" \
      "${art_args[@]}" \
      --event-name stage-finished \
      --details-json "$details" || return 1
    if [[ "$exit_code" -eq 3 ]]; then
      local run_id attempt
      run_id="$(jq -r '.runId // empty' "$registry_run/run.json" 2>/dev/null || true)"
      attempt="$(workflow_seq_read_stage "$registry_run" "$stage_id" 2>/dev/null | jq -r '.attempt // empty')"
      if [[ -n "$run_id" && -n "$attempt" ]] \
        && declare -F workflow_action_revoke_attempt_capability >/dev/null 2>&1; then
        workflow_action_revoke_attempt_capability "$registry_run" "$run_id" "$stage_id" \
          "${stage_id}-${attempt}" 2>/dev/null || true
        workflow_action_revoke_attempt_capability "$registry_run" "$run_id" "$stage_id" \
          "$attempt" 2>/dev/null || true
      fi
    fi
  fi

  owner_json="$(_workflow_seq_null_owner_json)"
  # A succeeded stage leaves the run running so later stages can proceed.
  # Failure or waiting (exit 3) updates the outer engine run state.
  case "$new_state" in
    succeeded)
      workflow_seq_update_run \
        --registry-run "$registry_run" \
        --current-stage-ids-json '[]' \
        --owner-json "$owner_json" \
        --event-name run-status-changed \
        --details-json "$(jq -cn --arg id "$stage_id" --arg st "$new_state" '{reason:"stage-finished",stageId:$id,stageState:$st}')" || return 1
      ;;
    *)
      workflow_seq_update_run \
        --registry-run "$registry_run" \
        --state "$new_state" \
        --current-stage-ids-json '[]' \
        --owner-json "$owner_json" \
        --event-name run-status-changed \
        --details-json "$(jq -cn --arg id "$stage_id" --arg st "$new_state" '{reason:"stage-finished",stageId:$id,stageState:$st}')" || return 1
      ;;
  esac
  workflow_seq_clear_stage_log_dir_exports
  return 0
}

# Soft wrapper used by orchestrator.sh: never changes stage failure semantics.
# Returns 0 even when journaling fails (logged to stderr); callers ignore status.
workflow_seq_orch_journal_before() {
  workflow_seq_journal_stage_before "$@" || {
    echo "Warning: sequential engine before-stage journal failed (continuing stage)" >&2
    return 0
  }
  return 0
}

workflow_seq_orch_journal_after() {
  workflow_seq_journal_stage_after "$@" || {
    echo "Warning: sequential engine after-stage journal failed (preserving stage result)" >&2
    workflow_seq_clear_stage_log_dir_exports
    return 0
  }
  return 0
}

# workflow_seq_operator_interrupt_checkpoint <registry-run> [resume-argv-json]
# Finalize an operator SIGINT after child teardown. The control plan and stage
# attempt are treated as the checkpoint; no source or audit record is removed.
workflow_seq_operator_interrupt_checkpoint() {
  local registry_run="${1:-}" resume_argv="${2:-}" state_root run_id outer engine current_ids
  local stage_id stage_json blocker current_state attempt attempt_id details
  [[ -n "$registry_run" && -d "$registry_run" ]] || return 1
  workflow_seq_engine_active "$registry_run" || return 0
  run_id="$(workflow_seq_read_outer_run "$registry_run" | jq -r '.runId // empty')" || return 1
  state_root="$(cd "$(dirname "$(dirname "$registry_run")")" && pwd -P)" || return 1
  engine="$(workflow_seq_read_run "$registry_run")" || return 1
  current_ids="$(printf '%s' "$engine" | jq -c '.currentStageIds // []')"
  stage_id="$(printf '%s' "$current_ids" | jq -r '.[0] // empty')"
  if [[ -n "$stage_id" ]]; then
    stage_json="$(workflow_seq_read_stage "$registry_run" "$stage_id")" || stage_json=""
    current_state="$(printf '%s' "$stage_json" | jq -r '.state // empty')"
    blocker="$(printf '%s' "$stage_json" | jq -c '.blocker // null')"
    # A durably published action owns this wait. Do not replace it.
    if [[ "$current_state" == "waiting" && "$blocker" != "null" && \
      -n "$(printf '%s' "$blocker" | jq -r '.requestId // empty')" ]]; then
      workflow_state_clear_owner_and_set_state "$state_root" "$run_id" waiting || true
      return 0
    fi
    attempt="$(printf '%s' "$stage_json" | jq -r '.attempt // 0')"
    details="$(jq -cn --arg reason operator-request --argjson attempt "$attempt" \
      '{reason:$reason,attempt:$attempt,phase:"operator-interrupted"}')"
    workflow_seq_write_stage --registry-run "$registry_run" --stage-id "$stage_id" \
      --state waiting --terminal-result null --blocker-json null \
      --event-name operator-interrupted --details-json "$details" || return 1
  fi
  [[ -n "$resume_argv" ]] || resume_argv="$(jq -cn --arg id "$run_id" '["ralph","workflow","resume",$id]')"
  workflow_seq_update_run --registry-run "$registry_run" --state waiting \
    --current-stage-ids-json "$current_ids" \
    --owner-json "$(_workflow_seq_null_owner_json)" \
    --event-name operator-interrupted \
    --details-json "$(jq -cn --argjson argv "$resume_argv" \
      '{reason:"operator-request",retryable:true,nextAction:{label:"Resume workflow",argv:$argv}}')" || return 1
  workflow_state_clear_owner_and_set_state "$state_root" "$run_id" waiting || return 1
  if declare -F workflow_action_revoke_attempt_capability >/dev/null 2>&1 && [[ -n "$stage_id" ]]; then
    # Capabilities are keyed by the canonical attempt id, not the attempt number.
    attempt_id="${stage_id}__${run_id}__${attempt}"
    workflow_action_revoke_attempt_capability "$registry_run" "$run_id" "$stage_id" "$attempt_id" || true
  fi
  workflow_state_write_diagnosis "$registry_run" "$(jq -cn \
    --argjson argv "$resume_argv" --arg runId "$run_id" --arg stageId "$stage_id" \
    '{state:"waiting",reasonCode:"operator-request",summary:"Workflow interrupted by operator",stageId:(if $stageId=="" then null else $stageId end),evidence:[],retryable:true,nextAction:{label:"Resume workflow",argv:$argv},runId:$runId}')" >/dev/null || true
}

workflow_seq_operator_cancel() {
  local registry_run="${1:-}" state_root run_id engine current_ids stage_id stage_json attempt attempt_id
  [[ -n "$registry_run" && -d "$registry_run" ]] || return 1
  workflow_seq_engine_active "$registry_run" || return 0
  run_id="$(workflow_seq_read_outer_run "$registry_run" | jq -r '.runId // empty')"
  state_root="$(cd "$(dirname "$(dirname "$registry_run")")" && pwd -P)"
  engine="$(workflow_seq_read_run "$registry_run")"
  current_ids="$(printf '%s' "$engine" | jq -c '.currentStageIds // []')"
  stage_id="$(printf '%s' "$current_ids" | jq -r '.[0] // empty')"
  attempt=""
  if [[ -n "$stage_id" ]]; then
    stage_json="$(workflow_seq_read_stage "$registry_run" "$stage_id" 2>/dev/null || true)"
    attempt="$(printf '%s' "$stage_json" | jq -r '.attempt // empty')"
  fi
  workflow_state_record_cancel_intent "$registry_run" "$(jq -cn --arg runId "$run_id" \
    '{runId:$runId,source:"operator-signal"}')" >/dev/null || true
  workflow_action_cancel_outstanding "$registry_run" "$run_id" || true
  if [[ -n "$stage_id" && -n "$attempt" ]]; then
    attempt_id="${stage_id}__${run_id}__${attempt}"
    workflow_action_revoke_attempt_capability "$registry_run" "$run_id" "$stage_id" "$attempt_id" || true
  fi
  workflow_seq_update_run --registry-run "$registry_run" --state cancelled \
    --current-stage-ids-json '[]' --owner-json "$(_workflow_seq_null_owner_json)" \
    --event-name operator-interrupted --details-json '{"reason":"cancelled","source":"operator-signal"}' \
    --skip-transition-check || true
  workflow_state_clear_owner_and_set_state "$state_root" "$run_id" cancelled || true
}

# ---------------------------------------------------------------------------
# Resume (internal, by common registry run)
# ---------------------------------------------------------------------------

# workflow_seq_classify_owner_json <owner-json> [ttl_seconds] [now_epoch]
# Prints: absent | healthy | stale | unknown
# Delegates to the shared workflow-state classifier (PID + process-start + TTL).
workflow_seq_classify_owner_json() {
  if ! declare -F workflow_state_classify_owner_json >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-state.sh"
  fi
  workflow_state_classify_owner_json "$@"
}

# workflow_seq_live_owner_matches <owner-json> [expected-hostname]
# Cancel strengthening check. Prints owned|foreign|not-live.
workflow_seq_live_owner_matches() {
  if ! declare -F workflow_state_live_owner_matches >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-state.sh"
  fi
  workflow_state_live_owner_matches "$@"
}

# workflow_seq_read_outer_run <registry-run>
# Reads the common registry run.json beside engine/ (best-effort).
workflow_seq_read_outer_run() {
  local registry_run="${1:-}" outer_file
  [[ -n "$registry_run" ]] || return 1
  outer_file="${registry_run%/}/run.json"
  if [[ -f "$outer_file" && ! -L "$outer_file" ]]; then
    jq -c '.' "$outer_file" 2>/dev/null
    return $?
  fi
  return 1
}

# workflow_seq_validate_immutable_hashes <registry-run>
# Validates engine inputSha256 against the frozen input file, and when the
# outer run has inputPlan metadata, validates the provided frozen source hash.
# Prints a JSON object {ok,inputSha256,providedSha256,errors[]} on stdout.
# Returns 0 when ok, 1 when any hash fails.
workflow_seq_validate_immutable_hashes() {
  local registry_run="${1:-}"
  local engine_run outer input_path expected_sha actual_sha
  local provided_source expected_provided actual_provided
  local errors='[]' ok=1

  [[ -n "$registry_run" ]] || {
    echo "Error: workflow_seq_validate_immutable_hashes requires registry-run" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1
  workflow_seq_engine_active "$registry_run" || {
    echo "Error: sequential engine not active: $registry_run" >&2
    return 1
  }

  engine_run="$(workflow_seq_read_run "$registry_run")" || return 1
  expected_sha="$(printf '%s' "$engine_run" | jq -r '.inputSha256 // empty')"
  outer="$(workflow_seq_read_outer_run "$registry_run" 2>/dev/null)" || outer=""
  input_path=""
  if [[ -n "$outer" ]]; then
    input_path="$(printf '%s' "$outer" | jq -r '.inputPath // empty')"
  fi
  if [[ -z "$input_path" && -f "$registry_run/input.orch.json" ]]; then
    input_path="$registry_run/input.orch.json"
  fi
  if [[ -z "$input_path" || ! -f "$input_path" ]]; then
    errors="$(jq -cn --argjson e "$errors" '$e + ["missing input file for hash check"]')"
    ok=0
  else
    actual_sha="$(_workflow_seq_file_sha256 "$input_path")" || actual_sha=""
    if [[ -z "$expected_sha" || "$actual_sha" != "$expected_sha" ]]; then
      errors="$(jq -cn --argjson e "$errors" --arg exp "$expected_sha" --arg act "$actual_sha" \
        '$e + ["input hash mismatch: expected=\($exp) actual=\($act)"]')"
      ok=0
    fi
  fi

  expected_provided=""
  actual_provided=""
  if [[ -n "$outer" ]]; then
    provided_source="$(printf '%s' "$outer" | jq -r '.inputPlan.sourcePath // empty')"
    expected_provided="$(printf '%s' "$outer" | jq -r '.inputPlan.sha256 // empty')"
    if [[ -n "$provided_source" && -n "$expected_provided" ]]; then
      if [[ ! -f "$provided_source" ]]; then
        errors="$(jq -cn --argjson e "$errors" '$e + ["provided plan source missing"]')"
        ok=0
      else
        actual_provided="$(_workflow_seq_file_sha256 "$provided_source")" || actual_provided=""
        if [[ "$actual_provided" != "$expected_provided" ]]; then
          errors="$(jq -cn --argjson e "$errors" --arg exp "$expected_provided" --arg act "$actual_provided" \
            '$e + ["provided hash mismatch: expected=\($exp) actual=\($act)"]')"
          ok=0
        fi
      fi
    fi
  fi

  jq -cn \
    --argjson ok "$ok" \
    --arg inputSha256 "${expected_sha}" \
    --arg actualInputSha256 "${actual_sha:-}" \
    --arg providedSha256 "${expected_provided}" \
    --arg actualProvidedSha256 "${actual_provided}" \
    --argjson errors "$errors" \
    '{
      ok: ($ok == 1),
      inputSha256: $inputSha256,
      actualInputSha256: (if $actualInputSha256 == "" then null else $actualInputSha256 end),
      providedSha256: (if $providedSha256 == "" then null else $providedSha256 end),
      actualProvidedSha256: (if $actualProvidedSha256 == "" then null else $actualProvidedSha256 end),
      errors: $errors
    }'
  [[ "$ok" -eq 1 ]]
}

# workflow_seq_list_stage_ids <registry-run>
# Prints stage ids in index order.
workflow_seq_list_stage_ids() {
  local registry_run="${1:-}" stages_dir
  stages_dir="$(workflow_seq_stages_dir "$registry_run")" || return 1
  [[ -d "$stages_dir" ]] || return 0
  # shellcheck disable=SC2012
  ls -1 "$stages_dir"/*.json 2>/dev/null \
    | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        jq -r '[.index // 0, .id] | @tsv' "$f"
      done \
    | sort -n -k1,1 \
    | cut -f2
}

# workflow_seq_prerequisites_satisfied <registry-run> <stage-id>
# True when every lower-index stage is succeeded (Sequential order contract).
workflow_seq_prerequisites_satisfied() {
  local registry_run="${1:-}" stage_id="${2:-}"
  local target_index id stage_json state idx

  [[ -n "$registry_run" && -n "$stage_id" ]] || return 1
  target_index="$(workflow_seq_read_stage "$registry_run" "$stage_id" | jq -r '.index // 0')" || return 1

  while IFS= read -r id || [[ -n "$id" ]]; do
    [[ -z "$id" || "$id" == "$stage_id" ]] && continue
    stage_json="$(workflow_seq_read_stage "$registry_run" "$id")" || return 1
    idx="$(printf '%s' "$stage_json" | jq -r '.index // 0')"
    if [[ "$idx" -lt "$target_index" ]]; then
      state="$(printf '%s' "$stage_json" | jq -r '.state // empty')"
      if [[ "$state" != "succeeded" ]]; then
        return 1
      fi
    fi
  done < <(workflow_seq_list_stage_ids "$registry_run")
  return 0
}

# workflow_seq_recheck_stage_artifacts <registry-run> <stage-id> [--workspace PATH]
# Rechecks non-empty required artifacts recorded on the stage document and/or
# declared on the frozen input orch JSON. Returns 0 when all present/non-empty.
workflow_seq_recheck_stage_artifacts() {
  local registry_run="" stage_id="" workspace=""
  local stage_json art abs input_path orch_stage missing=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --stage-id) stage_id="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      *)
        if [[ -z "$registry_run" ]]; then
          registry_run="$1"; shift
        elif [[ -z "$stage_id" ]]; then
          stage_id="$1"; shift
        else
          echo "Error: unknown workflow_seq_recheck_stage_artifacts argument: $1" >&2
          return 1
        fi
        ;;
    esac
  done

  [[ -n "$registry_run" && -n "$stage_id" ]] || {
    echo "Error: workflow_seq_recheck_stage_artifacts requires registry-run and stage-id" >&2
    return 1
  }
  stage_json="$(workflow_seq_read_stage "$registry_run" "$stage_id")" || return 1
  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-${WORKSPACE:-$PWD}}}"

  while IFS= read -r art || [[ -n "$art" ]]; do
    [[ -z "$art" || "$art" == "null" ]] && continue
    if [[ "$art" == /* ]]; then
      abs="$art"
    elif [[ "$art" == .ralph-workspace/* && -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
      abs="${RALPH_PLAN_WORKSPACE_ROOT%/}/${art#.ralph-workspace/}"
    else
      abs="${workspace%/}/$art"
    fi
    if [[ ! -f "$abs" || ! -s "$abs" ]]; then
      echo "Error: artifact recheck failed for stage $stage_id: $art (resolved: $abs)" >&2
      missing=1
    fi
  done < <(printf '%s' "$stage_json" | jq -r '.artifacts[]? // empty')

  # Also recheck required declarations from frozen input when available.
  input_path=""
  if outer="$(workflow_seq_read_outer_run "$registry_run" 2>/dev/null)"; then
    input_path="$(printf '%s' "$outer" | jq -r '.inputPath // empty')"
  fi
  if [[ -z "$input_path" && -f "$registry_run/input.orch.json" ]]; then
    input_path="$registry_run/input.orch.json"
  fi
  if [[ -n "$input_path" && -f "$input_path" ]]; then
    orch_stage="$(jq -c --arg id "$stage_id" '.stages[]? | select(.id == $id)' "$input_path" 2>/dev/null)" || orch_stage=""
    if [[ -n "$orch_stage" ]]; then
      while IFS= read -r art || [[ -n "$art" ]]; do
        [[ -z "$art" ]] && continue
        if [[ "$art" == /* ]]; then
          abs="$art"
        elif [[ "$art" == .ralph-workspace/* && -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
          abs="${RALPH_PLAN_WORKSPACE_ROOT%/}/${art#.ralph-workspace/}"
        else
          abs="${workspace%/}/$art"
        fi
        if [[ ! -f "$abs" || ! -s "$abs" ]]; then
          echo "Error: artifact recheck failed for stage $stage_id required path: $art (resolved: $abs)" >&2
          missing=1
        fi
      done < <(printf '%s' "$orch_stage" | jq -r '
        ((.artifacts // []) + (.outputArtifacts // []))
        | .[] | select(.required == true) | .path // empty
      ')
    fi
  fi

  [[ "$missing" -eq 0 ]]
}

# workflow_seq_stage_should_skip <registry-run> <stage-id>
# Exit 0 when the stage is already succeeded (resume must never rerun it).
workflow_seq_stage_should_skip() {
  local registry_run="${1:-}" stage_id="${2:-}" state
  [[ -n "$registry_run" && -n "$stage_id" ]] || return 1
  workflow_seq_engine_active "$registry_run" || return 1
  state="$(workflow_seq_read_stage "$registry_run" "$stage_id" | jq -r '.state // empty')" || return 1
  [[ "$state" == "succeeded" ]]
}

# workflow_seq_resolve_control_plan <registry-run> <stage-id>
# Prints the durable control plan path when present; empty otherwise.
workflow_seq_resolve_control_plan() {
  local registry_run="${1:-}" stage_id="${2:-}" path
  path="$(workflow_seq_read_stage "$registry_run" "$stage_id" | jq -r '.controlPlanPath // empty')" || return 1
  if [[ -n "$path" && "$path" != "null" ]]; then
    printf '%s\n' "$path"
  fi
  return 0
}

# Internal: append a stage decision object into an accumulating jq array file.
_workflow_seq_resume_push() {
  local file="$1" obj="$2"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/seq-resume.XXXXXX")" || return 1
  jq -cn --argjson rows "$(cat "$file")" --argjson obj "$obj" '$rows + [$obj]' >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$file"
}

# workflow_seq_resume --registry-run ... [--run-id ...] [--workspace ...] [--dry-run]
#
# Internal resume-by-common-run-ID for Sequential mode. Validates immutable
# workflow/supplied-plan hashes, skips succeeded stages, reconciles interrupted
# running stages via owner liveness, retries queued|failed|stale with satisfied
# prerequisites, and retries waiting only for clean interruption, answered
# input ready for consumption, or approved gate. Refuses unresolved
# permission/input/approval and changes-requested. Restores control/current
# TODO, loop/wave position, one-time response/approval consumption, and
# required-artifact checks. Does not implement public CLI or reset.
#
# Prints a JSON resume plan on stdout. Returns 0 when resume may proceed
# (retry set non-empty or only skips), 1 on hard refusal, 2 on hash failure.
workflow_seq_resume() {
  local registry_run="" run_id="" workspace="" dry_run=0
  local engine_run outer_run run_state owner_json owner_health hash_report
  local stages_tmp decisions_tmp id stage_json state blocker class
  local request_id loop_iterations completed_waves current_ids
  local control_plan current_todo plan_source_kind action
  local refuse_reason retry_count=0 refuse_count=0 skip_count=0
  local prereq_ok art_ok apply_state details consume_path

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_seq_resume argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$registry_run" ]]; then
    echo "Error: workflow_seq_resume requires --registry-run" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  workflow_seq_engine_active "$registry_run" || {
    echo "Error: sequential engine not active for resume: $registry_run" >&2
    return 1
  }

  engine_run="$(workflow_seq_read_run "$registry_run")" || return 1
  run_state="$(printf '%s' "$engine_run" | jq -r '.state // empty')"
  run_id="${run_id:-$(printf '%s' "$engine_run" | jq -r '.runId // empty')}"
  if [[ -z "$run_id" ]] && outer_run="$(workflow_seq_read_outer_run "$registry_run" 2>/dev/null)"; then
    run_id="$(printf '%s' "$outer_run" | jq -r '.runId // empty')"
  fi
  loop_iterations="$(printf '%s' "$engine_run" | jq -r '.loopIterations // 0')"
  completed_waves="$(printf '%s' "$engine_run" | jq -r '.completedWaves // 0')"
  current_ids="$(printf '%s' "$engine_run" | jq -c '.currentStageIds // []')"
  owner_json="$(printf '%s' "$engine_run" | jq -c '.owner // null')"
  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-${WORKSPACE:-$PWD}}}"

  case "$run_state" in
    cancelled|succeeded)
      echo "Error: workflow_seq_resume refuses terminal run state: $run_state" >&2
      return 1
      ;;
  esac

  # Live owner on a running engine refuses resume (recover owns stale owners).
  owner_health="$(workflow_seq_classify_owner_json "$owner_json")"
  if [[ "$run_state" == "running" && "$owner_health" == "healthy" ]]; then
    echo "Error: workflow_seq_resume refuses live-owner running run" >&2
    return 1
  fi

  if ! hash_report="$(workflow_seq_validate_immutable_hashes "$registry_run")"; then
    echo "Error: workflow_seq_resume immutable hash validation failed" >&2
    printf '%s\n' "$hash_report" >&2
    return 2
  fi

  decisions_tmp="$(mktemp "${TMPDIR:-/tmp}/seq-resume-dec.XXXXXX")" || return 1
  printf '[]\n' >"$decisions_tmp"

  while IFS= read -r id || [[ -n "$id" ]]; do
    [[ -z "$id" ]] && continue
    stage_json="$(workflow_seq_read_stage "$registry_run" "$id")" || {
      rm -f "$decisions_tmp"
      return 1
    }
    state="$(printf '%s' "$stage_json" | jq -r '.state // empty')"
    blocker="$(printf '%s' "$stage_json" | jq -c '.blocker // null')"
    control_plan="$(printf '%s' "$stage_json" | jq -r '.controlPlanPath // empty')"
    current_todo="$(printf '%s' "$stage_json" | jq -r '.currentTodoId // empty')"
    plan_source_kind="$(printf '%s' "$stage_json" | jq -r '.planSourceKind // empty')"
    action="skip"
    refuse_reason=""
    class=""

    case "$state" in
      succeeded)
        action="skip-succeeded"
        # Artifact recheck for succeeded stages before any downstream retry.
        if ! workflow_seq_recheck_stage_artifacts --registry-run "$registry_run" \
            --stage-id "$id" --workspace "$workspace" 2>/dev/null; then
          action="refuse"
          refuse_reason="missing-artifact"
          refuse_count=$((refuse_count + 1))
        else
          skip_count=$((skip_count + 1))
        fi
        ;;
      cancelled)
        action="skip-cancelled"
        skip_count=$((skip_count + 1))
        ;;
      running)
        case "$owner_health" in
          healthy)
            action="refuse"
            refuse_reason="live-owner"
            refuse_count=$((refuse_count + 1))
            ;;
          stale|absent)
            action="reconcile-stale-then-retry"
            if workflow_seq_prerequisites_satisfied "$registry_run" "$id"; then
              retry_count=$((retry_count + 1))
            else
              action="refuse"
              refuse_reason="unmet-dependency"
              refuse_count=$((refuse_count + 1))
            fi
            ;;
          *)
            action="refuse"
            refuse_reason="live-owner"
            refuse_count=$((refuse_count + 1))
            ;;
        esac
        ;;
      queued|failed|stale)
        if workflow_seq_prerequisites_satisfied "$registry_run" "$id"; then
          action="retry"
          retry_count=$((retry_count + 1))
        else
          action="defer"
        fi
        ;;
      waiting)
        request_id="$(printf '%s' "$blocker" | jq -r '.requestId // empty')"
        # Public Sequential approval: classify the common decision directly so
        # approve / request-changes / cancel apply durable stage+outer state.
        if [[ "$(printf '%s' "$blocker" | jq -r '.kind // empty')" == "approval" && -n "$request_id" ]]; then
          class="$(workflow_action_classify_for_resume "$registry_run" "$request_id" 2>/dev/null || printf 'invalid')"
          case "$class" in
            ready-approval)
              if [[ "$owner_health" == "healthy" ]]; then
                action="refuse"
                refuse_reason="live-owner"
                refuse_count=$((refuse_count + 1))
              else
                action="complete-approved-gate"
                skip_count=$((skip_count + 1))
              fi
              ;;
            changes-requested)
              action="apply-changes-requested"
              refuse_reason="human-changes-requested"
              refuse_count=$((refuse_count + 1))
              ;;
            cancelled)
              action="apply-cancel"
              refuse_reason="cancelled"
              refuse_count=$((refuse_count + 1))
              ;;
            unresolved)
              action="refuse"
              refuse_reason="human-approval"
              refuse_count=$((refuse_count + 1))
              ;;
            *)
              action="refuse"
              refuse_reason="human-approval"
              refuse_count=$((refuse_count + 1))
              ;;
          esac
        else
          class="$(workflow_action_waiting_resume_class "$registry_run" "$blocker")"
          case "$class" in
            clean-interruption)
              if [[ "$owner_health" == "healthy" ]]; then
                action="refuse"
                refuse_reason="live-owner"
                refuse_count=$((refuse_count + 1))
              elif workflow_seq_prerequisites_satisfied "$registry_run" "$id"; then
                action="retry-clean-interruption"
                retry_count=$((retry_count + 1))
              else
                action="refuse"
                refuse_reason="unmet-dependency"
                refuse_count=$((refuse_count + 1))
              fi
              ;;
            answered-input)
              if [[ "$owner_health" == "healthy" ]]; then
                action="refuse"
                refuse_reason="live-owner"
                refuse_count=$((refuse_count + 1))
              elif workflow_seq_prerequisites_satisfied "$registry_run" "$id"; then
                action="retry-answered-input"
                retry_count=$((retry_count + 1))
              else
                action="refuse"
                refuse_reason="unmet-dependency"
                refuse_count=$((refuse_count + 1))
              fi
              ;;
            approved-gate)
              if [[ "$owner_health" == "healthy" ]]; then
                action="refuse"
                refuse_reason="live-owner"
                refuse_count=$((refuse_count + 1))
              else
                action="complete-approved-gate"
                skip_count=$((skip_count + 1))
              fi
              ;;
            unresolved-action)
              action="refuse"
              refuse_reason="operator-input"
              if [[ "$(printf '%s' "$blocker" | jq -r '.kind // empty')" == "approval" ]]; then
                refuse_reason="human-approval"
              elif [[ "$(printf '%s' "$blocker" | jq -r '.kind // empty')" == "permission" ]]; then
                refuse_reason="operator-request"
              fi
              refuse_count=$((refuse_count + 1))
              ;;
            changes-requested)
              action="refuse"
              refuse_reason="human-changes-requested"
              refuse_count=$((refuse_count + 1))
              ;;
            *)
              action="refuse"
              refuse_reason="operator-request"
              refuse_count=$((refuse_count + 1))
              ;;
          esac
        fi
        ;;
      blocked)
        if [[ "$(printf '%s' "$blocker" | jq -r '.reasonCode // empty')" == "human-changes-requested" ]]; then
          action="refuse"
          refuse_reason="human-changes-requested"
        else
          action="refuse"
          refuse_reason="unmet-dependency"
        fi
        refuse_count=$((refuse_count + 1))
        ;;
      *)
        action="refuse"
        refuse_reason="stage-failed"
        refuse_count=$((refuse_count + 1))
        ;;
    esac

    details="$(jq -cn \
      --arg id "$id" \
      --arg state "$state" \
      --arg action "$action" \
      --arg class "${class}" \
      --arg reason "${refuse_reason}" \
      --arg controlPlanPath "${control_plan}" \
      --arg currentTodoId "${current_todo}" \
      --arg planSourceKind "${plan_source_kind}" \
      --argjson wave "$(printf '%s' "$stage_json" | jq -c '.wave // null')" \
      --argjson index "$(printf '%s' "$stage_json" | jq -r '.index // 0')" \
      --argjson attempt "$(printf '%s' "$stage_json" | jq -r '.attempt // 0')" \
      --argjson completedTodos "$(printf '%s' "$stage_json" | jq -r '.completedTodos // 0')" \
      --argjson totalTodos "$(printf '%s' "$stage_json" | jq -r '.totalTodos // 0')" \
      '{
        stageId: $id,
        priorState: $state,
        action: $action,
        waitingClass: (if $class == "" then null else $class end),
        reasonCode: (if $reason == "" then null else $reason end),
        index: $index,
        wave: $wave,
        attempt: $attempt,
        controlPlanPath: (if $controlPlanPath == "" or $controlPlanPath == "null" then null else $controlPlanPath end),
        currentTodoId: (if $currentTodoId == "" or $currentTodoId == "null" then null else $currentTodoId end),
        planSourceKind: (if $planSourceKind == "" or $planSourceKind == "null" then null else $planSourceKind end),
        completedTodos: $completedTodos,
        totalTodos: $totalTodos
      }')"
    _workflow_seq_resume_push "$decisions_tmp" "$details" || {
      rm -f "$decisions_tmp"
      return 1
    }
  done < <(workflow_seq_list_stage_ids "$registry_run")

  # Apply durable approval decisions even when resume will refuse (blocked /
  # cancelled). Approve completions also apply here when dry-run=0.
  _workflow_seq_resume_apply_approval_actions() {
    local details id action stage_json blocker request_id apply_rc
    while IFS= read -r details || [[ -n "$details" ]]; do
      [[ -z "$details" ]] && continue
      id="$(printf '%s' "$details" | jq -r '.stageId')"
      action="$(printf '%s' "$details" | jq -r '.action')"
      case "$action" in
        complete-approved-gate|apply-changes-requested|apply-cancel) ;;
        *) continue ;;
      esac
      stage_json="$(workflow_seq_read_stage "$registry_run" "$id")"
      blocker="$(printf '%s' "$stage_json" | jq -c '.blocker // null')"
      request_id="$(printf '%s' "$blocker" | jq -r '.requestId // empty')"
      [[ -n "$request_id" ]] || continue
      if ! declare -F workflow_seq_approval_apply_decision >/dev/null 2>&1; then
        echo "Error: workflow_seq_approval_apply_decision unavailable" >&2
        return 1
      fi
      apply_rc=0
      workflow_seq_approval_apply_decision \
        --registry-run "$registry_run" \
        --request-id "$request_id" \
        --run-id "$run_id" \
        --stage-id "$id" >/dev/null 2>&1 || apply_rc=$?
      if [[ "$action" == "complete-approved-gate" && "$apply_rc" -ne 0 ]]; then
        echo "Error: failed one-time approval consumption for $request_id" >&2
        return 1
      fi
      # changes-requested / cancel may return non-zero only on hard refuse.
      if [[ "$action" != "complete-approved-gate" && "$apply_rc" -ne 0 && "$apply_rc" -ne 2 ]]; then
        echo "Error: approval decision apply failed for $request_id (rc=$apply_rc)" >&2
        return 1
      fi
    done < <(jq -c '.[]' "$decisions_tmp")
    return 0
  }

  if [[ "$refuse_count" -gt 0 ]]; then
    if [[ "$dry_run" -eq 0 ]]; then
      if ! _workflow_seq_resume_apply_approval_actions; then
        rm -f "$decisions_tmp"
        return 1
      fi
    fi
    # Any unresolved action, changes-requested, live-owner, or artifact failure
    # refuses the entire resume (no partial retry apply).
    jq -cn \
      --arg runId "$run_id" \
      --argjson loopIterations "$loop_iterations" \
      --argjson completedWaves "$completed_waves" \
      --argjson currentStageIds "$current_ids" \
      --argjson hashReport "$hash_report" \
      --argjson stages "$(cat "$decisions_tmp")" \
      --argjson refuseCount "$refuse_count" \
      --argjson retryCount "$retry_count" \
      --argjson skipCount "$skip_count" \
      '{
        schemaVersion: 1,
        ok: false,
        runId: $runId,
        loopIterations: $loopIterations,
        completedWaves: $completedWaves,
        currentStageIds: $currentStageIds,
        hashes: $hashReport,
        refuseCount: $refuseCount,
        retryCount: $retryCount,
        skipCount: $skipCount,
        stages: $stages
      }'
    rm -f "$decisions_tmp"
    return 1
  fi

  # Apply mutations unless dry-run.
  if [[ "$dry_run" -eq 0 ]]; then
    while IFS= read -r details || [[ -n "$details" ]]; do
      [[ -z "$details" ]] && continue
      id="$(printf '%s' "$details" | jq -r '.stageId')"
      action="$(printf '%s' "$details" | jq -r '.action')"
      stage_json="$(workflow_seq_read_stage "$registry_run" "$id")"
      blocker="$(printf '%s' "$stage_json" | jq -c '.blocker // null')"
      request_id="$(printf '%s' "$blocker" | jq -r '.requestId // empty')"

      case "$action" in
        skip-succeeded|skip-cancelled|defer)
          ;;
        reconcile-stale-then-retry)
          workflow_seq_write_stage \
            --registry-run "$registry_run" \
            --stage-id "$id" \
            --state stale \
            --event-name stage-reconciled \
            --details-json '{"reason":"stale-owner","phase":"resume"}' || true
          workflow_seq_write_stage \
            --registry-run "$registry_run" \
            --stage-id "$id" \
            --state queued \
            --blocker-json null \
            --event-name stage-requeued \
            --details-json '{"reason":"resume","phase":"resume"}' || true
          ;;
        retry|retry-clean-interruption)
          if [[ "$(printf '%s' "$stage_json" | jq -r '.state')" != "queued" ]]; then
            workflow_seq_write_stage \
              --registry-run "$registry_run" \
              --stage-id "$id" \
              --state queued \
              --blocker-json null \
              --event-name stage-requeued \
              --details-json "$(jq -cn --arg a "$action" '{reason:$a,phase:"resume"}')" || true
          fi
          ;;
        retry-answered-input)
          if [[ -n "$request_id" ]]; then
            consume_path="$(workflow_action_consume_once "$registry_run" "$request_id" resume 2>/dev/null)" || {
              echo "Error: failed one-time input consumption for $request_id" >&2
              rm -f "$decisions_tmp"
              return 1
            }
            if ! declare -F workflow_action_stage_input_injection >/dev/null 2>&1; then
              # shellcheck source=./workflow-actions.sh
              source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-actions.sh"
            fi
            control_plan="$(printf '%s' "$details" | jq -r '.controlPlanPath // empty')"
            current_todo="$(printf '%s' "$details" | jq -r '.currentTodoId // empty')"
            if ! workflow_action_stage_input_injection "$registry_run" "$request_id" \
                --todo-id "${current_todo}" \
                --control-plan "${control_plan}" >/dev/null; then
              echo "Error: failed to stage delimited input injection for $request_id" >&2
              rm -f "$decisions_tmp"
              return 1
            fi
          fi
          workflow_seq_write_stage \
            --registry-run "$registry_run" \
            --stage-id "$id" \
            --state queued \
            --blocker-json null \
            --event-name stage-requeued \
            --details-json "$(jq -cn --arg rid "${request_id}" '{reason:"answered-input",requestId:$rid,phase:"resume",consumed:true,injectionStaged:true}')" || true
          ;;
        complete-approved-gate)
          # Prefer full Sequential apply (evidence re-verify + consume). Fall
          # back to consume-once for fixtures with placeholder evidence paths.
          if ! declare -F workflow_seq_approval_apply_decision >/dev/null 2>&1 || \
             ! workflow_seq_approval_apply_decision \
                --registry-run "$registry_run" \
                --request-id "$request_id" \
                --run-id "$run_id" \
                --stage-id "$id" >/dev/null 2>&1; then
            if [[ -n "$request_id" ]]; then
              consume_path="$(workflow_action_consume_once "$registry_run" "$request_id" resume 2>/dev/null)" || {
                echo "Error: failed one-time approval consumption for $request_id" >&2
                rm -f "$decisions_tmp"
                return 1
              }
            fi
            workflow_seq_write_stage \
              --registry-run "$registry_run" \
              --stage-id "$id" \
              --state succeeded \
              --terminal-result succeeded \
              --blocker-json null \
              --event-name stage-finished \
              --details-json "$(jq -cn --arg rid "${request_id}" '{reason:"approved-gate",requestId:$rid,phase:"resume",consumed:true}')" || true
          fi
          ;;
        apply-changes-requested|apply-cancel)
          # Handled in the refuse pre-apply path; should not reach here.
          ;;
      esac
    done < <(jq -c '.[]' "$decisions_tmp")

    # Restore loop/wave position; clear live ownership; mark run queued for dispatch.
    apply_state="queued"
    if [[ "$retry_count" -eq 0 ]]; then
      # Only skips/completions: if every stage succeeded, mark succeeded.
      if [[ "$(jq '[.[] | select(.action == "skip-succeeded" or .action == "complete-approved-gate")] | length' "$decisions_tmp")" \
            -eq "$(jq 'length' "$decisions_tmp")" ]]; then
        # Check all stages succeeded after apply.
        if [[ "$(jq -r '.state' "$registry_run/engine/stages/"*.json 2>/dev/null | grep -cv '^succeeded$' || true)" -eq 0 ]]; then
          apply_state="succeeded"
        fi
      fi
    fi
    workflow_seq_update_run \
      --registry-run "$registry_run" \
      --state "$apply_state" \
      --loop-iterations "$loop_iterations" \
      --completed-waves "$completed_waves" \
      --current-stage-ids-json "$current_ids" \
      --owner-json "$(_workflow_seq_null_owner_json)" \
      --event-name run-resumed \
      --details-json "$(jq -cn --argjson retry "$retry_count" --argjson skip "$skip_count" \
        '{reason:"resume",retryCount:$retry,skipCount:$skip}')" || true

    # Mirror public outer run state (engine ledger remains authoritative for Sequential).
    local outer_state_root
    outer_state_root="$(cd "$(dirname "$(dirname "$registry_run")")" && pwd -P)" || outer_state_root=""
    if [[ -n "$outer_state_root" && -n "$run_id" ]] && declare -F workflow_state_clear_owner_and_set_state >/dev/null 2>&1; then
      case "$apply_state" in
        queued) workflow_state_clear_owner_and_set_state "$outer_state_root" "$run_id" queued || true ;;
        succeeded) workflow_state_clear_owner_and_set_state "$outer_state_root" "$run_id" succeeded || true ;;
        *) workflow_state_clear_owner_and_set_state "$outer_state_root" "$run_id" "$apply_state" || true ;;
      esac
    fi
  fi

  jq -cn \
    --arg runId "$run_id" \
    --argjson ok true \
    --argjson dryRun "$dry_run" \
    --argjson loopIterations "$loop_iterations" \
    --argjson completedWaves "$completed_waves" \
    --argjson currentStageIds "$current_ids" \
    --argjson hashReport "$hash_report" \
    --argjson stages "$(cat "$decisions_tmp")" \
    --argjson refuseCount "$refuse_count" \
    --argjson retryCount "$retry_count" \
    --argjson skipCount "$skip_count" \
    '{
      schemaVersion: 1,
      ok: $ok,
      dryRun: ($dryRun == 1),
      runId: $runId,
      loopIterations: $loopIterations,
      completedWaves: $completedWaves,
      currentStageIds: $currentStageIds,
      hashes: $hashReport,
      refuseCount: $refuseCount,
      retryCount: $retryCount,
      skipCount: $skipCount,
      stages: $stages
    }'
  rm -f "$decisions_tmp"
  return 0
}

# workflow_seq_resume_by_run_id --state-root ... --run-id ... [--workspace ...] [--dry-run]
# Resolves the common registry run directory and delegates to workflow_seq_resume.
workflow_seq_resume_by_run_id() {
  local state_root="" run_id="" workspace="" dry_run=0
  local registry_run args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_seq_resume_by_run_id argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$state_root" || -z "$run_id" ]]; then
    echo "Error: workflow_seq_resume_by_run_id requires --state-root and --run-id" >&2
    return 1
  fi
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  if [[ ! -d "$registry_run" ]]; then
    echo "Error: workflow run not found: $run_id" >&2
    return 1
  fi
  args=(--registry-run "$registry_run" --run-id "$run_id")
  [[ -n "$workspace" ]] && args+=(--workspace "$workspace")
  [[ "$dry_run" -eq 1 ]] && args+=(--dry-run)
  workflow_seq_resume "${args[@]}"
}

# ---------------------------------------------------------------------------
# Sequential planFrom: resolve planner attempt, bind control copy, progress
# ---------------------------------------------------------------------------

# workflow_seq_resolve_planner_attempt <registry-run> <planner-stage-id>
# Prints the succeeded planner attempt number from the Sequential engine ledger.
# Missing/non-succeeded planners fail closed before any control copy is created.
workflow_seq_resolve_planner_attempt() {
  local registry_run="${1:-}" planner_stage_id="${2:-}"
  local stage_json state attempt manifest

  [[ -n "$registry_run" && -n "$planner_stage_id" ]] || {
    echo "Error: workflow_seq_resolve_planner_attempt requires registry-run and planner-stage-id" >&2
    return 1
  }
  workflow_seq_engine_active "$registry_run" || {
    echo "Error: sequential engine not active: $registry_run" >&2
    return 1
  }
  stage_json="$(workflow_seq_read_stage "$registry_run" "$planner_stage_id" 2>/dev/null)" || {
    echo "Error: planner stage ledger missing (unmet dependency): $planner_stage_id" >&2
    return 1
  }
  state="$(printf '%s' "$stage_json" | jq -r '.state // empty')"
  [[ "$state" == "succeeded" ]] || {
    echo "Error: planner stage $planner_stage_id latest attempt is not succeeded (state=$state)" >&2
    return 1
  }
  attempt="$(printf '%s' "$stage_json" | jq -r '.attempt // 0')"
  if ! [[ "$attempt" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: planner stage $planner_stage_id has no succeeded attempt number" >&2
    return 1
  fi
  manifest="$registry_run/plans/$planner_stage_id/attempt-${attempt}.manifest.json"
  if [[ -L "$manifest" || ! -f "$manifest" ]]; then
    echo "Error: missing generated-plan manifest for planner $planner_stage_id attempt $attempt: $manifest" >&2
    return 1
  fi
  printf '%s\n' "$attempt"
}

# workflow_seq_apply_planfrom_to_orch <orch-path> <stage-id> <control-plan-path>
# Projects the mutable control copy onto the orch stage plan field, removes
# planFrom (mutex with plan), and forces sessionStrategy fresh when absent.
workflow_seq_apply_planfrom_to_orch() {
  local orch_path="$1" stage_id="$2" control_plan="$3"
  local tmp
  [[ -f "$orch_path" && -n "$stage_id" && -n "$control_plan" ]] || {
    echo "Error: workflow_seq_apply_planfrom_to_orch requires orch_path, stage_id, control_plan" >&2
    return 1
  }
  tmp="$(mktemp "$(dirname "$orch_path")/.orch-seq-planfrom-XXXXXX")" || return 1
  if ! jq --arg id "$stage_id" --arg plan "$control_plan" '
      (.stages[] | select(.id == $id)) |= (
        .plan = $plan
        | del(.planFrom)
        | if ((.sessionStrategy // "") == "") then .sessionStrategy = "fresh" else . end
      )
    ' "$orch_path" >"$tmp"; then
    rm -f "$tmp"
    echo "Error: failed to project planFrom control plan onto orch stage $stage_id" >&2
    return 1
  fi
  mv -f "$tmp" "$orch_path" || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

# workflow_seq_persist_plan_progress <registry-run> <stage-id> <binding-json>
# Merges plan-backed progress fields onto the Sequential stage ledger without
# mutating the immutable source plan/manifest. Preserves current stage state.
# Supports both generated (planFrom) and provided (planInput) bindings,
# including originalPlanPath and null planSourceStageId for provided.
workflow_seq_persist_plan_progress() {
  local registry_run="${1:-}" stage_id="${2:-}" binding_json="${3:-}"
  local state current_todo completed total
  local plan_run_id source_kind source_stage source_plan control_plan plan_path
  local original_plan

  [[ -n "$registry_run" && -n "$stage_id" && -n "$binding_json" ]] || {
    echo "Error: workflow_seq_persist_plan_progress requires registry-run, stage-id, binding-json" >&2
    return 1
  }
  if ! printf '%s' "$binding_json" | jq -e . >/dev/null 2>&1; then
    echo "Error: invalid binding-json for sequential plan progress persist" >&2
    return 1
  fi
  state="$(workflow_seq_read_stage "$registry_run" "$stage_id" | jq -r '.state // empty')" || return 1
  [[ -n "$state" ]] || {
    echo "Error: sequential stage missing for plan progress persist: $stage_id" >&2
    return 1
  }

  plan_path="$(printf '%s' "$binding_json" | jq -r '.controlPlanPath // .planPath // empty')"
  plan_run_id="$(printf '%s' "$binding_json" | jq -r '.planRunId // empty')"
  source_kind="$(printf '%s' "$binding_json" | jq -r '.planSourceKind // "generated"')"
  source_stage="$(printf '%s' "$binding_json" | jq -r '.planSourceStageId // empty')"
  # jq -r prints the literal "null" for JSON null; treat that as empty.
  [[ "$source_stage" == "null" ]] && source_stage=""
  original_plan="$(printf '%s' "$binding_json" | jq -r '.originalPlanPath // empty')"
  [[ "$original_plan" == "null" ]] && original_plan=""
  source_plan="$(printf '%s' "$binding_json" | jq -r '.sourcePlanPath // empty')"
  [[ "$source_plan" == "null" ]] && source_plan=""
  control_plan="$(printf '%s' "$binding_json" | jq -r '.controlPlanPath // empty')"
  current_todo="$(printf '%s' "$binding_json" | jq -r '.currentTodoId // empty')"
  [[ "$current_todo" == "null" ]] && current_todo=""
  completed="$(printf '%s' "$binding_json" | jq -r '.completedTodos // 0')"
  total="$(printf '%s' "$binding_json" | jq -r '.totalTodos // 0')"

  workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id "$stage_id" \
    --state "$state" \
    --plan-path "${plan_path:-null}" \
    --plan-run-id "${plan_run_id:-null}" \
    --plan-source-kind "${source_kind:-null}" \
    --plan-source-stage-id "${source_stage:-null}" \
    --original-plan-path "${original_plan:-null}" \
    --source-plan-path "${source_plan:-null}" \
    --control-plan-path "${control_plan:-null}" \
    --current-todo-id "${current_todo:-null}" \
    --completed-todos "$completed" \
    --total-todos "$total" \
    --event-name plan-progress-updated \
    --details-json "$(jq -cn \
      --argjson completed "$completed" \
      --argjson total "$total" \
      --arg current "${current_todo}" \
      '{completedTodos:$completed,totalTodos:$total,currentTodoId:(if $current == "" then null else $current end)}')"
}

# workflow_seq_bind_planfrom_control --registry-run ... --orch-path ... --stage-id ...
#   [--consumer-attempt N] [--planner-attempt N] [--plan-run-id ...] [--force-fresh]
#
# Before a Sequential planFrom stage runs: resolve the referenced planner's
# latest succeeded attempt from the common registry engine ledger, verify
# manifest/hash/plan, create or reuse the stage-attempt control copy, project
# the orch stage onto that control with effective fresh session strategy, and
# persist source/control/progress on the Sequential stage document. Missing or
# invalid plans fail before any runtime invocation. --force-fresh creates a
# new control copy from the same verified source (consumer-only reset).
# Omitting --planner-attempt always prefers the planner's latest succeeded
# attempt so a planner reset's newer source wins on the next bind.
workflow_seq_bind_planfrom_control() {
  local registry_run="" orch_path="" stage_id="" consumer_attempt="" planner_attempt=""
  local plan_run_id="" force_fresh=0
  local stage_json planner_id binding bind_args=() current_attempt run_id

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --orch-path) orch_path="${2:-}"; shift 2 ;;
      --stage-id) stage_id="${2:-}"; shift 2 ;;
      --consumer-attempt) consumer_attempt="${2:-}"; shift 2 ;;
      --planner-attempt) planner_attempt="${2:-}"; shift 2 ;;
      --plan-run-id) plan_run_id="${2:-}"; shift 2 ;;
      --force-fresh) force_fresh=1; shift ;;
      *)
        echo "Error: unknown workflow_seq_bind_planfrom_control argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$registry_run" && -n "$orch_path" && -n "$stage_id" ]] || {
    echo "Error: workflow_seq_bind_planfrom_control requires --registry-run --orch-path --stage-id" >&2
    return 1
  }
  [[ -f "$orch_path" ]] || {
    echo "Error: orch path missing for planFrom bind: $orch_path" >&2
    return 1
  }
  workflow_seq_engine_active "$registry_run" || {
    echo "Error: sequential engine not active for planFrom bind: $registry_run" >&2
    return 1
  }

  stage_json="$(jq -c --arg id "$stage_id" '.stages[] | select(.id == $id)' "$orch_path" 2>/dev/null)" || stage_json=""
  [[ -n "$stage_json" ]] || {
    echo "Error: orch stage not found for planFrom bind: $stage_id" >&2
    return 1
  }
  # First bind reads authored planFrom. After projection the orch stage keeps
  # only plan=control; resume/rebind recover the planner from the engine ledger.
  planner_id="$(printf '%s' "$stage_json" | jq -r '.planFrom // empty')"
  if [[ -z "$planner_id" ]]; then
    planner_id="$(workflow_seq_read_stage "$registry_run" "$stage_id" 2>/dev/null \
      | jq -r '.planSourceStageId // empty')" || planner_id=""
  fi
  [[ -n "$planner_id" ]] || {
    echo "Error: stage $stage_id has no planFrom field and no persisted planSourceStageId" >&2
    return 1
  }

  if [[ -z "$consumer_attempt" ]]; then
    current_attempt="$(workflow_seq_read_stage "$registry_run" "$stage_id" | jq -r '.attempt // 0')" || return 1
    if [[ "$current_attempt" =~ ^[1-9][0-9]*$ ]]; then
      consumer_attempt="$current_attempt"
    else
      consumer_attempt=1
    fi
  fi
  if ! [[ "$consumer_attempt" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: consumer attempt must be a positive integer (got $consumer_attempt)" >&2
    return 1
  fi

  if [[ -z "$planner_attempt" ]]; then
    planner_attempt="$(workflow_seq_resolve_planner_attempt "$registry_run" "$planner_id")" || return 1
  fi

  if [[ -z "$plan_run_id" ]]; then
    run_id="$(workflow_seq_read_outer_run "$registry_run" 2>/dev/null | jq -r '.runId // empty')" || run_id=""
    if [[ -z "$run_id" ]]; then
      run_id="$(basename -- "$registry_run")"
    fi
    plan_run_id="${stage_id}__${run_id}__${consumer_attempt}"
  fi

  if ! declare -F workflow_state_bind_generated_plan_control >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-state.sh"
  fi

  bind_args=(
    --registry-run "$registry_run"
    --consumer-stage-id "$stage_id"
    --consumer-attempt "$consumer_attempt"
    --planner-stage-id "$planner_id"
    --planner-attempt "$planner_attempt"
    --plan-run-id "$plan_run_id"
  )
  [[ "$force_fresh" -eq 1 ]] && bind_args+=(--force-fresh)

  binding="$(workflow_state_bind_generated_plan_control "${bind_args[@]}")" || return 1
  workflow_seq_apply_planfrom_to_orch "$orch_path" "$stage_id" \
    "$(printf '%s' "$binding" | jq -r '.controlPlanPath')" || return 1
  workflow_seq_persist_plan_progress "$registry_run" "$stage_id" "$binding" || return 1
  printf '%s\n' "$binding"
}

# workflow_seq_refresh_plan_progress_after_runner <control-plan-path>
#
# After orchestrator/run-plan transitions a Sequential planFrom control copy,
# refresh completed/total/current TODO fields on the Sequential stage ledger.
# No-op when the plan is not a registry control copy or Sequential identity
# env is absent. Never mutates the immutable source plan or manifest.
workflow_seq_refresh_plan_progress_after_runner() {
  local control_plan="${1:-}"
  local registry="${RALPH_WORKFLOW_REGISTRY_RUN:-}"
  local stage_id="${RALPH_STAGE_ID:-}"
  local progress binding existing
  local control_real registry_real

  [[ -n "$control_plan" && -f "$control_plan" ]] || return 0
  [[ -n "$registry" && -n "$stage_id" ]] || return 0
  workflow_seq_engine_active "$registry" || return 0
  case "$control_plan" in
    */plans/*/attempt-*/control.plan.md) ;;
    *) return 0 ;;
  esac

  # Canonicalize so macOS /var vs /private/var does not skip the refresh.
  registry_real="$(cd "$registry" 2>/dev/null && pwd -P)" || registry_real="$registry"
  control_real="$(cd "$(dirname -- "$control_plan")" 2>/dev/null && pwd -P)/$(basename -- "$control_plan")" || control_real="$control_plan"
  case "$control_real" in
    "$registry_real"/plans/*/attempt-*/control.plan.md) ;;
    *) return 0 ;;
  esac
  control_plan="$control_real"

  if ! declare -F workflow_state_plan_progress_json >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-state.sh"
  fi
  progress="$(workflow_state_plan_progress_json "$control_plan")" || return 1

  binding="$(jq -cn \
    --arg control "$control_plan" \
    --arg planRunId "${RALPH_PLAN_KEY:-${stage_id}}" \
    --argjson progress "$progress" \
    '{
      planSourceKind: "generated",
      planSourceStageId: null,
      originalPlanPath: null,
      sourcePlanPath: null,
      controlPlanPath: $control,
      planPath: $control,
      planRunId: $planRunId,
      completedTodos: $progress.completedTodos,
      totalTodos: $progress.totalTodos,
      currentTodoId: $progress.currentTodoId
    }')" || return 1

  existing="$(workflow_seq_read_stage "$registry" "$stage_id" 2>/dev/null)" || existing=""
  if [[ -n "$existing" ]]; then
    binding="$(jq -cn --argjson a "$existing" --argjson b "$binding" '
      $b * {
        planSourceKind: ($a.planSourceKind // $b.planSourceKind),
        planSourceStageId: ($a.planSourceStageId // $b.planSourceStageId),
        originalPlanPath: ($a.originalPlanPath // $b.originalPlanPath),
        sourcePlanPath: ($a.sourcePlanPath // $b.sourcePlanPath),
        planRunId: ($a.planRunId // $b.planRunId),
        controlPlanPath: ($a.controlPlanPath // $b.controlPlanPath),
        planPath: ($a.controlPlanPath // $b.controlPlanPath // $b.planPath)
      }
    ')" || return 1
  fi

  workflow_seq_persist_plan_progress "$registry" "$stage_id" "$binding"
}

# ---------------------------------------------------------------------------
# Sequential provided plan (planInput): bind control copy, routing, progress
# ---------------------------------------------------------------------------

# workflow_seq_set_plan_input_stage <stage-id>
# Export the designated planInput.stage for Sequential plan-entry runs so only
# that stage binds the common input manifest. Empty/unset leaves task-entry and
# generated planFrom behavior unchanged.
workflow_seq_set_plan_input_stage() {
  local stage_id="${1:-}"
  if [[ -z "$stage_id" ]]; then
    unset RALPH_WORKFLOW_PLAN_INPUT_STAGE
    return 0
  fi
  export RALPH_WORKFLOW_PLAN_INPUT_STAGE="$stage_id"
}

# workflow_seq_stage_is_provided_consumer <registry-run> <stage-id> [stage-json]
# Returns 0 when this stage is the designated planInput consumer (env) or the
# Sequential ledger already records planSourceKind=provided (resume).
workflow_seq_stage_is_provided_consumer() {
  local registry_run="${1:-}" stage_id="${2:-}"
  local kind=""

  [[ -n "$registry_run" && -n "$stage_id" ]] || return 1
  if [[ -n "${RALPH_WORKFLOW_PLAN_INPUT_STAGE:-}" && \
        "${RALPH_WORKFLOW_PLAN_INPUT_STAGE}" == "$stage_id" ]]; then
    return 0
  fi
  kind="$(workflow_seq_read_stage "$registry_run" "$stage_id" 2>/dev/null \
    | jq -r '.planSourceKind // empty')" || kind=""
  [[ "$kind" == "provided" ]]
}

# workflow_seq_apply_provided_to_orch <orch-path> <stage-id> <control-plan-path>
# Projects the mutable provided-plan control copy onto the orch stage plan
# field, removes planFrom (mutex with plan), and forces sessionStrategy fresh
# when absent. Never mutates the original or frozen source.
workflow_seq_apply_provided_to_orch() {
  local orch_path="$1" stage_id="$2" control_plan="$3"
  local tmp
  [[ -f "$orch_path" && -n "$stage_id" && -n "$control_plan" ]] || {
    echo "Error: workflow_seq_apply_provided_to_orch requires orch_path, stage_id, control_plan" >&2
    return 1
  }
  tmp="$(mktemp "$(dirname "$orch_path")/.orch-seq-provided-XXXXXX")" || return 1
  if ! jq --arg id "$stage_id" --arg plan "$control_plan" '
      (.stages[] | select(.id == $id)) |= (
        .plan = $plan
        | del(.planFrom)
        | if ((.sessionStrategy // "") == "") then .sessionStrategy = "fresh" else . end
      )
    ' "$orch_path" >"$tmp"; then
    rm -f "$tmp"
    echo "Error: failed to project provided-plan control onto orch stage $stage_id" >&2
    return 1
  fi
  mv -f "$tmp" "$orch_path" || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

# workflow_seq_apply_provided_routing_order <orch-path> <stage-id> <source-plan-path>
#   [--invocation-runtime ...] [--invocation-model ...]
#   [--workflow-runtime ...] [--workflow-model ...]
#
# Resolves the fixed supplied-plan routing order onto the designated consumer
# orch stage only (stage beats provided-plan header; header fills when stage
# pins are empty). Never mutates original/frozen source.
workflow_seq_apply_provided_routing_order() {
  if ! declare -F workflow_routing_apply_provided_order_to_orch >/dev/null 2>&1; then
    # shellcheck source=./workflow-routing.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-routing.sh"
  fi
  workflow_routing_apply_provided_order_to_orch "$@"
}

# workflow_seq_bind_provided_plan_control --registry-run ... --orch-path ... --stage-id ...
#   [--consumer-attempt N] [--plan-run-id ...] [--force-fresh]
#   [--invocation-runtime ...] [--invocation-model ...]
#   [--workflow-runtime ...] [--workflow-model ...]
#
# For a Sequential plan-entry run: bind only the designated planInput stage to
# the common input manifest (source kind provided, null producer), validate
# hash/frozen plan, resolve supplied-plan routing order, create or reuse the
# stage-attempt control copy, project orch plan + fresh sessionStrategy, and
# persist original/source/control paths plus TODO progress. Resume reuses the
# control; --force-fresh creates a fresh control from the same source.
# Missing/corrupt input fails before any runtime invocation. Non-designated
# stages and task-entry planFrom paths are left untouched.
workflow_seq_bind_provided_plan_control() {
  local registry_run="" orch_path="" stage_id="" consumer_attempt="" plan_run_id=""
  local force_fresh=0
  local invocation_runtime="" invocation_model="" workflow_runtime="" workflow_model=""
  local stage_json binding bind_args=() current_attempt run_id
  local control source authored_plan

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --orch-path) orch_path="${2:-}"; shift 2 ;;
      --stage-id) stage_id="${2:-}"; shift 2 ;;
      --consumer-attempt) consumer_attempt="${2:-}"; shift 2 ;;
      --plan-run-id) plan_run_id="${2:-}"; shift 2 ;;
      --force-fresh) force_fresh=1; shift ;;
      --invocation-runtime) invocation_runtime="${2:-}"; shift 2 ;;
      --invocation-model) invocation_model="${2:-}"; shift 2 ;;
      --workflow-runtime) workflow_runtime="${2:-}"; shift 2 ;;
      --workflow-model) workflow_model="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_seq_bind_provided_plan_control argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$registry_run" && -n "$orch_path" && -n "$stage_id" ]] || {
    echo "Error: workflow_seq_bind_provided_plan_control requires --registry-run --orch-path --stage-id" >&2
    return 1
  }
  [[ -f "$orch_path" ]] || {
    echo "Error: orch path missing for provided-plan bind: $orch_path" >&2
    return 1
  }
  workflow_seq_engine_active "$registry_run" || {
    echo "Error: sequential engine not active for provided-plan bind: $registry_run" >&2
    return 1
  }

  # Bind only the designated planInput consumer (or a stage already marked provided).
  if ! workflow_seq_stage_is_provided_consumer "$registry_run" "$stage_id"; then
    echo "Error: stage $stage_id is not the designated Sequential planInput consumer" >&2
    return 1
  fi

  stage_json="$(jq -c --arg id "$stage_id" '.stages[] | select(.id == $id)' "$orch_path" 2>/dev/null)" || stage_json=""
  [[ -n "$stage_json" ]] || {
    echo "Error: orch stage not found for provided-plan bind: $stage_id" >&2
    return 1
  }

  # Refuse conflicting authored plan/planFrom on first bind (control projection
  # may already set plan=control on resume).
  if printf '%s' "$stage_json" | jq -e '(.planFrom // "") != ""' >/dev/null 2>&1; then
    echo "Error: invalid provided plan projection: stage $stage_id still declares planFrom" >&2
    return 1
  fi
  authored_plan="$(printf '%s' "$stage_json" | jq -r '.plan // .planFile // empty')"
  if [[ -n "$authored_plan" ]]; then
    case "$authored_plan" in
      */plans/"$stage_id"/attempt-*/control.plan.md) ;;
      *)
        echo "Error: invalid provided plan projection: stage $stage_id already carries a plan path: $authored_plan" >&2
        return 1
        ;;
    esac
  fi

  if [[ -z "$consumer_attempt" ]]; then
    current_attempt="$(workflow_seq_read_stage "$registry_run" "$stage_id" | jq -r '.attempt // 0')" || return 1
    if [[ "$current_attempt" =~ ^[1-9][0-9]*$ ]]; then
      consumer_attempt="$current_attempt"
    else
      consumer_attempt=1
    fi
  fi
  if ! [[ "$consumer_attempt" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: consumer attempt must be a positive integer (got $consumer_attempt)" >&2
    return 1
  fi

  if [[ -z "$plan_run_id" ]]; then
    run_id="$(workflow_seq_read_outer_run "$registry_run" 2>/dev/null | jq -r '.runId // empty')" || run_id=""
    if [[ -z "$run_id" ]]; then
      run_id="$(basename -- "$registry_run")"
    fi
    plan_run_id="${stage_id}__${run_id}__${consumer_attempt}"
  fi

  if ! declare -F workflow_state_bind_provided_plan_control >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-state.sh"
  fi

  bind_args=(
    --registry-run "$registry_run"
    --consumer-stage-id "$stage_id"
    --consumer-attempt "$consumer_attempt"
    --plan-run-id "$plan_run_id"
  )
  [[ "$force_fresh" -eq 1 ]] && bind_args+=(--force-fresh)

  binding="$(workflow_state_bind_provided_plan_control "${bind_args[@]}")" || return 1
  control="$(printf '%s' "$binding" | jq -r '.controlPlanPath')"
  source="$(printf '%s' "$binding" | jq -r '.sourcePlanPath')"
  workflow_seq_apply_provided_to_orch "$orch_path" "$stage_id" "$control" || return 1
  workflow_seq_apply_provided_routing_order "$orch_path" "$stage_id" "$source" \
    --invocation-runtime "$invocation_runtime" \
    --invocation-model "$invocation_model" \
    --workflow-runtime "$workflow_runtime" \
    --workflow-model "$workflow_model" || return 1
  workflow_seq_persist_plan_progress "$registry_run" "$stage_id" "$binding" || return 1
  printf '%s\n' "$binding"
}

# ---------------------------------------------------------------------------
# Public Sequential approval (common actions; no agent / no humanAck)
# ---------------------------------------------------------------------------

# workflow_seq_approval_stage_fields <orch-json|stage-json> <stage-id>
# Prints {question, changesTarget} for an approval stage. Accepts a full orch
# document or a single stage object when stage-id matches .id.
workflow_seq_approval_stage_fields() {
  local orch_or_stage="${1:-}" stage_id="${2:-}"
  [[ -n "$orch_or_stage" && -n "$stage_id" ]] || {
    echo "Error: workflow_seq_approval_stage_fields requires orch-or-stage and stage-id" >&2
    return 1
  }
  if [[ -f "$orch_or_stage" ]]; then
    jq -c --arg id "$stage_id" '
      (.stages // [])[]
      | select(.id == $id)
      | {
          question: (.question // ""),
          changesTarget: (.changesTarget // "")
        }
    ' "$orch_or_stage"
  else
    printf '%s' "$orch_or_stage" | jq -c --arg id "$stage_id" '
      (if type == "object" and has("stages") then (.stages // [])[]
       else . end)
      | select(.id == $id)
      | {
          question: (.question // ""),
          changesTarget: (.changesTarget // "")
        }
    '
  fi
}

# workflow_seq_approval_declared_paths <orch-json|stage-json> <stage-id>
# Prints the authored inputArtifacts/requires path array for an approval stage.
workflow_seq_approval_declared_paths() {
  local orch_or_stage="${1:-}" stage_id="${2:-}"
  [[ -n "$orch_or_stage" && -n "$stage_id" ]] || {
    echo "Error: workflow_seq_approval_declared_paths requires orch-or-stage and stage-id" >&2
    return 1
  }
  if [[ -f "$orch_or_stage" ]]; then
    jq -c --arg id "$stage_id" '
      (.stages // [])[]
      | select(.id == $id)
      | (
          if ((.inputArtifacts // []) | length) > 0 then .inputArtifacts
          else (.requires // [])
          end
        )
    ' "$orch_or_stage"
  else
    printf '%s' "$orch_or_stage" | jq -c --arg id "$stage_id" '
      (if type == "object" and has("stages") then (.stages // [])[]
       else . end)
      | select(.id == $id)
      | (
          if ((.inputArtifacts // []) | length) > 0 then .inputArtifacts
          else (.requires // [])
          end
        )
    '
  fi
}

# workflow_seq_is_legacy_orchestration_input <registry-run>
# True when outer run sourceKind is explicitly legacy-orchestration.
workflow_seq_is_legacy_orchestration_input() {
  local registry_run="${1:-}" kind
  [[ -n "$registry_run" && -f "$registry_run/run.json" ]] || return 1
  kind="$(jq -r '.sourceKind // empty' "$registry_run/run.json" 2>/dev/null)" || return 1
  [[ "$kind" == "legacy-orchestration" ]]
}

# workflow_seq_approval_activate
#   --workspace --namespace --run-id --registry-run --stage-id --attempt-id
#   --orch-json|--stage-json [--state-root] [--wave N]
# Freezes evidence, creates one common approval request, parks stage/run as
# non-retryable waiting with list argv, clears ownership. No agent invocation.
# Prints {requestId,requestPath,blocker,evidence,changesTarget,registryRun}.
workflow_seq_approval_activate() {
  local workspace="" namespace="" run_id="" registry_run="" stage_id="" attempt_id=""
  local orch_json="" stage_json="" state_root="" wave=""
  local fields question changes_target paths evidence request_id
  local request_json request_path blocker loop_iterations completed_waves current_ids

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace) workspace="${2:-}"; shift 2 ;;
      --namespace) namespace="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --stage-id) stage_id="${2:-}"; shift 2 ;;
      --attempt-id) attempt_id="${2:-}"; shift 2 ;;
      --orch-json) orch_json="${2:-}"; shift 2 ;;
      --stage-json) stage_json="${2:-}"; shift 2 ;;
      --state-root) state_root="${2:-}"; shift 2 ;;
      --wave) wave="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_seq_approval_activate argument: $1" >&2
        return 1
        ;;
    esac
  done
  [[ -n "$workspace" && -n "$namespace" && -n "$run_id" && -n "$registry_run" && -n "$stage_id" && -n "$attempt_id" ]] || {
    echo "Error: workflow_seq_approval_activate requires workspace namespace run-id registry-run stage-id attempt-id" >&2
    return 1
  }
  [[ -n "$orch_json" || -n "$stage_json" ]] || {
    echo "Error: workflow_seq_approval_activate requires --orch-json or --stage-json" >&2
    return 1
  }
  workflow_seq_engine_active "$registry_run" || {
    echo "Error: Sequential approval requires an active engine under $registry_run" >&2
    return 1
  }
  if workflow_seq_is_legacy_orchestration_input "$registry_run"; then
    echo "Error: Sequential approval is not used for legacy-orchestration inputs" >&2
    return 1
  fi

  if ! declare -F workflow_action_request_write >/dev/null 2>&1; then
    # shellcheck source=./workflow-actions.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-actions.sh"
  fi
  if ! declare -F workflow_state_clear_owner_and_set_state >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-state.sh"
  fi

  if [[ -n "$orch_json" ]]; then
    fields="$(workflow_seq_approval_stage_fields "$orch_json" "$stage_id")" || return 1
    paths="$(workflow_seq_approval_declared_paths "$orch_json" "$stage_id")" || return 1
  else
    fields="$(workflow_seq_approval_stage_fields "$stage_json" "$stage_id")" || return 1
    paths="$(workflow_seq_approval_declared_paths "$stage_json" "$stage_id")" || return 1
  fi
  question="$(printf '%s' "$fields" | jq -r '.question // empty')"
  changes_target="$(printf '%s' "$fields" | jq -r '.changesTarget // empty')"
  [[ -n "$question" && -n "$changes_target" ]] || {
    echo "Error: approval stage $stage_id missing question or changesTarget" >&2
    return 1
  }

  evidence="$(workflow_action_freeze_evidence "$workspace" "$namespace" "$paths")" || return 1
  workflow_action_verify_evidence "$evidence" || return 1

  # Fail closed on a duplicate outstanding approval for this stage.
  if declare -F workflow_action_list >/dev/null 2>&1; then
    if workflow_action_list "$registry_run" 2>/dev/null \
      | jq -e --arg sid "$stage_id" \
        'map(select(.kind=="approval" and .stageId==$sid and .consumed==null and (.decision==null))) | length > 0' \
        >/dev/null 2>&1; then
      echo "Error: duplicate approval request refused for stage $stage_id" >&2
      return 1
    fi
  fi

  request_id="$(workflow_action_approval_request_id "$run_id" "$stage_id" "$attempt_id")" || return 1
  request_json="$(jq -cn \
    --arg requestId "$request_id" \
    --arg runId "$run_id" \
    --arg stageId "$stage_id" \
    --arg attemptId "$attempt_id" \
    --arg question "$question" \
    --arg changesTarget "$changes_target" \
    --argjson evidence "$evidence" \
    --arg createdAt "$(workflow_action_now_iso)" \
    '{
      requestId: $requestId,
      kind: "approval",
      runId: $runId,
      stageId: $stageId,
      attemptId: $attemptId,
      choices: ["approve","request-changes","cancel"],
      createdAt: $createdAt,
      question: $question,
      changesTarget: $changesTarget,
      evidence: $evidence
    }')" || return 1
  request_path="$(workflow_action_request_write "$registry_run" "$request_json")" || return 1
  blocker="$(workflow_action_approval_blocker_json \
    --request-id "$request_id" \
    --run-id "$run_id" \
    --reason-code human-approval \
    --retryable false \
    --changes-target "$changes_target" \
    --mode list)" || return 1

  # Preserve loop/wave position; park only this gate as waiting.
  loop_iterations="$(workflow_seq_read_run "$registry_run" | jq -r '.loopIterations // 0')"
  completed_waves="$(workflow_seq_read_run "$registry_run" | jq -r '.completedWaves // 0')"
  current_ids="$(jq -cn --arg id "$stage_id" '[$id]')"

  local wave_args=()
  if [[ -n "$wave" && "$wave" != "null" ]]; then
    wave_args=(--wave "$wave")
  fi

  # Ensure stage is running (or already waiting) before parking so transitions stay legal.
  local prior_state
  prior_state="$(workflow_seq_read_stage "$registry_run" "$stage_id" | jq -r '.state // empty')"
  if [[ "$prior_state" != "running" && "$prior_state" != "waiting" ]]; then
    workflow_seq_write_stage \
      --registry-run "$registry_run" \
      --stage-id "$stage_id" \
      --state running \
      "${wave_args[@]}" \
      --event-name stage-started \
      --details-json "$(jq -cn --arg t approval '{stageType:$t,phase:"approval-activate"}')" || return 1
  fi

  workflow_seq_write_stage \
    --registry-run "$registry_run" \
    --stage-id "$stage_id" \
    --state waiting \
    --blocker-json "$blocker" \
    --terminal-result null \
    "${wave_args[@]}" \
    --event-name stage-finished \
    --details-json "$(jq -cn \
      --arg rid "$request_id" \
      --arg t approval \
      '{stageType:$t,phase:"approval-waiting",requestId:$rid,exitCode:3}')" || return 1

  workflow_seq_update_run \
    --registry-run "$registry_run" \
    --state waiting \
    --current-stage-ids-json "$current_ids" \
    --loop-iterations "$loop_iterations" \
    --completed-waves "$completed_waves" \
    --owner-json "$(_workflow_seq_null_owner_json)" \
    --event-name run-status-changed \
    --details-json "$(jq -cn --arg id "$stage_id" --arg rid "$request_id" \
      '{reason:"human-approval",stageId:$id,requestId:$rid}')" || return 1

  if [[ -z "$state_root" ]]; then
    state_root="$(cd "$(dirname "$(dirname "$registry_run")")" && pwd -P)"
  fi
  workflow_state_clear_owner_and_set_state "$state_root" "$run_id" waiting || return 1

  jq -cn \
    --arg requestId "$request_id" \
    --arg requestPath "$request_path" \
    --argjson blocker "$blocker" \
    --argjson evidence "$evidence" \
    --arg registryRun "$registry_run" \
    --arg changesTarget "$changes_target" \
    '{
      requestId: $requestId,
      requestPath: $requestPath,
      registryRun: $registryRun,
      changesTarget: $changesTarget,
      blocker: $blocker,
      evidence: $evidence
    }'
}

# workflow_seq_approval_apply_decision
#   --registry-run --request-id --run-id [--state-root] [--stage-id]
# Consumes approve exactly once; applies changes-requested (blocked + exact
# changesTarget reset argv + retained feedback) or cancel (terminal).
# Prints outcome JSON. Returns 2 when still unresolved.
workflow_seq_approval_apply_decision() {
  local registry_run="" request_id="" run_id="" state_root="" stage_id=""
  local class decision_json choice message changes_target consume_path blocker intent_path
  local loop_iterations completed_waves

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --request-id) request_id="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --state-root) state_root="${2:-}"; shift 2 ;;
      --stage-id) stage_id="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_seq_approval_apply_decision argument: $1" >&2
        return 1
        ;;
    esac
  done
  [[ -n "$registry_run" && -n "$request_id" && -n "$run_id" ]] || {
    echo "Error: workflow_seq_approval_apply_decision requires registry-run request-id run-id" >&2
    return 1
  }
  if ! declare -F workflow_action_classify_for_resume >/dev/null 2>&1; then
    # shellcheck source=./workflow-actions.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-actions.sh"
  fi
  if ! declare -F workflow_state_clear_owner_and_set_state >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-state.sh"
  fi

  class="$(workflow_action_classify_for_resume "$registry_run" "$request_id")" || return 1
  decision_json="$(workflow_action_decision_read "$registry_run" "$request_id" 2>/dev/null || true)"
  choice="$(printf '%s' "$decision_json" | jq -r '.decision // empty')"
  message="$(printf '%s' "$decision_json" | jq -r '.message // empty')"
  changes_target="$(workflow_action_request_read "$registry_run" "$request_id" | jq -r '.changesTarget // empty')"
  if [[ -z "$stage_id" ]]; then
    stage_id="$(workflow_action_request_read "$registry_run" "$request_id" | jq -r '.stageId // empty')"
  fi
  if [[ "$class" == "ready-approval" ]]; then
    local evidence
    evidence="$(workflow_action_request_read "$registry_run" "$request_id" | jq -c '.evidence // []')" || return 1
    workflow_action_verify_evidence "$evidence" || return 1
  fi

  if [[ -z "$state_root" ]]; then
    state_root="$(cd "$(dirname "$(dirname "$registry_run")")" && pwd -P)"
  fi
  loop_iterations="$(workflow_seq_read_run "$registry_run" | jq -r '.loopIterations // 0')"
  completed_waves="$(workflow_seq_read_run "$registry_run" | jq -r '.completedWaves // 0')"

  case "$class" in
    ready-approval)
      consume_path="$(workflow_action_consume_once "$registry_run" "$request_id" resume)" || return 1
      if [[ -n "$stage_id" ]]; then
        workflow_seq_write_stage \
          --registry-run "$registry_run" \
          --stage-id "$stage_id" \
          --state succeeded \
          --terminal-result succeeded \
          --blocker-json null \
          --event-name stage-finished \
          --details-json "$(jq -cn --arg rid "$request_id" \
            '{reason:"approved-gate",requestId:$rid,phase:"approval-resume",consumed:true}')" || return 1
      fi
      workflow_seq_update_run \
        --registry-run "$registry_run" \
        --state running \
        --current-stage-ids-json '[]' \
        --loop-iterations "$loop_iterations" \
        --completed-waves "$completed_waves" \
        --owner-json "$(_workflow_seq_null_owner_json)" \
        --event-name run-status-changed \
        --details-json "$(jq -cn --arg rid "$request_id" '{reason:"approved-gate",requestId:$rid}')" || true
      workflow_state_clear_owner_and_set_state "$state_root" "$run_id" running || true
      jq -cn \
        --arg outcome "approved" \
        --arg requestId "$request_id" \
        --arg consumed "$consume_path" \
        '{outcome:$outcome,requestId:$requestId,consumedPath:$consumed,nodeState:"succeeded"}'
      ;;
    changes-requested)
      [[ -n "$message" ]] || {
        echo "Error: request-changes decision requires a message" >&2
        return 1
      }
      blocker="$(workflow_action_approval_blocker_json \
        --request-id "$request_id" \
        --run-id "$run_id" \
        --reason-code human-changes-requested \
        --retryable false \
        --changes-target "$changes_target" \
        --mode reset)" || return 1
      # Retain bounded human feedback on the durable blocker for reset/resume.
      blocker="$(printf '%s' "$blocker" | jq -c --arg msg "$message" '. + {feedback:$msg}')" || return 1
      if [[ -n "$stage_id" ]]; then
        local prior
        prior="$(workflow_seq_read_stage "$registry_run" "$stage_id" | jq -r '.state // empty')"
        if [[ "$prior" == "waiting" || "$prior" == "running" ]]; then
          workflow_seq_write_stage \
            --registry-run "$registry_run" \
            --stage-id "$stage_id" \
            --state blocked \
            --blocker-json "$blocker" \
            --event-name stage-finished \
            --details-json "$(jq -cn --arg rid "$request_id" --arg msg "$message" --arg tgt "$changes_target" \
              '{reason:"human-changes-requested",requestId:$rid,feedback:$msg,changesTarget:$tgt}')" || return 1
        else
          workflow_seq_write_stage \
            --registry-run "$registry_run" \
            --stage-id "$stage_id" \
            --state blocked \
            --blocker-json "$blocker" \
            --skip-transition-check \
            --event-name stage-finished \
            --details-json "$(jq -cn --arg rid "$request_id" --arg msg "$message" --arg tgt "$changes_target" \
              '{reason:"human-changes-requested",requestId:$rid,feedback:$msg,changesTarget:$tgt}')" || return 1
        fi
      fi
      workflow_seq_update_run \
        --registry-run "$registry_run" \
        --state blocked \
        --current-stage-ids-json "$(jq -cn --arg id "${stage_id}" 'if $id == "" then [] else [$id] end')" \
        --loop-iterations "$loop_iterations" \
        --completed-waves "$completed_waves" \
        --owner-json "$(_workflow_seq_null_owner_json)" \
        --event-name run-status-changed \
        --details-json "$(jq -cn --arg rid "$request_id" --arg tgt "$changes_target" \
          '{reason:"human-changes-requested",requestId:$rid,changesTarget:$tgt}')" || return 1
      workflow_state_clear_owner_and_set_state "$state_root" "$run_id" blocked || return 1
      jq -cn \
        --arg outcome "changes-requested" \
        --arg requestId "$request_id" \
        --arg message "$message" \
        --argjson blocker "$blocker" \
        --arg changesTarget "$changes_target" \
        '{
          outcome:$outcome,
          requestId:$requestId,
          message:$message,
          changesTarget:$changesTarget,
          blocker:$blocker,
          nodeState:"blocked",
          nextAction:$blocker.action
        }'
      ;;
    cancelled)
      intent_path="$(workflow_state_record_cancel_intent "$registry_run" \
        "$(jq -cn --arg rid "$request_id" --arg runId "$run_id" --arg choice "$choice" \
          '{requestId:$rid,runId:$runId,decision:$choice,source:"approval"}')")" || return 1
      if [[ -n "$stage_id" ]]; then
        workflow_seq_write_stage \
          --registry-run "$registry_run" \
          --stage-id "$stage_id" \
          --state cancelled \
          --terminal-result cancelled \
          --blocker-json null \
          --event-name stage-finished \
          --details-json "$(jq -cn --arg rid "$request_id" \
            '{reason:"approval-cancelled",requestId:$rid}')" || return 1
      fi
      workflow_seq_update_run \
        --registry-run "$registry_run" \
        --state cancelled \
        --current-stage-ids-json '[]' \
        --loop-iterations "$loop_iterations" \
        --completed-waves "$completed_waves" \
        --owner-json "$(_workflow_seq_null_owner_json)" \
        --event-name run-status-changed \
        --details-json "$(jq -cn --arg rid "$request_id" '{reason:"approval-cancelled",requestId:$rid}')" || return 1
      workflow_state_clear_owner_and_set_state "$state_root" "$run_id" cancelled || return 1
      jq -cn \
        --arg outcome "cancelled" \
        --arg requestId "$request_id" \
        --arg intentPath "$intent_path" \
        '{outcome:$outcome,requestId:$requestId,cancelIntentPath:$intentPath,nodeState:"cancelled"}'
      ;;
    unresolved)
      echo "Error: approval decision still unresolved for $request_id" >&2
      return 2
      ;;
    already-consumed|missing|invalid|denied|*)
      echo "Error: approval decision refuse class=$class for $request_id" >&2
      return 1
      ;;
  esac
}

# workflow_seq_project_stages <registry-run>
# Public stages array ordered by index from engine/stages/*.json.
# Reads every stage document once but slurps them into a single jq
# invocation, so cost is one file read per stage plus one jq process total
# rather than one jq process per stage.
workflow_seq_project_stages() {
  local registry_run="${1:-}"
  local stages_dir
  local -a stage_files=()
  local nullglob_was_set=0

  [[ -n "$registry_run" ]] || {
    echo "Error: workflow_seq_project_stages requires registry-run" >&2
    return 1
  }
  stages_dir="$(workflow_seq_stages_dir "$registry_run")" || return 1
  if [[ ! -d "$stages_dir" ]]; then
    printf '[]\n'
    return 0
  fi
  stage_files=()
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  local stage_file
  for stage_file in "$stages_dir"/*.json; do
    [[ -f "$stage_file" && ! -L "$stage_file" ]] || continue
    stage_files+=("$stage_file")
  done
  if [[ "$nullglob_was_set" -eq 0 ]]; then
    shopt -u nullglob
  fi
  if [[ "${#stage_files[@]}" -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  jq -cs 'sort_by(.index // 0)' "${stage_files[@]}"
}

# workflow_seq_project_snapshot <state-root> <run-id>
#
# Projects the public stages array and Sequential diagnosis observation
# together from one bounded read of the run/stage documents: the outer run
# ledger, the engine run ledger, and every engine/stages/*.json document are
# each read once, and one slurping jq invocation derives both outputs. This
# avoids re-walking engine/stages/*.json per output and per stage. Read-only;
# never creates or updates state.
workflow_seq_project_snapshot() {
  local state_root="${1:-}" run_id="${2:-}"
  local outer registry_run engine_run run_status owner_json owner_class stages_dir
  local -a stage_files=()
  local nullglob_was_set=0 stage_file

  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_seq_project_snapshot requires state-root and run-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  outer="$(workflow_state_read "$state_root" "$run_id" 2>/dev/null)" || return 1
  run_status="$(printf '%s' "$outer" | jq -r '.state // "running"')"
  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1

  owner_class="none"
  if workflow_seq_engine_active "$registry_run" 2>/dev/null; then
    engine_run="$(workflow_seq_read_run "$registry_run")" || engine_run='{}'
    owner_json="$(printf '%s' "$engine_run" | jq -c '.owner // null')"
    owner_class="$(workflow_seq_classify_owner_json "$owner_json" 2>/dev/null || echo none)"
    [[ "$owner_class" == "absent" || "$owner_class" == "unknown" ]] && owner_class="none"

    stages_dir="$(workflow_seq_stages_dir "$registry_run")" || return 1
    if [[ -d "$stages_dir" ]]; then
      shopt -q nullglob && nullglob_was_set=1
      shopt -s nullglob
      for stage_file in "$stages_dir"/*.json; do
        [[ -f "$stage_file" && ! -L "$stage_file" ]] || continue
        stage_files+=("$stage_file")
      done
      if [[ "$nullglob_was_set" -eq 0 ]]; then
        shopt -u nullglob
      fi
    fi
  fi

  if [[ "${#stage_files[@]}" -eq 0 ]]; then
    jq -cn \
      --arg runId "$run_id" \
      --arg runStatus "$run_status" \
      --arg ownerClass "$owner_class" \
      '{
        stages: [],
        observation: {runId: $runId, runStatus: $runStatus, ownerClass: $ownerClass, nodes: [], cycle: []}
      }'
    return 0
  fi

  jq -cs \
    --arg runId "$run_id" \
    --arg runStatus "$run_status" \
    --arg ownerClass "$owner_class" \
    '
      sort_by(.index // 0) as $stages
      | {
          stages: $stages,
          observation: {
            runId: $runId,
            runStatus: $runStatus,
            ownerClass: $ownerClass,
            nodes: [
              $stages[]
              | select((.id // "") != "")
              | {
                  id: .id,
                  state: (.state // "queued"),
                  blocker: (.blocker // null),
                  changesTarget: (.changesTarget // .blocker.changesTarget // null),
                  reasonCode: (.reasonCode // .blocker.reasonCode // null),
                  loop: (.loop // null),
                  unmetDependencies: (.unmetDependencies // []),
                  missingArtifacts: (.missingArtifacts // []),
                  invalidArtifacts: (.invalidArtifacts // []),
                  failedPrerequisites: (.failedPrerequisites // []),
                  waveFailures: (.waveFailures // [])
                }
            ],
            cycle: []
          }
        }
    ' "${stage_files[@]}"
}

# workflow_seq_build_observation <state-root> <run-id>
# Read-only observation object for workflow_diagnose_sequential. Thin
# wrapper over workflow_seq_project_snapshot for callers that only need the
# observation half.
workflow_seq_build_observation() {
  local state_root="${1:-}" run_id="${2:-}"
  local snapshot

  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_seq_build_observation requires state-root and run-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  snapshot="$(workflow_seq_project_snapshot "$state_root" "$run_id")" || return 1
  printf '%s' "$snapshot" | jq -c '.observation'
}

# ---------------------------------------------------------------------------
# Internal Sequential reset planner / applier
#
# Accepts an exact common run ID plus one concrete stage ID. Uses immutable
# pipeline order and parallelStages waves to select that stage plus every later
# dependent stage (never earlier or independent same-wave peers). Returns a
# deterministic preview; on apply archives mutable state, queues affected
# executable/planner stages, invalidates derived supervisors/approvals, and
# leaves the outer run blocked-ready. No public CLI, inference, or confirmation.
# ---------------------------------------------------------------------------

_workflow_seq_orch_stage_json() {
  local orch_file="$1" stage_id="$2"
  jq -c --arg id "$stage_id" '
    (.stages // [])[]? | select(.id == $id)
  ' "$orch_file" 2>/dev/null
}

_workflow_seq_stage_is_supervisor_type() {
  local orch_file="$1" stage_id="$2"
  local ntype
  ntype="$(jq -r --arg id "$stage_id" '
    (.stages // [])[]? | select(.id == $id) | .type // empty
  ' "$orch_file" 2>/dev/null)" || ntype=""
  case "$ntype" in
    join|gate|checkpoint|router|integrate|approval|publish) return 0 ;;
    *) return 1 ;;
  esac
}

_workflow_seq_stage_is_direct_resettable() {
  local orch_file="$1" stage_id="$2"
  if _workflow_seq_stage_is_supervisor_type "$orch_file" "$stage_id"; then
    return 1
  fi
  return 0
}

_workflow_seq_stage_role() {
  local orch_file="$1" stage_id="$2"
  local stage_json
  if _workflow_seq_stage_is_supervisor_type "$orch_file" "$stage_id"; then
    printf 'derived-supervisor\n'
    return 0
  fi
  stage_json="$(_workflow_seq_orch_stage_json "$orch_file" "$stage_id")"
  if printf '%s' "$stage_json" | jq -e '.planner | type == "object"' >/dev/null 2>&1; then
    printf 'planner\n'
    return 0
  fi
  printf 'executable\n'
}

_workflow_seq_public_state_resettable() {
  case "${1:-}" in
    failed|blocked|stale|waiting|succeeded) return 0 ;;
    *) return 1 ;;
  esac
}

_workflow_seq_mint_reset_archive_id() {
  local now suffix
  if [[ -n "${WORKFLOW_STATE_FIXED_NOW:-}" ]]; then
    now="$WORKFLOW_STATE_FIXED_NOW"
  elif [[ -n "${WORKFLOW_SEQ_FIXED_NOW:-}" ]]; then
    now="$WORKFLOW_SEQ_FIXED_NOW"
  else
    now="$(workflow_state_now_iso 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  # reset-YYYYMMDDTHHMMSSZ-<six mktemp characters>
  now="$(printf '%s' "$now" | tr -d ':-' | sed 's/\..*//')"
  case "$now" in
    *Z) ;;
    *) now="${now}Z" ;;
  esac
  if [[ -n "${WORKFLOW_SEQ_FIXED_RESET_SUFFIX:-}" ]]; then
    suffix="$WORKFLOW_SEQ_FIXED_RESET_SUFFIX"
  else
    suffix="$(mktemp -u XXXXXX 2>/dev/null || printf '%s' "$$")"
    suffix="$(printf '%s' "$suffix" | tr -cd 'A-Za-z0-9' | cut -c1-6)"
    [[ "${#suffix}" -eq 6 ]] || suffix="$(printf '%06d' "$$" | cut -c1-6)"
  fi
  printf 'reset-%s-%s\n' "$now" "$suffix"
}

# Print space-separated stage IDs: selected first, then later dependents in
# immutable pipeline order. Excludes earlier stages and same-wave peers.
_workflow_seq_reset_closure() {
  local orch_file="$1" stage_id="$2"
  [[ -f "$orch_file" && -n "$stage_id" ]] || return 1
  jq -r --arg id "$stage_id" '
    (.stages // []) as $stages
    | (.parallelStages // []) as $waves
    | def wave_of($sid):
        if ($waves | length) == 0 then null
        else
          (reduce range(0; $waves | length) as $i
            ({found: null};
              if .found != null then .
              else
                (($waves[$i] | if type == "string" then split(",") else . end)
                  | map(gsub("^\\s+|\\s+$";""))
                  | index($sid)) as $pos
                | if $pos != null then .found = $i else . end
              end)
            | .found)
        end;
    ($stages | map(.id // empty) | index($id)) as $sel_idx
    | if $sel_idx == null then empty
      else
        (wave_of($id)) as $sel_wave
        | [range(0; $stages | length) as $i
          | ($stages[$i].id // empty) as $tid
          | select($tid != "")
          | (wave_of($tid)) as $tw
          | select(
              $tid == $id
              or (
                if $sel_wave != null then
                  if $tw != null then $tw > $sel_wave
                  else $i > $sel_idx
                  end
                else
                  $i > $sel_idx
                end
              )
            )
          | $tid]
        | .[]
      end
  ' "$orch_file"
}

# Print every stage id in immutable pipeline order (executable, planner, and
# derived supervisors). Used by --all reset selection.
_workflow_seq_reset_all_closure() {
  local orch_file="$1"
  [[ -f "$orch_file" ]] || return 1
  jq -r '(.stages // [])[]?.id // empty' "$orch_file"
}

_workflow_seq_plan_action_for_stage() {
  local orch_file="$1" stage_id="$2" role="$3" stage_ledger="$4" direct="$5"
  local plan_source_kind planfrom
  if [[ "$role" == "derived-supervisor" || "$direct" != "1" ]]; then
    if [[ "$role" == "derived-supervisor" ]]; then
      printf 'invalidate\n'
    else
      printf 'wait-upstream\n'
    fi
    return 0
  fi
  if [[ "$role" == "planner" ]]; then
    printf 'new-planner-attempt\n'
    return 0
  fi
  plan_source_kind="$(printf '%s' "$stage_ledger" | jq -r '.planSourceKind // empty')"
  planfrom="$(jq -r --arg id "$stage_id" '
    (.stages // [])[]? | select(.id == $id) | (.planFrom // empty)
  ' "$orch_file" 2>/dev/null || true)"
  if [[ -z "$planfrom" ]]; then
    planfrom="$(printf '%s' "$stage_ledger" | jq -r '.planSourceStageId // empty')"
  fi
  if [[ "$plan_source_kind" == "provided" ]]; then
    printf 'fresh-control-provided\n'
    return 0
  fi
  if [[ "$plan_source_kind" == "generated" || -n "$planfrom" ]]; then
    printf 'fresh-control-generated\n'
    return 0
  fi
  printf 'requeue\n'
}

_workflow_seq_patch_stage_extras() {
  local stage_file="$1"
  local patch_jq="$2"
  shift 2
  [[ -f "$stage_file" ]] || return 1
  ralph_atomic_write_json "$stage_file" \
    "(\$base | fromjson) | $patch_jq" \
    --arg base "$(jq -c . "$stage_file")" \
    "$@"
}

# workflow_seq_reset_plan --state-root ... --run-id ... --stage ... [--workspace ...]
# Deterministic preview only. Never mutates bytes. Prints JSON.
workflow_seq_reset_plan() {
  workflow_seq_reset "$@" --dry-run
}

# workflow_seq_reset_apply --state-root ... --run-id ... --stage ... [--workspace ...]
# Applies the reset for one concrete stage ID (archives + mutates).
workflow_seq_reset_apply() {
  workflow_seq_reset "$@"
}

# workflow_seq_reset --state-root ... --run-id ... --stage ... [--workspace ...] [--dry-run]
# Shared planner/applier. Dry-run is byte-nonmutating.
workflow_seq_reset() {
  local state_root="" run_id="" stage_id="" workspace="" dry_run=0 reset_all=0
  local outer registry_run orch_file run_state owner_json owner_class
  local stage_ledger public_state role direct plan_action
  local archive_id archive_path feedback_json feedback_request_id feedback_message
  local stages_tmp requests_tmp live_stage refuse_msg
  local next_attempt control_plan source_plan plan_source_kind planner_id
  local bind_json attempt_n requests_dir req_path req_json req_stage req_id
  local stage_file dest_dir archived_control closure_line node_id details
  local selected_wave completed_waves loop_iterations new_control
  local orch_stage_json select_all=0 primary_stage=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --stage) stage_id="${2:-}"; shift 2 ;;
      --all) reset_all=1; shift ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_seq_reset argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ "$reset_all" -eq 1 && -n "$stage_id" ]]; then
    echo "Error: workflow_seq_reset --stage and --all are mutually exclusive" >&2
    return 1
  fi
  if [[ "$reset_all" -eq 0 && -z "$stage_id" ]]; then
    echo "Error: workflow_seq_reset requires --state-root --run-id and (--stage or --all)" >&2
    return 1
  fi
  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_seq_reset requires --state-root --run-id and (--stage or --all)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1

  if ! declare -F workflow_action_find_changes_requested_for_target >/dev/null 2>&1; then
    # shellcheck source=./workflow-actions.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-actions.sh"
  fi
  if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
    # shellcheck source=../atomic-json.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/../atomic-json.sh"
  fi

  outer="$(workflow_state_read "$state_root" "$run_id")" || return 1
  run_state="$(printf '%s' "$outer" | jq -r '.state // empty')"
  case "$run_state" in
    cancelled|succeeded)
      echo "Error: workflow_seq_reset refuses terminal run state: $run_state" >&2
      return 1
      ;;
  esac

  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-$state_root}}"
  orch_file="$(printf '%s' "$outer" | jq -r '.inputPath // empty')"
  [[ -n "$orch_file" && -f "$orch_file" ]] || {
    echo "Error: workflow_seq_reset immutable input orch not found" >&2
    return 1
  }

  workflow_seq_engine_active "$registry_run" || {
    echo "Error: workflow_seq_reset sequential engine not active" >&2
    return 1
  }

  if [[ "$reset_all" -eq 1 ]]; then
    select_all=1
    closure_line="$(_workflow_seq_reset_all_closure "$orch_file" | tr '\n' ' ')"
    closure_line="$(printf '%s' "$closure_line" | sed 's/[[:space:]]*$//')"
    [[ -n "$closure_line" ]] || {
      echo "Error: workflow_seq_reset empty --all closure" >&2
      return 1
    }
    primary_stage=""
    for node_id in $closure_line; do
      [[ -n "$node_id" ]] || continue
      if _workflow_seq_stage_is_direct_resettable "$orch_file" "$node_id"; then
        primary_stage="$node_id"
        break
      fi
    done
    [[ -n "$primary_stage" ]] || {
      echo "Error: workflow_seq_reset --all found no executable/planner stages" >&2
      return 1
    }
    stage_id="$primary_stage"
  else
    if ! jq -e --arg id "$stage_id" 'any((.stages // [])[]?; .id == $id)' "$orch_file" >/dev/null 2>&1; then
      echo "Error: workflow_seq_reset unknown stage: $stage_id" >&2
      return 1
    fi

    if ! _workflow_seq_stage_is_direct_resettable "$orch_file" "$stage_id"; then
      echo "Error: workflow_seq_reset refuses direct supervisor/integrate/publish/approval selection: $stage_id" >&2
      return 1
    fi
  fi

  owner_json="$(workflow_seq_read_run "$registry_run" | jq -c '.owner // null')"
  owner_class="$(workflow_seq_classify_owner_json "$owner_json" 2>/dev/null || echo absent)"
  [[ "$owner_class" == "unknown" ]] && owner_class="absent"
  if [[ "$run_state" == "running" && "$owner_class" == "healthy" ]]; then
    echo "Error: workflow_seq_reset refuses live-running run" >&2
    return 1
  fi

  live_stage=""
  while IFS= read -r node_id || [[ -n "$node_id" ]]; do
    [[ -z "$node_id" ]] && continue
    public_state="$(workflow_seq_read_stage "$registry_run" "$node_id" 2>/dev/null | jq -r '.state // empty')" || public_state=""
    if [[ "$public_state" == "running" ]]; then
      live_stage="$node_id"
      break
    fi
  done < <(jq -r '(.stages // [])[]?.id // empty' "$orch_file")
  if [[ -n "$live_stage" ]]; then
    echo "Error: workflow_seq_reset refuses selection while stage is live-running: $live_stage" >&2
    return 1
  fi

  if [[ "$select_all" -ne 1 ]]; then
    stage_ledger="$(workflow_seq_read_stage "$registry_run" "$stage_id" 2>/dev/null || true)"
    [[ -n "$stage_ledger" ]] || {
      echo "Error: workflow_seq_reset missing ledger for stage: $stage_id" >&2
      return 1
    }
    public_state="$(printf '%s' "$stage_ledger" | jq -r '.state // empty')"
    if ! _workflow_seq_public_state_resettable "$public_state"; then
      echo "Error: workflow_seq_reset permits direct selection only in failed|blocked|stale|waiting|succeeded (got $public_state)" >&2
      return 1
    fi

    closure_line="$(_workflow_seq_reset_closure "$orch_file" "$stage_id" | tr '\n' ' ')"
    closure_line="$(printf '%s' "$closure_line" | sed 's/[[:space:]]*$//')"
    [[ -n "$closure_line" ]] || {
      echo "Error: workflow_seq_reset empty closure for stage: $stage_id" >&2
      return 1
    }
  fi

  archive_id="$(_workflow_seq_mint_reset_archive_id)"
  archive_path="$registry_run/archive/$archive_id"

  feedback_json="$(workflow_action_find_changes_requested_for_target "$registry_run" "$stage_id" 2>/dev/null || true)"
  feedback_request_id=""
  feedback_message=""
  if [[ -n "$feedback_json" && "$feedback_json" != "null" ]]; then
    feedback_request_id="$(printf '%s' "$feedback_json" | jq -r '.requestId // empty')"
    feedback_message="$(printf '%s' "$feedback_json" | jq -r '.message // empty')"
  fi

  stages_tmp="$(mktemp "${TMPDIR:-/tmp}/seq-reset-stages.XXXXXX")" || return 1
  requests_tmp="$(mktemp "${TMPDIR:-/tmp}/seq-reset-reqs.XXXXXX")" || {
    rm -f "$stages_tmp"
    return 1
  }
  printf '[]\n' >"$stages_tmp"
  printf '[]\n' >"$requests_tmp"

  for node_id in $closure_line; do
    [[ -n "$node_id" ]] || continue
    stage_ledger="$(workflow_seq_read_stage "$registry_run" "$node_id" 2>/dev/null || echo '{}')"
    public_state="$(printf '%s' "$stage_ledger" | jq -r '.state // "queued"')"
    role="$(_workflow_seq_stage_role "$orch_file" "$node_id")"
    if [[ "$select_all" -eq 1 ]]; then
      if _workflow_seq_stage_is_direct_resettable "$orch_file" "$node_id"; then
        direct=1
      else
        direct=0
      fi
    elif [[ "$node_id" == "$stage_id" ]]; then
      direct=1
    else
      direct=0
    fi
    plan_action="$(_workflow_seq_plan_action_for_stage "$orch_file" "$node_id" "$role" "$stage_ledger" "$direct")"
    next_attempt="$(printf '%s' "$stage_ledger" | jq -r '.attempt // 0')"
    next_attempt=$((next_attempt + 1))
    control_plan="$(printf '%s' "$stage_ledger" | jq -r '.controlPlanPath // empty')"
    source_plan="$(printf '%s' "$stage_ledger" | jq -r '.sourcePlanPath // empty')"
    plan_source_kind="$(printf '%s' "$stage_ledger" | jq -r '.planSourceKind // empty')"

    jq -c \
      --arg id "$node_id" \
      --arg role "$role" \
      --arg prior "$public_state" \
      --arg planAction "$plan_action" \
      --argjson direct "$direct" \
      --argjson nextAttempt "$next_attempt" \
      --arg controlPlanPath "$control_plan" \
      --arg sourcePlanPath "$source_plan" \
      --arg planSourceKind "$plan_source_kind" \
      --arg feedbackRequestId "$feedback_request_id" \
      '. + [{
        stageId: $id,
        role: $role,
        direct: ($direct == 1),
        priorState: $prior,
        action: (if $role == "derived-supervisor" then "invalidate" else "reset" end),
        planAction: $planAction,
        nextAttempt: $nextAttempt,
        controlPlanPath: (if $controlPlanPath == "" then null else $controlPlanPath end),
        sourcePlanPath: (if $sourcePlanPath == "" then null else $sourcePlanPath end),
        planSourceKind: (if $planSourceKind == "" then null else $planSourceKind end),
        humanFeedbackRequestId: (if ($direct == 1) and ($feedbackRequestId != "") then $feedbackRequestId else null end)
      }]' "$stages_tmp" >"${stages_tmp}.new" && mv -f "${stages_tmp}.new" "$stages_tmp"
  done

  requests_dir="$registry_run/actions/requests"
  if [[ -d "$requests_dir" ]]; then
    for req_path in "$requests_dir"/*.json; do
      [[ -f "$req_path" && ! -L "$req_path" ]] || continue
      req_json="$(jq -c . "$req_path" 2>/dev/null)" || continue
      req_stage="$(printf '%s' "$req_json" | jq -r '.stageId // empty')"
      req_id="$(printf '%s' "$req_json" | jq -r '.requestId // empty')"
      [[ -n "$req_stage" && -n "$req_id" ]] || continue
      case " $closure_line " in
        *" $req_stage "*) ;;
        *) continue ;;
      esac
      if workflow_action_consumed_read "$registry_run" "$req_id" >/dev/null 2>&1; then
        continue
      fi
      jq -c \
        --arg id "$req_id" \
        --arg stageId "$req_stage" \
        --arg kind "$(printf '%s' "$req_json" | jq -r '.kind // empty')" \
        '. + [{requestId:$id, stageId:$stageId, kind:$kind}]' \
        "$requests_tmp" >"${requests_tmp}.new" && mv -f "${requests_tmp}.new" "$requests_tmp"
    done
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    jq -cn \
      --arg runId "$run_id" \
      --arg stageId "$stage_id" \
      --arg archivePath "$archive_path" \
      --arg archiveId "$archive_id" \
      --argjson selectAll "$select_all" \
      --argjson stages "$(cat "$stages_tmp")" \
      --argjson invalidatedRequests "$(cat "$requests_tmp")" \
      --argjson humanFeedback "$(if [[ -n "$feedback_json" ]]; then printf '%s' "$feedback_json" | jq -c '{requestId,changesTarget,approvalStageId,message}'; else echo null; fi)" \
      '{
        schemaVersion: 1,
        ok: true,
        dryRun: true,
        mode: "sequential",
        runId: $runId,
        stageId: (if ($selectAll == 1) then "all" else $stageId end),
        selectAll: ($selectAll == 1),
        archiveId: $archiveId,
        archivePath: $archivePath,
        stages: $stages,
        invalidatedRequests: $invalidatedRequests,
        humanFeedback: $humanFeedback,
        preserved: [
          "workflow-input",
          "supplied-plan-source-manifest",
          "generated-source-plan-manifest",
          "logs",
          "artifacts",
          "decisions",
          "completed-attempt-evidence",
          "audit-history"
        ],
        outerStateAfterApply: "blocked"
      }'
    rm -f "$stages_tmp" "$requests_tmp"
    return 0
  fi

  # --- apply ---
  mkdir -p "$archive_path/stages" "$archive_path/plans" "$archive_path/actions/requests" \
    || {
      rm -f "$stages_tmp" "$requests_tmp"
      echo "Error: failed to create reset archive path" >&2
      return 1
    }

  for node_id in $closure_line; do
    [[ -n "$node_id" ]] || continue
    stage_file="$(workflow_seq_stage_file "$registry_run" "$node_id" 2>/dev/null || true)"
    if [[ -n "$stage_file" && -f "$stage_file" ]]; then
      cp -f "$stage_file" "$archive_path/stages/${node_id}.json" || true
    fi
    stage_ledger="$(workflow_seq_read_stage "$registry_run" "$node_id" 2>/dev/null || echo '{}')"
    control_plan="$(printf '%s' "$stage_ledger" | jq -r '.controlPlanPath // empty')"
    if [[ -n "$control_plan" && -f "$control_plan" ]]; then
      dest_dir="$archive_path/plans/$node_id"
      mkdir -p "$dest_dir"
      archived_control="$dest_dir/$(basename "$control_plan")"
      cp -f "$control_plan" "$archived_control" || true
    fi
    attempt_n="$(printf '%s' "$stage_ledger" | jq -r '.attempt // empty')"
    if [[ -n "$attempt_n" && "$attempt_n" != "0" && "$attempt_n" != "null" ]]; then
      workflow_action_revoke_attempt_capability "$registry_run" "$run_id" "$node_id" "${node_id}-${attempt_n}" 2>/dev/null || true
      workflow_action_revoke_attempt_capability "$registry_run" "$run_id" "$node_id" "$attempt_n" 2>/dev/null || true
    fi
  done

  while IFS= read -r req_json || [[ -n "$req_json" ]]; do
    [[ -z "$req_json" || "$req_json" == "null" ]] && continue
    req_id="$(printf '%s' "$req_json" | jq -r '.requestId // empty')"
    [[ -n "$req_id" ]] || continue
    if [[ -n "$feedback_request_id" && "$req_id" == "$feedback_request_id" ]]; then
      continue
    fi
    req_path="$(workflow_action_request_path "$registry_run" "$req_id" 2>/dev/null || true)"
    if [[ -n "$req_path" && -f "$req_path" ]]; then
      cp -f "$req_path" "$archive_path/actions/requests/${req_id}.json" || true
      rm -f "$req_path" || true
    fi
  done < <(jq -c '.[]' "$requests_tmp")

  while IFS= read -r details || [[ -n "$details" ]]; do
    [[ -z "$details" ]] && continue
    node_id="$(printf '%s' "$details" | jq -r '.stageId')"
    role="$(printf '%s' "$details" | jq -r '.role')"
    plan_action="$(printf '%s' "$details" | jq -r '.planAction')"
    direct="$(printf '%s' "$details" | jq -r 'if .direct then 1 else 0 end')"
    next_attempt="$(printf '%s' "$details" | jq -r '.nextAttempt // 1')"
    control_plan="$(printf '%s' "$details" | jq -r '.controlPlanPath // empty')"
    source_plan="$(printf '%s' "$details" | jq -r '.sourcePlanPath // empty')"
    plan_source_kind="$(printf '%s' "$details" | jq -r '.planSourceKind // empty')"
    stage_file="$(workflow_seq_stage_file "$registry_run" "$node_id")" || continue

    # Queue / invalidate with transition bypass (succeeded has no outgoing edge).
    workflow_seq_write_stage \
      --registry-run "$registry_run" \
      --stage-id "$node_id" \
      --state queued \
      --blocker-json null \
      --terminal-result null \
      --plan-path null \
      --plan-run-id null \
      --current-todo-id null \
      --completed-todos 0 \
      --control-plan-path null \
      --event-name stage-reset \
      --details-json "$(jq -cn --arg a "$plan_action" --arg r "$role" '{reason:"reset",planAction:$a,role:$r}')" \
      --skip-transition-check || true

    if [[ "$role" == "derived-supervisor" || "$direct" != "1" ]]; then
      if [[ "$plan_action" == "wait-upstream" ]]; then
        _workflow_seq_patch_stage_extras "$stage_file" \
          '.waitingForPlanner = true | del(.scheduledPlannerAttempt)' || true
      else
        _workflow_seq_patch_stage_extras "$stage_file" \
          'del(.waitingForPlanner) | del(.scheduledPlannerAttempt)' || true
      fi
      if [[ -n "$control_plan" && -f "$control_plan" ]]; then
        rm -f "$control_plan" || true
      fi
      # Preserve immutable sourcePlanPath / planSourceKind on ledger when present.
      if [[ -n "$source_plan" ]]; then
        workflow_seq_write_stage \
          --registry-run "$registry_run" \
          --stage-id "$node_id" \
          --state queued \
          --source-plan-path "$source_plan" \
          --plan-source-kind "${plan_source_kind:-null}" \
          --skip-transition-check \
          --event-name stage-reset-preserve-source \
          --details-json '{}' >/dev/null 2>&1 || true
      fi
      continue
    fi

    case "$plan_action" in
      new-planner-attempt)
        _workflow_seq_patch_stage_extras "$stage_file" \
          '.scheduledPlannerAttempt = $attempt | del(.waitingForPlanner)' \
          --argjson attempt "$next_attempt" || true
        workflow_seq_write_stage \
          --registry-run "$registry_run" \
          --stage-id "$node_id" \
          --state queued \
          --attempt "$next_attempt" \
          --skip-transition-check \
          --event-name stage-reset-planner \
          --details-json "$(jq -cn --argjson n "$next_attempt" '{scheduledPlannerAttempt:$n}')" || true
        ;;
      fresh-control-provided|fresh-control-generated)
        bind_json=""
        if ! declare -F workflow_state_bind_provided_plan_control >/dev/null 2>&1; then
          # shellcheck source=./workflow-state.sh
          source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-state.sh"
        fi
        if [[ "$plan_action" == "fresh-control-provided" ]]; then
          bind_json="$(workflow_state_bind_provided_plan_control \
            --registry-run "$registry_run" \
            --consumer-stage-id "$node_id" \
            --consumer-attempt "$next_attempt" \
            --force-fresh 2>/dev/null)" || bind_json=""
        else
          planner_id="$(jq -r --arg id "$node_id" '
            (.stages // [])[]? | select(.id == $id) | (.planFrom // empty)
          ' "$orch_file" 2>/dev/null || true)"
          if [[ -z "$planner_id" ]]; then
            planner_id="$(workflow_seq_read_stage "$registry_run" "$node_id" 2>/dev/null \
              | jq -r '.planSourceStageId // empty')" || planner_id=""
          fi
          if [[ -n "$planner_id" ]]; then
            bind_json="$(workflow_state_bind_generated_plan_control \
              --registry-run "$registry_run" \
              --consumer-stage-id "$node_id" \
              --consumer-attempt "$next_attempt" \
              --planner-stage-id "$planner_id" \
              --force-fresh 2>/dev/null)" || bind_json=""
          fi
        fi
        if [[ -z "$bind_json" && -n "$source_plan" && -f "$source_plan" ]]; then
          dest_dir="$registry_run/plans/$node_id/attempt-${next_attempt}"
          mkdir -p "$dest_dir"
          cp -f "$source_plan" "$dest_dir/control.plan.md"
          chmod u+w "$dest_dir/control.plan.md" 2>/dev/null || true
          bind_json="$(jq -cn \
            --arg source "$source_plan" \
            --arg control "$dest_dir/control.plan.md" \
            --arg kind "${plan_source_kind:-provided}" \
            --arg planner "${planner_id:-}" \
            '{
              sourcePlanPath: $source,
              controlPlanPath: $control,
              planPath: $control,
              planRunId: null,
              planSourceKind: $kind,
              planSourceStageId: (if $planner == "" then null else $planner end),
              originalPlanPath: null,
              completedTodos: 0,
              totalTodos: 1,
              currentTodoId: null
            }')"
        fi
        if [[ -n "$bind_json" ]]; then
          new_control="$(printf '%s' "$bind_json" | jq -r '.controlPlanPath // empty')"
          workflow_seq_write_stage \
            --registry-run "$registry_run" \
            --stage-id "$node_id" \
            --state queued \
            --attempt "$next_attempt" \
            --plan-path "$(printf '%s' "$bind_json" | jq -r '.planPath // empty')" \
            --plan-run-id "$(printf '%s' "$bind_json" | jq -r '.planRunId // empty')" \
            --plan-source-kind "$(printf '%s' "$bind_json" | jq -r '.planSourceKind // empty')" \
            --plan-source-stage-id "$(printf '%s' "$bind_json" | jq -r '.planSourceStageId // empty')" \
            --source-plan-path "$(printf '%s' "$bind_json" | jq -r '.sourcePlanPath // empty')" \
            --control-plan-path "$new_control" \
            --original-plan-path "$(printf '%s' "$bind_json" | jq -r '.originalPlanPath // empty')" \
            --completed-todos "$(printf '%s' "$bind_json" | jq -r '.completedTodos // 0')" \
            --total-todos "$(printf '%s' "$bind_json" | jq -r '.totalTodos // 0')" \
            --current-todo-id null \
            --skip-transition-check \
            --event-name stage-reset-fresh-control \
            --details-json "$(jq -cn --arg a "$plan_action" '{planAction:$a}')" || true
          _workflow_seq_patch_stage_extras "$stage_file" 'del(.waitingForPlanner)' || true
        fi
        if [[ -n "$control_plan" && -f "$control_plan" ]]; then
          new_control="$(printf '%s' "${bind_json:-}" | jq -r '.controlPlanPath // empty')"
          if [[ -n "$new_control" && "$control_plan" != "$new_control" ]]; then
            rm -f "$control_plan" || true
          fi
        fi
        ;;
      *)
        workflow_seq_write_stage \
          --registry-run "$registry_run" \
          --stage-id "$node_id" \
          --state queued \
          --attempt "$next_attempt" \
          --skip-transition-check \
          --event-name stage-reset-requeue \
          --details-json '{}' || true
        _workflow_seq_patch_stage_extras "$stage_file" 'del(.waitingForPlanner)' || true
        ;;
    esac
  done < <(jq -c '.[]' "$stages_tmp")

  # Bind human feedback to the selected target's next fresh attempt and consume once.
  if [[ -n "$feedback_request_id" ]]; then
    if declare -F workflow_action_continuation_abandon_stage_attempt >/dev/null 2>&1; then
      local _prior_attempt _prior_attempt_id
      _prior_attempt="$(workflow_seq_read_stage "$registry_run" "$stage_id" 2>/dev/null | jq -r '.attempt // empty')"
      if [[ -n "$_prior_attempt" && "$_prior_attempt" != "0" && "$_prior_attempt" != "null" ]]; then
        _prior_attempt_id="${stage_id}-${_prior_attempt}"
        workflow_action_continuation_abandon_stage_attempt "$run_id" "$stage_id" "$_prior_attempt_id" \
          "" "" 2>/dev/null || true
      fi
    fi
    next_attempt="$(jq -r --arg id "$stage_id" '
      map(select(.stageId == $id)) | .[0].nextAttempt // 1
    ' "$stages_tmp")"
    req_path="$(workflow_action_request_path "$registry_run" "$feedback_request_id" 2>/dev/null || true)"
    if [[ -n "$req_path" && -f "$req_path" ]]; then
      mkdir -p "$archive_path/actions/requests"
      cp -f "$req_path" "$archive_path/actions/requests/${feedback_request_id}.json" || true
    fi
    workflow_action_stage_human_feedback "$registry_run" "$feedback_request_id" \
      --target-stage "$stage_id" \
      --target-attempt "$next_attempt" >/dev/null 2>&1 || true
    workflow_action_consume_once "$registry_run" "$feedback_request_id" reset >/dev/null 2>&1 || true
  fi

  selected_wave="$(workflow_seq_read_stage "$registry_run" "$stage_id" 2>/dev/null | jq -r '.wave // empty')"
  loop_iterations="$(workflow_seq_read_run "$registry_run" | jq -r '.loopIterations // 0')"
  if [[ -n "$selected_wave" && "$selected_wave" != "null" ]]; then
    completed_waves="$selected_wave"
  else
    completed_waves="$(jq -r --arg id "$stage_id" '
      (.stages // []) as $stages
      | (.parallelStages // []) as $waves
      | ($stages | map(.id // empty) | index($id)) as $sel_idx
      | if $sel_idx == null or ($waves | length) == 0 then 0
        else
          ([range(0; $waves | length) as $i
            | (($waves[$i] | if type == "string" then split(",") else . end)
                | map(gsub("^\\s+|\\s+$";""))) as $members
            | select(all($members[]; . as $m | ($stages | map(.id) | index($m)) < $sel_idx))
            | $i] | length)
        end
    ' "$orch_file")"
  fi

  workflow_seq_update_run \
    --registry-run "$registry_run" \
    --state blocked \
    --current-stage-ids-json '[]' \
    --loop-iterations "$loop_iterations" \
    --completed-waves "$completed_waves" \
    --owner-json "$(_workflow_seq_null_owner_json)" \
    --event-name run-status-changed \
    --details-json "$(jq -cn --arg stage "$stage_id" --arg archive "$archive_path" \
      '{reason:"reset",stageId:$stage,archivePath:$archive}')" \
    --skip-transition-check || true

  workflow_state_clear_owner_and_set_state "$state_root" "$run_id" blocked || true

  jq -cn \
    --arg runId "$run_id" \
    --arg stageId "$stage_id" \
    --arg archivePath "$archive_path" \
    --arg archiveId "$archive_id" \
    --argjson selectAll "$select_all" \
    --argjson stages "$(cat "$stages_tmp")" \
    --argjson invalidatedRequests "$(cat "$requests_tmp")" \
    --argjson humanFeedback "$(if [[ -n "$feedback_json" ]]; then printf '%s' "$feedback_json" | jq -c '{requestId,changesTarget,approvalStageId,message}'; else echo null; fi)" \
    '{
      schemaVersion: 1,
      ok: true,
      dryRun: false,
      mode: "sequential",
      runId: $runId,
      stageId: (if ($selectAll == 1) then "all" else $stageId end),
      selectAll: ($selectAll == 1),
      archiveId: $archiveId,
      archivePath: $archivePath,
      stages: $stages,
      invalidatedRequests: $invalidatedRequests,
      humanFeedback: $humanFeedback,
      preserved: [
        "workflow-input",
        "supplied-plan-source-manifest",
        "generated-source-plan-manifest",
        "logs",
        "artifacts",
        "decisions",
        "completed-attempt-evidence",
        "audit-history"
      ],
      outerStateAfterApply: "blocked"
    }'
  rm -f "$stages_tmp" "$requests_tmp"
  return 0
}

# workflow_seq_reset_by_run_id --state-root ... --run-id ... [--stage ...|--all] [--workspace ...] [--dry-run]
# Resolves the common registry run directory and delegates to workflow_seq_reset.
workflow_seq_reset_by_run_id() {
  local state_root="" run_id="" stage_id="" workspace="" dry_run=0 reset_all=0
  local args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --stage) stage_id="${2:-}"; shift 2 ;;
      --all) reset_all=1; shift ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_seq_reset_by_run_id argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$state_root" || -z "$run_id" ]]; then
    echo "Error: workflow_seq_reset_by_run_id requires --state-root and --run-id" >&2
    return 1
  fi
  if [[ "$reset_all" -eq 0 && -z "$stage_id" ]]; then
    echo "Error: workflow_seq_reset_by_run_id requires --stage or --all" >&2
    return 1
  fi
  if ! workflow_state_run_dir "$state_root" "$run_id" >/dev/null 2>&1; then
    echo "Error: workflow run not found: $run_id" >&2
    return 1
  fi
  args=(--state-root "$state_root" --run-id "$run_id")
  [[ -n "$stage_id" ]] && args+=(--stage "$stage_id")
  [[ "$reset_all" -eq 1 ]] && args+=(--all)
  [[ -n "$workspace" ]] && args+=(--workspace "$workspace")
  [[ "$dry_run" -eq 1 ]] && args+=(--dry-run)
  workflow_seq_reset "${args[@]}"
}

# ---------------------------------------------------------------------------
# Sequential recover / cancel (internal by common run ID)
# ---------------------------------------------------------------------------

# _workflow_seq_source_recovery_libs
# Lazily source actions + process teardown helpers used by recover/cancel.
_workflow_seq_source_recovery_libs() {
  if ! declare -F workflow_action_revoke_residual_capabilities >/dev/null 2>&1; then
    # shellcheck source=./workflow-actions.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-actions.sh"
  fi
  if ! declare -F ralph_kill_tree >/dev/null 2>&1; then
    # shellcheck source=../ralph-process-teardown.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/../ralph-process-teardown.sh"
  fi
  if ! declare -F ralph_process_term_kill_tree >/dev/null 2>&1; then
    # shellcheck source=../ralph-process-supervisor.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/../ralph-process-supervisor.sh"
  fi
  if ! declare -F workflow_state_classify_owner_json >/dev/null 2>&1; then
    # shellcheck source=./workflow-state.sh
    source "$_WORKFLOW_SEQ_SCRIPT_DIR/workflow-state.sh"
  fi
}

# _workflow_seq_effective_owner_json <registry-run> <outer-json>
# Prefer engine owner; fall back to outer run owner.
_workflow_seq_effective_owner_json() {
  local registry_run="$1" outer_json="$2"
  local engine_owner outer_owner
  engine_owner="$(workflow_seq_read_run "$registry_run" 2>/dev/null | jq -c '.owner // null')" || engine_owner="null"
  outer_owner="$(printf '%s' "$outer_json" | jq -c '.owner // null')"
  if [[ "$engine_owner" != "null" && -n "$engine_owner" ]]; then
    local eng_pid
    eng_pid="$(printf '%s' "$engine_owner" | jq -r '.pid // empty')"
    if [[ -n "$eng_pid" && "$eng_pid" != "null" ]]; then
      printf '%s\n' "$engine_owner"
      return 0
    fi
  fi
  printf '%s\n' "$outer_owner"
}

# _workflow_seq_collect_retryable_stages <registry-run>
# Prints a JSON array of stage objects resume may retry after recover.
_workflow_seq_collect_retryable_stages() {
  local registry_run="$1"
  local stage_file stage_id state stages='[]'

  [[ -d "$registry_run/engine/stages" ]] || { printf '[]\n'; return 0; }
  shopt -s nullglob
  for stage_file in "$registry_run/engine/stages"/*.json; do
    [[ -f "$stage_file" ]] || continue
    stage_id="$(jq -r '.id // empty' "$stage_file" 2>/dev/null)"
    state="$(jq -r '.state // empty' "$stage_file" 2>/dev/null)"
    [[ -n "$stage_id" ]] || continue
    case "$state" in
      queued|failed|stale|waiting)
        stages="$(jq -cn --argjson arr "$stages" --arg id "$stage_id" --arg st "$state" \
          '$arr + [{stageId:$id,status:$st,retryable:true}]')"
        ;;
    esac
  done
  shopt -u nullglob
  printf '%s\n' "$stages"
}

# _workflow_seq_reconcile_interrupted_stages <registry-run> <run-id>
# Mark interrupted running stages stale/retryable, revoke residual capabilities,
# preserve wave/loop position on the engine run, and append audit events.
# Does not auto-resume or manufacture/consume human decisions.
_workflow_seq_reconcile_interrupted_stages() {
  local registry_run="$1" run_id="$2"
  local stage_file stage_id state attempt reset_count=0
  local loop_iterations completed_waves

  loop_iterations="$(workflow_seq_read_run "$registry_run" | jq -r '.loopIterations // 0')"
  completed_waves="$(workflow_seq_read_run "$registry_run" | jq -r '.completedWaves // 0')"

  shopt -s nullglob
  for stage_file in "$registry_run/engine/stages"/*.json; do
    [[ -f "$stage_file" ]] || continue
    stage_id="$(jq -r '.id // empty' "$stage_file" 2>/dev/null)"
    state="$(jq -r '.state // empty' "$stage_file" 2>/dev/null)"
    attempt="$(jq -r '.attempt // empty' "$stage_file" 2>/dev/null)"
    [[ -n "$stage_id" ]] || continue
    if [[ "$state" == "running" ]]; then
      workflow_seq_write_stage \
        --registry-run "$registry_run" \
        --stage-id "$stage_id" \
        --state stale \
        --event-name stage-reconciled \
        --details-json "$(jq -cn --arg from running \
          '{from:$from,to:"stale",reason:"stale-owner",source:"workflow-seq-recover",retryable:true}')" \
        || true
      reset_count=$((reset_count + 1))
    fi
    if [[ -n "$attempt" && "$attempt" != "null" && "$attempt" != "0" ]] \
      && declare -F workflow_action_revoke_attempt_capability >/dev/null 2>&1; then
      workflow_action_revoke_attempt_capability "$registry_run" "$run_id" "$stage_id" "$attempt" || true
    fi
  done
  shopt -u nullglob

  if declare -F workflow_action_revoke_residual_capabilities >/dev/null 2>&1; then
    workflow_action_revoke_residual_capabilities "$registry_run" "$run_id" || true
  fi

  # Restore persisted wave/loop position; clear live ownership; leave blocked-ready.
  workflow_seq_update_run \
    --registry-run "$registry_run" \
    --state stale \
    --current-stage-ids-json '[]' \
    --loop-iterations "$loop_iterations" \
    --completed-waves "$completed_waves" \
    --owner-json "$(_workflow_seq_null_owner_json)" \
    --event-name recovery-finish \
    --details-json "$(jq -cn --argjson reset "$reset_count" \
      --argjson loop "$loop_iterations" --argjson waves "$completed_waves" \
      '{source:"workflow-seq-recover",stagesMarkedStale:$reset,loopIterations:$loop,completedWaves:$waves}')" \
    --skip-transition-check || true

  printf '%s\n' "$reset_count"
}

# workflow_seq_recover --state-root ... --run-id ... [--workspace ...] [--dry-run]
#
# Internal Sequential recover keyed by the exact common run ID. Reuses production
# PID, process-start identity, hostname, heartbeat threshold, and lock ownership
# checks. Permits mutation only for a proven stale/orphaned supervisor.
# Intentional approval/input waits with no owner are returned unchanged.
workflow_seq_recover() {
  local state_root="" run_id="" workspace="" dry_run=0
  local outer registry_run engine_run run_state owner_json owner_class
  local outstanding request_id kind engine_state supervisor_pid
  local stages next_action result_outcome result_state
  local before_requests before_decisions before_consumed reset_count=0
  local loop_iterations completed_waves lock_live=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_seq_recover argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_seq_recover requires --state-root and --run-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1
  _workflow_seq_source_recovery_libs

  if ! outer="$(workflow_state_read "$state_root" "$run_id" 2>/dev/null)"; then
    echo "Error: workflow_seq_recover unknown run: $run_id" >&2
    return 1
  fi
  run_state="$(printf '%s' "$outer" | jq -r '.state // empty')"
  case "$run_state" in
    cancelled|succeeded)
      echo "Error: workflow_seq_recover refuses terminal run state: $run_state" >&2
      return 1
      ;;
  esac

  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-$state_root}}"
  if ! workflow_seq_engine_active "$registry_run"; then
    echo "Error: workflow_seq_recover requires an active Sequential engine for $run_id" >&2
    return 1
  fi

  engine_run="$(workflow_seq_read_run "$registry_run")" || return 1
  engine_state="$(printf '%s' "$engine_run" | jq -r '.state // empty')"
  owner_json="$(_workflow_seq_effective_owner_json "$registry_run" "$outer")"
  supervisor_pid="$(printf '%s' "$owner_json" | jq -r '.pid // empty')"
  owner_class="$(workflow_seq_classify_owner_json "$owner_json" 2>/dev/null || echo unknown)"
  loop_iterations="$(printf '%s' "$engine_run" | jq -r '.loopIterations // 0')"
  completed_waves="$(printf '%s' "$engine_run" | jq -r '.completedWaves // 0')"

  outstanding="$(workflow_action_first_outstanding "$registry_run" "$run_id" 2>/dev/null || jq -cn '{requestId:null}')"
  request_id="$(printf '%s' "$outstanding" | jq -r '.requestId // empty')"
  kind="$(printf '%s' "$outstanding" | jq -r '.kind // empty')"

  if workflow_state_run_lock_is_live "$state_root" "$run_id" 2>/dev/null; then
    lock_live=1
  fi

  # Intentional approval/input wait with no live owner: unchanged.
  if [[ -n "$request_id" && "$owner_class" != "healthy" && "$owner_class" != "stale" ]]; then
    if [[ "$run_state" == "waiting" || "$engine_state" == "waiting" ]]; then
      next_action="$(jq -cn --arg id "$run_id" \
        '{label:"List workflow actions",argv:["ralph","workflow","actions","list",$id]}')"
      jq -cn \
        --arg runId "$run_id" \
        --arg mode sequential \
        --arg outcome unchanged-intentional-wait \
        --arg runState "$run_state" \
        --arg ownerClass "$owner_class" \
        --argjson outstanding "$outstanding" \
        --argjson nextAction "$next_action" \
        --argjson dryRun "$dry_run" \
        --argjson loopIterations "$loop_iterations" \
        --argjson completedWaves "$completed_waves" \
        '{
          schemaVersion:1, ok:true, dryRun:($dryRun==1), mode:$mode, runId:$runId,
          outcome:$outcome, runState:$runState, ownerClass:$ownerClass,
          mutated:false, outstanding:$outstanding, nextAction:$nextAction,
          retryableStages:[], loopIterations:$loopIterations, completedWaves:$completedWaves,
          note:"intentional approval/input wait is not stale"
        }'
      return 0
    fi
  fi

  if [[ "$owner_class" == "healthy" || "$lock_live" -eq 1 ]]; then
    echo "Error: workflow_seq_recover refuses live-owner run" >&2
    return 1
  fi

  if [[ "$owner_class" == "unknown" ]]; then
    if [[ -n "$supervisor_pid" && "$supervisor_pid" != "null" ]] \
      || [[ "$run_state" == "running" || "$engine_state" == "running" ]]; then
      echo "Error: workflow_seq_recover refuses ambiguous ownership" >&2
      return 1
    fi
  fi

  # Proven stale/orphan, or already-stale engine with no live owner.
  if [[ "$owner_class" != "stale" && "$engine_state" != "stale" && "$run_state" != "stale" ]]; then
    if [[ -n "$supervisor_pid" && "$supervisor_pid" != "null" ]] \
      || [[ "$engine_state" == "running" || "$run_state" == "running" ]]; then
      # Allow recover when there is a running stage but owner is absent (orphaned).
      if [[ "$owner_class" != "absent" ]]; then
        echo "Error: workflow_seq_recover refuses run that is not proven stale/orphaned" >&2
        return 1
      fi
    fi
  fi

  before_requests="$(find "$registry_run/actions/requests" -type f 2>/dev/null | sort | cksum || true)"
  before_decisions="$(find "$registry_run/actions/decisions" -type f 2>/dev/null | sort | cksum || true)"
  before_consumed="$(find "$registry_run/actions/consumed" -type f 2>/dev/null | sort | cksum || true)"

  if [[ "$dry_run" -eq 1 ]]; then
    stages="$(_workflow_seq_collect_retryable_stages "$registry_run")"
    # Preview would also count currently-running stages that become stale.
    local preview_running=0 stage_file
    shopt -s nullglob
    for stage_file in "$registry_run/engine/stages"/*.json; do
      [[ "$(jq -r '.state // empty' "$stage_file" 2>/dev/null)" == "running" ]] && preview_running=$((preview_running + 1))
    done
    shopt -u nullglob
    jq -cn \
      --arg runId "$run_id" \
      --arg ownerClass "$owner_class" \
      --arg engineState "$engine_state" \
      --argjson stages "$stages" \
      --argjson wouldMarkStale "$preview_running" \
      --argjson loopIterations "$loop_iterations" \
      --argjson completedWaves "$completed_waves" \
      '{
        schemaVersion:1, ok:true, dryRun:true, mode:"sequential", runId:$runId,
        outcome:"would-recover", ownerClass:$ownerClass, engineState:$engineState,
        mutated:false, retryableStages:$stages, wouldMarkStale:$wouldMarkStale,
        loopIterations:$loopIterations, completedWaves:$completedWaves,
        preserves:["requests","decisions","consumed","immutable-input","logs","artifacts","attempts","wave-loop-position"]
      }'
    return 0
  fi

  if [[ "$owner_class" == "stale" || "$engine_state" == "running" || "$run_state" == "running" || "$run_state" == "stale" || "$engine_state" == "stale" ]]; then
    reset_count="$(_workflow_seq_reconcile_interrupted_stages "$registry_run" "$run_id")"
    if [[ "$owner_class" == "stale" ]]; then
      result_outcome="recovered-stale-supervisor"
    else
      result_outcome="recovered-orphaned-or-interrupted"
    fi
  else
    workflow_action_revoke_residual_capabilities "$registry_run" "$run_id" || true
    workflow_seq_update_run \
      --registry-run "$registry_run" \
      --state stale \
      --current-stage-ids-json '[]' \
      --loop-iterations "$loop_iterations" \
      --completed-waves "$completed_waves" \
      --owner-json "$(_workflow_seq_null_owner_json)" \
      --event-name recovery-finish \
      --details-json '{"source":"workflow-seq-recover","reason":"orphaned"}' \
      --skip-transition-check || true
    result_outcome="recovered-orphaned-or-interrupted"
  fi

  workflow_action_revoke_residual_capabilities "$registry_run" "$run_id" || true

  if [[ "$(find "$registry_run/actions/requests" -type f 2>/dev/null | sort | cksum || true)" != "$before_requests" ]] \
    || [[ "$(find "$registry_run/actions/decisions" -type f 2>/dev/null | sort | cksum || true)" != "$before_decisions" ]] \
    || [[ "$(find "$registry_run/actions/consumed" -type f 2>/dev/null | sort | cksum || true)" != "$before_consumed" ]]; then
    echo "Error: workflow_seq_recover must preserve request/decision/consumption records" >&2
    return 1
  fi

  # Re-read preserved wave/loop position after reconcile.
  loop_iterations="$(workflow_seq_read_run "$registry_run" | jq -r '.loopIterations // 0')"
  completed_waves="$(workflow_seq_read_run "$registry_run" | jq -r '.completedWaves // 0')"

  outstanding="$(workflow_action_first_outstanding "$registry_run" "$run_id" 2>/dev/null || jq -cn '{requestId:null}')"
  request_id="$(printf '%s' "$outstanding" | jq -r '.requestId // empty')"
  if [[ -n "$request_id" ]]; then
    result_state="waiting"
    next_action="$(jq -cn --arg id "$run_id" \
      '{label:"List workflow actions",argv:["ralph","workflow","actions","list",$id]}')"
    workflow_seq_update_run \
      --registry-run "$registry_run" \
      --state waiting \
      --owner-json "$(_workflow_seq_null_owner_json)" \
      --loop-iterations "$loop_iterations" \
      --completed-waves "$completed_waves" \
      --event-name run-status-changed \
      --details-json '{"reason":"recover-outstanding-action"}' \
      --skip-transition-check || true
    workflow_state_clear_owner_and_set_state "$state_root" "$run_id" waiting || return 1
  else
    result_state="blocked"
    next_action="$(jq -cn --arg id "$run_id" \
      '{label:"Resume workflow",argv:["ralph","workflow","resume",$id]}')"
    workflow_seq_update_run \
      --registry-run "$registry_run" \
      --state blocked \
      --owner-json "$(_workflow_seq_null_owner_json)" \
      --loop-iterations "$loop_iterations" \
      --completed-waves "$completed_waves" \
      --event-name run-status-changed \
      --details-json '{"reason":"recover-blocked-ready"}' \
      --skip-transition-check || true
    workflow_state_clear_owner_and_set_state "$state_root" "$run_id" blocked || return 1
  fi

  stages="$(_workflow_seq_collect_retryable_stages "$registry_run")"

  jq -cn \
    --arg runId "$run_id" \
    --arg outcome "$result_outcome" \
    --arg runState "$result_state" \
    --arg ownerClass "$owner_class" \
    --argjson stages "$stages" \
    --argjson outstanding "$outstanding" \
    --argjson nextAction "$next_action" \
    --argjson loopIterations "$loop_iterations" \
    --argjson completedWaves "$completed_waves" \
    --argjson stagesMarkedStale "${reset_count:-0}" \
    '{
      schemaVersion:1, ok:true, dryRun:false, mode:"sequential", runId:$runId,
      outcome:$outcome, runState:$runState, ownerClass:$ownerClass,
      mutated:true, autoReran:false, manufacturedDecision:false,
      outstanding:$outstanding, nextAction:$nextAction, retryableStages:$stages,
      loopIterations:$loopIterations, completedWaves:$completedWaves,
      stagesMarkedStale:$stagesMarkedStale,
      preserves:["requests","decisions","consumed","immutable-input","logs","artifacts","attempts","wave-loop-position"]
    }'
  return 0
}

# workflow_seq_cancel --state-root ... --run-id ... [--workspace ...] [--dry-run]
#
# Cancel a proven owned live Sequential supervisor, or a non-running cancellable
# Sequential run. Persist cancel intent before TERM so the supervisor signal
# handler records cancelled (never retryable waiting). Revokes capabilities,
# cancels outstanding actions without deletion, retains TERM/KILL timing via
# ralph_kill_tree, appends sequential audit events, and returns a normalized
# outer transition.
workflow_seq_cancel() {
  local state_root="" run_id="" workspace="" dry_run=0
  local outer registry_run engine_run run_state owner_json owner_class
  local live_proof supervisor_pid intent_path engine_state outstanding
  local loop_iterations completed_waves

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --workspace) workspace="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *)
        echo "Error: unknown workflow_seq_cancel argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_seq_cancel requires --state-root and --run-id" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || return 1
  _workflow_seq_source_recovery_libs

  if ! outer="$(workflow_state_read "$state_root" "$run_id" 2>/dev/null)"; then
    echo "Error: workflow_seq_cancel unknown run: $run_id" >&2
    return 1
  fi
  run_state="$(printf '%s' "$outer" | jq -r '.state // empty')"
  case "$run_state" in
    cancelled|succeeded)
      echo "Error: workflow_seq_cancel refuses terminal run state: $run_state" >&2
      return 1
      ;;
  esac

  registry_run="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  workspace="${workspace:-${RALPH_AGENT_WORKSPACE:-$state_root}}"
  if ! workflow_seq_engine_active "$registry_run"; then
    echo "Error: workflow_seq_cancel requires an active Sequential engine for $run_id" >&2
    return 1
  fi

  engine_run="$(workflow_seq_read_run "$registry_run")" || return 1
  engine_state="$(printf '%s' "$engine_run" | jq -r '.state // empty')"
  owner_json="$(_workflow_seq_effective_owner_json "$registry_run" "$outer")"
  supervisor_pid="$(printf '%s' "$owner_json" | jq -r '.pid // empty')"
  loop_iterations="$(printf '%s' "$engine_run" | jq -r '.loopIterations // 0')"
  completed_waves="$(printf '%s' "$engine_run" | jq -r '.completedWaves // 0')"

  owner_class="$(workflow_seq_classify_owner_json "$owner_json" 2>/dev/null || echo unknown)"
  live_proof="not-live"
  if [[ "$owner_class" == "healthy" ]]; then
    live_proof="$(workflow_seq_live_owner_matches "$owner_json" 2>/dev/null || echo not-live)"
  fi

  if [[ "$owner_class" == "healthy" && "$live_proof" != "owned" ]]; then
    echo "Error: workflow_seq_cancel refuses ambiguous or foreign live ownership" >&2
    return 1
  fi

  if [[ "$owner_class" == "unknown" && ( "$run_state" == "running" || "$engine_state" == "running" ) ]]; then
    echo "Error: workflow_seq_cancel refuses ambiguous ownership on running run" >&2
    return 1
  fi

  if [[ "$live_proof" != "owned" ]]; then
    case "$run_state" in
      waiting|blocked|stale|failed|queued) ;;
      running)
        if [[ "$owner_class" != "stale" && "$engine_state" != "stale" ]]; then
          echo "Error: workflow_seq_cancel refuses unproven running ownership" >&2
          return 1
        fi
        ;;
      *)
        echo "Error: workflow_seq_cancel refuses run state: $run_state" >&2
        return 1
        ;;
    esac
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    jq -cn \
      --arg runId "$run_id" \
      --arg ownerClass "$owner_class" \
      --arg liveProof "$live_proof" \
      --arg engineState "$engine_state" \
      '{
        schemaVersion:1, ok:true, dryRun:true, mode:"sequential", runId:$runId,
        outcome:"would-cancel", ownerClass:$ownerClass, liveProof:$liveProof,
        engineState:$engineState, mutated:false
      }'
    return 0
  fi

  # Persist cancel intent BEFORE signalling so the supervisor handler records
  # cancelled rather than retryable waiting.
  intent_path="$(workflow_state_record_cancel_intent "$registry_run" "$(jq -cn \
    --arg runId "$run_id" \
    --arg source "workflow-seq-cancel" \
    --arg liveProof "$live_proof" \
    '{runId:$runId,source:$source,liveProof:$liveProof}')" 2>/dev/null || true)"

  workflow_action_revoke_residual_capabilities "$registry_run" "$run_id" || true
  workflow_action_cancel_outstanding "$registry_run" "$run_id" || true

  workflow_seq_update_run \
    --registry-run "$registry_run" \
    --state cancelled \
    --current-stage-ids-json '[]' \
    --loop-iterations "$loop_iterations" \
    --completed-waves "$completed_waves" \
    --owner-json "$(_workflow_seq_null_owner_json)" \
    --event-name run-status-changed \
    --details-json "$(jq -cn --arg from "$engine_state" --arg live "$live_proof" \
      '{from:$from,to:"cancelled",source:"workflow-seq-cancel",liveProof:$live}')" \
    --skip-transition-check || true

  if [[ "$live_proof" == "owned" && "$supervisor_pid" =~ ^[0-9]+$ ]]; then
    # Retain existing TERM-then-KILL timing (ralph_process_term_kill_tree /
    # ralph_kill_tree). Cancel intent was persisted above.
    if declare -F ralph_process_term_kill_tree >/dev/null 2>&1; then
      ralph_process_term_kill_tree "$supervisor_pid" || true
    else
      ralph_kill_tree "$supervisor_pid" || true
    fi
  fi

  workflow_state_clear_owner_and_set_state "$state_root" "$run_id" cancelled || return 1
  outstanding="$(workflow_action_first_outstanding "$registry_run" "$run_id" 2>/dev/null || jq -cn '{requestId:null}')"

  jq -cn \
    --arg runId "$run_id" \
    --arg liveProof "$live_proof" \
    --arg intentPath "${intent_path:-}" \
    --argjson outstanding "$outstanding" \
    '{
      schemaVersion:1, ok:true, dryRun:false, mode:"sequential", runId:$runId,
      outcome:"cancelled", runState:"cancelled", liveProof:$liveProof,
      cancelIntentPath:(if $intentPath=="" then null else $intentPath end),
      outstanding:$outstanding, mutated:true,
      nextAction:null
    }'
  return 0
}

# workflow_seq_recover_by_run_id / workflow_seq_cancel_by_run_id
# Thin aliases matching the resume/reset_by_run_id naming convention.
workflow_seq_recover_by_run_id() {
  workflow_seq_recover "$@"
}

workflow_seq_cancel_by_run_id() {
  workflow_seq_cancel "$@"
}
