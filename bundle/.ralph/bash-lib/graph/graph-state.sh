#!/usr/bin/env bash
# Durable run-state ledger for graph mode.
#
# The plan file is the loop state (which todo is next, which are done). This
# ledger is the graph state: which run, which nodes, which attempt, which
# outcome. Never encode graph progress into plan checkboxes - the two states
# are deliberately separate so a run can be inspected and resumed even when
# the plan source has moved or changed, and so that loop idempotency inside a
# node (completed todos already marked done) composes cleanly with graph
# resume (succeeded nodes stay succeeded). See p3-resume for the load-bearing
# rationale.
#
# Layout under <state-root>/graph-runs/<namespace>/<run_id>/ (the default
# state root remains <workspace>/.ralph-workspace):
#   run.json     - schemaVersion, ralphVersion, runId, planPath, graphSha,
#                  startedAt, status, maxParallel. status is one of
#                  running, succeeded, failed, awaiting-ack, cancelled.
#   graph.json   - frozen compile output, immutable for the life of the run.
#   nodes/<node_id>.json - per-node ledger entry: nodeId, status, attempts[],
#                  lastAttemptId. Node states: pending, ready, running,
#                  succeeded, failed, blocked, skipped, awaiting-ack,
#                  cancelled. attempts entries carry attemptId, outcome,
#                  exitCode, startedAt, finishedAt, runtime, subagents,
#                  reason. Recording subagents per attempt keeps usage and
#                  savings comparisons honest: subagent tokens are an
#                  invocation-level cost that Ralph cannot itemize, so a run
#                  that had subagents=on for one node is not comparable to a
#                  run that did not without this provenance.
# A `latest` symlink at <state-root>/graph-runs/<namespace>/latest
# points at the newest run directory so resume can address it by name.
#
# All node state writes go through the shared ralph_atomic_write_json helper
# (see bundle/.ralph/bash-lib/atomic-json.sh) so no partial JSON is ever
# observable mid-write, matching the StageOutcomeReport contract. The ledger
# is jq-only; no python3 is required to read or update it, so resume and
# status operate on the frozen graph.json without re-entering the compiler.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

GRAPH_STATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F ralph_atomic_write_json >/dev/null 2>&1; then
  # shellcheck source=../atomic-json.sh
  source "$GRAPH_STATE_SCRIPT_DIR/../atomic-json.sh"
fi

# Schema version for run.json. Existing callers (the live scheduler) write
# and expect exactly this version; do not bump it here. See the p4-state-v2
# section near the end of this file for the v2 schema, states, and readers.
GRAPH_STATE_RUN_SCHEMA_VERSION=1
# Schema version for per-node ledger entries. Same stability note as above.
GRAPH_STATE_NODE_SCHEMA_VERSION=1

# The nine v1 node states. Order is stable for round-trip tests; do not
# reorder. v2 appends four more states after this array is defined (see
# p4-state-v2 below); appending, not reordering, keeps this literal list's
# round-trip tests unaffected.
GRAPH_STATE_NODE_STATES=(
  pending
  ready
  running
  succeeded
  failed
  blocked
  skipped
  awaiting-ack
  cancelled
)

# Run-level statuses (subset of node states that make sense for the whole run).
# v2 appends two more statuses after this array is defined (see
# p4-state-v2 below).
GRAPH_STATE_RUN_STATUSES=(
  running
  succeeded
  failed
  awaiting-ack
  cancelled
)

# graph_state_state_root <workspace>
# Prints the durable state root. RALPH_GRAPH_STATE_ROOT is the graph-run-owned
# exact state root; RALPH_PLAN_WORKSPACE_ROOT is the public three-root
# equivalent. With neither set, preserve the legacy workspace default.
graph_state_state_root() {
  local workspace="$1"
  if [[ -z "$workspace" ]]; then
    echo "Error: graph_state_state_root requires a workspace" >&2
    return 1
  fi
  if [[ -n "${RALPH_GRAPH_STATE_ROOT:-}" ]]; then
    printf '%s\n' "${RALPH_GRAPH_STATE_ROOT%/}"
  elif [[ -n "${RALPH_PLAN_WORKSPACE_ROOT:-}" ]]; then
    printf '%s\n' "${RALPH_PLAN_WORKSPACE_ROOT%/}"
  else
    printf '%s/.ralph-workspace\n' "$workspace"
  fi
}

# graph_state_runs_root <workspace>
# Prints the graph-runs directory below the resolved durable state root.
graph_state_runs_root() {
  local workspace="$1" state_root
  state_root="$(graph_state_state_root "$workspace")" || return 1
  printf '%s/graph-runs\n' "$state_root"
}

# graph_state_runs_namespace_root <workspace> <namespace>
# Prints the per-namespace runs directory. Does not create it.
graph_state_runs_namespace_root() {
  local workspace="$1" namespace="$2"
  if [[ -z "$workspace" || -z "$namespace" ]]; then
    echo "Error: graph_state_runs_namespace_root requires workspace and namespace" >&2
    return 1
  fi
  printf '%s/%s\n' "$(graph_state_runs_root "$workspace")" "$namespace"
}

# graph_state_run_dir <workspace> <namespace> <run_id>
# Prints the directory for one run. Does not create it.
graph_state_run_dir() {
  local workspace="$1" namespace="$2" run_id="$3"
  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" ]]; then
    echo "Error: graph_state_run_dir requires workspace, namespace, and run_id" >&2
    return 1
  fi
  printf '%s/%s\n' "$(graph_state_runs_namespace_root "$workspace" "$namespace")" "$run_id"
}

# graph_state_run_file <workspace> <namespace> <run_id>
graph_state_run_file() {
  local run_dir
  run_dir="$(graph_state_run_dir "$@")" || return 1
  printf '%s/run.json\n' "$run_dir"
}

# graph_state_graph_file <workspace> <namespace> <run_id>
# The frozen, immutable compile output for the run.
graph_state_graph_file() {
  local run_dir
  run_dir="$(graph_state_run_dir "$@")" || return 1
  printf '%s/graph.json\n' "$run_dir"
}

# graph_state_nodes_dir <workspace> <namespace> <run_id>
graph_state_nodes_dir() {
  local run_dir
  run_dir="$(graph_state_run_dir "$@")" || return 1
  printf '%s/nodes\n' "$run_dir"
}

# graph_state_node_file <workspace> <namespace> <run_id> <node_id>
# Node ids are sanitized to a safe filename component (the source id may
# contain the consensus separator ':' which is unsafe on some filesystems).
graph_state_node_file() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4"
  local nodes_dir safe_id
  if [[ -z "$node_id" ]]; then
    echo "Error: graph_state_node_file requires a node_id" >&2
    return 1
  fi
  nodes_dir="$(graph_state_nodes_dir "$workspace" "$namespace" "$run_id")" || return 1
  safe_id="$(printf '%s' "$node_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  printf '%s/%s.json\n' "$nodes_dir" "$safe_id"
}

# graph_state_latest_symlink <workspace> <namespace>
# The `latest` symlink path at the namespace root.
graph_state_latest_symlink() {
  local workspace="$1" namespace="$2"
  local ns_root
  ns_root="$(graph_state_runs_namespace_root "$workspace" "$namespace")" || return 1
  printf '%s/latest\n' "$ns_root"
}

# graph_state_mint_run_id
# Mints a run id from the current UTC timestamp with nanosecond precision and
# a short random suffix so two runs started in the same second do not collide.
# Format: run-YYYYMMDDTHHMMSSZ-<ns>-<rand>. Stays filesystem-safe.
graph_state_mint_run_id() {
  local ts ns rand
  if [[ -n "${GRAPH_STATE_FIXED_RUN_ID:-}" ]]; then
    printf '%s\n' "$GRAPH_STATE_FIXED_RUN_ID"
    return 0
  fi
  ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)"
  # nanoseconds when available (GNU date), else 0; keeps macOS bash 3.2 happy.
  ns="$(date +%N 2>/dev/null | tr -d '0-9' | head -c1)"
  [[ -z "$ns" ]] && ns="0"
  # Short random suffix (mktemp style); RANDOM may be unset on some shells.
  rand="$(mktemp -u XXXXXX 2>/dev/null)" || rand="$$"
  printf 'run-%s-%s-%s\n' "$ts" "$ns" "$rand"
}

