#!/usr/bin/env bash
# Shared fixtures and helpers for the graph scheduler suites.
#
# graph-schedule.bats keeps the library-level tests (index loading, reaper
# behaviour, ledger records). graph-schedule-e2e.bats keeps the tests that
# drive a real dispatch: each of those boots the orchestrator and run-plan
# once per node, so they run in the acceptance tier rather than on the
# pull-request path.
#
# This is the non-@test body of the original graph-schedule.bats in its
# original order. Several helpers are emitted inside heredocs and depend on
# that ordering, so do not reorder.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

FIXTURE_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-edges.plan.md"
DIAMOND_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-diamond.plan.md"
CONSENSUS_JOIN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/graph/graph-consensus-join-subagents-on.plan.md"
STUB_RUN_PLAN="$BATS_TEST_DIRNAME/../../fixtures/orchestrator-single-stage/run-plan-stub.sh"
RALPH_DIR="$REPO_ROOT/bundle/.ralph"
SCHEDULE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-schedule.sh"

json_payload() {
  printf '%s\n' "$1" | awk 'END{print}'
}

# Prepare a scratch workspace with a stubbed run-plan. Sets DISPATCH_WORKSPACE
# and exports (must not be invoked via command substitution — exports would be lost).
setup_dispatch_workspace() {
  local tmpd="$1"
  DISPATCH_WORKSPACE="$tmpd/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"

  # Fresh Ralph tree so the stubbed run-plan cannot affect the repo checkout.
  cp -R "$RALPH_DIR"/* "$DISPATCH_WORKSPACE/.ralph/"
  chmod +x "$DISPATCH_WORKSPACE/.ralph"/*.sh 2>/dev/null || true
  chmod +x "$DISPATCH_WORKSPACE/.ralph/bash-lib"/*/*.sh 2>/dev/null || true

  cp "$STUB_RUN_PLAN" "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"
  chmod +x "$DISPATCH_WORKSPACE/.ralph/run-plan.sh"

  export GRAPH_DISPATCH_ORCHESTRATOR="$DISPATCH_WORKSPACE/.ralph/orchestrator.sh"
  # Dispatch intentionally nests orchestrator.sh under the bats (or plan) process.
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  unset RALPH_ARTIFACT_NS 2>/dev/null || true
  unset RALPH_PLAN_KEY 2>/dev/null || true
}

compile_graph_to() {
  # $1 = workspace, $2 = out graph path
  local workspace="$1"
  local out_path="$2"
  local plan_file="$workspace/graph-edges.plan.md"
  cp "$FIXTURE_PLAN" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

compile_plan_graph_to() {
  # $1 = source plan fixture, $2 = workspace, $3 = out graph path
  local src_plan="$1"
  local workspace="$2"
  local out_path="$3"
  local plan_file="$workspace/$(basename "$src_plan")"
  cp "$src_plan" "$plan_file"
  plan_pipeline_graph_json "$plan_file" > "$out_path"
}

# Return 0 when haystack (delimited successors) contains needle as a whole token.
successor_set_has() {
  local haystack="$1"
  local needle="$2"
  local IFS="$GRAPH_SUCCESSOR_DELIM"
  local part
  # shellcheck disable=SC2086
  for part in $haystack; do
    [[ "$part" == "$needle" ]] && return 0
  done
  return 1
}



















# --- Child reaper -----------------------------------------------------------

write_fake_stage_report() {
  # $1=path $2=node_id $3=exit_code $4=outcome
  local path="$1" node_id="$2" exit_code="$3" outcome="$4"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
{"schemaVersion":1,"runId":"reaper-test","stageId":"$node_id","attemptId":"${node_id}__reaper-test__1","outcome":"$outcome","exitCode":$exit_code,"startedAt":"2026-01-01T00:00:00Z","finishedAt":"2026-01-01T00:00:01Z"}
EOF
}

assert_pid_gone() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    echo "orphan still alive: $pid" >&2
    return 1
  fi
  return 0
}

