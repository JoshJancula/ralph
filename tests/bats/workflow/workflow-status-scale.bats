#!/usr/bin/env bats
# Benchmark-style regression fixture for the public workflow status pipeline
# at scale (100+ stages), for both Sequential and Dependency modes.
#
# The primary gate is structural, not timing: workflow_dep_project_snapshot
# and workflow_seq_project_snapshot must issue a bounded, size-independent
# number of jq processes to read a run's ledger, regardless of stage count.
# A per-stage subprocess fan-out (one jq process per node/stage ledger file)
# would scale that count with the fixture size instead of staying flat.
#
# A wall-clock ceiling on the full public status path (workflow_operator_
# view_load, which backs `ralph workflow status --json`) guards only against
# a deadlock or runaway loop; it is intentionally not a brittle
# workstation-specific timing gate. The floor is a generous five seconds,
# but the ceiling scales up with this host's own measured subprocess-spawn
# cost (calibrated once per file from a handful of trivial jq calls) times
# the actual jq-call count from the same run, so a slower CI/dev box does
# not turn an honest, non-regressed run into a flaky failure.
#
# Baseline observed at authoring time, 100-stage fixtures, this machine:
#   Dependency batched snapshot jq calls: 3-5 (flat, independent of count)
#   Sequential batched snapshot jq calls: ~7 (flat, independent of count)
#   Full status --json jq calls: flat for workflows with no approval/input
#     records; ordinary stageKind enrichment is one jq pass over the array.
#
# Contracts: agents/rules/test-design.md (structural gate over timing gate),
# tests/bats/workflow/workflow-run-registry.bats (the 12-node projector test
# this fixture extends to 100+ stages and to Sequential mode and the full
# public status pipeline).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
DEP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-engine-dependency.sh"
SEQ_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-engine-sequential.sh"
OPVIEW="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-operator-view.sh"

STAGE_COUNT=100
STATUS_JQ_CEILING_FLOOR_SECONDS=5
# The real cost per jq call inside workflow_operator_view_load is higher
# than a bare "jq -n" calibration probe because the full path also pays for
# surrounding bash subshells, nested command substitutions, and function
# calls that are not in the jq calibration or count. The margin absorbs that
# gap; it only needs to be loose enough that an honest, non-regressed run
# never trips the deadlock guard.
STATUS_JQ_CEILING_MARGIN=20
# Flat, size-independent jq-call ceiling for the batched snapshot projectors
# (workflow_dep_project_snapshot / workflow_seq_project_snapshot). Observed
# values are around 3-5 for Dependency (varies slightly with whether a
# heartbeat is present on the graph run ledger) and around 7 for Sequential
# (it also reads/validates the outer run ledger and classifies the owner).
# The gate stays a small constant regardless of stage count; a return to
# per-node/per-stage ledger fan-out pushes it to roughly one call per stage.
SNAPSHOT_JQ_CEILING=10
FULL_STATUS_JQ_CEILING=80

setup_file() {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$STATE_LIB" ]
  [ -f "$DEP_LIB" ]
  [ -f "$SEQ_LIB" ]
  [ -f "$OPVIEW" ]
  # Calibrate this host's own jq subprocess-spawn cost once per file, so the
  # deadlock/runaway ceiling below scales with real hardware speed instead
  # of assuming a fixed-speed workstation.
  local calib_start calib_end calib_calls=40 i
  calib_start="$(date +%s%N)"
  for ((i = 0; i < calib_calls; i++)); do
    jq -n '1' >/dev/null
  done
  calib_end="$(date +%s%N)"
  CALIBRATED_JQ_SPAWN_MS=$(( (calib_end - calib_start) / 1000000 / calib_calls ))
  [ "$CALIBRATED_JQ_SPAWN_MS" -ge 1 ] || CALIBRATED_JQ_SPAWN_MS=1
  export CALIBRATED_JQ_SPAWN_MS
}

