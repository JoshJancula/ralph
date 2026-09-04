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
#                  startedAt, status, maxParallel, tooling. tooling records
#                  the workflow-level defaultProfile and the per-node
#                  resolved profile map frozen at init. status is one of
#                  running, succeeded, failed, awaiting-ack, cancelled.
#   graph.json   - frozen compile output, immutable for the life of the run.
#   nodes/<node_id>.json - per-node ledger entry: nodeId, status, attempts[],
#                  lastAttemptId, toolingProfile, and toolingDegradedKeys
#                  when the static resolver dropped keys for that node's
#                  runtime. Node states: pending, ready, running,
#                  succeeded, failed, blocked, skipped, awaiting-ack,
#                  cancelled. attempts entries carry attemptId, outcome,
#                  exitCode, startedAt, finishedAt, runtime, nativeSubagents,
#                  reason. Recording nativeSubagents per attempt keeps usage and
#                  savings comparisons honest: inherited native-subagent tokens
#                  are an opaque parent-owned cost that Ralph cannot itemize, so
#                  a run that had nativeSubagents=inherit for one node is not
#                  comparable to a run that used off without this provenance.
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

# Canonical graph ledger schema. All live run and node ledgers use this single
# shape and version. Do not create a version-N run containing version-(N-1)
# node ledgers: both constants move together.
GRAPH_STATE_RUN_SCHEMA_VERSION=3
GRAPH_STATE_NODE_SCHEMA_VERSION=3

# Canonical node states. Keep their order stable for readable ledgers/tests.
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
# equivalent. With neither set, use the workspace state-root default.
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
# Called on every ledger write, so it must not fork when bash can format the
# timestamp itself (%()T is bash 4.2+; bash 3.2 falls back to date(1)).
_GRAPH_STATE_TS_BUILTIN=""
graph_state_now_iso() {
  if [[ -z "$_GRAPH_STATE_TS_BUILTIN" ]]; then
    if printf '%(%Y)T' -1 >/dev/null 2>&1; then
      _GRAPH_STATE_TS_BUILTIN=1
    else
      _GRAPH_STATE_TS_BUILTIN=0
    fi
  fi
  if [[ "$_GRAPH_STATE_TS_BUILTIN" == "1" ]]; then
    local _ts
    TZ=UTC printf -v _ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
    printf '%s\n' "$_ts"
    return 0
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ
}

# graph_state_supervisor_pid
# Best-effort supervisor PID. Honors the GRAPH_STATE_SUPERVISOR_PID env
# override for tests and deterministic fixtures; otherwise reports the
# current shell PID ($$). Callers that launch graph-run from a subshell must
# bind GRAPH_STATE_SUPERVISOR_PID before invoking this helper so command
# substitution cannot capture a transient child process.
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