# graph_state_compute_graph_sha <graph_json_path>
# Computes a stable sha256 over the canonical, sorted, key-ordered form of the
# graph json so that two compiles of the same plan produce the same digest and
# any semantic change to the plan produces a different one. Uses jq to emit a
# canonical (sorted keys, no extra whitespace) form, then sha256sum/shasum.
graph_state_compute_graph_sha() {
  local graph_json_path="$1"
  local canonical
  if [[ -z "$graph_json_path" || ! -f "$graph_json_path" ]]; then
    echo "Error: graph_state_compute_graph_sha requires an existing graph json path" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  canonical="$(jq -cS . "$graph_json_path" 2>/dev/null)" || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$canonical" | openssl dgst -sha256 | awk '{print $NF}'
  else
    echo "Error: no sha256 tool available (sha256sum/shasum/openssl)" >&2
    return 1
  fi
}

# graph_state_ralph_version
# Best-effort canonical Ralph version, mirroring plan-todo.sh get_ralph_version
# without re-entering python3. Honors RALPH_VERSION, then bundle/.ralph/VERSION,
# then git describe, then a literal fallback.
graph_state_ralph_version() {
  local ralph_root bundle_root repo_root candidate value
  if [[ -n "${RALPH_VERSION:-}" ]]; then
    printf '%s\n' "$RALPH_VERSION"
    return 0
  fi
  ralph_root="$(cd "$GRAPH_STATE_SCRIPT_DIR/../.." && pwd)"
  for candidate in \
    "$ralph_root/VERSION" \
    "$ralph_root/version"; do
    if [[ -f "$candidate" ]]; then
      value="$(awk 'END{print}' "$candidate" 2>/dev/null)"
      if [[ -n "$value" ]]; then
        printf '%s\n' "$value"
        return 0
      fi
    fi
  done
  # A Git description is Ralph-owned only in this repository's canonical
  # bundle layout. In an installed downstream project, its Git HEAD and
  # VERSION belong to the application and must not be reported as Ralph's.
  bundle_root="$(dirname "$ralph_root")"
  repo_root="$(dirname "$bundle_root")"
  if [[ "$(basename "$bundle_root")" == "bundle" \
    && -d "$repo_root/.git" \
    && "$(cd "$repo_root/bundle/.ralph" 2>/dev/null && pwd -P)" == "$ralph_root" ]] \
    && command -v git >/dev/null 2>&1; then
    value="$(git -C "$repo_root" describe --tags --always --dirty 2>/dev/null)" || true
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  printf '1.0.0\n'
}

# graph_state_now_iso
# Prints the current UTC time as an ISO-8601 stamp (seconds precision).
graph_state_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ
}

# graph_state_supervisor_pid
# Best-effort supervisor PID. Honors the GRAPH_STATE_SUPERVISOR_PID env
# override for tests and deterministic fixtures; otherwise reports the
# current shell PID ($$).
graph_state_supervisor_pid() {
  if [[ -n "${GRAPH_STATE_SUPERVISOR_PID:-}" ]]; then
    printf '%s\n' "$GRAPH_STATE_SUPERVISOR_PID"
    return 0
  fi
  printf '%s\n' "$$"
}

# graph_state_owner_hostname
# Best-effort hostname of the supervisor. Honors GRAPH_STATE_OWNER_HOSTNAME
# for tests; otherwise tries the hostname(1) command. Falls back to empty
# (which the caller writes as JSON null) when unavailable.
graph_state_owner_hostname() {
  if [[ -n "${GRAPH_STATE_OWNER_HOSTNAME:-}" ]]; then
    printf '%s\n' "$GRAPH_STATE_OWNER_HOSTNAME"
    return 0
  fi
  if command -v hostname >/dev/null 2>&1; then
    hostname 2>/dev/null || true
  fi
}

# graph_state_owner_process_start_id
# Best-effort stable process-start identity for the supervisor. Honors
# GRAPH_STATE_OWNER_PROCESS_START_ID for tests and deterministic fixtures;
# otherwise probes /proc/<pid> (Linux) or ps -o lstart= (portable) to
# obtain a value that differs when a PID has been reused. Returns empty
# when the identity cannot be obtained (caller writes as JSON null).
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

# graph_state_heartbeat_now
# Current heartbeat timestamp. Honors GRAPH_STATE_HEARTBEAT_AT for tests and
# deterministic fixtures; otherwise uses graph_state_now_iso.
graph_state_heartbeat_now() {
  if [[ -n "${GRAPH_STATE_HEARTBEAT_AT:-}" ]]; then
    printf '%s\n' "$GRAPH_STATE_HEARTBEAT_AT"
    return 0
  fi
  graph_state_now_iso
}

# graph_state_validate_node_state <state>
# Returns 0 when <state> is one of the nine valid node states.
graph_state_validate_node_state() {
  local state="$1" s
  [[ -z "$state" ]] && return 1
  for s in "${GRAPH_STATE_NODE_STATES[@]}"; do
    [[ "$s" == "$state" ]] && return 0
  done
  return 1
}

# graph_state_validate_run_status <status>
# Returns 0 when <status> is one of the valid run-level statuses.
graph_state_validate_run_status() {
  local status="$1" s
  [[ -z "$status" ]] && return 1
  for s in "${GRAPH_STATE_RUN_STATUSES[@]}"; do
    [[ "$s" == "$status" ]] && return 0
  done
  return 1
}