setup() {
  unset RALPH_WORKFLOW_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT RALPH_GRAPH_STATE_ROOT
  unset WORKFLOW_STATE_FIXED_RUN_ID WORKFLOW_STATE_FIXED_NOW
  unset GRAPH_STATE_FIXED_RUN_ID GRAPH_STATE_SUPERVISOR_PID
  unset GRAPH_STATE_OWNER_HOSTNAME GRAPH_STATE_OWNER_PROCESS_START_ID
  unset GRAPH_STATE_HEARTBEAT_AT
  export WORKFLOW_STATE_SKIP_FSYNC=1
  # shellcheck source=/dev/null
  source "$STATE_LIB"
  # shellcheck source=/dev/null
  source "$DEP_LIB"
  # shellcheck source=/dev/null
  source "$SEQ_LIB"
  # shellcheck source=/dev/null
  source "$OPVIEW"
  CASE="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wf-status-scale.XXXXXX")"
  export CASE
}

teardown() {
  rm -rf "$CASE"
}

# install_jq_counter <count-log-path>
# Prepends a counting shim ahead of the real jq on PATH. Every jq
# invocation, including ones made deep inside sourced functions, appends one
# byte to the log. Must be called directly (never via command substitution:
# a `$(...)` capture forks a subshell and the PATH/export side effects here
# would be lost the instant it returns). Sets _JQ_COUNTER_SHIM for
# uninstall_jq_counter and also forces bash to forget any already-cached
# "jq" location (`hash -r`), since a stale hash entry would otherwise keep
# resolving to the real binary and silently bypass the shim.
install_jq_counter() {
  local log="$1"
  _JQ_COUNTER_SHIM="$CASE/jq-shim"
  mkdir -p "$_JQ_COUNTER_SHIM"
  : >"$log"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf x >> "$JQ_COUNT_LOG"' \
    'exec "$REAL_JQ" "$@"' \
    >"$_JQ_COUNTER_SHIM/jq"
  chmod +x "$_JQ_COUNTER_SHIM/jq"
  REAL_JQ="$(command -v jq)"
  export REAL_JQ
  export JQ_COUNT_LOG="$log"
  PATH="$_JQ_COUNTER_SHIM:$PATH"
  export PATH
  hash -r
}

# uninstall_jq_counter
uninstall_jq_counter() {
  PATH="${PATH#"$_JQ_COUNTER_SHIM:"}"
  export PATH
  unset REAL_JQ JQ_COUNT_LOG
  hash -r
}

jq_calls() {
  wc -c <"$1" | tr -d ' '
}

# write_dependency_graph_json <path> <node-count>
# One implement node plus batch-1..batch-(node-count-1), all independent
# agent nodes, written with a single jq process.
write_dependency_graph_json() {
  local path="$1" node_count="$2"
  jq -n --argjson n "$node_count" '{
    schemaVersion: 1,
    namespace: "scale-dep",
    maxParallel: 4,
    tooling: { defaultProfile: null },
    nodes: ([{
      id: "implement", type: "agent", dependsOn: [],
      derivedFrom: "stage", stage: { id: "implement", runtime: "cursor", toolingProfile: null }
    }] + [range(1; $n) | {
      id: ("batch-" + tostring), type: "agent", dependsOn: [],
      derivedFrom: "stage", stage: { id: ("batch-" + tostring), runtime: "cursor" }
    }]),
    edges: []
  }' >"$path"
}

# build_dependency_run <stage-count>
# Starts a Dependency-mode registry run and frozen graph ledger with
# <stage-count> nodes. Extra node ledger files are written directly (no jq
# process per node) so fixture setup cost stays out of the measured path.
build_dependency_run() {
  local node_count="$1" run_id graph_json plan_path graph_dir i

  mkdir -p "$CASE/inputs"
  printf '%s\n' '---' 'kind: workflow' 'mode: dependency' '---' >"$CASE/inputs/wf-dep.md"
  printf '# plan\n- [ ] work\n' >"$CASE/inputs/dep.plan.md"
  graph_json="$CASE/inputs/graph.json"
  write_dependency_graph_json "$graph_json" "$node_count"

  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T00:00:00Z"
  export WORKFLOW_STATE_FIXED_RUN_ID="run-20260101T000000Z-0-scaledep"
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf-dep.md" \
      --source-kind project \
      --mode dependency \
      --entry-kind task \
      --task "Scale fixture" \
      --task-provenance explicit \
      --input-file "$CASE/inputs/dep.plan.md" \
      --workflow-id scale-delivery \
      --engine-namespace scale-dep
  )"
  unset WORKFLOW_STATE_FIXED_RUN_ID WORKFLOW_STATE_FIXED_NOW

  plan_path="$CASE/inputs/dep.plan.md"
  graph_dir="$(
    workflow_dep_start_engine \
      --state-root "$CASE" \
      --run-id "$run_id" \
      --workspace "$CASE" \
      --plan-path "$plan_path" \
      --graph-json "$graph_json" \
      --namespace scale-dep
  )"
  # workflow_dep_start_engine exports these inside the command-substitution
  # subshell above, which does not survive back into this shell; the
  # projector below resolves the graph ledger through these same variables.
  export RALPH_GRAPH_STATE_ROOT="$CASE"
  export RALPH_PLAN_WORKSPACE_ROOT="$CASE"

  for ((i = 1; i < node_count; i++)); do
    printf '{"schemaVersion":3,"nodeId":"batch-%s","status":"succeeded","attempts":[]}\n' "$i" \
      >"$graph_dir/nodes/batch-$i.json"
  done

  printf '%s\n' "$run_id"
}

