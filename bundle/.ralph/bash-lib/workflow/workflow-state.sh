#!/usr/bin/env bash
# Outer workflow-run registry storage under <state-root>/workflow-runs/<run-id>/.
#
# Responsibilities for this module (create/read/validate/update/list/import/
# materialize-generated-plan / bind-generated-plan-control):
#   - Resolve the durable state root without cwd assumptions after paths are set
#   - Mint filesystem-safe run IDs (same algorithm as graph_state_mint_run_id)
#   - Create task/plan entries under .create.lock with collision retry
#   - Byte-copy immutable workflow input (input.orch.json | input.plan.md)
#   - Store nullable already-validated inputPlan metadata at create time
#   - Import a provided leaf plan into plans/input/{source.plan.md,manifest.json}
#   - Materialize planner-output JSON into immutable attempt-scoped plan+manifest
#   - Bind a planFrom consumer to a validated immutable source + mutable control copy
#   - Bind a planInput (provided) consumer to the frozen input source + mutable control
#   - Update run.json via per-run .lock + temp-file rename
#   - Refuse symlink escapes outside the state root
#
# Does not invoke engines or inspect feature gates.

if [[ -n "${RALPH_WORKFLOW_STATE_LOADED:-}" ]]; then
  return 0
fi
RALPH_WORKFLOW_STATE_LOADED=1

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

_WORKFLOW_STATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$_WORKFLOW_STATE_SCRIPT_DIR/../atomic-json.sh"
fi

if ! declare -F ralph_wait >/dev/null 2>&1; then
  # shellcheck source=../ralph-wait.sh
  source "$_WORKFLOW_STATE_SCRIPT_DIR/../ralph-wait.sh"
fi

# Reuse graph mint/time/owner helpers when already loaded; otherwise provide the
# same algorithms locally so this module does not pay for sourcing graph-state.sh.
if ! declare -F graph_state_mint_run_id >/dev/null 2>&1; then
  graph_state_mint_run_id() {
    local ts ns rand
    if [[ -n "${GRAPH_STATE_FIXED_RUN_ID:-}" ]]; then
      printf '%s\n' "$GRAPH_STATE_FIXED_RUN_ID"
      return 0
    fi
    ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)"
    ns="$(date +%N 2>/dev/null | tr -d '0-9' | head -c1)"
    [[ -z "$ns" ]] && ns="0"
    rand="$(mktemp -u XXXXXX 2>/dev/null)" || rand="$$"
    printf 'run-%s-%s-%s\n' "$ts" "$ns" "$rand"
  }
fi

if ! declare -F graph_state_now_iso >/dev/null 2>&1; then
  graph_state_now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ
  }
fi

if ! declare -F graph_state_supervisor_pid >/dev/null 2>&1; then
  graph_state_supervisor_pid() {
    if [[ -n "${GRAPH_STATE_SUPERVISOR_PID:-}" ]]; then
      printf '%s\n' "$GRAPH_STATE_SUPERVISOR_PID"
      return 0
    fi
    printf '%s\n' "$$"
  }
fi

if ! declare -F graph_state_owner_hostname >/dev/null 2>&1; then
  graph_state_owner_hostname() {
    if [[ -n "${GRAPH_STATE_OWNER_HOSTNAME:-}" ]]; then
      printf '%s\n' "$GRAPH_STATE_OWNER_HOSTNAME"
      return 0
    fi
    if command -v hostname >/dev/null 2>&1; then
      hostname 2>/dev/null || true
    fi
  }
fi

if ! declare -F graph_state_owner_process_start_id >/dev/null 2>&1; then
  graph_state_owner_process_start_id() {
    if [[ -n "${GRAPH_STATE_OWNER_PROCESS_START_ID:-}" ]]; then
      printf '%s\n' "$GRAPH_STATE_OWNER_PROCESS_START_ID"
      return 0
    fi
    local pid start
    pid="${GRAPH_STATE_SUPERVISOR_PID:-$$}"
    [[ -z "$pid" ]] && return 0
    start=""
    if [[ -d "/proc/$pid" ]] && command -v stat >/dev/null 2>&1; then
      start="$(stat -c %Z "/proc/$pid" 2>/dev/null || stat -f %B "/proc/$pid" 2>/dev/null)"
    fi
    if [[ -z "$start" ]] && command -v ps >/dev/null 2>&1; then
      start="$(ps -o lstart= -p "$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | head -n1)"
    fi
    printf '%s\n' "$start"
  }
fi

if ! declare -F graph_state_heartbeat_now >/dev/null 2>&1; then
  graph_state_heartbeat_now() {
    if [[ -n "${GRAPH_STATE_HEARTBEAT_AT:-}" ]]; then
      printf '%s\n' "$GRAPH_STATE_HEARTBEAT_AT"
      return 0
    fi
    graph_state_now_iso
  }
fi

_workflow_state_fsync() {
  if [[ "${WORKFLOW_STATE_SKIP_FSYNC:-0}" == "1" ]]; then
    return 0
  fi
  ralph_fsync_path "$@"
}

# Atomic JSON write that honors WORKFLOW_STATE_SKIP_FSYNC for fast tests.
_workflow_state_atomic_write_json() {
  local target_path="$1"; shift
  local jq_filter="$1"; shift
  local target_dir tmp_file
  if [[ "${WORKFLOW_STATE_SKIP_FSYNC:-0}" != "1" ]]; then
    ralph_atomic_write_json "$target_path" "$jq_filter" "$@"
    return $?
  fi
  command -v jq >/dev/null 2>&1 || return 1
  target_dir="$(dirname "$target_path")"
  tmp_file="$(mktemp "$target_dir/.atomic-json-XXXXXX" 2>/dev/null)" || return 1
  if ! jq -n "$jq_filter" "$@" > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$tmp_file" "$target_path" 2>/dev/null; then
    rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
  return 0
}

WORKFLOW_STATE_PUBLIC_STATES=(
  queued running waiting blocked stale failed cancelled succeeded
)
WORKFLOW_STATE_SOURCE_KINDS=(
  project global bundled file legacy-orchestration
)
WORKFLOW_STATE_TASK_PROVENANCES=(
  explicit workflow plan-overview plan-filename task-file
)
WORKFLOW_STATE_LOCK_TIMEOUT_SECS="${WORKFLOW_STATE_LOCK_TIMEOUT_SECS:-30}"
WORKFLOW_STATE_CREATE_COLLISION_RETRIES="${WORKFLOW_STATE_CREATE_COLLISION_RETRIES:-8}"

# ---------------------------------------------------------------------------
# Path / containment helpers
# ---------------------------------------------------------------------------

_workflow_state_abs_path() {
  local path="${1:-}"
  local parent base abs_parent
  [[ -n "$path" ]] || return 1
  path="${path%/}"
  if [[ "$path" != /* ]]; then
    path="$(pwd -P)/$path"
  fi
  parent="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  if [[ -d "$parent" ]]; then
    abs_parent="$(cd -- "$parent" && pwd -P)" || return 1
    printf '%s/%s\n' "$abs_parent" "$base"
  else
    printf '%s\n' "$path"
  fi
}

_workflow_state_real_dir() {
  local path="$1"
  [[ -n "$path" && -d "$path" ]] || return 1
  (cd "$path" 2>/dev/null && pwd -P)
}

_workflow_state_is_within() {
  local parent="$1" child="$2"
  [[ -n "$parent" && -n "$child" ]] || return 1
  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

_workflow_state_has_dotdot() {
  local path="$1" rest component
  rest="$path"
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"
    if [[ "$component" == ".." ]]; then
      return 0
    fi
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
  done
  return 1
}

# workflow_state_state_root [workspace]
# Exact override: RALPH_WORKFLOW_STATE_ROOT, then RALPH_PLAN_WORKSPACE_ROOT,
# else <workspace>/.ralph-workspace. Workspace is required when neither override
# is set. Relative workspace values are absolutized once here.
workflow_state_state_root() {
  local workspace="${1:-}"
  if [[ -n "${RALPH_WORKFLOW_STATE_ROOT:-}" ]]; then
    _workflow_state_abs_path "${RALPH_WORKFLOW_STATE_ROOT}"
    return $?
  fi
  if [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    _workflow_state_abs_path "${RALPH_PLAN_WORKSPACE_ROOT}"
    return $?
  fi
  if [[ -z "$workspace" ]]; then
    echo "Error: workflow_state_state_root requires a workspace when no state-root override is set" >&2
    return 1
  fi
  workspace="$(_workflow_state_abs_path "$workspace")" || return 1
  printf '%s/.ralph-workspace\n' "${workspace%/}"
}

# workflow_state_runs_root <state_root>
workflow_state_runs_root() {
  local state_root="${1:-}"
  [[ -n "$state_root" ]] || {
    echo "Error: workflow_state_runs_root requires state_root" >&2
    return 1
  }
  state_root="$(_workflow_state_abs_path "$state_root")" || return 1
  printf '%s/workflow-runs\n' "${state_root%/}"
}

# workflow_state_ensure_state_root <state_root>
# Physicalize and ensure the state root exists. Refuses when a path component
# is a symlink that escapes the resolved state root's parent tree after mkdir.
workflow_state_ensure_state_root() {
  local state_root="${1:-}" real
  [[ -n "$state_root" ]] || return 1
  state_root="$(_workflow_state_abs_path "$state_root")" || return 1
  mkdir -p "$state_root" || {
    echo "Error: failed to create state root: $state_root" >&2
    return 1
  }
  real="$(_workflow_state_real_dir "$state_root")" || {
    echo "Error: state root is not a usable directory: $state_root" >&2
    return 1
  }
  printf '%s\n' "$real"
}

# workflow_state_resolve_under_state_root <state_root> <relative-path>
# Containment helper. Never follows a symlink that leaves the state root.
workflow_state_resolve_under_state_root() {
  local state_root="${1:-}" rel="${2:-}"
  local root_real current rest component next resolved_dir target

  [[ -n "$state_root" && -n "$rel" ]] || {
    echo "Error: workflow_state_resolve_under_state_root requires state_root and relative path" >&2
    return 1
  }
  if [[ "$rel" == /* ]]; then
    echo "Error: path must be relative to the state root: $rel" >&2
    return 1
  fi
  if _workflow_state_has_dotdot "$rel"; then
    echo "Error: path may not contain '..': $rel" >&2
    return 1
  fi

  root_real="$(workflow_state_ensure_state_root "$state_root")" || return 1
  current="$root_real"
  rest="$rel"
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"
    if [[ "$rest" == */* ]]; then
      rest="${rest#*/}"
    else
      rest=""
    fi
    if [[ -z "$component" || "$component" == "." || "$component" == ".." ]]; then
      echo "Error: path has an illegal component: $rel" >&2
      return 1
    fi
    next="$current/$component"
    if [[ -L "$next" ]]; then
      if [[ -d "$next" ]]; then
        resolved_dir="$(_workflow_state_real_dir "$next")" || {
          echo "Error: symlink is not a usable directory: $rel" >&2
          return 1
        }
        if ! _workflow_state_is_within "$root_real" "$resolved_dir"; then
          echo "Error: path escapes the state root via symlink: $rel" >&2
          return 1
        fi
        current="$resolved_dir"
      else
        target="$(readlink "$next" 2>/dev/null || true)"
        if [[ -z "$target" || "$target" == /* ]] || _workflow_state_has_dotdot "$target"; then
          echo "Error: path escapes the state root via symlink: $rel" >&2
          return 1
        fi
        resolved_dir="$(_workflow_state_real_dir "$(dirname -- "$next")")" || return 1
        if ! _workflow_state_is_within "$root_real" "$resolved_dir"; then
          echo "Error: path escapes the state root via symlink: $rel" >&2
          return 1
        fi
        current="$next"
      fi
    elif [[ -d "$next" ]]; then
      resolved_dir="$(_workflow_state_real_dir "$next")" || return 1
      if ! _workflow_state_is_within "$root_real" "$resolved_dir"; then
        echo "Error: path escapes the state root via symlink: $rel" >&2
        return 1
      fi
      current="$resolved_dir"
    else
      current="$next"
    fi
  done

  if ! _workflow_state_is_within "$root_real" "$current" \
    && ! _workflow_state_is_within "$root_real" "$(dirname -- "$current")"; then
    echo "Error: path is not contained in the state root: $rel" >&2
    return 1
  fi
  printf '%s\n' "$current"
}

# workflow_state_run_dir <state_root> <run_id>
workflow_state_run_dir() {
  local state_root="${1:-}" run_id="${2:-}"
  [[ -n "$state_root" && -n "$run_id" ]] || {
    echo "Error: workflow_state_run_dir requires state_root and run_id" >&2
    return 1
  }
  case "$run_id" in
    */*|*\\*|*".."*|.*|"")
      echo "Error: invalid run id: $run_id" >&2
      return 1
      ;;
  esac
  workflow_state_resolve_under_state_root "$state_root" "workflow-runs/$run_id"
}

# workflow_state_run_file <state_root> <run-id>
workflow_state_run_file() {
  local run_dir
  run_dir="$(workflow_state_run_dir "$@")" || return 1
  printf '%s/run.json\n' "$run_dir"
}

# workflow_state_export_operator_input_identity
#   --registry-run --run-id --stage-id --attempt-id
# Exports common run/stage/attempt identity for OPERATOR_INPUT capability binding.
# Does not mint or print a capability nonce.
workflow_state_export_operator_input_identity() {
  local registry_run="" run_id="" stage_id="" attempt_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --stage-id) stage_id="${2:-}"; shift 2 ;;
      --attempt-id) attempt_id="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_state_export_operator_input_identity argument: $1" >&2
        return 1
        ;;
    esac
  done
  [[ -n "$registry_run" && -d "$registry_run" && -n "$run_id" && -n "$stage_id" && -n "$attempt_id" ]] || {
    echo "Error: workflow_state_export_operator_input_identity requires registry-run run-id stage-id attempt-id" >&2
    return 1
  }
  export RALPH_WORKFLOW_REGISTRY_RUN="$registry_run"
  export RALPH_WORKFLOW_RUN_ID="$run_id"
  export RALPH_WORKFLOW_STAGE_ID="$stage_id"
  export RALPH_WORKFLOW_STAGE_ATTEMPT="$attempt_id"
}

# workflow_state_create_lock_path <state_root>
workflow_state_create_lock_path() {
  local state_root="${1:-}"
  workflow_state_resolve_under_state_root "$state_root" "workflow-runs/.create.lock"
}

# workflow_state_update_lock_path <state_root> <run_id>
workflow_state_update_lock_path() {
  local run_dir
  run_dir="$(workflow_state_run_dir "$@")" || return 1
  printf '%s/.lock\n' "$run_dir"
}