# Capture reap stdout without command-substitution (subshell cannot wait on
# this shell's children, and GRAPH_REAP_* globals must stay in-shell).
reap_one_capture() {
  # Sets: REAP_RC, REAP_LINE. Uses REAP_OUT_FILE if set.
  local out="${REAP_OUT_FILE:-}"
  if [[ -z "$out" ]]; then
    out="$(mktemp "${TMPDIR:-/tmp}/ralph-reap-out.XXXXXX")"
  fi
  REAP_RC=0
  graph_schedule_reap_one >"$out" || REAP_RC=$?
  REAP_LINE="$(cat "$out")"
  if [[ -z "${REAP_OUT_FILE:-}" ]]; then
    rm -f "$out"
  fi
}






# --- Ready-set scheduling loop ---------------------------------------------

# Wrap the stub run-plan so each stage writes only its own produces and appends
# to an order log. Diamond branches sleep briefly so wall-clock overlap is
# observable without a mutual barrier (which flakes when spawn is staggered).
install_stage_aware_run_plan() {
  # $1 = workspace, $2 = order_log, $3 = marker_dir
  local workspace="$1" order_log="$2" marker_dir="$3"
  local stub_src="$workspace/.ralph/run-plan.sh"
  local stub_real="$workspace/.ralph/run-plan.stub-real.sh"
  mv "$stub_src" "$stub_real"
  cat >"$stub_src" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ORDER_LOG="$order_log"
MARKER_DIR="$marker_dir"
STAGE="\${RALPH_STAGE_ID:-unknown}"
mkdir -p "\$MARKER_DIR" "\$(dirname "\$ORDER_LOG")"
printf '%s\n' "\$STAGE" >>"\$ORDER_LOG"
# Second-resolution timestamps are enough to detect a 1s overlap window.
date +%s >"\$MARKER_DIR/\$STAGE.started_at"
: >"\$MARKER_DIR/\$STAGE.started"
case "\$STAGE" in
  source) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/input.md" ;;
  transform) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/output.md" ;;
  left) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/left.md" ;;
  right) export RUN_PLAN_STUB_WRITE_ARTIFACTS="shared/right.md" ;;
  sink) export RUN_PLAN_STUB_WRITE_ARTIFACTS="" ;;
  *) export RUN_PLAN_STUB_WRITE_ARTIFACTS="\${RUN_PLAN_STUB_WRITE_ARTIFACTS:-}" ;;
esac
if [[ "\${GRAPH_TEST_ASSERT_ISOLATION:-0}" == "1" ]]; then
  if [[ "\$STAGE" == "source" ]]; then
    printf 'producer-private\n' >"\${RALPH_PROJECT_ROOT}/private-uncommitted.txt"
  elif [[ "\$STAGE" == "sink" ]]; then
    [[ ! -e "\${RALPH_PROJECT_ROOT}/private-uncommitted.txt" ]] || exit 91
    [[ -s "\${RALPH_PROJECT_ROOT}/shared/input.md" ]] || exit 92
    printf 'isolated-with-artifact\n' >"\$MARKER_DIR/sink.exchange-ok"
  fi
fi
if [[ -n "\${GRAPH_TEST_MUTATION_PATH:-}" ]]; then
  mkdir -p "\${RALPH_PROJECT_ROOT}/\$(dirname "\$GRAPH_TEST_MUTATION_PATH")"
  printf 'node mutation\n' >"\${RALPH_PROJECT_ROOT}/\$GRAPH_TEST_MUTATION_PATH"
fi
if [[ "\${GRAPH_TEST_INTEGRATION_MUTATIONS:-0}" == "1" ]]; then
  case "\$STAGE" in
    left) mkdir -p "\${RALPH_PROJECT_ROOT}/src"; printf 'left\n' >"\${RALPH_PROJECT_ROOT}/src/left.txt" ;;
    right) mkdir -p "\${RALPH_PROJECT_ROOT}/src"; printf 'right\n' >"\${RALPH_PROJECT_ROOT}/src/right.txt" ;;
  esac
  export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