# write_sequential_orch_json <path> <stage-count>
write_sequential_orch_json() {
  local path="$1" stage_count="$2"
  jq -n --argjson n "$stage_count" '{
    stages: [range(0; $n) | {id: ("stage-" + (. | tostring)), runtime: "cursor"}]
  }' >"$path"
}

# build_sequential_run <stage-count>
build_sequential_run() {
  local stage_count="$1" run_id registry_run input_path

  mkdir -p "$CASE/inputs"
  printf '%s\n' '---' 'kind: workflow' 'mode: sequential' '---' >"$CASE/inputs/wf-seq.md"
  write_sequential_orch_json "$CASE/inputs/orch.json" "$stage_count"

  export WORKFLOW_STATE_FIXED_NOW="2026-01-01T00:00:00Z"
  export WORKFLOW_STATE_FIXED_RUN_ID="run-20260101T000000Z-0-scaleseq"
  run_id="$(
    workflow_state_create \
      --state-root "$CASE" \
      --source-path "$CASE/inputs/wf-seq.md" \
      --source-kind project \
      --mode sequential \
      --entry-kind task \
      --task "Scale fixture" \
      --task-provenance explicit \
      --input-file "$CASE/inputs/orch.json" \
      --workflow-id scale-delivery
  )"
  unset WORKFLOW_STATE_FIXED_RUN_ID WORKFLOW_STATE_FIXED_NOW

  registry_run="$CASE/workflow-runs/$run_id"
  input_path="$(jq -r '.inputPath' "$registry_run/run.json")"
  workflow_seq_init_engine \
    --registry-run "$registry_run" \
    --input-file "$input_path" \
    --run-id "$run_id" >/dev/null

  printf '%s\n' "$run_id"
}

# assert_within_deadlock_ceiling <elapsed-ms> <jq-call-count>
# The deadlock/runaway guard: a generous five-second floor, scaled up by
# this host's own calibrated jq-spawn cost times the actual call count times
# a wide safety margin. A real hang or an O(n^2)-scale blowup fails this; an
# honest, non-regressed run on a slow CI box does not.
assert_within_deadlock_ceiling() {
  local elapsed_ms="$1" jq_call_count="$2" ceiling_ms scaled_ms
  scaled_ms=$(( CALIBRATED_JQ_SPAWN_MS * jq_call_count * STATUS_JQ_CEILING_MARGIN ))
  ceiling_ms=$(( STATUS_JQ_CEILING_FLOOR_SECONDS * 1000 ))
  [ "$scaled_ms" -gt "$ceiling_ms" ] && ceiling_ms="$scaled_ms"
  [ "$elapsed_ms" -lt "$ceiling_ms" ]
}

@test "Dependency mode: 100-stage status --json holds the batched-projector jq gate and the deadlock ceiling" {
  local run_id outer status_json start_ns end_ns elapsed_ms jq_count

  run_id="$(build_dependency_run "$STAGE_COUNT")"
  outer="$(workflow_state_read "$CASE" "$run_id")"

  # Primary structural gate: reading graph.json plus every node ledger must
  # cost a flat, size-independent number of jq processes.
  install_jq_counter "$CASE/snapshot-jq.log"
  workflow_dep_project_snapshot "$CASE" scale-dep "$run_id" "$outer" >/dev/null
  uninstall_jq_counter
  [ "$(jq_calls "$CASE/snapshot-jq.log")" -le "$SNAPSHOT_JQ_CEILING" ]

  # Full public status path: baseline jq-call count plus the deadlock guard.
  install_jq_counter "$CASE/full-jq.log"
  start_ns="$(date +%s%N)"
  status_json="$(workflow_operator_view_load "$CASE" "$run_id")"
  end_ns="$(date +%s%N)"
  uninstall_jq_counter

  [ "$(printf '%s' "$status_json" | jq '.stages | length')" -eq "$STAGE_COUNT" ]
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  jq_count="$(jq_calls "$CASE/full-jq.log")"
  assert_within_deadlock_ceiling "$elapsed_ms" "$jq_count"
  [ "$(jq_calls "$CASE/full-jq.log")" -le "$FULL_STATUS_JQ_CEILING" ]
}