# ---------------------------------------------------------------------------
# Time / owner / mint
# ---------------------------------------------------------------------------

workflow_state_now_iso() {
  if [[ -n "${WORKFLOW_STATE_FIXED_NOW:-}" ]]; then
    printf '%s\n' "$WORKFLOW_STATE_FIXED_NOW"
    return 0
  fi
  graph_state_now_iso
}

workflow_state_mint_run_id() {
  local next
  if [[ -n "${WORKFLOW_STATE_MINT_SEQUENCE_FILE:-}" && -f "${WORKFLOW_STATE_MINT_SEQUENCE_FILE}" ]]; then
    next="$(head -n1 "${WORKFLOW_STATE_MINT_SEQUENCE_FILE}" 2>/dev/null || true)"
    if [[ -n "$next" ]]; then
      # Drop the consumed line without requiring GNU sed -i.
      { tail -n +2 "${WORKFLOW_STATE_MINT_SEQUENCE_FILE}" 2>/dev/null || true; } >"${WORKFLOW_STATE_MINT_SEQUENCE_FILE}.tmp" \
        && mv -f "${WORKFLOW_STATE_MINT_SEQUENCE_FILE}.tmp" "${WORKFLOW_STATE_MINT_SEQUENCE_FILE}"
      printf '%s\n' "$next"
      return 0
    fi
  fi
  if [[ -n "${WORKFLOW_STATE_FIXED_RUN_ID:-}" ]]; then
    printf '%s\n' "$WORKFLOW_STATE_FIXED_RUN_ID"
    return 0
  fi
  graph_state_mint_run_id
}

_workflow_state_owner_json() {
  local pid hostname start_id heartbeat
  if [[ -n "${WORKFLOW_STATE_OWNER_JSON:-}" ]]; then
    printf '%s\n' "$WORKFLOW_STATE_OWNER_JSON"
    return 0
  fi
  pid="$(graph_state_supervisor_pid)"
  hostname="$(graph_state_owner_hostname)"
  start_id="$(graph_state_owner_process_start_id)"
  heartbeat="$(graph_state_heartbeat_now)"
  jq -cn \
    --argjson pid "$( [[ "$pid" =~ ^[0-9]+$ ]] && printf '%s' "$pid" || printf 'null' )" \
    --arg hostname "$hostname" \
    --arg processStartId "$start_id" \
    --arg heartbeatAt "$heartbeat" \
    '{
      pid: $pid,
      hostname: (if $hostname == "" then null else $hostname end),
      processStartId: (if $processStartId == "" then null else $processStartId end),
      heartbeatAt: (if $heartbeatAt == "" then null else $heartbeatAt end)
    }'
}

_workflow_state_owner_pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

_workflow_state_lock_is_stale() {
  local lock_path="$1"
  local owner_file pid start_id current_start
  owner_file="$lock_path/owner.json"
  [[ -f "$owner_file" ]] || return 0
  pid="$(jq -r '.pid // empty' "$owner_file" 2>/dev/null || true)"
  start_id="$(jq -r '.processStartId // empty' "$owner_file" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    return 0
  fi
  if ! _workflow_state_owner_pid_alive "$pid"; then
    return 0
  fi
  if [[ -n "$start_id" ]]; then
    current_start="$(
      GRAPH_STATE_SUPERVISOR_PID="$pid" graph_state_owner_process_start_id 2>/dev/null || true
    )"
    if [[ -n "$current_start" && "$current_start" != "$start_id" ]]; then
      return 0
    fi
  fi
  return 1
}

_workflow_state_lock_force_remove() {
  local lock_path="$1"
  rm -f "$lock_path/owner.json" 2>/dev/null || true
  rmdir "$lock_path" 2>/dev/null || true
  # Last resort if a non-dir lock file was left behind.
  [[ -e "$lock_path" ]] && rm -rf "$lock_path" 2>/dev/null || true
}

# Directory lock with owner metadata (graph-style mkdir lock + stale reclaim for
# dead pid / process-start mismatch). Kept in-process so sourced callers can
# hold the lock across multi-step create/update work without exec/flock fd games.
_workflow_state_acquire_lock() {
  local lock_path="$1"
  local parent owner_json deadline now
  parent="$(dirname -- "$lock_path")"
  mkdir -p "$parent" || return 1

  deadline=$(( $(date +%s) + WORKFLOW_STATE_LOCK_TIMEOUT_SECS ))
  while true; do
    if mkdir "$lock_path" 2>/dev/null; then
      owner_json="$(_workflow_state_owner_json)" || owner_json='{}'
      printf '%s\n' "$owner_json" >"$lock_path/owner.json" || {
        _workflow_state_lock_force_remove "$lock_path"
        return 1
      }
      return 0
    fi
    if _workflow_state_lock_is_stale "$lock_path"; then
      _workflow_state_lock_force_remove "$lock_path"
      continue
    fi
    now="$(date +%s)"
    if [[ "$now" -ge "$deadline" ]]; then
      echo "Error: timeout acquiring lock: $lock_path" >&2
      return 1
    fi
    ralph_wait 1
  done
}

_workflow_state_release_lock() {
  local lock_path="$1"
  _workflow_state_lock_force_remove "$lock_path"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

_workflow_state_enum_member() {
  local value="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$value" ]] && return 0
  done
  return 1
}