fi
if [[ "\$STAGE" == "left" || "\$STAGE" == "right" ]]; then
  if [[ "\${RUN_PLAN_STUB_OVERLAP_BARRIER:-0}" == "1" ]]; then
    # Rendezvous instead of a fixed hold. A fixed sleep races the scheduler:
    # under a parallel suite the sibling's orch startup can lag by more than
    # the hold, so both stages run concurrently yet their second-resolution
    # intervals do not overlap and the overlap assertion fails spuriously.
    # Waiting for the sibling's own started marker makes the overlap window
    # depend on real concurrency rather than on startup skew. The bounded
    # wait falls through instead of hanging, so a scheduler that genuinely
    # serializes the two stages still fails the assertion honestly.
    if [[ "\$STAGE" == "left" ]]; then PEER="right"; else PEER="left"; fi
    waited=0
    while [[ ! -e "\$MARKER_DIR/\$PEER.started" && "\$waited" -lt 300 ]]; do
      sleep 0.1
      waited=\$((waited + 1))
    done
    # Both stages are now in flight; hold past the next second boundary so the
    # recorded intervals overlap at second resolution.
    sleep 2
  else
    sleep 3
  fi
fi
date +%s >"\$MARKER_DIR/\$STAGE.finished_at"
: >"\$MARKER_DIR/\$STAGE.finished"
export RALPH_RUN_PLAN_CAPTURE_FILE="\$MARKER_DIR/capture-\$STAGE.json"
export RUN_PLAN_STUB_EXIT_CODE="\${RUN_PLAN_STUB_EXIT_CODE:-0}"
exec "$stub_real" "\$@"
EOF
  chmod +x "$stub_src"
}

assert_intervals_overlap() {
  # $1=a_start $2=a_end $3=b_start $4=b_end (unix seconds)
  local a_start="$1" a_end="$2" b_start="$3" b_end="$4"
  [ "$a_start" -lt "$b_end" ] && [ "$b_start" -lt "$a_end" ]
}