# graph_state_init_run <workspace> <namespace> <run_id> <plan_path> <graph_json_path> <max_parallel>
#
# Creates the run directory, writes run.json and the frozen graph.json, and
# writes a pending node ledger entry for every node in the graph. Updates the
# `latest` symlink to point at this run. Returns 1 with a diagnostic on
# failure; on success prints nothing.
#
# The frozen graph.json is copied verbatim (not re-emitted) so the ledger
# guarantees the run operates on the exact bytes the scheduler loaded. The
# graphSha recorded in run.json is computed over the canonical form of the
# graph so two compiles of an unchanged plan produce the same digest and a
# recompile after an edit produces a different one (see p3-resume).
graph_state_init_run() {
  local workspace="$1" namespace="$2" run_id="$3" plan_path="$4" graph_json_path="$5" max_parallel="${6:-2}"
  local run_dir run_file graph_file nodes_dir graph_sha ralph_version started_at node_count node_id
  local plan_abs

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" || -z "$plan_path" || -z "$graph_json_path" ]]; then
    echo "Error: graph_state_init_run requires workspace, namespace, run_id, plan_path, graph_json_path" >&2
    return 1
  fi
  if [[ ! -f "$graph_json_path" ]]; then
    echo "Error: graph_state_init_run graph json not found: $graph_json_path" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  [[ "$max_parallel" =~ ^[1-9][0-9]*$ ]] || max_parallel=2

  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || return 1
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  graph_file="$(graph_state_graph_file "$workspace" "$namespace" "$run_id")" || return 1
  nodes_dir="$(graph_state_nodes_dir "$workspace" "$namespace" "$run_id")" || return 1

  if ! mkdir -p "$run_dir" "$nodes_dir"; then
    echo "Error: failed to create run directory: $run_dir" >&2
    return 1
  fi

  # Freeze the graph verbatim. Use a plain copy in the same directory so the
  # rename is atomic; do not canonicalize here, because graphSha must reflect
  # the canonical form (computed below) but the frozen file is what the
  # scheduler reads, and the scheduler already accepts the compiler output.
  local tmp_graph
  tmp_graph="$(mktemp "$run_dir/.graph-XXXXXX")" || return 1
  if ! cp "$graph_json_path" "$tmp_graph"; then
    rm -f "$tmp_graph"
    return 1
  fi
  if ! mv -f "$tmp_graph" "$graph_file"; then
    rm -f "$tmp_graph"
    return 1
  fi

  graph_sha="$(graph_state_compute_graph_sha "$graph_file")" || return 1
  ralph_version="$(graph_state_ralph_version)"
  started_at="$(graph_state_now_iso)"

  # Absolute plan path so resume can re-open it even when cwd differs. Do not
  # fail when the plan path is already absolute or already missing (caller may
  # pass a relative path that no longer exists at resume time).
  case "$plan_path" in
    /*) plan_abs="$plan_path" ;;
    *) plan_abs="$plan_path" ;;
  esac

  if ! ralph_atomic_write_json "$run_file" \
    '{schemaVersion: $sv, ralphVersion: $rv, runId: $rid, planPath: $pp, graphSha: $gs, startedAt: $sa, status: "running", maxParallel: $mp}' \
    --argjson sv "$GRAPH_STATE_RUN_SCHEMA_VERSION" \
    --arg rv "$ralph_version" \
    --arg rid "$run_id" \
    --arg pp "$plan_abs" \
    --arg gs "$graph_sha" \
    --arg sa "$started_at" \
    --argjson mp "$max_parallel"; then
    echo "Error: failed to write run.json" >&2
    return 1
  fi

  # Seed a pending node entry for every node in the graph. The runtime and
  # subagents fields are recorded from the frozen graph so a later usage
  # comparison can tell whether subagents were available for that node.
  node_count="$(jq '.nodes | length' "$graph_file")" || node_count=0
  local i=0
  while [[ "$i" -lt "$node_count" ]]; do
    node_id="$(jq -r ".nodes[$i].id // empty" "$graph_file")"
    if [[ -n "$node_id" ]]; then
      graph_state_write_node "$workspace" "$namespace" "$run_id" "$node_id" "pending" "" "" "" "" "" "" || {
        echo "Error: failed to seed node ledger entry for $node_id" >&2
        return 1
      }
    fi
    i=$((i + 1))
  done

  graph_state_update_latest "$workspace" "$namespace" "$run_id" || true
  return 0
}

# graph_state_update_latest <workspace> <namespace> <run_id>
# Points the `latest` symlink at <run_id>. Idempotent. Uses ln -sfn where
# available, falls back to rm + ln -s. Never fails the caller when the
# namespace directory exists.
graph_state_update_latest() {
  local workspace="$1" namespace="$2" run_id="$3"
  local ns_root symlink target
  ns_root="$(graph_state_runs_namespace_root "$workspace" "$namespace")" || return 1
  symlink="$(graph_state_latest_symlink "$workspace" "$namespace")" || return 1
  if [[ ! -d "$ns_root" ]]; then
    mkdir -p "$ns_root" 2>/dev/null || return 1
  fi
  target="$run_id"
  # Use a relative target so the symlink survives a workspace move.
  if ln -sfn "$target" "$symlink" 2>/dev/null; then
    return 0
  fi
  rm -f "$symlink" 2>/dev/null || true
  ln -s "$target" "$symlink" 2>/dev/null || return 1
  return 0
}

# graph_state_read_run <workspace> <namespace> <run_id>
# Prints run.json contents (raw) on stdout. Returns 1 when missing.
graph_state_read_run() {
  local run_file
  run_file="$(graph_state_run_file "$@")" || return 1
  [[ -f "$run_file" ]] || return 1
  cat "$run_file"
}

# graph_state_read_graph <workspace> <namespace> <run_id>
# Prints the frozen graph.json verbatim. Returns 1 when missing.
graph_state_read_graph() {
  local graph_file
  graph_file="$(graph_state_graph_file "$@")" || return 1
  [[ -f "$graph_file" ]] || return 1
  cat "$graph_file"
}

# graph_state_set_run_status <workspace> <namespace> <run_id> <status>
# Atomically updates the status field of run.json. Validates <status> first.
# Preserves all other fields by reading the existing file and merging.
graph_state_set_run_status() {
  local workspace="$1" namespace="$2" run_id="$3" status="$4"
  local run_file base_json
  if ! graph_state_validate_run_status "$status"; then
    echo "Error: invalid run status: ${status:-}" >&2
    return 1
  fi
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  [[ -f "$run_file" ]] || return 1
  base_json="$(jq -c . "$run_file" 2>/dev/null)" || base_json="null"
  if ! ralph_atomic_write_json "$run_file" \
    '(($base | fromjson) // {}) + {status: $status}' \
    --arg base "$base_json" \
    --arg status "$status"; then
    echo "Error: failed to update run status" >&2
    return 1
  fi
  return 0
}

# graph_state_write_node <workspace> <namespace> <run_id> <node_id> <state>
#   [attempt_id] [outcome] [exit_code] [started_at] [finished_at]
#   [runtime] [subagents] [reason] [extra_json]
#
# Atomically writes the per-node ledger entry. Uses the shared atomic writer
# so no partial JSON is observable mid-write. When an attempt_id is supplied,
# the attempt is appended to the attempts array and lastAttemptId is updated;
# when omitted, only the node state is updated (and attempts stays as-is).
#
# runtime and subagents are recorded per-attempt (not per-node) because a
# retry could in principle run under a different runtime/agent (e.g. after an
# operator edits the plan between attempts), and because subagent tokens are
# an invocation-level cost. The per-node runtime/subagents fields are kept in
# sync with the latest attempt for convenience.
#
# extra_json is an optional JSON object string merged into the node ledger
# entry (and into the new attempt, when one is supplied). It is used by the
# v2 observability layer to attach workspace mode, write scopes, changeset
# hash, integration inputs, gate outcome, repair epoch, subagent policy,
# brokered child provenance, runtime admission, usage, and publish readiness
# without changing existing callers.
graph_state_write_node() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" state="$5"
  local attempt_id="${6:-}" outcome="${7:-}" exit_code="${8:-}"
  local started_at="${9:-}" finished_at="${10:-}" runtime="${11:-}"
  local subagents="${12:-}" reason="${13:-}" extra_json="${14:-}"
  local node_file

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" || -z "$node_id" ]]; then
    echo "Error: graph_state_write_node requires workspace, namespace, run_id, node_id" >&2
    return 1
  fi
  if ! graph_state_validate_node_state "$state"; then
    echo "Error: invalid node state: ${state:-}" >&2
    return 1
  fi
  node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  if ! mkdir -p "$(dirname "$node_file")"; then
    echo "Error: failed to create nodes directory" >&2
    return 1
  fi

  command -v jq >/dev/null 2>&1 || return 1

  # Sanitize numeric exit code to an integer or null. jq --argjson requires a
  # literal; pass null when empty so the attempt object stays valid JSON.
  local exit_code_json="null"
  if [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then
    exit_code_json="$exit_code"
  fi

  # ralph_atomic_write_json invokes `jq -n`, so it does not read stdin. We
  # load the existing entry (when present) into a string and inline it via
  # --argjson so the new document folds in the previous attempts array.
  local base_json="null"
  if [[ -f "$node_file" ]]; then
    base_json="$(jq -c . "$node_file" 2>/dev/null)" || base_json="null"
  fi

  local has_attempt=0
  [[ -n "$attempt_id" ]] && has_attempt=1

  # Validate extra_json once; default to an empty object and reject invalid JSON.
  if [[ -z "$extra_json" ]]; then
    extra_json='{}'
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$extra_json"; then
    echo "Error: invalid extra_json for node ledger entry $node_id" >&2
    return 1
  fi

  if [[ "$has_attempt" -eq 1 ]]; then
    # Build the attempt object as a jq expression that conditionally includes
    # each optional field, so the on-disk JSON omits empty strings cleanly.
    local attempt_expr
    attempt_expr='{attemptId: $aid}
      + (if $outcome == "" then {} else {outcome: $outcome} end)
      + (if $exitCodeJson == "null" then {} else {exitCode: ($exitCodeJson | tonumber)} end)
      + (if $startedAt == "" then {} else {startedAt: $startedAt} end)
      + (if $finishedAt == "" then {} else {finishedAt: $finishedAt} end)
      + (if $runtime == "" then {} else {runtime: $runtime} end)
      + (if $subagents == "" then {} else {subagents: $subagents} end)
      + (if $reason == "" then {} else {reason: $reason} end)
      + (if $extra == "{}" then {} else ($extra | fromjson) end)'

    if ! ralph_atomic_write_json "$node_file" \
      '(if $base == "null" then {schemaVersion: $sv, nodeId: $nid, status: "pending", attempts: [], lastAttemptId: null} else ($base | fromjson) end)
       | .schemaVersion = $sv
       | .nodeId = $nid
       | .status = $state
       | .attempts = ((.attempts // []) + ['"$attempt_expr"'])
       | .lastAttemptId = $aid
       | (if $runtime != "" then .runtime = $runtime else . end)
       | (if $subagents != "" then .subagents = $subagents else . end)
       + (if $extra == "{}" then {} else ($extra | fromjson) end)' \
      --argjson sv "$GRAPH_STATE_NODE_SCHEMA_VERSION" \
      --arg nid "$node_id" --arg state "$state" --arg aid "$attempt_id" \
      --arg outcome "$outcome" --arg exitCodeJson "$exit_code_json" \
      --arg startedAt "$started_at" --arg finishedAt "$finished_at" \
      --arg runtime "$runtime" --arg subagents "$subagents" --arg reason "$reason" \
      --arg extra "$extra_json" \
      --arg base "$base_json"; then
      echo "Error: failed to write node ledger entry for $node_id" >&2
      return 1
    fi
    return 0
  fi

  # No attempt: update only the status (and refresh runtime/subagents when
  # supplied for non-attempt state transitions like a manual block/skip).
  if ! ralph_atomic_write_json "$node_file" \
    '(if $base == "null" then {schemaVersion: $sv, nodeId: $nid, status: "pending", attempts: [], lastAttemptId: null} else ($base | fromjson) end)
     | .schemaVersion = $sv
     | .nodeId = $nid
     | .status = $state
     | (if $runtime != "" then .runtime = $runtime else . end)
     | (if $subagents != "" then .subagents = $subagents else . end)
     + (if $extra == "{}" then {} else ($extra | fromjson) end)' \
    --argjson sv "$GRAPH_STATE_NODE_SCHEMA_VERSION" \
    --arg nid "$node_id" --arg state "$state" \
    --arg runtime "$runtime" --arg subagents "$subagents" \
    --arg extra "$extra_json" \
    --arg base "$base_json"; then
    echo "Error: failed to write node ledger entry for $node_id" >&2
    return 1
  fi
  return 0
}

# graph_state_read_node <workspace> <namespace> <run_id> <node_id>
# Prints the per-node ledger entry (raw JSON) on stdout. Returns 1 when
# missing.
graph_state_read_node() {
  local node_file
  node_file="$(graph_state_node_file "$@")" || return 1
  [[ -f "$node_file" ]] || return 1
  cat "$node_file"
}

# graph_state_node_status <workspace> <namespace> <run_id> <node_id>
# Prints the node's status field on stdout. Returns 1 when missing.
graph_state_node_status() {
  local node_file
  node_file="$(graph_state_node_file "$@")" || return 1
  [[ -f "$node_file" ]] || return 1
  jq -r '.status // empty' "$node_file" 2>/dev/null
}

# graph_state_resolve_run_id <workspace> <namespace> <run_id_or_latest>
# Resolves the literal token `latest` to the target of the latest symlink.
# Any other value is returned verbatim. Returns 1 when `latest` is requested
# but the symlink is missing or broken.
graph_state_resolve_run_id() {
  local workspace="$1" namespace="$2" token="$3"
  local symlink target
  if [[ "$token" != "latest" ]]; then
    printf '%s\n' "$token"
    return 0
  fi
  symlink="$(graph_state_latest_symlink "$workspace" "$namespace")" || return 1
  [[ -L "$symlink" ]] || return 1
  target="$(readlink "$symlink" 2>/dev/null)" || return 1
  [[ -n "$target" ]] || return 1
  printf '%s\n' "$target"
}

# graph_state_list_runs <workspace> <namespace>
# Prints one run id per line, oldest first, for the namespace. Returns 0 even
# when the directory is empty.
graph_state_list_runs() {
  local workspace="$1" namespace="$2"
  local ns_root entry
  ns_root="$(graph_state_runs_namespace_root "$workspace" "$namespace")" || return 1
  [[ -d "$ns_root" ]] || return 0
  # List directories only; skip the `latest` symlink. Sort by mtime ascending
  # so the newest is last. Do not rely on GNU find -printf (macOS lacks it).
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-graph-runs.XXXXXX")" || return 1
  find "$ns_root" -mindepth 1 -maxdepth 1 -type d -exec stat -f '%m %N' {} \; 2>/dev/null \
    | sort -n | awk '{print $2}' > "$tmp" 2>/dev/null
  # GNU stat fallback (Linux CI): %Y mtime seconds.
  if [[ ! -s "$tmp" ]]; then
    find "$ns_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
      | sort -n | awk '{print $2}' > "$tmp" 2>/dev/null
  fi
  # Print only the basename of each run directory.
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -z "$entry" ]] && continue
    basename "$entry"
  done < "$tmp"
  rm -f "$tmp"
  return 0
}

# graph_state_node_ids_from_graph <graph_json_path>
# Prints one node id per line, in graph order. Returns 1 on missing/invalid.
graph_state_node_ids_from_graph() {
  local graph_json_path="$1"
  if [[ -z "$graph_json_path" || ! -f "$graph_json_path" ]]; then
    echo "Error: graph_state_node_ids_from_graph requires an existing graph json path" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  jq -r '.nodes[].id // empty' "$graph_json_path" 2>/dev/null
}

# graph_state_field <run_file> <field>
# Prints a single scalar field from run.json via jq -r. Returns 1 on miss.
graph_state_field() {
  local run_file="$1" field="$2"
  if [[ -z "$run_file" || ! -f "$run_file" || -z "$field" ]]; then
    return 1
  fi
  jq -r --arg f "$field" '.[$f] // empty' "$run_file" 2>/dev/null
}

# graph_state_node_stage_json <graph_json_path> <node_id>
# Prints the canonical (sorted-key, compact) form of the node's nested stage
# object, the unit of comparison for p3-resume invalidation. Byte differences
# here mean the node's own work contract changed and the node must be rerun.
graph_state_node_stage_json() {
  local graph_json_path="$1" node_id="$2"
  if [[ -z "$graph_json_path" || ! -f "$graph_json_path" || -z "$node_id" ]]; then
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  jq -c --arg id "$node_id" '(.nodes[] | select(.id == $id) | .stage) // empty' \
    "$graph_json_path" 2>/dev/null
}

# graph_state_node_digest <graph_json_path> <node_id>
# Prints a stable sha256 over the canonical form of the node's stage object.
# Two compiles of an unchanged plan produce identical digests; any semantic
# edit to the node's stage produces a different one. Used by p3-resume to
# decide whether a node's own contract changed.
graph_state_node_digest() {
  local graph_json_path="$1" node_id="$2"
  local stage_json
  stage_json="$(graph_state_node_stage_json "$graph_json_path" "$node_id")" || return 1
  [[ -z "$stage_json" ]] && return 1
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$stage_json" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$stage_json" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$stage_json" | openssl dgst -sha256 | awk '{print $NF}'
  else
    echo "Error: no sha256 tool available" >&2
    return 1
  fi
}

# graph_state_ancestor_sets <graph_json_path>
# Prints one line per node: "<node_id>\t<ancestor1> <ancestor2> ...". The
# ancestor set is the transitive closure of inbound edges (dependsOn + derived
# edges), so a change to any ancestor's stage invalidates this node under
# p3-resume. Edges are read from the frozen graph so resume does not re-enter
# the compiler. jq-only; no python3.
graph_state_ancestor_sets() {
  local graph_json_path="$1"
  if [[ -z "$graph_json_path" || ! -f "$graph_json_path" ]]; then
    echo "Error: graph_state_ancestor_sets requires an existing graph json path" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  # Emit a TSV: node_id \t space-separated ancestor ids. Implemented entirely
  # in jq via a fixpoint over the edges array so resume stays jq-only.
  jq -r '
    def transitive(start; edges):
      # Breadth-first closure; bash 3.2 never sees this — it runs in jq.
      {seen: [], frontier: [start]} as $init
      | reduce range(0; 1000) as $_ ( $init;
          if (.frontier | length) == 0 then . else
            . as $s
            | ($s.frontier | .[]) as $n
            | ($s.seen + [$n] | unique) as $seen2
            | (edges | map(select(.from == $n)) | map(.to)) as $next
            | {seen: $seen2, frontier: (($s.frontier + $next) | unique | . - $seen2)}
          end )
      | .seen;
    .nodes[].id as $id
    | [ $id, (transitive($id; .edges) | map(select(. != $id)) | sort | join(" ")) ]
    | @tsv
  ' "$graph_json_path" 2>/dev/null
}

# graph_state_node_last_attempt_id <workspace> <namespace> <run_id> <node_id>
# Prints the lastAttemptId from the node ledger entry, or empty when unset.
graph_state_node_last_attempt_id() {
  local node_file
  node_file="$(graph_state_node_file "$@")" || return 1
  [[ -f "$node_file" ]] || return 1
  jq -r '.lastAttemptId // empty' "$node_file" 2>/dev/null
}

# graph_state_node_last_attempt_reason <workspace> <namespace> <run_id> <node_id>
# Prints the reason recorded on the most recent ledger attempt (identified by
# lastAttemptId, not merely the last array entry), or empty when unset. Used
# on resume to recover a gate node's semantic outcome (passed vs
# changes-required) from its recorded reason (e.g. "gate-passed",
# "gate-changes-required-repair-edge") without re-running the gate.
graph_state_node_last_attempt_reason() {
  local node_file
  node_file="$(graph_state_node_file "$@")" || return 1
  [[ -f "$node_file" ]] || return 1
  jq -r '
    (.lastAttemptId // "") as $aid
    | (.attempts // [])
    | (map(select(.attemptId == $aid)) | last // (last // {}))
    | .reason // empty
  ' "$node_file" 2>/dev/null
}

# graph_state_node_attempts_json <workspace> <namespace> <run_id> <node_id>
# Prints the raw attempts array as compact JSON. Returns 1 when missing.
graph_state_node_attempts_json() {
  local node_file
  node_file="$(graph_state_node_file "$@")" || return 1
  [[ -f "$node_file" ]] || return 1
  jq -c '.attempts // []' "$node_file" 2>/dev/null
}

# graph_state_max_attempt_number <node_file>
#
# Prints the maximum numeric suffix of unique attemptIds in a node ledger
# file (e.g. left__run-1__3 -> 3). Duplicate attemptIds (v1 transition
# records for the same attempt) do not inflate the result: numbering uses
# this suffix, not attempts[] array length and not unique-id count. Prints
# 0 when the file is missing or has no numeric suffixes.
graph_state_max_attempt_number() {
  local node_file="$1" n
  if [[ -z "$node_file" || ! -f "$node_file" ]]; then
    echo 0
    return 0
  fi
  command -v jq >/dev/null 2>&1 || { echo 0; return 1; }
  n="$(jq '[.attempts[]?.attemptId? // empty | try (capture("__(?<number>[0-9]+)$").number | tonumber) catch empty] | max // 0' "$node_file" 2>/dev/null)" || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}

# graph_state_node_max_attempt_number <workspace> <namespace> <run_id> <node_id>
# Ledger-path wrapper around graph_state_max_attempt_number.
graph_state_node_max_attempt_number() {
  local node_file
  node_file="$(graph_state_node_file "$@")" || { echo 0; return 0; }
  graph_state_max_attempt_number "$node_file"
}

# graph_state_reset_node_to_pending <workspace> <namespace> <run_id> <node_id>
# Resets a node's status to pending without appending an attempt. Preserves
# the existing attempts array so prior provenance is not lost. Used by
# p3-resume for failed/cancelled/blocked nodes and for running nodes with no
# adoptable StageOutcomeReport.
#
# This is a supervisor reset, not a model-driven state transition: v1 has no
# transition check, and v2's machine rejects running->pending and
# cancelled->pending. A v2 node is therefore rewritten in place (schema and
# attempts preserved) rather than routed through graph_state_write_node_v2.
# A v1 node keeps using graph_state_write_node so resume reads stay byte-
# compatible with pre-v2 ledgers.
graph_state_reset_node_to_pending() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4"
  local node_file version base_json

  node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  if [[ -f "$node_file" ]]; then
    version="$(jq -r '.schemaVersion // 1' "$node_file" 2>/dev/null)" || version=1
    if [[ "$version" =~ ^[0-9]+$ ]] && [[ "$version" -ge 2 ]]; then
      base_json="$(jq -c . "$node_file" 2>/dev/null)" || return 1
      if ! ralph_atomic_write_json "$node_file" \
        '($base | fromjson) | .status = "pending"' \
        --arg base "$base_json"; then
        echo "Error: failed to reset v2 node ledger entry for $node_id" >&2
        return 1
      fi
      return 0
    fi
  fi
  graph_state_write_node "$workspace" "$namespace" "$run_id" "$node_id" "pending" \
    "" "" "" "" "" "" "" ""
}

# graph_state_node_id_from_filename <safe_id>
# Inverse of the sed sanitization in graph_state_node_file. Best-effort: the
# sanitizer is non-injective, so callers that need the original id should read
# .nodeId from the ledger entry instead. Provided for completeness only.
graph_state_node_id_from_filename() {
  printf '%s\n' "$1"
}

# ---------------------------------------------------------------------------
# p4-state-v2: ledger schema v2
# ---------------------------------------------------------------------------
#
# v2 extends the v1 ledger without changing v1 on-disk bytes or any existing
# scheduler/status/resume/retention/publish behavior: graph_state_init_run
# and graph_state_write_node above are untouched and keep writing
# schemaVersion 1, exactly as before. v1 runs remain readable forever
# through the normalizing readers below; a read never rewrites a v1 file.
#
# A v2 node ledger owns one attempts[] object per attemptId (not one object
# per state transition, which is the known v1 duplication: a running
# transition and its later terminal transition both append separate
# attempts[] records for the same attemptId). Each v2 attempt object may
# carry: attemptId, startedAt, finishedAt, outcome, exitCode, runtime,
# reason, logPaths, usageSnapshot, usageReliable, retryClassification,
# heartbeatAt, operatorRequestId.
#
# graph_state_init_run_v2 / graph_state_write_node_v2 are the new entry
# points that write this shape; graph_state_write_node_v2 is the atomic
# attempt upsert (p5-attempt-upserts): starting an attempt creates one
# record, and heartbeat/usage/log-metadata/terminalization calls update that
# same record, idempotently, through ralph_atomic_write_json. The live
# scheduler (bash-lib/graph/graph-schedule.sh, _graph_schedule_ledger_record)
# reads a run's schemaVersion once per run and dispatches to
# graph_state_write_node for schemaVersion 1 (unchanged) or
# graph_state_write_node_v2 for schemaVersion 2+, so a v1 run's on-disk
# behavior is untouched and a v2 run gets one attempts[] object per attempt.
# No caller creates a v2 run by default yet -- graph_state_init_run_v2 is
# available for callers that opt in.

# Highest schemaVersion this Ralph build understands for node and run ledger
# documents. A document with a higher schemaVersion is from a newer Ralph
# and must be rejected with an actionable error rather than guessed at.
GRAPH_STATE_MAX_KNOWN_NODE_SCHEMA_VERSION=2
GRAPH_STATE_MAX_KNOWN_RUN_SCHEMA_VERSION=2

# Schema version written by the new v2 entry points.
GRAPH_STATE_NODE_SCHEMA_VERSION_V2=2
GRAPH_STATE_RUN_SCHEMA_VERSION_V2=2

# v2 node states, appended after the original nine (see the note above
# GRAPH_STATE_NODE_STATES): a retry backoff wait, a block on an explicit
# operator decision (distinct from awaiting-ack, which is a gate outcome),
# a node whose stage contract needs a plan edit before it can run again,
# and a node whose owning attempt was orphaned by a dead supervisor.
GRAPH_STATE_NODE_STATES+=(
  retry-wait
  awaiting-operator
  needs-plan-repair
  interrupted
)

# Run-level states meaningful at the whole-run granularity. interrupted
# mirrors the node state: the owning supervisor died mid-run. awaiting-operator
# mirrors awaiting-ack for a whole-run operator decision (as opposed to one
# node's gate outcome). retry-wait and needs-plan-repair are node-scoped
# concepts only; a run as a whole does not retry-wait or need-plan-repair.
GRAPH_STATE_RUN_STATUSES+=(
  interrupted
  awaiting-operator
)

# graph_state_validate_node_transition <from_state> <to_state>
#
# Returns 0 when moving a node from <from_state> to <to_state> is legal in
# the v2 state machine. An empty <from_state> (the node's first write) is
# always legal, matching how a node is seeded at "pending" implicitly. A
# same-state transition is always legal (an idempotent re-write, e.g. a
# heartbeat refresh on a running attempt). Terminal states (succeeded,
# skipped, cancelled) have no legal outgoing transition other than to
# themselves.
graph_state_validate_node_transition() {
  local from="$1" to="$2"
  if [[ -z "$to" ]]; then
    return 1
  fi
  if [[ -z "$from" ]]; then
    return 0
  fi
  if [[ "$from" == "$to" ]]; then
    return 0
  fi
  case "$from" in
    pending)
      case "$to" in
        ready|running|blocked|skipped|cancelled|needs-plan-repair) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    ready)
      case "$to" in
        running|blocked|skipped|cancelled) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    running)
      case "$to" in
        succeeded|failed|blocked|awaiting-ack|cancelled|retry-wait|awaiting-operator|needs-plan-repair|interrupted) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    failed)
      case "$to" in
        pending|retry-wait|needs-plan-repair) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    blocked)
      case "$to" in
        pending) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    awaiting-ack)
      case "$to" in
        ready|running|cancelled|needs-plan-repair) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    retry-wait)
      case "$to" in
        pending|ready|running|cancelled) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    awaiting-operator)
      case "$to" in
        pending|ready|running|cancelled|needs-plan-repair) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    needs-plan-repair)
      case "$to" in
        pending|cancelled) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    interrupted)
      case "$to" in
        pending|ready|running|cancelled|needs-plan-repair) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    succeeded|skipped|cancelled)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# graph_state_normalize_node_json <node_json>
#
# Pure in-memory transform: normalizes a raw node ledger JSON document (any
# supported schemaVersion) into the v2 shape. attempts[] is deduplicated to
# one object per attemptId by folding records in array order, so a v1
# running record and its later terminal record for the same attemptId merge
# into a single object (later records win per field; a field only present on
# the earlier record, such as startedAt, survives). Never reads or writes a
# file; the caller decides whether/where to persist the result. The result
# always carries schemaVersion 2 plus sourceSchemaVersion recording the
# original on-disk version, so a caller can tell a document was normalized
# rather than natively v2.
graph_state_normalize_node_json() {
  local node_json="$1"
  if [[ -z "$node_json" ]]; then
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  jq -c '
    . as $doc
    | ($doc.schemaVersion // 1) as $src
    | ($doc.attempts // [])
    | reduce .[] as $a ({}; .[$a.attemptId] = ((.[$a.attemptId] // {}) * $a))
    | [.[]]
    as $merged
    | $doc
    | .attempts = $merged
    | .lastAttemptId = ($doc.lastAttemptId // (if ($merged | length) > 0 then $merged[-1].attemptId else null end))
    | .schemaVersion = 2
    | .sourceSchemaVersion = $src
  ' <<<"$node_json" 2>/dev/null
}

# graph_state_read_node_v2 <workspace> <namespace> <run_id> <node_id>
#
# Reads a node ledger entry normalized to the v2 shape regardless of its
# on-disk schemaVersion. v1 files are normalized in memory only; the file on
# disk is never rewritten by this read. Fails with an actionable error for a
# missing/non-numeric schemaVersion or one beyond
# GRAPH_STATE_MAX_KNOWN_NODE_SCHEMA_VERSION rather than guessing at an
# unknown future shape.
graph_state_read_node_v2() {
  local node_file raw version
  node_file="$(graph_state_node_file "$@")" || return 1
  [[ -f "$node_file" ]] || return 1
  raw="$(cat "$node_file")" || return 1
  command -v jq >/dev/null 2>&1 || return 1
  version="$(jq -r '.schemaVersion // 1' <<<"$raw" 2>/dev/null)"
  if [[ ! "$version" =~ ^[0-9]+$ ]]; then
    echo "Error: node ledger $node_file has a non-numeric schemaVersion: ${version:-<missing>}" >&2
    return 1
  fi
  if [[ "$version" -lt 1 ]]; then
    echo "Error: node ledger $node_file has an invalid schemaVersion: $version" >&2
    return 1
  fi
  if [[ "$version" -gt "$GRAPH_STATE_MAX_KNOWN_NODE_SCHEMA_VERSION" ]]; then
    echo "Error: node ledger $node_file has schemaVersion $version, newer than the highest version this Ralph build understands ($GRAPH_STATE_MAX_KNOWN_NODE_SCHEMA_VERSION). Upgrade Ralph before reading this run." >&2
    return 1
  fi
  if [[ "$version" -eq 1 ]]; then
    graph_state_normalize_node_json "$raw"
    return $?
  fi
  jq -c '.' <<<"$raw" 2>/dev/null
}

# graph_state_normalize_run_json <run_json>
#
# Pure in-memory transform: normalizes a raw run ledger JSON document (v1 or
# v2) into the v2 shape. A v1 document is upgraded to schemaVersion 2 with
# sourceSchemaVersion recording the original on-disk version, and any missing
# v2 owner/heartbeat fields are filled with JSON null. The original file is
# never read or written by this helper; the caller decides whether/where to
# persist the result. A document that is already v2 passes through unchanged.
graph_state_normalize_run_json() {
  local run_json="$1"
  if [[ -z "$run_json" ]]; then
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  jq -c '
    . as $doc
    | ($doc.schemaVersion // 1) as $src
    | (if $src == 2 then . else (.schemaVersion = 2 | .sourceSchemaVersion = $src) end)
    | .supervisorPid = (.supervisorPid // null)
    | .ownerHostname = (.ownerHostname // null)
    | .ownerProcessStartId = (.ownerProcessStartId // null)
    | .heartbeatAt = (.heartbeatAt // null)
  ' <<<"$run_json" 2>/dev/null
}

# graph_state_read_run_v2 <workspace> <namespace> <run_id>
#
# Reads run.json with schema-version validation. v2 documents pass through
# unchanged; v1 documents are normalized in memory to the v2 shape (missing
# owner/heartbeat fields become null) without rewriting the file. Fails with
# an actionable error for a missing/non-numeric schemaVersion or one beyond
# GRAPH_STATE_MAX_KNOWN_RUN_SCHEMA_VERSION rather than guessing at an
# unknown future shape.
graph_state_read_run_v2() {
  local run_file raw version
  run_file="$(graph_state_run_file "$@")" || return 1
  [[ -f "$run_file" ]] || return 1
  raw="$(cat "$run_file")" || return 1
  command -v jq >/dev/null 2>&1 || return 1
  version="$(jq -r '.schemaVersion // 1' <<<"$raw" 2>/dev/null)"
  if [[ ! "$version" =~ ^[0-9]+$ ]]; then
    echo "Error: run ledger $run_file has a non-numeric schemaVersion: ${version:-<missing>}" >&2
    return 1
  fi
  if [[ "$version" -lt 1 ]]; then
    echo "Error: run ledger $run_file has an invalid schemaVersion: $version" >&2
    return 1
  fi
  if [[ "$version" -gt "$GRAPH_STATE_MAX_KNOWN_RUN_SCHEMA_VERSION" ]]; then
    echo "Error: run ledger $run_file has schemaVersion $version, newer than the highest version this Ralph build understands ($GRAPH_STATE_MAX_KNOWN_RUN_SCHEMA_VERSION). Upgrade Ralph before reading this run." >&2
    return 1
  fi
  if [[ "$version" -eq 1 ]]; then
    graph_state_normalize_run_json "$raw"
    return $?
  fi
  jq -c '.' <<<"$raw" 2>/dev/null
}

# graph_state_write_node_v2 <workspace> <namespace> <run_id> <node_id> <state>
#   [attempt_id] [attempt_fields_json] [node_extra_json]
#
# v2 node writer -- the atomic attempt upsert. attempt_fields_json is an
# optional JSON object populating any subset of the v2 attempt fields:
# startedAt, finishedAt, outcome, exitCode, runtime, reason, logPaths,
# usageSnapshot, usageReliable, retryClassification, heartbeatAt,
# operatorRequestId. When attempt_id matches an existing attempts[] entry,
# the fields are merged into that one object through ralph_atomic_write_json
# so the node keeps exactly one attempts[] object per attemptId -- starting
# an attempt creates the one record; a later heartbeat, usage, log-metadata,
# or terminalization call updates it in place. Fields already on the
# existing entry that are not present in attempt_fields_json are left
# alone. node_extra_json is merged into both the node document and the
# matching attempt (same contract as v1 extra_json). Repeating an identical
# update is idempotent (the merged content is byte-for-byte the same);
# attempting to terminalize an attempt that already has a different recorded
# outcome is rejected before any write, so the file on disk is left unchanged.
#
# A v1 predecessor node file is normalized in memory before merging (see
# graph_state_normalize_node_json); the resulting write is v2 going forward.
# Validates the requested state transition against the node's current
# on-disk state (a node's first write is always legal) and rejects a node
# ledger with an unknown future schemaVersion.
graph_state_write_node_v2() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" state="$5"
  local attempt_id="${6:-}" attempt_fields_json="${7:-}" node_extra_json="${8:-}"
  local node_file

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" || -z "$node_id" ]]; then
    echo "Error: graph_state_write_node_v2 requires workspace, namespace, run_id, node_id" >&2
    return 1
  fi
  if ! graph_state_validate_node_state "$state"; then
    echo "Error: invalid node state: ${state:-}" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1

  node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  if ! mkdir -p "$(dirname "$node_file")"; then
    echo "Error: failed to create nodes directory" >&2
    return 1
  fi

  if [[ -z "$attempt_fields_json" ]]; then
    attempt_fields_json='{}'
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$attempt_fields_json"; then
    echo "Error: invalid attempt_fields_json for node ledger entry $node_id" >&2
    return 1
  fi
  if [[ -z "$node_extra_json" ]]; then
    node_extra_json='{}'
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$node_extra_json"; then
    echo "Error: invalid node_extra_json for node ledger entry $node_id" >&2
    return 1
  fi

  local base_json="null" prev_state=""
  if [[ -f "$node_file" ]]; then
    base_json="$(jq -c . "$node_file" 2>/dev/null)" || base_json="null"
    if [[ "$base_json" != "null" ]]; then
      local base_version
      base_version="$(jq -r '.schemaVersion // 1' <<<"$base_json" 2>/dev/null)"
      if [[ ! "$base_version" =~ ^[0-9]+$ ]] || [[ "$base_version" -gt "$GRAPH_STATE_MAX_KNOWN_NODE_SCHEMA_VERSION" ]]; then
        echo "Error: node ledger $node_file has schemaVersion ${base_version:-<invalid>}, newer than the highest version this Ralph build understands ($GRAPH_STATE_MAX_KNOWN_NODE_SCHEMA_VERSION)" >&2
        return 1
      fi
      if [[ "$base_version" -eq 1 ]]; then
        base_json="$(graph_state_normalize_node_json "$base_json")" || base_json="null"
      fi
      prev_state="$(jq -r '.status // empty' <<<"$base_json" 2>/dev/null)"
    fi
  fi

  if ! graph_state_validate_node_transition "$prev_state" "$state"; then
    echo "Error: illegal node state transition for $node_id: ${prev_state:-<none>} -> $state" >&2
    return 1
  fi

  # Conflict detection: an attempt that already recorded a terminal outcome
  # cannot be re-terminalized with a different outcome. Repeating the same
  # outcome (or any other idempotent repeat) is allowed and leaves the
  # merged content unchanged; this check only rejects a genuine conflict,
  # and it rejects before any write, so the file on disk is untouched.
  if [[ -n "$attempt_id" && "$attempt_fields_json" != "{}" ]]; then
    local existing_outcome incoming_outcome
    existing_outcome="$(jq -r --arg aid "$attempt_id" '(.attempts // [])[]? | select(.attemptId == $aid) | .outcome // empty' <<<"$base_json" 2>/dev/null)"
    incoming_outcome="$(jq -r '.outcome // empty' <<<"$attempt_fields_json" 2>/dev/null)"
    if [[ -n "$existing_outcome" && -n "$incoming_outcome" && "$existing_outcome" != "$incoming_outcome" ]]; then
      echo "Error: attempt $attempt_id for node $node_id already terminalized with outcome '$existing_outcome'; refusing to terminalize again with a different outcome '$incoming_outcome'" >&2
      return 1
    fi
  fi

  local has_attempt=0
  [[ -n "$attempt_id" ]] && has_attempt=1

  if ! ralph_atomic_write_json "$node_file" \
    '(if $base == "null" then {schemaVersion: $sv, nodeId: $nid, status: "pending", attempts: [], lastAttemptId: null} else ($base | fromjson) end)
     | .schemaVersion = $sv
     | .nodeId = $nid
     | .status = $state
     | (if $hasAttempt == "1" then
         (.attempts = ((.attempts // []) as $atts
           | ($atts | map(.attemptId) | index($aid)) as $idx
           | (if $extra == "{}" then {} else ($extra | fromjson) end) as $ex
           | if $idx == null then
               $atts + [({attemptId: $aid} * ($fields | fromjson) * $ex)]
             else
               $atts | .[$idx] = ($atts[$idx] * ($fields | fromjson) * $ex)
             end))
         | .lastAttemptId = $aid
       else . end)
     + (if $extra == "{}" then {} else ($extra | fromjson) end)' \
    --argjson sv "$GRAPH_STATE_NODE_SCHEMA_VERSION_V2" \
    --arg nid "$node_id" --arg state "$state" --arg aid "$attempt_id" \
    --arg hasAttempt "$has_attempt" \
    --arg fields "$attempt_fields_json" \
    --arg extra "$node_extra_json" \
    --arg base "$base_json"; then
    echo "Error: failed to write v2 node ledger entry for $node_id" >&2
    return 1
  fi
  return 0
}

# graph_state_init_run_v2 <workspace> <namespace> <run_id> <plan_path>
#   <graph_json_path> [max_parallel]
#
# Same contract as graph_state_init_run, but writes schemaVersion 2 for
# run.json and seeds every node through graph_state_write_node_v2. Does not
# modify graph_state_init_run itself, so the live scheduler (which still
# calls graph_state_init_run) is unaffected; this is the entry point a later
# TODO wires callers to.
graph_state_init_run_v2() {
  local workspace="$1" namespace="$2" run_id="$3" plan_path="$4" graph_json_path="$5" max_parallel="${6:-2}"
  local run_dir run_file graph_file nodes_dir graph_sha ralph_version started_at node_count node_id

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" || -z "$plan_path" || -z "$graph_json_path" ]]; then
    echo "Error: graph_state_init_run_v2 requires workspace, namespace, run_id, plan_path, graph_json_path" >&2
    return 1
  fi
  if [[ ! -f "$graph_json_path" ]]; then
    echo "Error: graph_state_init_run_v2 graph json not found: $graph_json_path" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  [[ "$max_parallel" =~ ^[1-9][0-9]*$ ]] || max_parallel=2

  run_dir="$(graph_state_run_dir "$workspace" "$namespace" "$run_id")" || return 1
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  graph_file="$(graph_state_graph_file "$workspace" "$namespace" "$run_id")" || return 1
  nodes_dir="$(graph_state_nodes_dir "$workspace" "$namespace" "$run_id")" || return 1

  if ! mkdir -p "$run_dir" "$nodes_dir"; then
    echo "Error: failed to create run directory: $run_dir" >&2
    return 1
  fi

  local tmp_graph
  tmp_graph="$(mktemp "$run_dir/.graph-XXXXXX")" || return 1
  if ! cp "$graph_json_path" "$tmp_graph"; then
    rm -f "$tmp_graph"
    return 1
  fi
  if ! mv -f "$tmp_graph" "$graph_file"; then
    rm -f "$tmp_graph"
    return 1
  fi

  graph_sha="$(graph_state_compute_graph_sha "$graph_file")" || return 1
  ralph_version="$(graph_state_ralph_version)"
  started_at="$(graph_state_now_iso)"

  local supervisor_pid owner_hostname process_start_id heartbeat_at spid_json
  supervisor_pid="$(graph_state_supervisor_pid)"
  owner_hostname="$(graph_state_owner_hostname)"
  process_start_id="$(graph_state_owner_process_start_id)"
  heartbeat_at="$(graph_state_heartbeat_now)"
  if [[ "$supervisor_pid" =~ ^[0-9]+$ ]]; then
    spid_json="$supervisor_pid"
  else
    spid_json="null"
  fi

  if ! ralph_atomic_write_json "$run_file" \
    '{schemaVersion: $sv, ralphVersion: $rv, runId: $rid, planPath: $pp, graphSha: $gs, startedAt: $sa, status: "running", maxParallel: $mp, supervisorPid: $spid, ownerHostname: (if $oh == "" then null else $oh end), ownerProcessStartId: (if $op == "" then null else $op end), heartbeatAt: $hb}' \
    --argjson sv "$GRAPH_STATE_RUN_SCHEMA_VERSION_V2" \
    --arg rv "$ralph_version" \
    --arg rid "$run_id" \
    --arg pp "$plan_path" \
    --arg gs "$graph_sha" \
    --arg sa "$started_at" \
    --argjson mp "$max_parallel" \
    --argjson spid "$spid_json" \
    --arg oh "$owner_hostname" \
    --arg op "$process_start_id" \
    --arg hb "$heartbeat_at"; then
    echo "Error: failed to write run.json" >&2
    return 1
  fi

  node_count="$(jq '.nodes | length' "$graph_file")" || node_count=0
  local i=0
  while [[ "$i" -lt "$node_count" ]]; do
    node_id="$(jq -r ".nodes[$i].id // empty" "$graph_file")"
    if [[ -n "$node_id" ]]; then
      graph_state_write_node_v2 "$workspace" "$namespace" "$run_id" "$node_id" "pending" || {
        echo "Error: failed to seed v2 node ledger entry for $node_id" >&2
        return 1
      }
    fi
    i=$((i + 1))
  done

  graph_state_update_latest "$workspace" "$namespace" "$run_id" || true
  return 0
}

# graph_state_run_status_is_terminal <status>
# Returns 0 when <status> is a terminal whole-run status. The only non-terminal
# run status is "running".
graph_state_run_status_is_terminal() {
  case "${1:-}" in
    running) return 1 ;;
    succeeded|failed|cancelled|awaiting-ack|interrupted|awaiting-operator) return 0 ;;
    *) return 1 ;;
  esac
}

# graph_state_update_run_heartbeat <workspace> <namespace> <run_id> [timestamp]
#
# Atomically updates the heartbeatAt field of run.json. Rejects the update
# when the run has already reached a terminal status. Repeating the exact same
# timestamp is a no-op (idempotent). When <timestamp> is omitted, the current
# heartbeat time is used.
graph_state_update_run_heartbeat() {
  local workspace="$1" namespace="$2" run_id="$3" timestamp="${4:-}"
  local run_file base_json status current_hb

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" ]]; then
    echo "Error: graph_state_update_run_heartbeat requires workspace, namespace, and run_id" >&2
    return 1
  fi
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  if [[ ! -f "$run_file" ]]; then
    echo "Error: run ledger not found: $run_file" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1

  base_json="$(graph_state_read_run_v2 "$workspace" "$namespace" "$run_id")" || return 1
  status="$(jq -r '.status // empty' <<<"$base_json" 2>/dev/null)"
  if graph_state_run_status_is_terminal "$status"; then
    echo "Error: cannot update heartbeat for terminal run $run_id (status: $status)" >&2
    return 1
  fi

  if [[ -z "$timestamp" ]]; then
    timestamp="$(graph_state_heartbeat_now)"
  fi
  current_hb="$(jq -r '.heartbeatAt // empty' <<<"$base_json" 2>/dev/null)"
  if [[ "$current_hb" == "$timestamp" ]]; then
    return 0
  fi

  if ! ralph_atomic_write_json "$run_file" \
    '($base | fromjson) | .heartbeatAt = $hb' \
    --arg base "$base_json" \
    --arg hb "$timestamp"; then
    echo "Error: failed to update run heartbeat for $run_id" >&2
    return 1
  fi
  return 0
}

# graph_state_update_attempt_heartbeat <workspace> <namespace> <run_id>
#   <node_id> <attempt_id> [timestamp]
#
# Atomically updates the heartbeatAt field on a single running attempt. The
# node must be in the running state and the attempt must not already carry a
# terminal outcome. Repeating the exact same timestamp is a no-op. When
# <timestamp> is omitted, the current heartbeat time is used.
graph_state_update_attempt_heartbeat() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" attempt_id="$5" timestamp="${6:-}"
  local node_file base_json status attempt_idx outcome current_hb

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" || -z "$node_id" || -z "$attempt_id" ]]; then
    echo "Error: graph_state_update_attempt_heartbeat requires workspace, namespace, run_id, node_id, and attempt_id" >&2
    return 1
  fi
  node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  if [[ ! -f "$node_file" ]]; then
    echo "Error: node ledger not found: $node_file" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1

  base_json="$(graph_state_read_node_v2 "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  status="$(jq -r '.status // empty' <<<"$base_json" 2>/dev/null)"
  if [[ "$status" != "running" ]]; then
    echo "Error: cannot update heartbeat for node $node_id because it is not running (status: $status)" >&2
    return 1
  fi

  attempt_idx="$(jq -r --arg aid "$attempt_id" '(.attempts // []) | map(.attemptId) | index($aid)' <<<"$base_json" 2>/dev/null)"
  if [[ -z "$attempt_idx" || "$attempt_idx" == "null" ]]; then
    echo "Error: attempt $attempt_id not found for node $node_id" >&2
    return 1
  fi
  outcome="$(jq -r --arg aid "$attempt_id" '(.attempts // [])[] | select(.attemptId == $aid) | .outcome // empty' <<<"$base_json" 2>/dev/null)"
  if [[ -n "$outcome" ]]; then
    echo "Error: cannot update heartbeat for terminal attempt $attempt_id on node $node_id (outcome: $outcome)" >&2
    return 1
  fi

  if [[ -z "$timestamp" ]]; then
    timestamp="$(graph_state_heartbeat_now)"
  fi
  current_hb="$(jq -r --arg aid "$attempt_id" '(.attempts // [])[] | select(.attemptId == $aid) | .heartbeatAt // empty' <<<"$base_json" 2>/dev/null)"
  if [[ "$current_hb" == "$timestamp" ]]; then
    return 0
  fi

  if ! ralph_atomic_write_json "$node_file" \
    '($base | fromjson)
     | .attempts = ((.attempts // []) as $atts
       | ($atts | map(.attemptId) | index($aid)) as $idx
       | if $idx == null then $atts
         else ($atts | .[$idx] = ($atts[$idx] * {heartbeatAt: $hb}))
         end)' \
    --arg base "$base_json" \
    --arg aid "$attempt_id" \
    --arg hb "$timestamp"; then
    echo "Error: failed to update attempt heartbeat for $attempt_id on node $node_id" >&2
    return 1
  fi
  return 0
}