@test "Sequential mode: 100-stage status --json holds the batched-projector jq gate and the deadlock ceiling" {
  local run_id status_json start_ns end_ns elapsed_ms jq_count

  run_id="$(build_sequential_run "$STAGE_COUNT")"

  # Primary structural gate: reading every engine/stages/*.json document must
  # cost a flat, size-independent number of jq processes. Sequential's
  # snapshot legitimately costs a few more calls than Dependency's (it reads
  # and validates the outer run ledger itself and classifies the owner),
  # observed at 7 for this fixture; the ceiling stays a small constant
  # either way, independent of stage count.
  install_jq_counter "$CASE/snapshot-jq.log"
  workflow_seq_project_snapshot "$CASE" "$run_id" >/dev/null
  uninstall_jq_counter
  [ "$(jq_calls "$CASE/snapshot-jq.log")" -le "$SNAPSHOT_JQ_CEILING" ]

  # Full public status path: baseline jq-call count plus the deadlock guard.
  install_jq_counter "$CASE/full-jq.log"
  start_ns="$(date +%s%N)"
  status_json="$(workflow_operator_view_load "$CASE" "$run_id")"
  end_ns="$(date +%s%N)"
  uninstall_jq_counter

  [ "$(printf '%s' "$status_json" | jq '.stages | length')" -eq "$STAGE_COUNT" ]
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  jq_count="$(jq_calls "$CASE/full-jq.log")"
  assert_within_deadlock_ceiling "$elapsed_ms" "$jq_count"
  [ "$(jq_calls "$CASE/full-jq.log")" -le "$FULL_STATUS_JQ_CEILING" ]
}

@test "batched-projector jq gate catches a reintroduced per-node subprocess fan-out, then the implementation is restored" {
  local run_id outer original_def regressed_count restored_count

  run_id="$(build_dependency_run "$STAGE_COUNT")"
  outer="$(workflow_state_read "$CASE" "$run_id")"

  original_def="$(declare -f workflow_dep_project_snapshot)"

  # Deliberately bypass the batched projector: read every node ledger with
  # its own jq process, reproducing the historical per-stage subprocess
  # fan-out this fixture guards against.
  workflow_dep_project_snapshot() {
    local workspace="$1" namespace="$2" rid="$3"
    local nodes_dir f
    _workflow_dep_ensure_graph_state_root "$workspace" "$namespace" "$rid"
    nodes_dir="$(dirname "$(graph_state_run_file "$workspace" "$namespace" "$rid")")/nodes"
    for f in "$nodes_dir"/*.json; do
      jq -c '.' "$f" >/dev/null
    done
    printf '{"stages":[],"observation":{"nodes":[]}}\n'
  }

  install_jq_counter "$CASE/regression-jq.log"
  workflow_dep_project_snapshot "$CASE" scale-dep "$run_id" "$outer" >/dev/null
  uninstall_jq_counter
  regressed_count="$(jq_calls "$CASE/regression-jq.log")"

  # The gate must fail on the regressed implementation: per-node fan-out
  # pushes the call count from a flat <=3 to roughly one per node.
  [ "$regressed_count" -gt "$SNAPSHOT_JQ_CEILING" ]
  [ "$regressed_count" -ge "$STAGE_COUNT" ]

  eval "$original_def"

  install_jq_counter "$CASE/restored-jq.log"
  workflow_dep_project_snapshot "$CASE" scale-dep "$run_id" "$outer" >/dev/null
  uninstall_jq_counter
  restored_count="$(jq_calls "$CASE/restored-jq.log")"
  [ "$restored_count" -le "$SNAPSHOT_JQ_CEILING" ]
}