# Fail loudly when a barrier participant gave up waiting. Without this a
# timeout looks identical to the scheduler genuinely serializing the nodes,
# which is the actual bug the overlap tests exist to catch.
assert_no_barrier_timeout() {
  local marker_dir="$1" f
  for f in "$marker_dir"/*.barrier_timeout; do
    [[ -e "$f" ]] || continue
    echo "barrier timed out in $(basename "$f"): $(cat "$f")" >&2
    return 1
  done
  return 0
}

assert_intervals_disjoint() {
  # $1=a_start $2=a_end $3=b_start $4=b_end (unix seconds)
  local a_start="$1" a_end="$2" b_start="$3" b_end="$4"
  ! { [ "$a_start" -lt "$b_end" ] && [ "$b_start" -lt "$a_end" ]; }
}

# Write a fan-out .graph.json of ready (indegree-0) nodes.
# Args: out_path namespace maxParallel then one or more id:runtime[:nativeSubagents]
# Optional env WRITE_GRAPH_FAILURE_POLICY (drain|cancel, default drain).
write_ready_fanout_graph() {
  local out_path="$1" ns="$2" max_parallel="$3"
  shift 3
  WRITE_GRAPH_FAILURE_POLICY="${WRITE_GRAPH_FAILURE_POLICY:-drain}" \
  python3 - "$out_path" "$ns" "$max_parallel" "$@" <<'PY'
import json, os, sys
out_path, ns, max_parallel = sys.argv[1], sys.argv[2], int(sys.argv[3])
policy = os.environ.get("WRITE_GRAPH_FAILURE_POLICY", "drain")
nodes = []
for spec in sys.argv[4:]:
    parts = spec.split(":")
    node_id, runtime = parts[0], parts[1]
    native = parts[2] if len(parts) > 2 else "off"
    if native == "on":
        native = "off"
    nodes.append({
        "id": node_id,
        "type": "agent",
        "dependsOn": [],
        "derivedFrom": "stage",
        "stage": {
            "id": node_id,
            "runtime": runtime,
            "role": "research",
            "nativeSubagents": native,
            "_inlineTodos": [{
                "id": f"{node_id}-1",
                "content": f"work {node_id}",
                "verification": "ok",
                "status": "pending",
            }],
        },
    })
doc = {
    "schemaVersion": 2,
    "ralphVersion": "1.0.0",
    "name": ns,
    "namespace": ns,
    "maxParallel": max_parallel,
    "failurePolicy": policy,
    "nodes": nodes,
    "edges": [],
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

# Write a .graph.json from node specs and edge pairs.
# Args: out_path namespace maxParallel failurePolicy
#       --nodes id:runtime[:nativeSubagents]... --edges from:to...
write_graph_with_edges() {
  local out_path="$1" ns="$2" max_parallel="$3" policy="$4"
  shift 4
  python3 - "$out_path" "$ns" "$max_parallel" "$policy" "$@" <<'PY'
import json, sys
out_path, ns, max_parallel, policy = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
args = sys.argv[5:]
mode = None
node_specs = []
edge_specs = []
for a in args:
    if a == "--nodes":
        mode = "nodes"
        continue
    if a == "--edges":
        mode = "edges"
        continue
    if mode == "nodes":
        node_specs.append(a)
    elif mode == "edges":
        edge_specs.append(a)
nodes = []
depends = {spec.split(":")[0]: [] for spec in node_specs}
for es in edge_specs:
    frm, to = es.split(":", 1)
    depends.setdefault(to, []).append(frm)
for spec in node_specs:
    parts = spec.split(":")
    node_id, runtime = parts[0], parts[1]
    native = parts[2] if len(parts) > 2 else "off"
    if native == "on":
        native = "off"
    nodes.append({
        "id": node_id,
        "type": "agent",
        "dependsOn": depends.get(node_id, []),
        "derivedFrom": "stage",
        "stage": {
            "id": node_id,
            "runtime": runtime,
            "role": "research",
            "nativeSubagents": native,
            "_inlineTodos": [{
                "id": f"{node_id}-1",
                "content": f"work {node_id}",
                "verification": "ok",
                "status": "pending",
            }],
        },
    })
edges = []
for es in edge_specs:
    frm, to = es.split(":", 1)
    edges.append({"from": frm, "to": to, "reasons": ["declared"]})
doc = {
    "schemaVersion": 2,
    "ralphVersion": "1.0.0",
    "name": ns,
    "namespace": ns,
    "maxParallel": max_parallel,
    "failurePolicy": policy,
    "nodes": nodes,
    "edges": edges,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

# Install a lightweight single-stage orchestrator driven by per-stage behavior
# files under behavior_dir: success | fail:<ec> | awaiting | stuck | sleep:<sec>
# On SIGTERM/SIGINT writes outcome=cancelled (simulates real orch EXIT trap).
# Writes $marker_dir/$stage.pid for orphan assertions.
install_behavior_orchestrator() {
  local workspace="$1" ns="$2" run_id="$3" behavior_dir="$4" marker_dir="$5"
  mkdir -p "$behavior_dir" "$marker_dir"
  cat >"$workspace/.ralph/orchestrator.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
attempt=""
stage=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--attempt-id" ]]; then
    attempt="\$arg"
  elif [[ "\$prev" == "--single-stage" ]]; then
    stage="\$arg"
  fi
  prev="\$arg"
done
workspace="\${@: -1}"
ns="$ns"
run_id="$run_id"
behavior_dir="$behavior_dir"
marker_dir="$marker_dir"
report="\$workspace/.ralph-workspace/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "\$marker_dir"
printf '%s\n' "\$\$" >"\$marker_dir/\$stage.pid"
: >"\$marker_dir/\$stage.started"

write_report() {
  local outcome="\$1" exit_code="\$2"
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"\$run_id\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"\$outcome\",\"exitCode\":\$exit_code,\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
}

on_cancel() {
  write_report cancelled 143
  : >"\$marker_dir/\$stage.cancelled"
  exit 143
}
trap on_cancel TERM INT

behavior="success"
if [[ -f "\$behavior_dir/\$stage" ]]; then
  behavior="\$(cat "\$behavior_dir/\$stage")"
fi

case "\$behavior" in
  fail:*)
    ec="\${behavior#fail:}"
    [[ "\$ec" =~ ^[0-9]+$ ]] || ec=1
    write_report failed "\$ec"
    : >"\$marker_dir/\$stage.finished"
    exit "\$ec"
    ;;
  awaiting)
    write_report failed 3
    : >"\$marker_dir/\$stage.finished"
    exit 3
    ;;
  stuck)
    write_report failed 4
    : >"\$marker_dir/\$stage.finished"
    exit 4
    ;;
  sleep:*)
    sec="\${behavior#sleep:}"
    [[ "\$sec" =~ ^[0-9]+([.][0-9]+)?$ ]] || sec=2
    sleep "\$sec"
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
  *)
    write_report success 0
    : >"\$marker_dir/\$stage.finished"
    exit 0
    ;;
esac
EOF
  chmod +x "$workspace/.ralph/orchestrator.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$workspace/.ralph/orchestrator.sh"
}

assert_no_orphan_pids() {
  local marker_dir="$1"
  local pid_file pid
  for pid_file in "$marker_dir"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    pid="$(cat "$pid_file")"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      echo "orphan still alive: $pid ($(basename "$pid_file"))" >&2
      return 1
    fi
  done
  return 0
}

# Timed stub: every stage sleeps so overlap/serialization is observable.
install_timed_run_plan() {
  # $1=workspace $2=order_log $3=marker_dir $4=sleep_seconds
  local workspace="$1" order_log="$2" marker_dir="$3" sleep_s="${4:-1}"
  local stub_src="$workspace/.ralph/run-plan.sh"
  local stub_real="$workspace/.ralph/run-plan.stub-real.sh"
  mv "$stub_src" "$stub_real"
  cat >"$stub_src" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ORDER_LOG="$order_log"
MARKER_DIR="$marker_dir"
STAGE="\${RALPH_STAGE_ID:-unknown}"
mkdir -p "\$MARKER_DIR" "\$(dirname "\$ORDER_LOG")"
printf '%s\n' "\$STAGE" >>"\$ORDER_LOG"
printf '%s\n' "\${RALPH_ARTIFACT_NS:-}" >"\$MARKER_DIR/\$STAGE.artifact_ns"
printf '%s\n' "\${RALPH_PLAN_KEY:-}" >"\$MARKER_DIR/\$STAGE.plan_key"
printf '%s\n' "\${RALPH_GRAPH_NODE_ID:-}" >"\$MARKER_DIR/\$STAGE.graph_node_id"
date +%s >"\$MARKER_DIR/\$STAGE.started_at"
: >"\$MARKER_DIR/\$STAGE.started"
sleep "$sleep_s"
date +%s >"\$MARKER_DIR/\$STAGE.finished_at"
: >"\$MARKER_DIR/\$STAGE.finished"
export RALPH_RUN_PLAN_CAPTURE_FILE="\$MARKER_DIR/capture-\$STAGE.json"
export RUN_PLAN_STUB_EXIT_CODE="\${RUN_PLAN_STUB_EXIT_CODE:-0}"
export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
exec "$stub_real" "\$@"
EOF
  chmod +x "$stub_src"
}

# Barrier stub: each stage waits until barrier_count peers have started (or
# timeout). Guarantees wall-clock overlap despite staggered orch startup.
# Nodes that run alone later must use a different marker_dir or lower count.
install_barrier_run_plan() {
  # $1=workspace $2=order_log $3=marker_dir $4=barrier_count
  local workspace="$1" order_log="$2" marker_dir="$3" barrier_count="${4:-2}"
  local stub_src="$workspace/.ralph/run-plan.sh"
  local stub_real="$workspace/.ralph/run-plan.stub-real.sh"
  mv "$stub_src" "$stub_real"
  cat >"$stub_src" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ORDER_LOG="$order_log"
MARKER_DIR="$marker_dir"
BARRIER_COUNT="$barrier_count"
STAGE="\${RALPH_STAGE_ID:-unknown}"
mkdir -p "\$MARKER_DIR" "\$(dirname "\$ORDER_LOG")"
printf '%s\n' "\$STAGE" >>"\$ORDER_LOG"
printf '%s\n' "\${RALPH_ARTIFACT_NS:-}" >"\$MARKER_DIR/\$STAGE.artifact_ns"
printf '%s\n' "\${RALPH_PLAN_KEY:-}" >"\$MARKER_DIR/\$STAGE.plan_key"
printf '%s\n' "\${RALPH_GRAPH_NODE_ID:-}" >"\$MARKER_DIR/\$STAGE.graph_node_id"
date +%s >"\$MARKER_DIR/\$STAGE.started_at"
: >"\$MARKER_DIR/\$STAGE.started"
# Wait for every barrier participant to start. The old 20s budget (80 * 0.25)
# was too tight under run-bats' 8-way file parallelism: a node that takes
# longer than that to get scheduled would fall through the loop, run alone,
# and fail the overlap assertion as if the scheduler had serialized it. The
# budget is now 150s, and exhausting it records a marker so the failure reads
# as "barrier timed out" instead of a mysterious non-overlap.
i=0
while [[ "\$i" -lt 600 ]]; do
  # Avoid ls-glob + pipefail aborting when the directory is briefly empty.
  n=0
  for _f in "\$MARKER_DIR"/*.started; do
    [[ -e "\$_f" ]] || continue
    n=\$((n + 1))
  done
  if [[ "\$n" -ge "\$BARRIER_COUNT" ]]; then
    break
  fi
  sleep 0.25
  i=\$((i + 1))
done
if [[ "\$i" -ge 600 ]]; then
  printf 'barrier timeout: saw %s of %s starters\\n' "\$n" "\$BARRIER_COUNT" \
    >"\$MARKER_DIR/\$STAGE.barrier_timeout"
fi
# Hold for a full second so started_at < finished_at under second-resolution clocks.
sleep 1
date +%s >"\$MARKER_DIR/\$STAGE.finished_at"
: >"\$MARKER_DIR/\$STAGE.finished"
export RALPH_RUN_PLAN_CAPTURE_FILE="\$MARKER_DIR/capture-\$STAGE.json"
export RUN_PLAN_STUB_EXIT_CODE="\${RUN_PLAN_STUB_EXIT_CODE:-0}"
export RUN_PLAN_STUB_WRITE_ARTIFACTS=""
exec "$stub_real" "\$@"
EOF
  chmod +x "$stub_src"
}





# --- Concurrency caps and per-node isolation -------------------------------










# --- Failure and cancellation semantics -------------------------------------





# Exit 4 used to be an ordinary drain failure. The operator-permission work in
# the production-hardening continuation made it a permission pause instead: the
# node parks in awaiting-operator, keeps its retry grant, and the run reports 3
# (incomplete, waiting on a human) rather than a failure exit. Independent
# siblings still drain and the paused node's descendants are still blocked.
# See graph-operator-schedule.bats for the request/decision contract itself.

# --- consensus-join scheduling regression ---------------------------------
# Regression test for the edge-alias bug: plan_pipeline_graph_json previously
# emitted edges referencing the bare consensus root id (e.g. "review") which
# is not a real node id after consensus expansion. graph_schedule_load_index
# would fail with "unknown node: review". The fix rewrites:
#   from=consensus_root  ->  from=consensus_root:barrier
#   to=consensus_root    ->  fan-out to to=consensus_root:<voter_id>
# This test compiles the join fixture (consensus voters + downstream join node)
# and drives the full ready-set loop to completion, proving the adjudicate node
# can be scheduled after the barrier.


# --- voter->barrier gating regression --------------------------------------
# Regression test for the missing voter->barrier edge bug: plan_pipeline_graph_json
# previously never emitted voter->barrier edges into the top-level edges[] array.
# The scheduler computes indegree strictly from edges[], so the barrier's indegree
# was 0 and it was dispatched immediately (concurrently with voters).
#
# This test proves the fix by:
# 1. Asserting voter->barrier edges are present in the compiled graph.
# 2. Running the full scheduler ready-set loop with voters that sleep long enough
#    to create a real race window.
# 3. Asserting the barrier's started_at timestamp is >= all voters' finished_at
#    timestamps, proving it was not dispatched before voters completed.



# ---------------------------------------------------------------------------
# Canonical attempt-upsert writer
# ---------------------------------------------------------------------------