# graph_state_downstream_closure <graph_json_path> <node_id>
#
# Prints one line of space-separated node ids: the selected node first, then
# every transitive downstream dependent reachable via frozen edges (from -> to),
# with dependents sorted for a deterministic preview. Returns 1 when the graph
# file is missing or node_id is unknown. jq-only; no python3.
graph_state_downstream_closure() {
  local graph_json_path="$1" node_id="$2"
  local line
  if [[ -z "$graph_json_path" || ! -f "$graph_json_path" || -z "$node_id" ]]; then
    echo "Error: graph_state_downstream_closure requires graph json path and node id" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  if ! jq -e --arg id "$node_id" 'any(.nodes[]?; .id == $id)' "$graph_json_path" >/dev/null 2>&1; then
    echo "Error: unknown graph node for downstream closure: $node_id" >&2
    return 1
  fi
  line="$(jq -r --arg id "$node_id" '
    def downs($n; $edges; $seen):
      ($edges | map(select(.from == $n) | .to) - $seen) as $next
      | if ($next | length) == 0 then $seen
        else
          reduce $next[] as $x ($seen + $next | unique;
            downs($x; $edges; .)
          )
        end;
    (downs($id; (.edges // []); [$id]) | map(select(. != $id)) | sort) as $deps
    | ([$id] + $deps) | join(" ")
  ' "$graph_json_path" 2>/dev/null)" || return 1
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
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
# file (e.g. left__run-1__3 -> 3). Duplicate attemptIds do not inflate the
# result: numbering uses
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
# This is a supervisor reset, not a model-driven state transition: the
# canonical state machine rejects running->pending and cancelled->pending.
# Preserve the attempt history while resetting the node in place.
graph_state_reset_node_to_pending() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4"
  local node_file base_json

  node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  [[ -f "$node_file" ]] || return 1
  base_json="$(jq -c . "$node_file" 2>/dev/null)" || return 1
  if ! ralph_atomic_write_json "$node_file" \
    '($base | fromjson) | .status = "pending"' \
    --arg base "$base_json"; then
    echo "Error: failed to reset node ledger entry for $node_id" >&2
    return 1
  fi
  return 0
}

# graph_state_node_id_from_filename <safe_id>
# Inverse of the sed sanitization in graph_state_node_file. Best-effort: the
# sanitizer is non-injective, so callers that need the original id should read
# .nodeId from the ledger entry instead. Provided for completeness only.
graph_state_node_id_from_filename() {
  printf '%s\n' "$1"
}

# Canonical graph ledgers own one attempts[] object per attemptId. A running
# attempt is updated in place with heartbeat, usage, logs, and terminal
# evidence rather than appending duplicate transition records.

# Extra node states: a retry backoff wait, a block on an explicit
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
# the canonical state machine. An empty <from_state> (the node's first write) is
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


# graph_state_unsupported_schema_error <run|node> <detected> <required>
# Graph mode has one unreleased ledger shape. A stale file is rejected rather
# than silently interpreted or migrated, and the error tells the operator the
# recoverable action.
graph_state_unsupported_schema_error() {
  local kind="$1" detected="$2" required="$3"
  printf "Error: unsupported graph %s ledger schema '%s' (detected schemaVersion %s); graph mode requires schemaVersion %s. Re-create this graph run with the current Ralph version.\n" \
    "$kind" "${detected:-<missing>}" "${detected:-<missing>}" "$required" >&2
}

# graph_state_build_tooling_manifest <graph_file>
# Prints the run-ledger tooling object: workflow defaultProfile plus the
# per-node resolved profile map derived from the frozen graph. Absent values
# are JSON null. Never consults ambient environment.
graph_state_build_tooling_manifest() {
  local graph_file="$1"
  if [[ -z "$graph_file" || ! -f "$graph_file" ]]; then
    echo "Error: graph_state_build_tooling_manifest requires a graph file" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  jq -c '{
    defaultProfile: (.tooling.defaultProfile // null),
    nodes: (
      [.nodes[]? | {key: .id, value: (.stage.toolingProfile // null)}]
      | from_entries
    )
  }' "$graph_file"
}

# graph_state_tooling_degraded_keys_json <profile> <runtime>
# Prints a stable JSON array of profile env keys the static resolver drops
# for <runtime>. Empty array when nothing is dropped or <profile> is empty.
# Derives from tooling-profiles.json + graph_runtime_tooling_profile_capabilities;
# does not read ambient env overlays.
graph_state_tooling_degraded_keys_json() {
  local profile="${1:-}" runtime="${2:-}"
  local env_lines degraded
  if [[ -z "$profile" ]]; then
    printf '%s\n' '[]'
    return 0
  fi
  if ! declare -F ralph_tooling_profile_env >/dev/null 2>&1; then
    # shellcheck source=../tooling-profile.sh
    source "$GRAPH_STATE_SCRIPT_DIR/../tooling-profile.sh"
  fi
  env_lines="$(ralph_tooling_profile_env "$profile" "$runtime")" || return 1
  degraded="$(printf '%s\n' "$env_lines" | sed -n 's/^RALPH_TOOLING_PROFILE_DEGRADED=//p' | head -n1)"
  if [[ -z "$degraded" ]]; then
    printf '%s\n' '[]'
    return 0
  fi
  printf '%s' "$degraded" | jq -Rc 'split(",") | map(select(length > 0))'
}

# graph_state_node_tooling_extra_json <graph_file> <node_id>
# Builds the node-ledger tooling seed object for one node: toolingProfile and,
# when the resolver degraded anything for that node runtime, toolingDegradedKeys.
graph_state_node_tooling_extra_json() {
  local graph_file="$1" node_id="$2"
  local profile runtime degraded_json
  if [[ -z "$graph_file" || -z "$node_id" || ! -f "$graph_file" ]]; then
    echo "Error: graph_state_node_tooling_extra_json requires graph_file and node_id" >&2
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 1
  profile="$(jq -r --arg id "$node_id" '
    .nodes[]? | select(.id == $id) | .stage.toolingProfile // empty
  ' "$graph_file")"
  runtime="$(jq -r --arg id "$node_id" '
    .nodes[]? | select(.id == $id) | .stage.runtime // empty
  ' "$graph_file")"
  if [[ -z "$profile" ]]; then
    printf '%s\n' '{"toolingProfile":null}'
    return 0
  fi
  degraded_json="$(graph_state_tooling_degraded_keys_json "$profile" "$runtime")" || return 1
  if [[ "$degraded_json" == "[]" ]]; then
    jq -nc --arg p "$profile" '{toolingProfile: $p}'
  else
    jq -nc --arg p "$profile" --argjson d "$degraded_json" \
      '{toolingProfile: $p, toolingDegradedKeys: $d}'
  fi
}

# graph_state_require_run_schema <workspace> <namespace> <run_id>
# Fail-closed schema gate used by resume and other readers that must not
# interpret a stale run ledger. Prints the unsupported-schema error to stderr.
graph_state_require_run_schema() {
  graph_state_read_run "$@" >/dev/null
}

# graph_state_require_node_schema <workspace> <namespace> <run_id> <node_id>
# Fail-closed schema gate for a single node ledger file.
graph_state_require_node_schema() {
  graph_state_read_node "$@" >/dev/null
}

# graph_state_read_node <workspace> <namespace> <run_id> <node_id>
#
# Reads the one canonical graph node ledger shape. Graph mode is unreleased;
# it deliberately does not normalize or execute a second historical format.
graph_state_read_node() {
  local node_file raw version
  node_file="$(graph_state_node_file "$@")" || return 1
  [[ -f "$node_file" ]] || return 1
  raw="$(cat "$node_file")" || return 1
  command -v jq >/dev/null 2>&1 || return 1
  version="$(jq -r '.schemaVersion // empty' <<<"$raw" 2>/dev/null)"
  if [[ "$version" != "$GRAPH_STATE_NODE_SCHEMA_VERSION" ]]; then
    graph_state_unsupported_schema_error node "$version" "$GRAPH_STATE_NODE_SCHEMA_VERSION"
    return 1
  fi
  jq -c '.' <<<"$raw" 2>/dev/null
}


# graph_state_read_run <workspace> <namespace> <run_id>
#
# Reads the canonical graph run ledger shape.
graph_state_read_run() {
  local run_file raw version
  run_file="$(graph_state_run_file "$@")" || return 1
  [[ -f "$run_file" ]] || return 1
  raw="$(cat "$run_file")" || return 1
  command -v jq >/dev/null 2>&1 || return 1
  version="$(jq -r '.schemaVersion // empty' <<<"$raw" 2>/dev/null)"
  if [[ "$version" != "$GRAPH_STATE_RUN_SCHEMA_VERSION" ]]; then
    graph_state_unsupported_schema_error run "$version" "$GRAPH_STATE_RUN_SCHEMA_VERSION"
    return 1
  fi
  jq -c '.' <<<"$raw" 2>/dev/null
}

# graph_state_write_node <workspace> <namespace> <run_id> <node_id> <state>
#   [attempt_id] [attempt_fields_json] [node_extra_json]
#
# Canonical node writer -- atomic attempt upsert. attempt_fields_json is an
# optional JSON object populating any subset of the attempt fields:
# startedAt, finishedAt, outcome, exitCode, runtime, reason, logPaths,
# usageSnapshot, usageReliable, retryClassification, heartbeatAt,
# operatorRequestId. When attempt_id matches an existing attempts[] entry,
# the fields are merged into that one object through ralph_atomic_write_json
# so the node keeps exactly one attempts[] object per attemptId -- starting
# an attempt creates the one record; a later heartbeat, usage, log-metadata,
# or terminalization call updates it in place. Fields already on the
# existing entry that are not present in attempt_fields_json are left
# alone. node_extra_json is merged into both the node document and the
# matching attempt. Repeating an identical
# update is idempotent (the merged content is byte-for-byte the same);
# attempting to terminalize an attempt that already has a different recorded
# outcome is rejected before any write, so the file on disk is left unchanged.
#
# Validates the requested state transition against the node's current
# on-disk state (a node's first write is always legal) and rejects a node
# ledger with an unknown future schemaVersion.
graph_state_write_node() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" state="$5"
  local attempt_id="${6:-}" attempt_fields_json="${7:-}" node_extra_json="${8:-}"
  local node_file

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" || -z "$node_id" ]]; then
    echo "Error: graph_state_write_node requires workspace, namespace, run_id, node_id" >&2
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
      base_version="$(jq -r '.schemaVersion // empty' <<<"$base_json" 2>/dev/null)"
      if [[ "$base_version" != "$GRAPH_STATE_NODE_SCHEMA_VERSION" ]]; then
        graph_state_unsupported_schema_error node "$base_version" "$GRAPH_STATE_NODE_SCHEMA_VERSION"
        return 1
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
    --argjson sv "$GRAPH_STATE_NODE_SCHEMA_VERSION" \
    --arg nid "$node_id" --arg state "$state" --arg aid "$attempt_id" \
    --arg hasAttempt "$has_attempt" \
    --arg fields "$attempt_fields_json" \
    --arg extra "$node_extra_json" \
    --arg base "$base_json"; then
    echo "Error: failed to write node ledger entry for $node_id" >&2
    return 1
  fi
  return 0
}

# graph_state_init_run <workspace> <namespace> <run_id> <plan_path>
#   <graph_json_path> [max_parallel] [registry_run_path]
#
# Creates the canonical graph run ledger and seeds every node through the
# canonical atomic node writer. When registry_run_path is non-empty (or
# RALPH_WORKFLOW_REGISTRY_RUN is set), stores that absolute outer workflow
# registry path as registryRunPath so Dependency adapters can correlate without
# copying ledgers. The run_id is always the caller-supplied common ID.
graph_state_init_run() {
  local workspace="$1" namespace="$2" run_id="$3" plan_path="$4" graph_json_path="$5" max_parallel="${6:-2}"
  local registry_run_path="${7:-${RALPH_WORKFLOW_REGISTRY_RUN:-}}"
  local run_dir run_file graph_file nodes_dir graph_sha ralph_version started_at node_count node_id

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
  if [[ -n "$registry_run_path" ]]; then
    case "$registry_run_path" in
      /*) ;;
      *)
        echo "Error: registryRunPath must be an absolute path: $registry_run_path" >&2
        return 1
        ;;
    esac
    if [[ -L "$registry_run_path" ]]; then
      echo "Error: refusing registryRunPath through a symlink: $registry_run_path" >&2
      return 1
    fi
  fi

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

  local tooling_json
  tooling_json="$(graph_state_build_tooling_manifest "$graph_file")" || {
    echo "Error: failed to build tooling manifest for run $run_id" >&2
    return 1
  }

  if ! ralph_atomic_write_json "$run_file" \
    '{schemaVersion: $sv, ralphVersion: $rv, runId: $rid, planPath: $pp, graphSha: $gs, startedAt: $sa, status: "running", maxParallel: $mp, supervisorPid: $spid, ownerHostname: (if $oh == "" then null else $oh end), ownerProcessStartId: (if $op == "" then null else $op end), heartbeatAt: $hb, tooling: $tooling, registryRunPath: (if $rrp == "" then null else $rrp end)}' \
    --argjson sv "$GRAPH_STATE_RUN_SCHEMA_VERSION" \
    --arg rv "$ralph_version" \
    --arg rid "$run_id" \
    --arg pp "$plan_path" \
    --arg gs "$graph_sha" \
    --arg sa "$started_at" \
    --argjson mp "$max_parallel" \
    --argjson spid "$spid_json" \
    --arg oh "$owner_hostname" \
    --arg op "$process_start_id" \
    --arg hb "$heartbeat_at" \
    --argjson tooling "$tooling_json" \
    --arg rrp "$registry_run_path"; then
    echo "Error: failed to write run.json" >&2
    return 1
  fi

  node_count="$(jq '.nodes | length' "$graph_file")" || node_count=0
  local i=0 node_extra_json
  while [[ "$i" -lt "$node_count" ]]; do
    node_id="$(jq -r ".nodes[$i].id // empty" "$graph_file")"
    if [[ -n "$node_id" ]]; then
      node_extra_json="$(graph_state_node_tooling_extra_json "$graph_file" "$node_id")" || {
        echo "Error: failed to resolve tooling seed for node $node_id" >&2
        return 1
      }
      graph_state_write_node "$workspace" "$namespace" "$run_id" "$node_id" "pending" \
        "" "{}" "$node_extra_json" || {
        echo "Error: failed to seed node ledger entry for $node_id" >&2
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

# graph_state_rebind_run_owner <workspace> <namespace> <run_id> [supervisor_pid]
#
# Transfers a running ledger from the short-lived process that initialized it
# to the process that actually owns scheduling. Detached public workflow starts
# initialize before launching their isolated supervisor, so heartbeat-only
# updates would otherwise leave a dead startup PID in durable ownership.
graph_state_rebind_run_owner() {
  local workspace="$1" namespace="$2" run_id="$3"
  local supervisor_pid="${4:-${GRAPH_STATE_SUPERVISOR_PID:-${BASHPID:-$$}}}"
  local run_file base_json status owner_hostname process_start_id heartbeat_at

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" ]]; then
    echo "Error: graph_state_rebind_run_owner requires workspace, namespace, and run_id" >&2
    return 1
  fi
  if [[ ! "$supervisor_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: graph_state_rebind_run_owner requires a positive supervisor pid" >&2
    return 1
  fi
  run_file="$(graph_state_run_file "$workspace" "$namespace" "$run_id")" || return 1
  [[ -f "$run_file" ]] || {
    echo "Error: run ledger not found: $run_file" >&2
    return 1
  }

  base_json="$(graph_state_read_run "$workspace" "$namespace" "$run_id")" || return 1
  status="$(jq -r '.status // empty' <<<"$base_json" 2>/dev/null)"
  if graph_state_run_status_is_terminal "$status"; then
    echo "Error: cannot rebind owner for terminal run $run_id (status: $status)" >&2
    return 1
  fi

  owner_hostname="$(graph_state_owner_hostname)"
  process_start_id="$(GRAPH_STATE_SUPERVISOR_PID="$supervisor_pid" graph_state_owner_process_start_id)"
  heartbeat_at="$(graph_state_heartbeat_now)"
  if ! ralph_atomic_write_json "$run_file" \
    '($base | fromjson)
     | .supervisorPid = $pid
     | .ownerHostname = (if $host == "" then null else $host end)
     | .ownerProcessStartId = (if $start == "" then null else $start end)
     | .heartbeatAt = $heartbeat' \
    --arg base "$base_json" \
    --argjson pid "$supervisor_pid" \
    --arg host "$owner_hostname" \
    --arg start "$process_start_id" \
    --arg heartbeat "$heartbeat_at"; then
    echo "Error: failed to rebind run owner for $run_id" >&2
    return 1
  fi
  return 0
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

  base_json="$(graph_state_read_run "$workspace" "$namespace" "$run_id")" || return 1
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

  base_json="$(graph_state_read_node "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
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

# graph_state_persist_plan_progress <workspace> <namespace> <run_id> <node_id>
#   <binding-json>
#
# Merges plan-backed progress fields from a bind/progress JSON object onto the
# node ledger without mutating source plan/manifest. binding-json must include
# sourcePlanPath, controlPlanPath, planRunId, planSourceKind, planSourceStageId,
# completedTodos, totalTodos, and currentTodoId (nullable).
graph_state_persist_plan_progress() {
  local workspace="$1" namespace="$2" run_id="$3" node_id="$4" binding_json="${5:-}"
  local node_file status extra

  if [[ -z "$workspace" || -z "$namespace" || -z "$run_id" || -z "$node_id" || -z "$binding_json" ]]; then
    echo "Error: graph_state_persist_plan_progress requires workspace, namespace, run_id, node_id, binding-json" >&2
    return 1
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$binding_json"; then
    echo "Error: invalid binding-json for plan progress persist" >&2
    return 1
  fi

  node_file="$(graph_state_node_file "$workspace" "$namespace" "$run_id" "$node_id")" || return 1
  if [[ ! -f "$node_file" ]]; then
    echo "Error: node ledger missing for plan progress persist: $node_id" >&2
    return 1
  fi
  status="$(jq -r '.status // "pending"' "$node_file")"

  extra="$(printf '%s' "$binding_json" | jq -c '{
    planPath: (.controlPlanPath // .planPath // null),
    planRunId: (.planRunId // null),
    planSourceKind: (.planSourceKind // "generated"),
    planSourceStageId: (.planSourceStageId // null),
    originalPlanPath: (.originalPlanPath // null),
    sourcePlanPath: (.sourcePlanPath // null),
    controlPlanPath: (.controlPlanPath // null),
    currentTodoId: (.currentTodoId // null),
    completedTodos: (.completedTodos // 0),
    totalTodos: (.totalTodos // 0)
  }')" || return 1

  graph_state_write_node "$workspace" "$namespace" "$run_id" "$node_id" "$status" \
    "" "{}" "$extra"
}