_workflow_state_is_abs_path() {
  [[ "${1:-}" == /* && "${1:-}" != *'..'* ]]
}

_workflow_state_is_iso_ts() {
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# workflow_state_validate_run_json <path>
# Structural validation matching workflow-run.schema.json. Prints nothing on
# success. Distinguishes missing vs corrupt entry in the error text.
workflow_state_validate_run_json() {
  local path="${1:-}" json
  [[ -n "$path" ]] || {
    echo "Error: workflow_state_validate_run_json requires a path" >&2
    return 1
  }
  if [[ ! -e "$path" ]]; then
    echo "Error: missing run entry: $path" >&2
    return 1
  fi
  if [[ -L "$path" ]]; then
    echo "Error: refusing to validate run.json through a symlink: $path" >&2
    return 1
  fi
  if [[ ! -f "$path" ]]; then
    echo "Error: corrupt run entry (not a file): $path" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to validate run.json" >&2
    return 1
  }
  if ! json="$(jq -c . "$path" 2>/dev/null)"; then
    echo "Error: corrupt run entry (invalid JSON): $path" >&2
    return 1
  fi

  local ok
  ok="$(printf '%s' "$json" | jq -r '
    def abs: type == "string" and startswith("/") and (contains("..") | not);
    def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def sha: type == "string" and test("^[a-f0-9]{64}$");
    def nonneg: type == "number" and . >= 0 and (. == floor);
    (
      type == "object"
      and (.runId | type == "string" and length > 0)
      and ((.workflowId == null) or (.workflowId | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$")))
      and (.sourcePath | abs)
      and (.sourceKind | IN("project","global","bundled","file","legacy-orchestration"))
      and (.mode | IN("sequential","dependency"))
      and (.entryKind | IN("task","plan"))
      and (.task | type == "string" and length > 0)
      and (.taskProvenance | IN("explicit","workflow","plan-overview","plan-filename","task-file"))
      and (.inputPath | abs)
      and (.state | IN("queued","running","waiting","blocked","stale","failed","cancelled","succeeded"))
      and (.createdAt | iso)
      and (.updatedAt | iso)
      and (
        .owner == null
        or (
          (.owner | type) == "object"
          and (.owner | has("pid") and has("hostname") and has("processStartId") and has("heartbeatAt"))
          and ((.owner.pid == null) or ((.owner.pid | type) == "number"))
          and ((.owner.hostname == null) or ((.owner.hostname | type) == "string"))
          and ((.owner.processStartId == null) or ((.owner.processStartId | type) == "string"))
          and ((.owner.heartbeatAt == null) or (.owner.heartbeatAt | iso))
        )
      )
      and (
        .engine == null
        or (
          (.engine | type) == "object"
          and (.engine.kind | IN("orchestration","graph"))
          and (.engine.statePath | abs)
          and ((.engine.namespace == null) or ((.engine.namespace | type) == "string" and (.engine.namespace | length) > 0))
        )
      )
      and (
        .inputPlan == null
        or (
          (.inputPlan | type) == "object"
          and (.inputPlan.originalPath | abs)
          and (.inputPlan.sourcePath | abs)
          and (.inputPlan.manifestPath | abs)
          and (.inputPlan.sha256 | sha)
          and (.inputPlan.format | IN("classic","yaml"))
          and (.inputPlan.totalTodos | nonneg)
          and (.inputPlan.completedTodos | nonneg)
          and (.inputPlan.openTodos | nonneg)
        )
      )
      and (
        (.entryKind == "task" and .inputPlan == null)
        or (.entryKind == "plan")
      )
    ) | if . then "ok" else "bad" end
  ' 2>/dev/null)" || ok="bad"

  if [[ "$ok" != "ok" ]]; then
    echo "Error: corrupt run entry (schema mismatch): $path" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Create / read / update / list
# ---------------------------------------------------------------------------

_workflow_state_input_basename_for_mode() {
  case "${1:-}" in
    sequential) printf 'input.orch.json\n' ;;
    dependency) printf 'input.plan.md\n' ;;
    *)
      echo "Error: unsupported mode for input copy: ${1:-}" >&2
      return 1
      ;;
  esac
}

_workflow_state_default_engine_json() {
  local mode="$1" state_root="$2" run_id="$3" namespace="${4:-}"
  local run_dir state_path kind
  run_dir="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  case "$mode" in
    sequential)
      kind="orchestration"
      state_path="$run_dir/engine"
      namespace=""
      ;;
    dependency)
      kind="graph"
      [[ -n "$namespace" ]] || namespace="workflow"
      state_path="$(workflow_state_ensure_state_root "$state_root")/graph-runs/$namespace/$run_id"
      ;;
    *)
      return 1
      ;;
  esac
  jq -cn \
    --arg kind "$kind" \
    --arg statePath "$state_path" \
    --arg namespace "$namespace" \
    '{
      kind: $kind,
      statePath: $statePath,
      namespace: (if $namespace == "" then null else $namespace end)
    }'
}

_workflow_state_copy_immutable_input() {
  local src="$1" dest="$2"
  local dest_dir tmp
  [[ -f "$src" && ! -L "$src" ]] || {
    echo "Error: workflow input source must be a regular non-symlink file: $src" >&2
    return 1
  }
  dest_dir="$(dirname -- "$dest")"
  mkdir -p "$dest_dir" || return 1
  if [[ -e "$dest" ]]; then
    echo "Error: immutable workflow input already exists: $dest" >&2
    return 1
  fi
  tmp="$(mktemp "$dest_dir/.input-XXXXXX")" || return 1
  if ! cp "$src" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  _workflow_state_fsync "$tmp"
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  _workflow_state_fsync "$dest_dir"
  chmod a-w "$dest" 2>/dev/null || true
  return 0
}

# workflow_state_create --state-root ... --source-path ... --source-kind ...
#   --mode ... --entry-kind ... --task ... --task-provenance ... --input-file ...
#   [--workflow-id ...] [--input-plan-json ...] [--engine-json ...]
#   [--engine-namespace ...] [--owner-json ...] [--state queued]
#
# Prints the minted run id on stdout. Stores already-validated inputPlan JSON
# when provided; does not publish plans/input/source.plan.md (use
# workflow_state_import_provided_plan).
workflow_state_create() {
  local state_root="" source_path="" source_kind="" mode="" entry_kind=""
  local task="" task_provenance="" task_file="" input_file="" workflow_id=""
  local input_plan_json="null" engine_json="" engine_namespace=""
  local owner_json="null" state="queued"
  local runs_root lock_path run_id run_dir run_file input_name input_path
  local now attempt=0 created=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --source-path) source_path="${2:-}"; shift 2 ;;
      --source-kind) source_kind="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --entry-kind) entry_kind="${2:-}"; shift 2 ;;
      --task) task="${2:-}"; shift 2 ;;
      --task-provenance) task_provenance="${2:-}"; shift 2 ;;
      --task-file) task_file="${2:-}"; shift 2 ;;
      --input-file) input_file="${2:-}"; shift 2 ;;
      --workflow-id) workflow_id="${2:-}"; shift 2 ;;
      --input-plan-json) input_plan_json="${2:-}"; shift 2 ;;
      --engine-json) engine_json="${2:-}"; shift 2 ;;
      --engine-namespace) engine_namespace="${2:-}"; shift 2 ;;
      --owner-json) owner_json="${2:-}"; shift 2 ;;
      --state) state="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_state_create argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$state_root" && -n "$source_path" && -n "$source_kind" && -n "$mode" \
    && -n "$entry_kind" && -n "$task" && -n "$task_provenance" && -n "$input_file" ]] || {
    echo "Error: workflow_state_create requires --state-root --source-path --source-kind --mode --entry-kind --task --task-provenance --input-file" >&2
    return 1
  }

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for workflow_state_create" >&2
    return 1
  }

  state_root="$(workflow_state_ensure_state_root "$state_root")" || return 1
  source_path="$(_workflow_state_abs_path "$source_path")" || return 1
  input_file="$(_workflow_state_abs_path "$input_file")" || return 1

  _workflow_state_enum_member "$source_kind" "${WORKFLOW_STATE_SOURCE_KINDS[@]}" || {
    echo "Error: invalid sourceKind: $source_kind" >&2
    return 1
  }
  case "$mode" in sequential|dependency) ;; *)
    echo "Error: invalid mode: $mode" >&2
    return 1
  esac
  case "$entry_kind" in task|plan) ;; *)
    echo "Error: invalid entryKind: $entry_kind" >&2
    return 1
  esac
  _workflow_state_enum_member "$task_provenance" "${WORKFLOW_STATE_TASK_PROVENANCES[@]}" || {
    echo "Error: invalid taskProvenance: $task_provenance" >&2
    return 1
  }
  _workflow_state_enum_member "$state" "${WORKFLOW_STATE_PUBLIC_STATES[@]}" || {
    echo "Error: invalid state: $state" >&2
    return 1
  }
  _workflow_state_is_abs_path "$source_path" || {
    echo "Error: sourcePath must be absolute: $source_path" >&2
    return 1
  }
  [[ -f "$input_file" && ! -L "$input_file" ]] || {
    echo "Error: --input-file must be a regular non-symlink file" >&2
    return 1
  }

  if [[ "$entry_kind" == "task" ]]; then
    if [[ "$input_plan_json" != "null" && -n "$input_plan_json" ]]; then
      echo "Error: task entry requires null inputPlan metadata" >&2
      return 1
    fi
    input_plan_json="null"
  else
    if [[ "$input_plan_json" != "null" ]]; then
      if ! printf '%s' "$input_plan_json" | jq -e '
        type == "object"
        and (.originalPath | type == "string" and startswith("/"))
        and (.sourcePath | type == "string" and startswith("/"))
        and (.manifestPath | type == "string" and startswith("/"))
        and (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))
        and (.format | IN("classic","yaml"))
        and (.totalTodos | type == "number")
        and (.completedTodos | type == "number")
        and (.openTodos | type == "number")
      ' >/dev/null 2>&1; then
        echo "Error: plan entry inputPlan metadata is incomplete or invalid" >&2
        return 1
      fi
    fi
  fi

  if [[ -n "$workflow_id" ]]; then
    if ! [[ "$workflow_id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
      echo "Error: invalid workflowId: $workflow_id" >&2
      return 1
    fi
  fi

  runs_root="$(workflow_state_runs_root "$state_root")" || return 1
  mkdir -p "$runs_root" || return 1
  lock_path="$(workflow_state_create_lock_path "$state_root")" || return 1
  _workflow_state_acquire_lock "$lock_path" || return 1

  while [[ "$attempt" -lt "$WORKFLOW_STATE_CREATE_COLLISION_RETRIES" ]]; do
    attempt=$((attempt + 1))
    run_id="$(workflow_state_mint_run_id)" || {
      _workflow_state_release_lock "$lock_path"
      return 1
    }
    case "$run_id" in
      */*|*\\*|*".."*|.*|"")
        _workflow_state_release_lock "$lock_path"
        echo "Error: minted invalid run id: $run_id" >&2
        return 1
        ;;
    esac
    run_dir="$runs_root/$run_id"
    if [[ -L "$run_dir" ]]; then
      # Existing symlink at the mint target is always a collision; remint.
      continue
    fi
    if mkdir "$run_dir" 2>/dev/null; then
      created=1
      break
    fi
  done

  if [[ "$created" -ne 1 ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to allocate a unique workflow run id after $WORKFLOW_STATE_CREATE_COLLISION_RETRIES attempts" >&2
    return 1
  fi

  # Re-resolve through containment after create.
  run_dir="$(workflow_state_run_dir "$state_root" "$run_id")" || {
    rm -rf "$runs_root/$run_id" 2>/dev/null || true
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  run_file="$run_dir/run.json"
  input_name="$(_workflow_state_input_basename_for_mode "$mode")" || {
    rm -rf "$run_dir"
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  input_path="$run_dir/$input_name"

  if ! _workflow_state_copy_immutable_input "$input_file" "$input_path"; then
    rm -rf "$run_dir"
    _workflow_state_release_lock "$lock_path"
    return 1
  fi

  if [[ -z "$engine_json" ]]; then
    engine_json="$(_workflow_state_default_engine_json "$mode" "$state_root" "$run_id" "$engine_namespace")" || {
      rm -rf "$run_dir"
      _workflow_state_release_lock "$lock_path"
      return 1
    }
  fi
  if [[ "$owner_json" == "null" || -z "$owner_json" ]]; then
    owner_json="null"
  fi

  now="$(workflow_state_now_iso)"
  if ! _workflow_state_atomic_write_json "$run_file" \
    '{
      runId: $runId,
      workflowId: (if $workflowId == "" then null else $workflowId end),
      sourcePath: $sourcePath,
      sourceKind: $sourceKind,
      mode: $mode,
      entryKind: $entryKind,
      task: $task,
      taskProvenance: $taskProvenance,
      taskFile: (if $taskFile == "" then null else $taskFile end),
      inputPath: $inputPath,
      inputPlan: $inputPlan,
      state: $state,
      createdAt: $createdAt,
      updatedAt: $updatedAt,
      owner: $owner,
      engine: $engine
    }' \
    --arg runId "$run_id" \
    --arg workflowId "$workflow_id" \
    --arg sourcePath "$source_path" \
    --arg sourceKind "$source_kind" \
    --arg mode "$mode" \
    --arg entryKind "$entry_kind" \
    --arg task "$task" \
    --arg taskProvenance "$task_provenance" \
    --arg taskFile "$task_file" \
    --arg inputPath "$input_path" \
    --argjson inputPlan "$input_plan_json" \
    --arg state "$state" \
    --arg createdAt "$now" \
    --arg updatedAt "$now" \
    --argjson owner "$owner_json" \
    --argjson engine "$engine_json"; then
    rm -rf "$run_dir"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to write run.json for $run_id" >&2
    return 1
  fi

  # Create path already assembled required fields; cheap sanity check only.
  # Full schema validation runs on read/update.
  if ! jq -e '.runId and .inputPath and .createdAt' "$run_file" >/dev/null 2>&1; then
    rm -rf "$run_dir"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to persist a readable run.json for $run_id" >&2
    return 1
  fi

  _workflow_state_release_lock "$lock_path"
  printf '%s\n' "$run_id"
}

# workflow_state_read <state_root> <run_id>
# Prints validated run.json. Fails on missing/corrupt entries and symlink escape.
workflow_state_read() {
  local state_root="${1:-}" run_id="${2:-}" run_file
  run_file="$(workflow_state_run_file "$state_root" "$run_id")" || return 1
  if [[ -L "$run_file" ]]; then
    echo "Error: refusing to read run.json through a symlink: $run_file" >&2
    return 1
  fi
  workflow_state_validate_run_json "$run_file" || return 1
  cat "$run_file"
}

# workflow_state_read_input_path <state_root> <run_id>
# Prints the absolute immutable input path from run.json after validation.
workflow_state_read_input_path() {
  local state_root="${1:-}" run_id="${2:-}" json input_path run_dir
  json="$(workflow_state_read "$state_root" "$run_id")" || return 1
  input_path="$(printf '%s' "$json" | jq -r '.inputPath')"
  run_dir="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  case "$input_path" in
    "$run_dir"/*) ;;
    *)
      echo "Error: inputPath is not under the registry run directory" >&2
      return 1
      ;;
  esac
  if [[ -L "$input_path" ]]; then
    echo "Error: immutable input must not be a symlink: $input_path" >&2
    return 1
  fi
  if [[ ! -f "$input_path" ]]; then
    echo "Error: missing immutable workflow input: $input_path" >&2
    return 1
  fi
  printf '%s\n' "$input_path"
}

# workflow_state_update <state_root> <run_id> <jq_filter> [jq_args...]
# Lock + temp rename update. Always refreshes updatedAt. Never rewrites input.
workflow_state_update() {
  local state_root="${1:-}" run_id="${2:-}"
  shift 2
  local jq_filter="${1:-}"
  shift || true
  local run_dir run_file lock_path current now tmp merged

  [[ -n "$state_root" && -n "$run_id" && -n "$jq_filter" ]] || {
    echo "Error: workflow_state_update requires state_root, run_id, and jq filter" >&2
    return 1
  }

  run_dir="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  run_file="$(workflow_state_run_file "$state_root" "$run_id")" || return 1
  workflow_state_validate_run_json "$run_file" || return 1
  lock_path="$(workflow_state_update_lock_path "$state_root" "$run_id")" || return 1

  _workflow_state_acquire_lock "$lock_path" || return 1

  current="$(cat "$run_file")" || {
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  now="$(workflow_state_now_iso)"
  if ! merged="$(printf '%s\n' "$current" | jq -c --arg updatedAt "$now" \
    "($jq_filter) | .updatedAt = \$updatedAt" \
    "$@" 2>/dev/null)"; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: workflow_state_update jq filter failed" >&2
    return 1
  fi

  # Protect immutable identity / input fields.
  if ! printf '%s\n' "$merged" | jq -e --argjson base "$(printf '%s' "$current" | jq -c .)" '
    .runId == $base.runId
    and .inputPath == $base.inputPath
    and .entryKind == $base.entryKind
    and .mode == $base.mode
    and .createdAt == $base.createdAt
  ' >/dev/null 2>&1; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: workflow_state_update refused mutation of immutable run fields" >&2
    return 1
  fi

  tmp="$(mktemp "$run_dir/.run-XXXXXX")" || {
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  if ! printf '%s\n' "$merged" >"$tmp"; then
    rm -f "$tmp"
    _workflow_state_release_lock "$lock_path"
    return 1
  fi
  if ! workflow_state_validate_run_json "$tmp"; then
    rm -f "$tmp"
    _workflow_state_release_lock "$lock_path"
    return 1
  fi
  _workflow_state_fsync "$tmp"
  if ! mv -f "$tmp" "$run_file"; then
    rm -f "$tmp"
    _workflow_state_release_lock "$lock_path"
    return 1
  fi
  _workflow_state_fsync "$run_dir"
  _workflow_state_release_lock "$lock_path"
  return 0
}

# workflow_state_list <state_root> [--state <s>] [--workflow <id>] [--limit N|--all] [--json|--tsv]
# Newest-first by createdAt then runId. Default limit 20.
# Non-TTY and --tsv emit the stable 6-column TSV. Suitable TTYs get a styled table.
workflow_state_list() {
  local state_root="${1:-}"
  shift || true
  local filter_state="" filter_workflow="" limit=20 all=0 as_json=0 as_tsv=0
  local runs_root entry run_file created rid row
  local -a rows=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) filter_state="${2:-}"; shift 2 ;;
      --workflow) filter_workflow="${2:-}"; shift 2 ;;
      --limit) limit="${2:-}"; shift 2 ;;
      --all) all=1; shift ;;
      --json) as_json=1; shift ;;
      --tsv) as_tsv=1; shift ;;
      *)
        echo "Error: unknown workflow_state_list argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$state_root" ]] || {
    echo "Error: workflow_state_list requires state_root" >&2
    return 1
  }
  if [[ "$as_json" -eq 1 && "$as_tsv" -eq 1 ]]; then
    echo "Error: --json and --tsv are mutually exclusive" >&2
    return 2
  fi
  if [[ "$all" -eq 1 ]]; then
    limit=0
  fi
  if [[ "$limit" -lt 0 ]]; then
    echo "Error: --limit must be nonnegative" >&2
    return 1
  fi

  state_root="$(workflow_state_ensure_state_root "$state_root")" || return 1
  runs_root="$(workflow_state_runs_root "$state_root")" || return 1
  if [[ ! -d "$runs_root" ]]; then
    if [[ "$as_json" -eq 1 ]]; then
      printf '[]\n'
    elif [[ "$as_tsv" -eq 1 ]] || [[ ! -t 1 && "${WORKFLOW_RUNS_FORCE_TABLE:-0}" != "1" ]]; then
      :
    else
      _workflow_state_render_runs_table '[]'
    fi
    return 0
  fi
  if [[ -L "$runs_root" ]]; then
    local real
    real="$(_workflow_state_real_dir "$runs_root")" || {
      echo "Error: workflow-runs escapes the state root via symlink" >&2
      return 1
    }
    if ! _workflow_state_is_within "$state_root" "$real"; then
      echo "Error: workflow-runs escapes the state root via symlink" >&2
      return 1
    fi
  fi

  for entry in "$runs_root"/run-*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    run_file="$entry/run.json"
    [[ -f "$run_file" && ! -L "$run_file" ]] || continue
    if ! jq -e '.runId and .createdAt and .state' "$run_file" >/dev/null 2>&1; then
      continue
    fi
    row="$(jq -c '{
      runId, workflowId, mode, entryKind, state, createdAt, updatedAt, task, sourceKind
    }' "$run_file" 2>/dev/null)" || continue
    if [[ -n "$filter_state" ]]; then
      [[ "$(printf '%s' "$row" | jq -r '.state')" == "$filter_state" ]] || continue
    fi
    if [[ -n "$filter_workflow" ]]; then
      [[ "$(printf '%s' "$row" | jq -r '.workflowId // empty')" == "$filter_workflow" ]] || continue
    fi
    created="$(printf '%s' "$row" | jq -r '.createdAt')"
    rid="$(printf '%s' "$row" | jq -r '.runId')"
    rows+=("${created}"$'\t'"${rid}"$'\t'"${row}")
  done

  if [[ "${#rows[@]}" -eq 0 ]]; then
    if [[ "$as_json" -eq 1 ]]; then
      printf '[]\n'
    elif [[ "$as_tsv" -eq 1 ]] || [[ ! -t 1 && "${WORKFLOW_RUNS_FORCE_TABLE:-0}" != "1" ]]; then
      :
    else
      _workflow_state_render_runs_table '[]'
    fi
    return 0
  fi

  local sorted count=0
  local -a json_items=()
  sorted="$(printf '%s\n' "${rows[@]}" | LC_ALL=C sort -r)"
  while IFS=$'\t' read -r _created _rid payload; do
    [[ -n "$payload" ]] || continue
    count=$((count + 1))
    if [[ "$limit" -gt 0 && "$count" -gt "$limit" ]]; then
      break
    fi
    json_items+=("$payload")
  done <<<"$sorted"

  if [[ "$as_json" -eq 1 ]]; then
    if [[ "${#json_items[@]}" -eq 0 ]]; then
      printf '[]\n'
    else
      printf '%s\n' "${json_items[@]}" | jq -s '.'
    fi
    return 0
  fi

  local json_array="[]"
  if [[ "${#json_items[@]}" -gt 0 ]]; then
    json_array="$(printf '%s\n' "${json_items[@]}" | jq -s '.')"
  fi

  # Explicit --tsv, redirected stdout, or missing Python: stable machine TSV.
  if [[ "$as_tsv" -eq 1 ]] \
    || { [[ ! -t 1 ]] && [[ "${WORKFLOW_RUNS_FORCE_TABLE:-0}" != "1" ]]; } \
    || ! command -v python3 >/dev/null 2>&1 \
    || [[ ! -f "$_WORKFLOW_STATE_SCRIPT_DIR/../../python/workflow_static.py" ]]; then
    if [[ "${#json_items[@]}" -eq 0 ]]; then
      return 0
    fi
    printf '%s\n' "${json_items[@]}" | jq -r \
      '[.runId, (.workflowId // "-"), .mode, .entryKind, .state, .createdAt] | @tsv'
    return 0
  fi

  _workflow_state_render_runs_table "$json_array"
}

# _workflow_state_render_runs_table <json-array>
_workflow_state_render_runs_table() {
  local json_array="${1:-[]}"
  local py="$_WORKFLOW_STATE_SCRIPT_DIR/../../python/workflow_static.py"
  local -a py_args=(runs-table)
  [[ -f "$py" ]] || {
    printf '%s\n' "$json_array" | jq -r \
      '.[] | [.runId, (.workflowId // "-"), .mode, .entryKind, .state, .createdAt] | @tsv'
    return 0
  }
  if [[ -n "${COLUMNS:-}" ]]; then
    py_args+=(--width "$COLUMNS")
  fi
  if [[ "${WORKFLOW_OPERATOR_FORCE_COLOR:-0}" == "1" || "${WORKFLOW_RUNS_FORCE_COLOR:-0}" == "1" ]]; then
    py_args+=(--force-color)
    if [[ -n "${WORKFLOW_OPERATOR_COLOR_DEPTH:-}" ]]; then
      py_args+=(--depth "$WORKFLOW_OPERATOR_COLOR_DEPTH")
    fi
  fi
  if [[ -n "${WORKFLOW_RUNS_NOW:-}" ]]; then
    py_args+=(--now "$WORKFLOW_RUNS_NOW")
  fi
  printf '%s' "$json_array" | python3 "$py" "${py_args[@]}"
}

# ---------------------------------------------------------------------------
# Provided-plan import (plans/input/source.plan.md + manifest.json)
# ---------------------------------------------------------------------------

_workflow_state_ensure_plan_todo_lib() {
  if declare -F plan_provided_input_extract >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=../plan-todo.sh
  source "$_WORKFLOW_STATE_SCRIPT_DIR/../plan-todo.sh"
}

# Test-only race hooks. Production leaves these unset.
# Phases: after-copy | before-manifest | before-attach | after-source-publish
# Env: WORKFLOW_STATE_IMPORT_HOOK_<PHASE> = shell command evaluated in-process.
# Context exports: WORKFLOW_STATE_IMPORT_ORIGINAL, _SOURCE_TMP, _SOURCE_DEST,
#   _MANIFEST_TMP, _MANIFEST_DEST, _RUN_DIR, _RUN_ID, _STATE_ROOT
_workflow_state_import_run_hook() {
  local phase="$1"
  local hook=""
  case "$phase" in
    after-copy) hook="${WORKFLOW_STATE_IMPORT_HOOK_AFTER_COPY:-}" ;;
    after-source-publish) hook="${WORKFLOW_STATE_IMPORT_HOOK_AFTER_SOURCE_PUBLISH:-}" ;;
    before-manifest) hook="${WORKFLOW_STATE_IMPORT_HOOK_BEFORE_MANIFEST:-}" ;;
    before-attach) hook="${WORKFLOW_STATE_IMPORT_HOOK_BEFORE_ATTACH:-}" ;;
    *) return 0 ;;
  esac
  [[ -n "$hook" ]] || return 0
  # shellcheck disable=SC2086
  eval "$hook"
}

_workflow_state_import_cleanup_temps() {
  local path
  for path in "$@"; do
    [[ -n "$path" && -e "$path" ]] || continue
    if [[ -f "$path" && ! -L "$path" ]]; then
      rm -f "$path" 2>/dev/null || true
    fi
  done
}

# Rollback only artifacts this import created. Never removes a pre-existing
# source/manifest (second-import / collision paths refuse before write).
_workflow_state_import_rollback_published() {
  local source_dest="$1" manifest_dest="$2" created_source="$3" created_manifest="$4"
  if [[ "$created_manifest" -eq 1 && -e "$manifest_dest" && ! -L "$manifest_dest" ]]; then
    rm -f "$manifest_dest" 2>/dev/null || true
  fi
  if [[ "$created_source" -eq 1 && -e "$source_dest" && ! -L "$source_dest" ]]; then
    rm -f "$source_dest" 2>/dev/null || true
  fi
}

# workflow_state_import_provided_plan --state-root ... --run-id ... --plan ...
#   --project-root ... [--explicit-task ...] [--created-at ...]
#
# Supervisor import for an existing plan-entry registry run:
#   1. Revalidate leaf plan format/content and allowed-root containment
#   2. Byte-copy to <registry-run>/plans/input/source.plan.md (temp + fsync + rename)
#   3. Verify original/copied SHA-256 match and original is unchanged since extract
#   4. Publish plans/input/manifest.json last (schema version 1)
#   5. Atomically attach inputPlan metadata onto run.json
#
# Refuses task-entry runs, a second import, destination collision, symlink/race,
# hash change during copy, invalid/zero-TODO/zero-open input, and partial files.
# Cleans safe temp files; never overwrites an existing source/manifest. The
# operator original plan is never mutated.
workflow_state_import_provided_plan() {
  local state_root="" run_id="" plan_path="" project_root="" explicit_task="" created_at=""
  local run_dir run_file lock_path current entry_kind input_plan_field
  local extract_json plan_real original_sha_extract original_sha_now copied_sha
  local input_dir source_dest manifest_dest source_tmp manifest_tmp
  local manifest_json input_plan_json now merged tmp
  local created_source=0 created_manifest=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-root) state_root="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --plan) plan_path="${2:-}"; shift 2 ;;
      --project-root) project_root="${2:-}"; shift 2 ;;
      --explicit-task) explicit_task="${2:-}"; shift 2 ;;
      --created-at) created_at="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_state_import_provided_plan argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$state_root" && -n "$run_id" && -n "$plan_path" && -n "$project_root" ]] || {
    echo "Error: workflow_state_import_provided_plan requires --state-root --run-id --plan --project-root" >&2
    return 1
  }

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for workflow_state_import_provided_plan" >&2
    return 1
  }
  _workflow_state_ensure_plan_todo_lib || {
    echo "Error: failed to load plan-todo helpers for provided-plan import" >&2
    return 1
  }

  state_root="$(workflow_state_ensure_state_root "$state_root")" || return 1
  project_root="$(_workflow_state_abs_path "$project_root")" || return 1
  plan_path="$(_workflow_state_abs_path "$plan_path")" || return 1

  run_dir="$(workflow_state_run_dir "$state_root" "$run_id")" || return 1
  run_file="$(workflow_state_run_file "$state_root" "$run_id")" || return 1
  if [[ -L "$run_file" ]]; then
    echo "Error: refusing to import through a symlink run.json: $run_file" >&2
    return 1
  fi
  workflow_state_validate_run_json "$run_file" || return 1

  lock_path="$(workflow_state_update_lock_path "$state_root" "$run_id")" || return 1
  _workflow_state_acquire_lock "$lock_path" || return 1

  current="$(cat "$run_file")" || {
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  entry_kind="$(printf '%s' "$current" | jq -r '.entryKind')"
  if [[ "$entry_kind" != "plan" ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided-plan import requires a plan-entry run (got entryKind=$entry_kind)" >&2
    return 1
  fi
  input_plan_field="$(printf '%s' "$current" | jq -c '.inputPlan')"
  if [[ "$input_plan_field" != "null" ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided-plan import refused: run already has inputPlan metadata (second import)" >&2
    return 1
  fi

  input_dir="$run_dir/plans/input"
  source_dest="$input_dir/source.plan.md"
  manifest_dest="$input_dir/manifest.json"

  if [[ -L "$input_dir" || -L "$run_dir/plans" ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: plans/input path must not be a symlink" >&2
    return 1
  fi
  if [[ -e "$source_dest" || -L "$source_dest" ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: destination collision: $source_dest already exists" >&2
    return 1
  fi
  if [[ -e "$manifest_dest" || -L "$manifest_dest" ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: destination collision: $manifest_dest already exists" >&2
    return 1
  fi

  # Revalidate format/content/containment against the live original (read-only).
  if ! extract_json="$(plan_provided_input_extract "$plan_path" "$project_root" "$state_root" "$explicit_task")"; then
    _workflow_state_release_lock "$lock_path"
    return 1
  fi
  plan_real="$(printf '%s' "$extract_json" | jq -r '.originalPath')"
  original_sha_extract="$(printf '%s' "$extract_json" | jq -r '.originalSha256')"

  if [[ -L "$plan_path" ]]; then
    # Operator may pass a symlink; resolution already happened. Refuse if the
    # path argument itself is a symlink that escapes after a race to a new target.
    local plan_link_real
    plan_link_real="$(plan_provided_input_realpath "$plan_path")" || {
      _workflow_state_release_lock "$lock_path"
      echo "Error: cannot resolve provided plan symlink: $plan_path" >&2
      return 1
    }
    if [[ "$plan_link_real" != "$plan_real" ]]; then
      _workflow_state_release_lock "$lock_path"
      echo "Error: provided plan symlink race detected" >&2
      return 1
    fi
  fi
  if [[ -L "$plan_real" ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided plan must resolve to a regular file, not a symlink: $plan_real" >&2
    return 1
  fi
  if [[ ! -f "$plan_real" ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided plan not found: $plan_real" >&2
    return 1
  fi

  mkdir -p "$input_dir" || {
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  # Re-check containment of the input dir under the run dir after mkdir.
  case "$(cd "$input_dir" && pwd -P)" in
    "$run_dir"|"$run_dir"/*) ;;
    *)
      _workflow_state_release_lock "$lock_path"
      echo "Error: plans/input escapes the registry run directory" >&2
      return 1
      ;;
  esac

  source_tmp="$(mktemp "$input_dir/.source-XXXXXX")" || {
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  export WORKFLOW_STATE_IMPORT_ORIGINAL="$plan_real"
  export WORKFLOW_STATE_IMPORT_SOURCE_TMP="$source_tmp"
  export WORKFLOW_STATE_IMPORT_SOURCE_DEST="$source_dest"
  export WORKFLOW_STATE_IMPORT_MANIFEST_DEST="$manifest_dest"
  export WORKFLOW_STATE_IMPORT_RUN_DIR="$run_dir"
  export WORKFLOW_STATE_IMPORT_RUN_ID="$run_id"
  export WORKFLOW_STATE_IMPORT_STATE_ROOT="$state_root"

  if ! cp "$plan_real" "$source_tmp"; then
    _workflow_state_import_cleanup_temps "$source_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to byte-copy provided plan" >&2
    return 1
  fi
  _workflow_state_fsync "$source_tmp"

  if ! _workflow_state_import_run_hook after-copy; then
    _workflow_state_import_cleanup_temps "$source_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided-plan import after-copy hook failed" >&2
    return 1
  fi

  # Detect original change / symlink swap during copy.
  if [[ -L "$plan_real" || ! -f "$plan_real" ]]; then
    _workflow_state_import_cleanup_temps "$source_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided plan became a symlink or disappeared during copy" >&2
    return 1
  fi
  original_sha_now="$(plan_provided_input_file_sha256 "$plan_real")" || {
    _workflow_state_import_cleanup_temps "$source_tmp"
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  copied_sha="$(plan_provided_input_file_sha256 "$source_tmp")" || {
    _workflow_state_import_cleanup_temps "$source_tmp"
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  if [[ "$original_sha_now" != "$original_sha_extract" ]]; then
    _workflow_state_import_cleanup_temps "$source_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided plan changed during copy (hash race)" >&2
    return 1
  fi
  if [[ "$copied_sha" != "$original_sha_extract" ]]; then
    _workflow_state_import_cleanup_temps "$source_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: copied plan hash does not match original" >&2
    return 1
  fi

  # Destination collision / symlink race immediately before rename.
  if [[ -e "$source_dest" || -L "$source_dest" ]]; then
    _workflow_state_import_cleanup_temps "$source_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: destination collision: $source_dest already exists" >&2
    return 1
  fi
  if ! mv -f "$source_tmp" "$source_dest"; then
    _workflow_state_import_cleanup_temps "$source_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to publish source.plan.md" >&2
    return 1
  fi
  created_source=1
  source_tmp=""
  _workflow_state_fsync "$source_dest"
  _workflow_state_fsync "$input_dir"
  chmod a-w "$source_dest" 2>/dev/null || true

  if ! _workflow_state_import_run_hook after-source-publish; then
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided-plan import after-source-publish hook failed" >&2
    return 1
  fi
  if ! _workflow_state_import_run_hook before-manifest; then
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided-plan import before-manifest hook failed" >&2
    return 1
  fi

  if [[ -z "$created_at" ]]; then
    if [[ -n "${WORKFLOW_STATE_FIXED_NOW:-}" ]]; then
      created_at="$WORKFLOW_STATE_FIXED_NOW"
    else
      created_at="$(workflow_state_now_iso)"
    fi
  fi

  if ! manifest_json="$(plan_provided_input_manifest_json "$extract_json" "$source_dest" "$created_at" "$copied_sha")"; then
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    return 1
  fi

  if [[ -e "$manifest_dest" || -L "$manifest_dest" ]]; then
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: destination collision: $manifest_dest already exists" >&2
    return 1
  fi

  manifest_tmp="$(mktemp "$input_dir/.manifest-XXXXXX")" || {
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  export WORKFLOW_STATE_IMPORT_MANIFEST_TMP="$manifest_tmp"
  if ! printf '%s\n' "$manifest_json" >"$manifest_tmp"; then
    _workflow_state_import_cleanup_temps "$manifest_tmp"
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    return 1
  fi
  if ! plan_provided_input_validate_manifest "$manifest_tmp"; then
    _workflow_state_import_cleanup_temps "$manifest_tmp"
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided-plan import produced an invalid manifest" >&2
    return 1
  fi
  _workflow_state_fsync "$manifest_tmp"
  if ! mv -f "$manifest_tmp" "$manifest_dest"; then
    _workflow_state_import_cleanup_temps "$manifest_tmp"
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to publish manifest.json" >&2
    return 1
  fi
  created_manifest=1
  manifest_tmp=""
  _workflow_state_fsync "$manifest_dest"
  _workflow_state_fsync "$input_dir"
  chmod a-w "$manifest_dest" 2>/dev/null || true

  if ! _workflow_state_import_run_hook before-attach; then
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided-plan import before-attach hook failed" >&2
    return 1
  fi

  if ! input_plan_json="$(plan_provided_input_to_run_metadata "$manifest_json" "$manifest_dest")"; then
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    return 1
  fi

  # Re-read under lock so we refuse a concurrent attach / second import.
  current="$(cat "$run_file")" || {
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  if [[ "$(printf '%s' "$current" | jq -c '.inputPlan')" != "null" ]]; then
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: provided-plan import refused: run already has inputPlan metadata (second import)" >&2
    return 1
  fi

  now="$(workflow_state_now_iso)"
  if ! merged="$(printf '%s\n' "$current" | jq -c \
    --arg updatedAt "$now" \
    --argjson inputPlan "$input_plan_json" \
    '.inputPlan = $inputPlan | .updatedAt = $updatedAt')"; then
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to attach inputPlan metadata" >&2
    return 1
  fi

  tmp="$(mktemp "$run_dir/.run-XXXXXX")" || {
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  if ! printf '%s\n' "$merged" >"$tmp"; then
    _workflow_state_import_cleanup_temps "$tmp"
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    return 1
  fi
  if ! workflow_state_validate_run_json "$tmp"; then
    _workflow_state_import_cleanup_temps "$tmp"
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: attached inputPlan failed run.json validation" >&2
    return 1
  fi
  _workflow_state_fsync "$tmp"
  if ! mv -f "$tmp" "$run_file"; then
    _workflow_state_import_cleanup_temps "$tmp"
    _workflow_state_import_rollback_published "$source_dest" "$manifest_dest" "$created_source" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to atomically attach inputPlan to run.json" >&2
    return 1
  fi
  _workflow_state_fsync "$run_dir"
  _workflow_state_release_lock "$lock_path"

  unset WORKFLOW_STATE_IMPORT_ORIGINAL WORKFLOW_STATE_IMPORT_SOURCE_TMP \
    WORKFLOW_STATE_IMPORT_SOURCE_DEST WORKFLOW_STATE_IMPORT_MANIFEST_TMP \
    WORKFLOW_STATE_IMPORT_MANIFEST_DEST WORKFLOW_STATE_IMPORT_RUN_DIR \
    WORKFLOW_STATE_IMPORT_RUN_ID WORKFLOW_STATE_IMPORT_STATE_ROOT
  printf '%s\n' "$source_dest"
  return 0
}

# ---------------------------------------------------------------------------
# Generated-plan materialization (plans/<stage>/attempt-<n>.{plan.md,manifest.json})
# ---------------------------------------------------------------------------

_workflow_state_planner_contract_py() {
  local candidate
  candidate="$(cd "$_WORKFLOW_STATE_SCRIPT_DIR/../.." && pwd)/python/planner_contract.py"
  [[ -f "$candidate" ]] || {
    echo "Error: planner_contract.py not found near workflow-state.sh" >&2
    return 1
  }
  printf '%s\n' "$candidate"
}

_workflow_state_stage_id_ok() {
  local stage_id="${1:-}"
  [[ "$stage_id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

_workflow_state_runtime_ok() {
  case "${1:-}" in
    cursor|claude|codex|opencode|antigravity) return 0 ;;
    *) return 1 ;;
  esac
}

# Test-only race hooks. Production leaves these unset.
# Phases: after-render | after-plan-publish | before-manifest
# Env: WORKFLOW_STATE_GENPLAN_HOOK_<PHASE> = shell command evaluated in-process.
_workflow_state_genplan_run_hook() {
  local phase="$1"
  local hook=""
  case "$phase" in
    after-render) hook="${WORKFLOW_STATE_GENPLAN_HOOK_AFTER_RENDER:-}" ;;
    after-plan-publish) hook="${WORKFLOW_STATE_GENPLAN_HOOK_AFTER_PLAN_PUBLISH:-}" ;;
    before-manifest) hook="${WORKFLOW_STATE_GENPLAN_HOOK_BEFORE_MANIFEST:-}" ;;
    *) return 0 ;;
  esac
  [[ -n "$hook" ]] || return 0
  # shellcheck disable=SC2086
  eval "$hook"
}

_workflow_state_genplan_cleanup_temps() {
  local path
  for path in "$@"; do
    [[ -n "$path" && -e "$path" ]] || continue
    if [[ -f "$path" && ! -L "$path" ]]; then
      rm -f "$path" 2>/dev/null || true
    fi
  done
}

# Rollback only artifacts this materialization created.
_workflow_state_genplan_rollback_published() {
  local plan_dest="$1" manifest_dest="$2" created_plan="$3" created_manifest="$4"
  if [[ "$created_manifest" -eq 1 && -e "$manifest_dest" && ! -L "$manifest_dest" ]]; then
    rm -f "$manifest_dest" 2>/dev/null || true
  fi
  if [[ "$created_plan" -eq 1 && -e "$plan_dest" && ! -L "$plan_dest" ]]; then
    rm -f "$plan_dest" 2>/dev/null || true
  fi
}

# workflow_state_materialize_generated_plan --registry-run ... --planner-stage-id ...
#   --attempt ... --artifact ... --max-todos ... --default-runtime ...
#   [--default-model ...] [--created-at ...]
#
# Supervisor materialization for planner-output v2:
#   1. Validate registry-run containment and positive attempt / stage id
#   2. Validate artifact + freeze effective defaults via planner_contract
#   3. Validate rendered plan with validate-plan.sh (via render-plan CLI)
#   4. Atomically publish plans/<stage>/attempt-<n>.plan.md
#   5. Publish attempt-<n>.manifest.json last (schema version 1)
#
# Refuses overwrite, symlink escape, path/run/stage/attempt mismatch,
# missing/unsupported default runtime, corrupt JSON, invalid plan, and
# count overflow without leaving a manifest or partial plan. Does not mutate
# the model-written planner JSON and does not inspect feature gates.
#
# Orchestrator hook (workflow-run plan-file only): after ordinary stage
# artifact verification, orch_planner_apply_workflow_plan_file calls this with
# RALPH_WORKFLOW_REGISTRY_RUN, current attempt, and the frozen effective
# default runtime/model. Validation/publication failure is treated as
# reasonCode invalid-artifact; this function never leaves a manifest for a
# failed call. Ungated: callers must not consult RALPH_DYNAMIC_PLANNER /
# RALPH_MODE for workflow plan-file publication.
workflow_state_materialize_generated_plan() {
  local registry_run="" planner_stage_id="" attempt="" artifact="" max_todos=""
  local default_runtime="" default_model="" created_at=""
  local run_dir run_file run_id state_root plans_parent stage_dir
  local plan_dest manifest_dest plan_tmp manifest_tmp
  local py render_err manifest_json plan_sha todo_count
  local lock_path artifact_abs stage_real plans_real run_real
  local created_plan=0 created_manifest=0
  local expected_plan_suffix expected_manifest_name
  local detail

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --planner-stage-id) planner_stage_id="${2:-}"; shift 2 ;;
      --attempt) attempt="${2:-}"; shift 2 ;;
      --artifact) artifact="${2:-}"; shift 2 ;;
      --max-todos) max_todos="${2:-}"; shift 2 ;;
      --default-runtime) default_runtime="${2:-}"; shift 2 ;;
      --default-model) default_model="${2:-}"; shift 2 ;;
      --created-at) created_at="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_state_materialize_generated_plan argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$registry_run" && -n "$planner_stage_id" && -n "$attempt" && -n "$artifact" && -n "$max_todos" && -n "$default_runtime" ]] || {
    echo "Error: workflow_state_materialize_generated_plan requires --registry-run --planner-stage-id --attempt --artifact --max-todos --default-runtime" >&2
    return 1
  }

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for workflow_state_materialize_generated_plan" >&2
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "Error: python3 is required for workflow_state_materialize_generated_plan" >&2
    return 1
  }

  if ! _workflow_state_stage_id_ok "$planner_stage_id"; then
    echo "Error: planner stage id must be lowercase-hyphen: $planner_stage_id" >&2
    return 1
  fi
  if ! [[ "$attempt" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: attempt must be a positive integer (got $attempt)" >&2
    return 1
  fi
  if ! [[ "$max_todos" =~ ^[1-9][0-9]*$ ]] || [[ "$max_todos" -gt 200 ]]; then
    echo "Error: maxTodos must be an integer between 1 and 200 (got $max_todos)" >&2
    return 1
  fi
  if ! _workflow_state_runtime_ok "$default_runtime"; then
    echo "Error: missing/unsupported default runtime: ${default_runtime:-<empty>}" >&2
    return 1
  fi

  registry_run="$(_workflow_state_abs_path "$registry_run")" || return 1
  artifact_abs="$(_workflow_state_abs_path "$artifact")" || return 1

  if [[ -L "$registry_run" ]]; then
    echo "Error: registry-run path must not be a symlink: $registry_run" >&2
    return 1
  fi
  if [[ ! -d "$registry_run" ]]; then
    echo "Error: registry-run does not exist: $registry_run" >&2
    return 1
  fi
  run_real="$(_workflow_state_real_dir "$registry_run")" || {
    echo "Error: registry-run is not a usable directory: $registry_run" >&2
    return 1
  }
  run_dir="$run_real"
  run_file="$run_dir/run.json"
  if [[ -L "$run_file" ]]; then
    echo "Error: refusing to materialize through a symlink run.json: $run_file" >&2
    return 1
  fi
  if [[ ! -f "$run_file" ]]; then
    echo "Error: registry-run missing run.json: $run_file" >&2
    return 1
  fi
  workflow_state_validate_run_json "$run_file" || return 1

  run_id="$(basename -- "$run_dir")"
  state_root="$(dirname -- "$(dirname -- "$run_dir")")"
  # Path/run mismatch: basename must match run.json runId.
  if [[ "$(jq -r '.runId' "$run_file")" != "$run_id" ]]; then
    echo "Error: path/run mismatch: directory $run_id != run.json runId" >&2
    return 1
  fi

  if [[ -L "$artifact_abs" ]]; then
    echo "Error: planner artifact must not be a symlink: $artifact_abs" >&2
    return 1
  fi
  if [[ ! -f "$artifact_abs" ]]; then
    echo "Error: planner artifact not found: $artifact_abs" >&2
    return 1
  fi

  plans_parent="$run_dir/plans"
  stage_dir="$plans_parent/$planner_stage_id"
  plan_dest="$stage_dir/attempt-${attempt}.plan.md"
  manifest_dest="$stage_dir/attempt-${attempt}.manifest.json"
  expected_plan_suffix="/plans/${planner_stage_id}/attempt-${attempt}.plan.md"
  expected_manifest_name="attempt-${attempt}.manifest.json"

  if [[ -L "$plans_parent" ]]; then
    plans_real="$(cd "$plans_parent" 2>/dev/null && pwd -P)" || {
      echo "Error: cannot resolve plans symlink" >&2
      return 1
    }
    if ! _workflow_state_is_within "$run_dir" "$plans_real"; then
      echo "Error: plans path escapes the registry run via symlink" >&2
      return 1
    fi
  fi
  if [[ -d "$stage_dir" || -L "$stage_dir" ]]; then
    if [[ -L "$stage_dir" ]]; then
      stage_real="$(cd "$stage_dir" 2>/dev/null && pwd -P)" || {
        echo "Error: cannot resolve planner stage directory symlink" >&2
        return 1
      }
      if ! _workflow_state_is_within "$run_dir" "$stage_real"; then
        echo "Error: planner stage path escapes the registry run via symlink" >&2
        return 1
      fi
    fi
  fi

  if [[ -e "$plan_dest" || -L "$plan_dest" ]]; then
    echo "Error: destination collision: $plan_dest already exists (refuse overwrite)" >&2
    return 1
  fi
  if [[ -e "$manifest_dest" || -L "$manifest_dest" ]]; then
    echo "Error: destination collision: $manifest_dest already exists (refuse overwrite)" >&2
    return 1
  fi

  lock_path="$run_dir/.lock"
  _workflow_state_acquire_lock "$lock_path" || return 1

  # Re-check collision under lock.
  if [[ -e "$plan_dest" || -L "$plan_dest" || -e "$manifest_dest" || -L "$manifest_dest" ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: destination collision under lock (refuse overwrite)" >&2
    return 1
  fi

  mkdir -p "$stage_dir" || {
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  stage_real="$(_workflow_state_real_dir "$stage_dir")" || {
    _workflow_state_release_lock "$lock_path"
    echo "Error: planner stage directory is not usable: $stage_dir" >&2
    return 1
  }
  if ! _workflow_state_is_within "$run_dir" "$stage_real"; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: planner stage path escapes the registry run via symlink" >&2
    return 1
  fi
  # Refresh destinations onto the resolved stage directory for rename safety.
  plan_dest="$stage_real/attempt-${attempt}.plan.md"
  manifest_dest="$stage_real/attempt-${attempt}.manifest.json"

  if [[ "$plan_dest" != *"$expected_plan_suffix" ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: path/stage/attempt mismatch for plan destination: $plan_dest" >&2
    return 1
  fi
  if [[ "$(basename -- "$manifest_dest")" != "$expected_manifest_name" ]]; then
    _workflow_state_release_lock "$lock_path"
    echo "Error: path/stage/attempt mismatch for manifest destination: $manifest_dest" >&2
    return 1
  fi

  py="$(_workflow_state_planner_contract_py)" || {
    _workflow_state_release_lock "$lock_path"
    return 1
  }

  plan_tmp="$(mktemp "$stage_real/.attempt-${attempt}-plan-XXXXXX")" || {
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  export WORKFLOW_STATE_GENPLAN_REGISTRY_RUN="$run_dir"
  export WORKFLOW_STATE_GENPLAN_STAGE_ID="$planner_stage_id"
  export WORKFLOW_STATE_GENPLAN_ATTEMPT="$attempt"
  export WORKFLOW_STATE_GENPLAN_ARTIFACT="$artifact_abs"
  export WORKFLOW_STATE_GENPLAN_PLAN_TMP="$plan_tmp"
  export WORKFLOW_STATE_GENPLAN_PLAN_DEST="$plan_dest"
  export WORKFLOW_STATE_GENPLAN_MANIFEST_DEST="$manifest_dest"

  render_err="$(mktemp "$stage_real/.attempt-${attempt}-render-err-XXXXXX")" || {
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  if ! python3 "$py" render-plan \
    --artifact "$artifact_abs" \
    --default-runtime "$default_runtime" \
    --default-model "$default_model" \
    --output "$plan_tmp" \
    --max-todos "$max_todos" \
    >/dev/null 2>"$render_err"; then
    detail="$(tr '\n' ' ' <"$render_err" | sed 's/[[:space:]]*$//')"
    _workflow_state_genplan_cleanup_temps "$plan_tmp" "$render_err"
    _workflow_state_release_lock "$lock_path"
    if [[ "$detail" == *"maxTodos"* || "$detail" == *"hard maximum"* ]]; then
      echo "Error: invalid planner artifact (count overflow): $detail" >&2
    elif [[ "$detail" == *"JSON"* || "$detail" == *"json"* || "$detail" == *"Expecting"* || "$detail" == *"corrupt"* ]]; then
      echo "Error: corrupt planner JSON: $detail" >&2
    elif [[ "$detail" == *"validate-plan"* ]]; then
      echo "Error: invalid plan after render: $detail" >&2
    else
      echo "Error: invalid planner artifact: ${detail:-render-plan failed}" >&2
    fi
    return 1
  fi
  _workflow_state_genplan_cleanup_temps "$render_err"
  render_err=""
  _workflow_state_fsync "$plan_tmp"

  if ! _workflow_state_genplan_run_hook after-render; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: generated-plan after-render hook failed" >&2
    return 1
  fi

  todo_count="$(grep -cE '^  - id: ' "$plan_tmp" || true)"
  if ! [[ "$todo_count" =~ ^[1-9][0-9]*$ ]]; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: rendered plan has no TODOs" >&2
    return 1
  fi
  if [[ "$todo_count" -gt "$max_todos" ]]; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: invalid planner artifact (count overflow): rendered $todo_count todos exceeds maxTodos $max_todos" >&2
    return 1
  fi

  plan_sha="$(
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$plan_tmp" | awk '{print $1}'
    else
      shasum -a 256 "$plan_tmp" | awk '{print $1}'
    fi
  )" || {
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to hash rendered plan" >&2
    return 1
  }

  if [[ -z "$created_at" ]]; then
    if [[ -n "${WORKFLOW_STATE_FIXED_NOW:-}" ]]; then
      created_at="$WORKFLOW_STATE_FIXED_NOW"
    else
      created_at="$(workflow_state_now_iso)"
    fi
  fi

  if ! manifest_json="$(
    python3 "$py" build-manifest \
      --producer-stage-id "$planner_stage_id" \
      --producer-attempt "$attempt" \
      --source-artifact "$artifact_abs" \
      --plan-path "$plan_dest" \
      --todo-count "$todo_count" \
      --plan-sha256 "$plan_sha" \
      --created-at "$created_at"
  )"; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to build generated-plan manifest" >&2
    return 1
  fi

  # Refuse path/run/stage/attempt mismatch in manifest fields before publish.
  if [[ "$(printf '%s' "$manifest_json" | jq -r '.producerStageId')" != "$planner_stage_id" ]]; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: path/stage/attempt mismatch: manifest producerStageId" >&2
    return 1
  fi
  if [[ "$(printf '%s' "$manifest_json" | jq -r '.producerAttempt')" != "$attempt" ]]; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: path/stage/attempt mismatch: manifest producerAttempt" >&2
    return 1
  fi
  if [[ "$(printf '%s' "$manifest_json" | jq -r '.planPath')" != "$plan_dest" ]]; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: path/stage/attempt mismatch: manifest planPath" >&2
    return 1
  fi
  if [[ "$(printf '%s' "$manifest_json" | jq -r '.sourceArtifact')" != "$artifact_abs" ]]; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: path/stage/attempt mismatch: manifest sourceArtifact" >&2
    return 1
  fi
  if [[ "$(printf '%s' "$manifest_json" | jq -r '.schemaVersion')" != "1" ]]; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: generated-plan manifest schemaVersion must be 1" >&2
    return 1
  fi

  if [[ -e "$plan_dest" || -L "$plan_dest" ]]; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: destination collision: $plan_dest already exists (refuse overwrite)" >&2
    return 1
  fi
  if ! mv -f "$plan_tmp" "$plan_dest"; then
    _workflow_state_genplan_cleanup_temps "$plan_tmp"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to publish attempt plan" >&2
    return 1
  fi
  created_plan=1
  plan_tmp=""
  _workflow_state_fsync "$plan_dest"
  _workflow_state_fsync "$stage_real"
  chmod a-w "$plan_dest" 2>/dev/null || true

  if ! _workflow_state_genplan_run_hook after-plan-publish; then
    _workflow_state_genplan_rollback_published "$plan_dest" "$manifest_dest" "$created_plan" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: generated-plan after-plan-publish hook failed" >&2
    return 1
  fi
  if ! _workflow_state_genplan_run_hook before-manifest; then
    _workflow_state_genplan_rollback_published "$plan_dest" "$manifest_dest" "$created_plan" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: generated-plan before-manifest hook failed" >&2
    return 1
  fi

  if [[ -e "$manifest_dest" || -L "$manifest_dest" ]]; then
    _workflow_state_genplan_rollback_published "$plan_dest" "$manifest_dest" "$created_plan" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: destination collision: $manifest_dest already exists (refuse overwrite)" >&2
    return 1
  fi

  manifest_tmp="$(mktemp "$stage_real/.attempt-${attempt}-manifest-XXXXXX")" || {
    _workflow_state_genplan_rollback_published "$plan_dest" "$manifest_dest" "$created_plan" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    return 1
  }
  export WORKFLOW_STATE_GENPLAN_MANIFEST_TMP="$manifest_tmp"
  if ! printf '%s\n' "$manifest_json" >"$manifest_tmp"; then
    _workflow_state_genplan_cleanup_temps "$manifest_tmp"
    _workflow_state_genplan_rollback_published "$plan_dest" "$manifest_dest" "$created_plan" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    return 1
  fi
  if ! python3 "$py" validate-manifest --manifest "$manifest_tmp" >/dev/null; then
    _workflow_state_genplan_cleanup_temps "$manifest_tmp"
    _workflow_state_genplan_rollback_published "$plan_dest" "$manifest_dest" "$created_plan" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: generated-plan materialization produced an invalid manifest" >&2
    return 1
  fi
  _workflow_state_fsync "$manifest_tmp"
  if ! mv -f "$manifest_tmp" "$manifest_dest"; then
    _workflow_state_genplan_cleanup_temps "$manifest_tmp"
    _workflow_state_genplan_rollback_published "$plan_dest" "$manifest_dest" "$created_plan" "$created_manifest"
    _workflow_state_release_lock "$lock_path"
    echo "Error: failed to publish attempt manifest" >&2
    return 1
  fi
  created_manifest=1
  manifest_tmp=""
  _workflow_state_fsync "$manifest_dest"
  _workflow_state_fsync "$stage_real"
  chmod a-w "$manifest_dest" 2>/dev/null || true

  _workflow_state_release_lock "$lock_path"
  unset WORKFLOW_STATE_GENPLAN_REGISTRY_RUN WORKFLOW_STATE_GENPLAN_STAGE_ID \
    WORKFLOW_STATE_GENPLAN_ATTEMPT WORKFLOW_STATE_GENPLAN_ARTIFACT \
    WORKFLOW_STATE_GENPLAN_PLAN_TMP WORKFLOW_STATE_GENPLAN_PLAN_DEST \
    WORKFLOW_STATE_GENPLAN_MANIFEST_TMP WORKFLOW_STATE_GENPLAN_MANIFEST_DEST

  # Keep model-written JSON untouched; print absolute immutable plan path.
  printf '%s\n' "$plan_dest"
  return 0
}

# ---------------------------------------------------------------------------
# Generated planFrom consumer: validate evidence + mutable control copy
# ---------------------------------------------------------------------------

_workflow_state_file_sha256() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

_workflow_state_validate_plan_sh() {
  local candidate
  candidate="$(cd "$_WORKFLOW_STATE_SCRIPT_DIR/../.." && pwd)/validate-plan.sh"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  echo "Error: validate-plan.sh not found near workflow-state.sh" >&2
  return 1
}

# workflow_state_plan_progress_json <plan-path>
# Prints {completedTodos,totalTodos,currentTodoId,openTodos} from a Ralph plan.
# currentTodoId is null when every TODO is complete. Does not mutate the plan.
workflow_state_plan_progress_json() {
  local plan_path="${1:-}"
  local py
  [[ -n "$plan_path" && -f "$plan_path" && ! -L "$plan_path" ]] || {
    echo "Error: workflow_state_plan_progress_json requires a regular plan file" >&2
    return 1
  }
  plan_path="$(_workflow_state_abs_path "$plan_path")" || return 1
  command -v python3 >/dev/null 2>&1 || {
    echo "Error: python3 is required for workflow_state_plan_progress_json" >&2
    return 1
  }
  python3 - "$plan_path" <<'PY'
import json, re, sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
lines = text.splitlines()
completed = total = 0
current_id = None

def is_done(status: str) -> bool:
    return status.strip().lower() in {"completed", "complete", "done"}

if lines and lines[0].strip() == "---":
    # YAML frontmatter todos
    in_todos = False
    cur = None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if re.match(r"^todos:\s*$", line):
            in_todos = True
            continue
        if not in_todos:
            continue
        m = re.match(r"^  - id:\s*(\S+)\s*$", line)
        if m:
            if cur is not None:
                total += 1
                if is_done(cur.get("status", "pending")):
                    completed += 1
                elif current_id is None:
                    current_id = cur.get("id")
            cur = {"id": m.group(1), "status": "pending"}
            continue
        if cur is not None:
            sm = re.match(r"^    status:\s*(\S+)\s*$", line)
            if sm:
                cur["status"] = sm.group(1)
    if cur is not None:
        total += 1
        if is_done(cur.get("status", "pending")):
            completed += 1
        elif current_id is None:
            current_id = cur.get("id")
else:
    # Classic markdown checkboxes
    for line in lines:
        if re.match(r"^\s*-\s+\[[xX]\]\s+", line):
            total += 1
            completed += 1
        elif re.match(r"^\s*-\s+\[\s\]\s+", line):
            total += 1
            if current_id is None:
                current_id = f"todo-{total}"

open_todos = max(total - completed, 0)
print(json.dumps({
    "completedTodos": completed,
    "totalTodos": total,
    "openTodos": open_todos,
    "currentTodoId": current_id,
}, separators=(",", ":")))
PY
}

# workflow_state_resolve_generated_plan_manifest --registry-run ... --planner-stage-id ...
#   [--planner-attempt N] [--graph-workspace ...] [--namespace ...] [--run-id ...]
#
# Resolves the immutable source manifest for a planFrom consumer. When graph
# ledger args are provided, requires the planner node's latest attempt to be
# succeeded and uses that attempt number. Otherwise --planner-attempt is
# required. Prints absolute manifest path on stdout.
workflow_state_resolve_generated_plan_manifest() {
  local registry_run="" planner_stage_id="" planner_attempt=""
  local graph_workspace="" namespace="" run_id=""
  local run_dir manifest_path node_file status last_attempt attempt_num

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --planner-stage-id) planner_stage_id="${2:-}"; shift 2 ;;
      --planner-attempt) planner_attempt="${2:-}"; shift 2 ;;
      --graph-workspace) graph_workspace="${2:-}"; shift 2 ;;
      --namespace) namespace="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_state_resolve_generated_plan_manifest argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$registry_run" && -n "$planner_stage_id" ]] || {
    echo "Error: workflow_state_resolve_generated_plan_manifest requires --registry-run --planner-stage-id" >&2
    return 1
  }
  if ! _workflow_state_stage_id_ok "$planner_stage_id"; then
    echo "Error: planner stage id must be lowercase-hyphen: $planner_stage_id" >&2
    return 1
  fi

  registry_run="$(_workflow_state_abs_path "$registry_run")" || return 1
  run_dir="$(_workflow_state_real_dir "$registry_run")" || {
    echo "Error: registry-run is not a usable directory: $registry_run" >&2
    return 1
  }

  if [[ -n "$graph_workspace" && -n "$namespace" && -n "$run_id" ]]; then
    if ! declare -F graph_state_node_file >/dev/null 2>&1; then
      # shellcheck source=../graph/graph-state.sh
      source "$_WORKFLOW_STATE_SCRIPT_DIR/../graph/graph-state.sh"
    fi
    node_file="$(graph_state_node_file "$graph_workspace" "$namespace" "$run_id" "$planner_stage_id")" || return 1
    [[ -f "$node_file" ]] || {
      echo "Error: planner stage ledger missing (unmet dependency): $planner_stage_id (expected $node_file)" >&2
      return 1
    }
    status="$(jq -r '.status // empty' "$node_file")"
    [[ "$status" == "succeeded" ]] || {
      echo "Error: planner stage $planner_stage_id latest attempt is not succeeded (status=$status)" >&2
      return 1
    }
    last_attempt="$(jq -r '.lastAttemptId // empty' "$node_file")"
    [[ -n "$last_attempt" ]] || {
      echo "Error: planner stage $planner_stage_id has no succeeded attempt id" >&2
      return 1
    }
    attempt_num="$(printf '%s' "$last_attempt" | sed -n 's/.*__\([0-9][0-9]*\)$/\1/p')"
    [[ -n "$attempt_num" ]] || {
      echo "Error: cannot parse planner attempt number from $last_attempt" >&2
      return 1
    }
    if [[ -n "$planner_attempt" && "$planner_attempt" != "$attempt_num" ]]; then
      echo "Error: planner attempt mismatch: ledger=$attempt_num requested=$planner_attempt" >&2
      return 1
    fi
    planner_attempt="$attempt_num"
  fi

  [[ -n "$planner_attempt" && "$planner_attempt" =~ ^[1-9][0-9]*$ ]] || {
    echo "Error: --planner-attempt is required when graph ledger context is absent" >&2
    return 1
  }

  manifest_path="$run_dir/plans/$planner_stage_id/attempt-${planner_attempt}.manifest.json"
  if [[ -L "$manifest_path" ]]; then
    echo "Error: refusing symlink manifest: $manifest_path" >&2
    return 1
  fi
  [[ -f "$manifest_path" ]] || {
    echo "Error: missing generated-plan manifest for planner $planner_stage_id attempt $planner_attempt: $manifest_path" >&2
    return 1
  }
  printf '%s\n' "$manifest_path"
}

# workflow_state_validate_generated_plan_evidence <manifest-path> [--expect-planner-stage-id ID]
# Re-validates manifest schema, absolute paths, planSha256 vs source plan bytes,
# and validate-plan.sh. Does not mutate source plan or manifest.
workflow_state_validate_generated_plan_evidence() {
  local manifest_path="${1:-}"
  local expect_planner=""
  local py plan_path expected_sha actual_sha producer validate_sh
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --expect-planner-stage-id) expect_planner="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_state_validate_generated_plan_evidence argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$manifest_path" && -f "$manifest_path" && ! -L "$manifest_path" ]] || {
    echo "Error: generated-plan manifest path required" >&2
    return 1
  }
  manifest_path="$(_workflow_state_abs_path "$manifest_path")" || return 1
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to validate generated-plan evidence" >&2
    return 1
  }
  py="$(_workflow_state_planner_contract_py)" || return 1
  if ! python3 "$py" validate-manifest --manifest "$manifest_path" >/dev/null; then
    echo "Error: generated-plan manifest schema/hash contract failed: $manifest_path" >&2
    return 1
  fi

  producer="$(jq -r '.producerStageId // empty' "$manifest_path")"
  plan_path="$(jq -r '.planPath // empty' "$manifest_path")"
  expected_sha="$(jq -r '.planSha256 // empty' "$manifest_path")"
  [[ -n "$producer" && -n "$plan_path" && -n "$expected_sha" ]] || {
    echo "Error: generated-plan manifest missing required fields" >&2
    return 1
  }
  if [[ -n "$expect_planner" && "$producer" != "$expect_planner" ]]; then
    echo "Error: manifest producerStageId $producer does not match frozen planner $expect_planner" >&2
    return 1
  fi
  case "$plan_path" in
    /*) ;;
    *)
      echo "Error: manifest planPath must be absolute: $plan_path" >&2
      return 1
      ;;
  esac
  if [[ -L "$plan_path" ]]; then
    echo "Error: refusing symlink source plan: $plan_path" >&2
    return 1
  fi
  [[ -f "$plan_path" ]] || {
    echo "Error: source plan missing for manifest: $plan_path" >&2
    return 1
  }
  actual_sha="$(_workflow_state_file_sha256 "$plan_path")" || {
    echo "Error: failed to hash source plan: $plan_path" >&2
    return 1
  }
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Error: source plan hash mismatch (stale or mutated): expected=$expected_sha actual=$actual_sha" >&2
    return 1
  fi

  validate_sh="$(_workflow_state_validate_plan_sh)" || return 1
  if ! bash "$validate_sh" "$plan_path" >/dev/null 2>&1; then
    echo "Error: source plan failed validate-plan.sh: $plan_path" >&2
    return 1
  fi
  return 0
}

# workflow_state_bind_generated_plan_control --registry-run ... --consumer-stage-id ...
#   --consumer-attempt N --planner-stage-id ...
#   [--planner-attempt N] [--graph-workspace ...] [--namespace ...] [--run-id ...]
#   [--plan-run-id ID] [--force-fresh]
#
# At first dispatch for this consumer attempt: resolve + validate planner
# evidence, then byte-copy the immutable source into
#   <registry-run>/plans/<consumer>/attempt-<n>/control.plan.md
# Resume reuses that control copy. Consumer reset and each bounded rework clone
# pass --force-fresh for a new byte-copy from the same frozen source (never
# mutates planner JSON or the immutable generated source/manifest). Prints
# compact JSON with source/control paths, planRunId, and TODO progress.
workflow_state_bind_generated_plan_control() {
  local registry_run="" consumer_stage_id="" consumer_attempt="" planner_stage_id=""
  local planner_attempt="" graph_workspace="" namespace="" run_id="" plan_run_id=""
  local force_fresh=0
  local run_dir manifest_path source_plan control_dir control_path progress
  local source_sha created_control=0 resolve_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --consumer-stage-id) consumer_stage_id="${2:-}"; shift 2 ;;
      --consumer-attempt) consumer_attempt="${2:-}"; shift 2 ;;
      --planner-stage-id) planner_stage_id="${2:-}"; shift 2 ;;
      --planner-attempt) planner_attempt="${2:-}"; shift 2 ;;
      --graph-workspace) graph_workspace="${2:-}"; shift 2 ;;
      --namespace) namespace="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --plan-run-id) plan_run_id="${2:-}"; shift 2 ;;
      --force-fresh) force_fresh=1; shift ;;
      *)
        echo "Error: unknown workflow_state_bind_generated_plan_control argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$registry_run" && -n "$consumer_stage_id" && -n "$consumer_attempt" && -n "$planner_stage_id" ]] || {
    echo "Error: workflow_state_bind_generated_plan_control requires --registry-run --consumer-stage-id --consumer-attempt --planner-stage-id" >&2
    return 1
  }
  if ! _workflow_state_stage_id_ok "$consumer_stage_id"; then
    echo "Error: consumer stage id must be lowercase-hyphen: $consumer_stage_id" >&2
    return 1
  fi
  if ! _workflow_state_stage_id_ok "$planner_stage_id"; then
    echo "Error: planner stage id must be lowercase-hyphen: $planner_stage_id" >&2
    return 1
  fi
  if ! [[ "$consumer_attempt" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: consumer attempt must be a positive integer (got $consumer_attempt)" >&2
    return 1
  fi

  registry_run="$(_workflow_state_abs_path "$registry_run")" || return 1
  run_dir="$(_workflow_state_real_dir "$registry_run")" || {
    echo "Error: registry-run is not a usable directory: $registry_run" >&2
    return 1
  }

  resolve_args=(--registry-run "$run_dir" --planner-stage-id "$planner_stage_id")
  [[ -n "$planner_attempt" ]] && resolve_args+=(--planner-attempt "$planner_attempt")
  if [[ -n "$graph_workspace" && -n "$namespace" && -n "$run_id" ]]; then
    resolve_args+=(--graph-workspace "$graph_workspace" --namespace "$namespace" --run-id "$run_id")
  fi
  manifest_path="$(workflow_state_resolve_generated_plan_manifest "${resolve_args[@]}")" || return 1
  workflow_state_validate_generated_plan_evidence "$manifest_path" \
    --expect-planner-stage-id "$planner_stage_id" || return 1

  source_plan="$(jq -r '.planPath' "$manifest_path")"
  source_sha="$(jq -r '.planSha256' "$manifest_path")"
  control_dir="$run_dir/plans/$consumer_stage_id/attempt-${consumer_attempt}"
  control_path="$control_dir/control.plan.md"

  # Containment: control must stay under registry-run/plans/<consumer>/
  case "$control_path" in
    "$run_dir/plans/$consumer_stage_id/"*) ;;
    *)
      echo "Error: control path escaped registry run: $control_path" >&2
      return 1
      ;;
  esac

  if [[ -L "$control_dir" || -L "$control_path" ]]; then
    echo "Error: refusing symlink control path under $control_dir" >&2
    return 1
  fi

  if [[ "$force_fresh" -eq 1 && -f "$control_path" ]]; then
    rm -f "$control_path" || {
      echo "Error: failed to clear prior control copy for fresh bind: $control_path" >&2
      return 1
    }
  fi

  if [[ -f "$control_path" ]]; then
    # Resume: reuse existing control; still require source hash match.
    if [[ "$(_workflow_state_file_sha256 "$source_plan")" != "$source_sha" ]]; then
      echo "Error: source plan hash stale while resuming control copy" >&2
      return 1
    fi
  else
    mkdir -p "$control_dir" || {
      echo "Error: failed to create control directory: $control_dir" >&2
      return 1
    }
    if ! cp "$source_plan" "$control_path"; then
      rm -f "$control_path" 2>/dev/null || true
      echo "Error: failed to create control copy from $source_plan" >&2
      return 1
    fi
    # Source plans are published immutable (a-w); the control copy must remain
    # mutable so runner-owned checkbox transitions can update TODO state.
    chmod u+w "$control_path" 2>/dev/null || true
    created_control=1
    _workflow_state_fsync "$control_path"
    _workflow_state_fsync "$control_dir"
  fi

  progress="$(workflow_state_plan_progress_json "$control_path")" || {
    [[ "$created_control" -eq 1 ]] && rm -f "$control_path"
    return 1
  }
  if [[ "$(printf '%s' "$progress" | jq -r '.totalTodos')" -lt 1 ]]; then
    [[ "$created_control" -eq 1 ]] && rm -f "$control_path"
    echo "Error: control plan has no TODOs" >&2
    return 1
  fi

  if [[ -z "$plan_run_id" ]]; then
    plan_run_id="${consumer_stage_id}__attempt-${consumer_attempt}"
  fi

  jq -cn \
    --arg source "$source_plan" \
    --arg control "$control_path" \
    --arg manifest "$manifest_path" \
    --arg planner "$planner_stage_id" \
    --arg consumer "$consumer_stage_id" \
    --argjson attempt "$consumer_attempt" \
    --arg planRunId "$plan_run_id" \
    --arg sha "$source_sha" \
    --argjson progress "$progress" \
    --argjson created "$created_control" \
    '{
      planSourceKind: "generated",
      planSourceStageId: $planner,
      consumerStageId: $consumer,
      consumerAttempt: $attempt,
      originalPlanPath: null,
      sourcePlanPath: $source,
      controlPlanPath: $control,
      manifestPath: $manifest,
      planPath: $control,
      planRunId: $planRunId,
      planSha256: $sha,
      completedTodos: $progress.completedTodos,
      totalTodos: $progress.totalTodos,
      currentTodoId: $progress.currentTodoId,
      createdControl: ($created == 1)
    }'
}

# ---------------------------------------------------------------------------
# Provided planInput consumer: validate input manifest + mutable control copy
# ---------------------------------------------------------------------------

# workflow_state_provided_input_manifest_path <registry-run>
# Prints absolute plans/input/manifest.json path.
workflow_state_provided_input_manifest_path() {
  local registry_run="${1:-}"
  local run_dir
  [[ -n "$registry_run" ]] || {
    echo "Error: workflow_state_provided_input_manifest_path requires registry-run" >&2
    return 1
  }
  registry_run="$(_workflow_state_abs_path "$registry_run")" || return 1
  run_dir="$(_workflow_state_real_dir "$registry_run")" || {
    echo "Error: registry-run is not a usable directory: $registry_run" >&2
    return 1
  }
  printf '%s\n' "$run_dir/plans/input/manifest.json"
}

# workflow_state_validate_provided_plan_evidence --registry-run ...
# Re-validates the common input manifest schema, absolute paths, copiedSha256
# vs frozen source.plan.md bytes, and validate-plan.sh. Does not create a
# control copy and never mutates the original or frozen source.
workflow_state_validate_provided_plan_evidence() {
  local registry_run=""
  local run_dir manifest_path source_plan original_path expected_sha actual_sha validate_sh

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      *)
        echo "Error: unknown workflow_state_validate_provided_plan_evidence argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$registry_run" ]] || {
    echo "Error: workflow_state_validate_provided_plan_evidence requires --registry-run" >&2
    return 1
  }
  registry_run="$(_workflow_state_abs_path "$registry_run")" || return 1
  run_dir="$(_workflow_state_real_dir "$registry_run")" || {
    echo "Error: registry-run is not a usable directory: $registry_run" >&2
    return 1
  }

  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required to validate provided-plan evidence" >&2
    return 1
  }

  if ! declare -F plan_provided_input_validate_manifest >/dev/null 2>&1; then
    # shellcheck source=../plan-todo.sh
    source "$_WORKFLOW_STATE_SCRIPT_DIR/../plan-todo.sh" || {
      echo "Error: failed to load plan-todo helpers for provided-plan validation" >&2
      return 1
    }
  fi

  manifest_path="$run_dir/plans/input/manifest.json"
  if [[ -L "$manifest_path" ]]; then
    echo "Error: refusing symlink provided-plan manifest: $manifest_path" >&2
    return 1
  fi
  [[ -f "$manifest_path" ]] || {
    echo "Error: missing/invalid input: provided-plan manifest not found: $manifest_path" >&2
    return 1
  }
  if ! plan_provided_input_validate_manifest "$manifest_path"; then
    echo "Error: invalid input: provided-plan manifest failed schema validation: $manifest_path" >&2
    return 1
  fi

  if [[ "$(jq -r '.sourceKind // empty' "$manifest_path")" != "provided" ]]; then
    echo "Error: invalid input: provided-plan manifest sourceKind must be provided" >&2
    return 1
  fi

  source_plan="$(jq -r '.copiedPath // empty' "$manifest_path")"
  original_path="$(jq -r '.originalPath // empty' "$manifest_path")"
  expected_sha="$(jq -r '.copiedSha256 // empty' "$manifest_path")"
  [[ -n "$source_plan" && -n "$original_path" && -n "$expected_sha" ]] || {
    echo "Error: invalid input: provided-plan manifest missing required path/hash fields" >&2
    return 1
  }
  case "$source_plan" in
    /*) ;;
    *)
      echo "Error: invalid input: copiedPath must be absolute: $source_plan" >&2
      return 1
      ;;
  esac
  case "$original_path" in
    /*) ;;
    *)
      echo "Error: invalid input: originalPath must be absolute: $original_path" >&2
      return 1
      ;;
  esac
  case "$source_plan" in
    "$run_dir/plans/input/"*) ;;
    *)
      echo "Error: invalid input: copiedPath escaped registry plans/input/: $source_plan" >&2
      return 1
      ;;
  esac
  if [[ -L "$source_plan" ]]; then
    echo "Error: refusing symlink frozen provided source: $source_plan" >&2
    return 1
  fi
  [[ -f "$source_plan" ]] || {
    echo "Error: missing/invalid input: frozen provided source missing: $source_plan" >&2
    return 1
  }
  actual_sha="$(_workflow_state_file_sha256 "$source_plan")" || {
    echo "Error: failed to hash frozen provided source: $source_plan" >&2
    return 1
  }
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Error: invalid input: frozen provided source hash mismatch (stale or corrupted): expected=$expected_sha actual=$actual_sha" >&2
    return 1
  fi

  validate_sh="$(_workflow_state_validate_plan_sh)" || return 1
  if ! bash "$validate_sh" "$source_plan" >/dev/null 2>&1; then
    echo "Error: invalid input: frozen provided source failed validate-plan.sh: $source_plan" >&2
    return 1
  fi
  return 0
}

# workflow_state_bind_provided_plan_control --registry-run ... --consumer-stage-id ...
#   --consumer-attempt N [--plan-run-id ID] [--force-fresh]
#
# Validates the common input manifest/hash/frozen plan, then creates or reuses
# a durable mutable control copy at:
#   <registry-run>/plans/<consumer>/attempt-<n>/control.plan.md
# Resume (same consumer attempt) reuses the existing control. Consumer reset
# and each bounded rework clone pass --force-fresh for a new byte-copy from the
# same frozen source (never mutates original or frozen source/manifest).
# Prints compact JSON with original/source/control paths and TODO progress.
workflow_state_bind_provided_plan_control() {
  local registry_run="" consumer_stage_id="" consumer_attempt="" plan_run_id=""
  local force_fresh=0
  local run_dir manifest_path source_plan original_path control_dir control_path
  local source_sha progress created_control=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registry-run) registry_run="${2:-}"; shift 2 ;;
      --consumer-stage-id) consumer_stage_id="${2:-}"; shift 2 ;;
      --consumer-attempt) consumer_attempt="${2:-}"; shift 2 ;;
      --plan-run-id) plan_run_id="${2:-}"; shift 2 ;;
      --force-fresh) force_fresh=1; shift ;;
      *)
        echo "Error: unknown workflow_state_bind_provided_plan_control argument: $1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$registry_run" && -n "$consumer_stage_id" && -n "$consumer_attempt" ]] || {
    echo "Error: workflow_state_bind_provided_plan_control requires --registry-run --consumer-stage-id --consumer-attempt" >&2
    return 1
  }
  if ! _workflow_state_stage_id_ok "$consumer_stage_id"; then
    echo "Error: consumer stage id must be lowercase-hyphen: $consumer_stage_id" >&2
    return 1
  fi
  if ! [[ "$consumer_attempt" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: consumer attempt must be a positive integer (got $consumer_attempt)" >&2
    return 1
  fi

  registry_run="$(_workflow_state_abs_path "$registry_run")" || return 1
  run_dir="$(_workflow_state_real_dir "$registry_run")" || {
    echo "Error: registry-run is not a usable directory: $registry_run" >&2
    return 1
  }

  workflow_state_validate_provided_plan_evidence --registry-run "$run_dir" || return 1

  manifest_path="$run_dir/plans/input/manifest.json"
  source_plan="$(jq -r '.copiedPath' "$manifest_path")"
  original_path="$(jq -r '.originalPath' "$manifest_path")"
  source_sha="$(jq -r '.copiedSha256' "$manifest_path")"
  control_dir="$run_dir/plans/$consumer_stage_id/attempt-${consumer_attempt}"
  control_path="$control_dir/control.plan.md"

  case "$control_path" in
    "$run_dir/plans/$consumer_stage_id/"*) ;;
    *)
      echo "Error: control path escaped registry run: $control_path" >&2
      return 1
      ;;
  esac

  if [[ -L "$control_dir" || -L "$control_path" ]]; then
    echo "Error: refusing symlink control path under $control_dir" >&2
    return 1
  fi

  if [[ "$force_fresh" -eq 1 && -f "$control_path" ]]; then
    rm -f "$control_path" || {
      echo "Error: failed to clear prior control copy for fresh bind: $control_path" >&2
      return 1
    }
  fi

  if [[ -f "$control_path" ]]; then
    if [[ "$(_workflow_state_file_sha256 "$source_plan")" != "$source_sha" ]]; then
      echo "Error: frozen provided source hash stale while resuming control copy" >&2
      return 1
    fi
  else
    mkdir -p "$control_dir" || {
      echo "Error: failed to create control directory: $control_dir" >&2
      return 1
    }
    if ! cp "$source_plan" "$control_path"; then
      rm -f "$control_path" 2>/dev/null || true
      echo "Error: failed to create provided-plan control copy from $source_plan" >&2
      return 1
    fi
    chmod u+w "$control_path" 2>/dev/null || true
    created_control=1
    _workflow_state_fsync "$control_path"
    _workflow_state_fsync "$control_dir"
  fi

  progress="$(workflow_state_plan_progress_json "$control_path")" || {
    [[ "$created_control" -eq 1 ]] && rm -f "$control_path"
    return 1
  }
  if [[ "$(printf '%s' "$progress" | jq -r '.totalTodos')" -lt 1 ]]; then
    [[ "$created_control" -eq 1 ]] && rm -f "$control_path"
    echo "Error: control plan has no TODOs" >&2
    return 1
  fi

  if [[ -z "$plan_run_id" ]]; then
    plan_run_id="${consumer_stage_id}__attempt-${consumer_attempt}"
  fi

  jq -cn \
    --arg original "$original_path" \
    --arg source "$source_plan" \
    --arg control "$control_path" \
    --arg manifest "$manifest_path" \
    --arg consumer "$consumer_stage_id" \
    --argjson attempt "$consumer_attempt" \
    --arg planRunId "$plan_run_id" \
    --arg sha "$source_sha" \
    --argjson progress "$progress" \
    --argjson created "$created_control" \
    '{
      planSourceKind: "provided",
      planSourceStageId: null,
      consumerStageId: $consumer,
      consumerAttempt: $attempt,
      originalPlanPath: $original,
      sourcePlanPath: $source,
      controlPlanPath: $control,
      manifestPath: $manifest,
      planPath: $control,
      planRunId: $planRunId,
      planSha256: $sha,
      completedTodos: $progress.completedTodos,
      totalTodos: $progress.totalTodos,
      currentTodoId: $progress.currentTodoId,
      createdControl: ($created == 1)
    }'
}

# workflow_state_clear_owner_and_set_state <state-root> <run-id> <state>
# Atomically set public run state and clear live owner (waiting/blocked/cancelled).
workflow_state_clear_owner_and_set_state() {
  local state_root="${1:-}" run_id="${2:-}" state="${3:-}"
  [[ -n "$state_root" && -n "$run_id" && -n "$state" ]] || {
    echo "Error: workflow_state_clear_owner_and_set_state requires state-root run-id state" >&2
    return 1
  }
  case "$state" in
    queued|running|waiting|blocked|stale|failed|cancelled|succeeded) ;;
    *)
      echo "Error: invalid workflow public state: $state" >&2
      return 1
      ;;
  esac
  workflow_state_update "$state_root" "$run_id" \
    '.state = $state | .owner = {pid:null,hostname:null,processStartId:null,heartbeatAt:null}' \
    --arg state "$state"
}

# workflow_state_classify_owner_json <owner-json> [ttl_seconds] [now_epoch]
# Shared outer/engine owner liveness classifier. Prints:
#   absent | healthy | stale | unknown
# Never infers ownership from PID alone: expired heartbeats require a matching
# process-start identity (or a dead PID) before classifying stale.
workflow_state_classify_owner_json() {
  local owner_json="${1:-}"
  local ttl_seconds="${2:-${WORKFLOW_STATE_OWNER_TTL_SECONDS:-${WORKFLOW_SEQ_OWNER_TTL_SECONDS:-${GRAPH_HEARTBEAT_TTL_SECONDS:-60}}}}"
  local now_epoch="${3:-${WORKFLOW_STATE_OWNER_NOW_EPOCH:-${WORKFLOW_SEQ_OWNER_NOW_EPOCH:-${GRAPH_HEARTBEAT_NOW_EPOCH:-}}}}"
  local heartbeat_at heartbeat_epoch pid owner_start_id current_start_id pid_rc=0

  command -v jq >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }

  if [[ -z "$owner_json" || "$owner_json" == "null" ]]; then
    printf 'absent\n'
    return 0
  fi
  if ! printf '%s' "$owner_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi

  pid="$(printf '%s' "$owner_json" | jq -r '.pid // empty')"
  if [[ -z "$pid" || "$pid" == "null" ]]; then
    printf 'absent\n'
    return 0
  fi

  if [[ -z "$now_epoch" ]]; then
    if declare -F graph_heartbeat_now_epoch >/dev/null 2>&1; then
      now_epoch="$(graph_heartbeat_now_epoch 2>/dev/null || date +%s)"
    else
      now_epoch="$(date +%s)"
    fi
  fi
  [[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=60

  heartbeat_at="$(printf '%s' "$owner_json" | jq -r '.heartbeatAt // empty')"
  if [[ -z "$heartbeat_at" || "$heartbeat_at" == "null" ]]; then
    printf 'unknown\n'
    return 0
  fi
  if declare -F graph_heartbeat_parse_iso_to_epoch >/dev/null 2>&1; then
    heartbeat_epoch="$(graph_heartbeat_parse_iso_to_epoch "$heartbeat_at" 2>/dev/null)" || true
  else
    heartbeat_epoch=""
  fi
  if [[ -z "$heartbeat_epoch" || ! "$heartbeat_epoch" =~ ^[0-9]+$ ]]; then
    printf 'unknown\n'
    return 0
  fi

  if [[ "$(( now_epoch - heartbeat_epoch ))" -lt "$ttl_seconds" ]]; then
    printf 'healthy\n'
    return 0
  fi

  [[ "$pid" =~ ^[0-9]+$ ]] || { printf 'unknown\n'; return 0; }
  owner_start_id="$(printf '%s' "$owner_json" | jq -r '.processStartId // empty')"
  if declare -F graph_heartbeat_process_start_id_of_pid >/dev/null 2>&1; then
    current_start_id="$(graph_heartbeat_process_start_id_of_pid "$pid")"; pid_rc=$?
  else
    current_start_id=""
    pid_rc=2
  fi

  if [[ "$pid_rc" -eq 2 ]]; then
    printf 'unknown\n'
    return 0
  fi
  if [[ "$pid_rc" -eq 1 ]]; then
    printf 'stale\n'
    return 0
  fi
  if [[ -z "$owner_start_id" || "$owner_start_id" == "null" ]]; then
    # Expired heartbeat with a live PID but no recorded start id: never trust PID alone.
    printf 'unknown\n'
    return 0
  fi
  if [[ "$current_start_id" != "$owner_start_id" ]]; then
    printf 'stale\n'
    return 0
  fi
  printf 'unknown\n'
  return 0
}

# workflow_state_live_owner_matches <owner-json> [expected-hostname]
# Strengthening check for cancel: requires healthy classification, live PID,
# matching processStartId, and (when recorded) a matching hostname. Prints:
#   owned | foreign | not-live
# Returns 0 only for owned. Never infers ownership from PID alone.
workflow_state_live_owner_matches() {
  local owner_json="${1:-}"
  local expected_hostname="${2:-}"
  local health pid recorded_start recorded_host current_start pid_rc=0

  health="$(workflow_state_classify_owner_json "$owner_json" 2>/dev/null || echo unknown)"
  if [[ "$health" != "healthy" ]]; then
    printf 'not-live\n'
    return 1
  fi

  pid="$(printf '%s' "$owner_json" | jq -r '.pid // empty' 2>/dev/null)"
  recorded_start="$(printf '%s' "$owner_json" | jq -r '.processStartId // empty' 2>/dev/null)"
  recorded_host="$(printf '%s' "$owner_json" | jq -r '.hostname // empty' 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] || { printf 'not-live\n'; return 1; }
  [[ -n "$recorded_start" && "$recorded_start" != "null" ]] || { printf 'foreign\n'; return 1; }

  if ! declare -F graph_heartbeat_process_start_id_of_pid >/dev/null 2>&1; then
    printf 'not-live\n'
    return 1
  fi
  current_start="$(graph_heartbeat_process_start_id_of_pid "$pid")"; pid_rc=$?
  if [[ "$pid_rc" -ne 0 ]]; then
    printf 'not-live\n'
    return 1
  fi
  if [[ "$current_start" != "$recorded_start" ]]; then
    printf 'foreign\n'
    return 1
  fi

  if [[ -z "$expected_hostname" ]] && declare -F graph_state_owner_hostname >/dev/null 2>&1; then
    expected_hostname="$(graph_state_owner_hostname 2>/dev/null || true)"
  fi
  if [[ -n "$recorded_host" && -n "$expected_hostname" && "$recorded_host" != "$expected_hostname" ]]; then
    printf 'foreign\n'
    return 1
  fi

  printf 'owned\n'
  return 0
}

# workflow_state_run_lock_is_live <state-root> <run-id>
# Returns 0 when the per-run update lock is held by a proven live owner
# (PID alive + matching processStartId). Absent/stale locks return 1.
workflow_state_run_lock_is_live() {
  local state_root="${1:-}" run_id="${2:-}"
  local lock_path
  [[ -n "$state_root" && -n "$run_id" ]] || return 1
  lock_path="$(workflow_state_update_lock_path "$state_root" "$run_id" 2>/dev/null)" || return 1
  [[ -d "$lock_path" ]] || return 1
  if _workflow_state_lock_is_stale "$lock_path"; then
    return 1
  fi
  return 0
}

# workflow_state_write_diagnosis <registry-run> <diagnosis-json-or-path>
# Diagnosis is a separate durable projection so the strict run identity schema
# remains stable while interruption/recovery retains a copyable next action.
workflow_state_write_diagnosis() {
  local registry_run="${1:-}" input="${2:-}" raw path tmp
  [[ -n "$registry_run" && -d "$registry_run" && -n "$input" ]] || {
    echo "Error: workflow_state_write_diagnosis requires registry-run and diagnosis" >&2
    return 1
  }
  if [[ "$input" == \{* ]]; then
    raw="$input"
  elif [[ -f "$input" ]]; then
    raw="$(cat -- "$input")"
  else
    echo "Error: diagnosis must be a JSON object or file" >&2
    return 1
  fi
  printf '%s' "$raw" | jq -e 'type == "object" and .state == "waiting" and .reasonCode == "operator-request" and .retryable == true' >/dev/null 2>&1 || {
    echo "Error: invalid operator interruption diagnosis" >&2
    return 1
  }
  path="$registry_run/diagnosis.json"
  [[ ! -L "$path" ]] || return 1
  tmp="$(mktemp "$registry_run/.diagnosis-XXXXXX")" || return 1
  if ! printf '%s\n' "$raw" | jq -c . >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  _workflow_state_fsync "$tmp"
  mv -f "$tmp" "$path" || {
    rm -f "$tmp"
    return 1
  }
  _workflow_state_fsync "$registry_run"
  printf '%s\n' "$path"
}

# workflow_state_record_cancel_intent <registry-run> <intent-json-or-path>
# Durable cancel intent under actions/cancel-intent.json (create-once).
# Prints absolute path. Identical replay is accepted; conflicting content fails.
workflow_state_record_cancel_intent() {
  local registry_run="${1:-}" input="${2:-}"
  local raw abs rel now

  [[ -n "$registry_run" && -d "$registry_run" ]] || {
    echo "Error: workflow_state_record_cancel_intent requires a registry-run directory" >&2
    return 1
  }
  if ! declare -F graph_operator_load_json >/dev/null 2>&1; then
    # shellcheck source=../graph/graph-operator-records.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../graph/graph-operator-records.sh"
  fi
  if ! declare -F workflow_action_now_iso >/dev/null 2>&1; then
    # shellcheck source=./workflow-actions.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workflow-actions.sh"
  fi
  raw="$(graph_operator_load_json "$input")" || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: cancel intent must be a JSON object" >&2
    return 1
  fi
  now="$(workflow_action_now_iso)"
  raw="$(printf '%s' "$raw" | jq -c --arg now "$now" '
    . + {
      schemaVersion: (.schemaVersion // 1),
      kind: "cancel-intent",
      recordedAt: (.recordedAt // $now)
    }
  ')" || return 1
  rel="actions/cancel-intent.json"
  abs="$(workflow_action_prepare_write "$registry_run" "$rel" "actions/cancel-intent.json")" || return 1
  if [[ -f "$abs" ]]; then
    if jq -e --argjson want "$raw" '. == $want' "$abs" >/dev/null 2>&1; then
      printf '%s\n' "$abs"
      return 0
    fi
    echo "Error: cancel intent conflicts with an existing durable record" >&2
    return 1
  fi
  graph_operator_create_once_write "$abs" "$raw" || return 1
  printf '%s\n' "$abs"
}
