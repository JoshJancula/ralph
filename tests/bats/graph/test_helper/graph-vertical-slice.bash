#!/usr/bin/env bash
# Graph vertical-slice harness helper.
#
# Exercises the public graph CLI, the real scheduler, the real
# orchestrator.sh, the real run-plan.sh, and one fake runtime executable
# through one bounded, real two-node graph run. Nothing here fakes or
# short-circuits orchestrator.sh or run-plan.sh for the "success" scenario;
# the "bypass" scenario exists only to prove the crossing checks below
# would catch it if that ever happened by accident.
#
# Public interface:
#   graph_vertical_slice_setup <scenario>
#     Builds fixtures for one scenario. Supported scenarios:
#       success -- real orchestrator.sh and real run-plan.sh dispatch a fake
#                  cursor-agent CLI for both nodes.
#       bypass  -- dispatch is redirected around orchestrator.sh/run-plan.sh
#                  (GRAPH_DISPATCH_ORCHESTRATOR points at a stub), so the
#                  crossing checks can be proven to correctly fail.
#   graph_vertical_slice_run
#     Invokes `graph-run.sh run <plan> --yes` with a bounded 90-second
#     timeout from
#     inside the fixture workspace. Sets GVS_STATUS and GVS_OUTPUT.
#   graph_vertical_slice_run_dir
#     Prints the run directory once graph_vertical_slice_run has completed.
#   graph_vertical_slice_runner_log / agent_log / usage_json <node-id>
#     Print the exact runner/agent/usage log paths for one node's last
#     attempt.
#   graph_vertical_slice_outcome_json <node-id>
#     Prints the exact StageOutcomeReport path for one node's last attempt.
#   graph_vertical_slice_node_ledger <node-id>
#     Prints the exact node ledger path (nodes/<id>.json).
#   graph_vertical_slice_events_jsonl
#     Prints the exact run-root event journal path.
#   graph_vertical_slice_crossed_all_layers
#     Returns 0 only when every real-layer artifact (orchestrator log
#     banner, run-plan usage.json, exactly two real fake-runtime
#     invocations) is present and correct for both nodes. Returns 1 and
#     prints the first missing check to stderr otherwise.
#   graph_vertical_slice_cleanup
#     Kills any leftover child processes rooted at the fixture workspace,
#     removes runtime-overlay temp files, and deletes the scenario's temp
#     directory. Call from teardown().

GVS_NODES=(first second)
GVS_NAMESPACE="vslice-test"

# The slice starts a real scheduler tree. A parent-only timeout leaves that
# tree alive and makes Bats appear hung, so run it in its own session and reap
# the entire process group on the deadline.
source "$REPO_ROOT/bundle/.ralph/bash-lib/ralph-process-teardown.sh"

# graph_vertical_slice_setup <scenario>
graph_vertical_slice_setup() {
  local scenario="${1:-success}"
  case "$scenario" in
    success | bypass) ;;
    *)
      echo "Error: graph_vertical_slice_setup unknown scenario '$scenario'" >&2
      return 1
      ;;
  esac
  GVS_SCENARIO="$scenario"

  GVS_TMPDIR="$(mktemp -d)"
  GVS_WORKSPACE="$GVS_TMPDIR/workspace"
  GVS_BIN_DIR="$GVS_TMPDIR/bin"
  GVS_RECORD="$GVS_TMPDIR/cursor-agent.record"
  mkdir -p "$GVS_WORKSPACE/.ralph" "$GVS_WORKSPACE/src" "$GVS_BIN_DIR"
  cp -R "$REPO_ROOT/bundle/.ralph/." "$GVS_WORKSPACE/.ralph/"

  GVS_PLAN="$GVS_WORKSPACE/PLAN1.graph.plan.md"
  cat >"$GVS_PLAN" <<PLAN
---
name: ${GVS_NAMESPACE}
namespace: ${GVS_NAMESPACE}
execution: graph
pipeline:
  stages:
    - id: first
      runtime: cursor
      workspaceMode: shared
    - id: second
      dependsOn: [first]
      runtime: cursor
      workspaceMode: shared
todos:
  - id: first-1
    stage: first
    content: do the first thing
    status: pending
  - id: second-1
    stage: second
    content: do the second thing
    status: pending
---
PLAN

  # Prebuilt agent config. The validator (bash-lib/agent-config/validate.sh)
  # greps for each required key at the start of a line, so this must stay
  # pretty-printed one-key-per-line -- compact single-line JSON fails
  # validation even though it is syntactically valid JSON.
  mkdir -p "$GVS_WORKSPACE/.cursor/agents/alpha"
  cat >"$GVS_WORKSPACE/.cursor/agents/alpha/config.json" <<'CONFIG'
{
  "name": "alpha",
  "model": "auto",
  "description": "vertical slice test agent",
  "rules": [],
  "skills": []
}
CONFIG

  # Fake runtime executable (G20): prints deterministic native-format
  # output and the completion sentinel, records received argv, never
  # writes a StageOutcomeReport/ledger/changeset/operator record itself --
  # those are written by the real run-plan.sh/orchestrator.sh code this
  # harness proves is actually exercised.
  cat >"$GVS_BIN_DIR/cursor-agent" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" >>"$GVS_RECORD"
case "\$1" in
  --help)
    printf '%s\n' "Usage: cursor-agent" "  --permission-prompt-tool <name>"
    exit 0
    ;;
esac
printf 'REAL_INVOCATION\n' >>"$GVS_RECORD"
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: SKIPPED"
exit 0
EOF
  chmod +x "$GVS_BIN_DIR/cursor-agent"

  if [[ "$scenario" == "bypass" ]]; then
    # Redirect dispatch around orchestrator.sh (and therefore run-plan.sh
    # and the fake CLI above) entirely. This scenario exists only to prove
    # graph_vertical_slice_crossed_all_layers correctly fails when the real
    # layers are not exercised.
    cat >"$GVS_TMPDIR/bypass-orchestrator-stub.sh" <<EOF
#!/usr/bin/env bash
echo "bypass stub: orchestrator.sh and run-plan.sh were never invoked" >&2
exit 3
EOF
    chmod +x "$GVS_TMPDIR/bypass-orchestrator-stub.sh"
    GVS_DISPATCH_ORCHESTRATOR_OVERRIDE="$GVS_TMPDIR/bypass-orchestrator-stub.sh"
  else
    GVS_DISPATCH_ORCHESTRATOR_OVERRIDE=""
  fi
}

# graph_vertical_slice_run
# Invokes the public CLI with a bounded timeout. Never reads stdin (--yes).
graph_vertical_slice_run() {
  local prior_path="$PATH"
  # This deadline exists to stop a wedged run from hanging the suite forever,
  # not to assert how fast a two-node graph run is. 90s left no headroom: the
  # run measures ~82s on an idle host, so any parallel load pushed it past the
  # deadline and the reap turned a healthy run into a failure that read like a
  # product bug. A wedged run is still caught -- it never finishes at all.
  local timeout_seconds="${GVS_TIMEOUT_SECONDS:-300}"
  local run_pid elapsed=0 run_rc=0
  PATH="$GVS_BIN_DIR:$PATH"
  # The bypass scenario is expected to exit nonzero; wrap in `if` so this
  # helper's own `set -e` (inherited from bats) never hard-aborts before
  # GVS_STATUS/GVS_OUTPUT are captured below.
  (
    export PATH="$GVS_BIN_DIR:$PATH"
    # Real end-to-end graph runs must not inherit this process's own
    # exported plan/agent/session state (this harness may itself run
    # nested inside a managed Ralph session).
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_OPTIMIZATION_MODE \
      RALPH_MCP_TOOLS_ENABLED RALPH_TOOL_ACCESS_FLAG_SET \
      RALPH_PLAN_INVOCATION_TIMEOUT_RAW RALPH_PLAN_WORKSPACE_ROOT \
      RALPH_PROXY_SHELL_COMPACT RALPH_PROJECT_ROOT RALPH_AGENT_WORKSPACE \
      RALPH_ARTIFACT_NS RALPH_PLAN_KEY RALPH_MODE RALPH_BASH_COMPACT \
      RALPH_COMPACT_GENERIC_THRESHOLD_BYTES RALPH_COMPACT_STDOUT \
      RALPH_COMPACT_STDERR RALPH_COMPACTORS_LIB_DIR \
      RALPH_MCP_PROXY_SERVER_SCRIPT RALPH_RUNTIME_MCP_RESOLVE_PATH \
      RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON RALPH_RUN_PLAN_ACTIVE \
      RALPH_CURRENT_PLAN_PATH RALPH_CURRENT_TODO_LINE \
      RALPH_CURRENT_TODO_ORDINAL RALPH_CURRENT_TODO_ID \
      RALPH_CURRENT_TODO_HASH RALPH_MCP_PREFLIGHT_PASSED \
      RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE \
      RALPH_PLAN_INVOCATION_CLI_PID_FILE RALPH_PLAN_INVOCATION_CLI_START_FILE \
      RALPH_SESSION_DIR RALPH_RUN_PLAN_RESET_COMMAND_USED \
      RALPH_PLAN_SESSION_HOME RALPH_PLAN_CAPTURE_USAGE RALPH_GRAPH_STATE_ROOT
    # This harness may run nested inside an active managed Ralph session;
    # allow the intentional nested run rather than refusing it.
    export RALPH_ALLOW_NESTED_RUNS=1
    # run-plan.sh refuses --non-interactive without a model. This used to be
    # supplied indirectly by the authored `role:` selecting a prebuilt agent
    # config; `role` was removed, so the model is now provided by the
    # environment. It is deliberately NOT declared on the stages: graph
    # preflight's model-auth check validates a declared model against what the
    # runtime CLI can list, and the fake cursor-agent here implements only
    # --help, so any declared model is refused before the run can start.
    export CURSOR_PLAN_MODEL=gpt-5
    export RALPH_PLAN_CLI_RESUME=0
    export RALPH_PLAN_AGENT_POLL_INTERVAL=0.1
    if [[ -n "$GVS_DISPATCH_ORCHESTRATOR_OVERRIDE" ]]; then
      export GRAPH_DISPATCH_ORCHESTRATOR="$GVS_DISPATCH_ORCHESTRATOR_OVERRIDE"
    fi
    cd "$GVS_WORKSPACE"
    exec python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
      bash "$GVS_WORKSPACE/.ralph/graph-run.sh" run "$GVS_PLAN" --yes </dev/null
  ) >"$GVS_TMPDIR/graph-run.log" 2>&1 &
  run_pid=$!
  while kill -0 "$run_pid" 2>/dev/null && (( elapsed < timeout_seconds * 10 )); do
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  if kill -0 "$run_pid" 2>/dev/null; then
    printf 'graph vertical slice: deadline=%ss; reaping process group %s\n' \
      "$timeout_seconds" "$run_pid" >>"$GVS_TMPDIR/graph-run.log"
    ralph_kill_process_group "$run_pid" 2
    wait "$run_pid" 2>/dev/null || true
    GVS_STATUS=124
  else
    if wait "$run_pid"; then
      run_rc=0
    else
      run_rc=$?
    fi
    GVS_STATUS="$run_rc"
  fi
  GVS_OUTPUT="$(cat "$GVS_TMPDIR/graph-run.log")"
  PATH="$prior_path"
  return 0
}

# graph_vertical_slice_run_dir
graph_vertical_slice_run_dir() {
  find "$GVS_WORKSPACE/.ralph-workspace/graph-runs/$GVS_NAMESPACE" \
    -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1
}

_gvs_last_attempt_id() {
  local node="$1" run_dir
  run_dir="$(graph_vertical_slice_run_dir)"
  [[ -n "$run_dir" ]] || return 1
  jq -r '.lastAttemptId // empty' "$run_dir/nodes/${node}.json" 2>/dev/null
}

# graph_vertical_slice_runner_log <node-id>
graph_vertical_slice_runner_log() {
  local node="$1" run_dir attempt
  run_dir="$(graph_vertical_slice_run_dir)" || return 1
  attempt="$(_gvs_last_attempt_id "$node")" || return 1
  [[ -n "$attempt" ]] || return 1
  printf '%s\n' "$run_dir/logs/nodes/$node/$attempt/runner.log"
}

# graph_vertical_slice_agent_log <node-id>
graph_vertical_slice_agent_log() {
  local node="$1" run_dir attempt
  run_dir="$(graph_vertical_slice_run_dir)" || return 1
  attempt="$(_gvs_last_attempt_id "$node")" || return 1
  [[ -n "$attempt" ]] || return 1
  printf '%s\n' "$run_dir/logs/nodes/$node/$attempt/agent.log"
}

# graph_vertical_slice_usage_json <node-id>
graph_vertical_slice_usage_json() {
  local node="$1" run_dir attempt
  run_dir="$(graph_vertical_slice_run_dir)" || return 1
  attempt="$(_gvs_last_attempt_id "$node")" || return 1
  [[ -n "$attempt" ]] || return 1
  printf '%s\n' "$run_dir/logs/nodes/$node/$attempt/usage.json"
}

# graph_vertical_slice_outcome_json <node-id>
# The StageOutcomeReport run-plan.sh's orchestrator wrapper writes.
graph_vertical_slice_outcome_json() {
  local node="$1" attempt
  attempt="$(_gvs_last_attempt_id "$node")" || return 1
  [[ -n "$attempt" ]] || return 1
  printf '%s\n' "$GVS_WORKSPACE/.ralph-workspace/artifacts/$GVS_NAMESPACE/stage-outcomes/$attempt.json"
}

# graph_vertical_slice_node_ledger <node-id>
graph_vertical_slice_node_ledger() {
  local node="$1" run_dir
  run_dir="$(graph_vertical_slice_run_dir)" || return 1
  printf '%s\n' "$run_dir/nodes/${node}.json"
}

# graph_vertical_slice_events_jsonl
graph_vertical_slice_events_jsonl() {
  local run_dir
  run_dir="$(graph_vertical_slice_run_dir)" || return 1
  printf '%s\n' "$run_dir/events.jsonl"
}

# graph_vertical_slice_orchestrator_log
# The real orchestrator.sh's own append-only log (one per namespace).
graph_vertical_slice_orchestrator_log() {
  printf '%s\n' "$GVS_WORKSPACE/.ralph-workspace/logs/orchestrator-${GVS_NAMESPACE}.orch.log"
}

# graph_vertical_slice_crossed_all_layers
#
# Returns 0 only when every real-layer artifact is present and correct for
# both nodes: the node ledger reports succeeded, the real orchestrator.sh
# banner line is present in its own log, run-plan.sh's usage.json exists,
# the StageOutcomeReport exists with outcome=succeeded, and the fake
# runtime recorded exactly two real (non --help) invocations. A "bypass"
# scenario is expected to fail one or more of these.
graph_vertical_slice_crossed_all_layers() {
  local node run_dir orch_log real_invocations

  run_dir="$(graph_vertical_slice_run_dir)"
  if [[ -z "$run_dir" || ! -d "$run_dir" ]]; then
    echo "crossing check failed: no run directory was created" >&2
    return 1
  fi

  for node in "${GVS_NODES[@]}"; do
    local ledger status attempt outcome_file runner_log usage_json
    ledger="$(graph_vertical_slice_node_ledger "$node")"
    if [[ ! -f "$ledger" ]]; then
      echo "crossing check failed: missing node ledger for '$node': $ledger" >&2
      return 1
    fi
    status="$(jq -r '.status // empty' "$ledger" 2>/dev/null)"
    if [[ "$status" != "succeeded" ]]; then
      echo "crossing check failed: node '$node' ledger status is '$status', not succeeded" >&2
      return 1
    fi

    runner_log="$(graph_vertical_slice_runner_log "$node")"
    if [[ ! -s "$runner_log" ]] || ! grep -q "Invoking: .ralph/run-plan.sh" "$runner_log"; then
      echo "crossing check failed: node '$node' runner.log missing the real orchestrator's run-plan.sh invocation banner: $runner_log" >&2
      return 1
    fi

    usage_json="$(graph_vertical_slice_usage_json "$node")"
    if [[ ! -s "$usage_json" ]]; then
      echo "crossing check failed: node '$node' is missing run-plan.sh's usage.json: $usage_json" >&2
      return 1
    fi

    outcome_file="$(graph_vertical_slice_outcome_json "$node")"
    if [[ ! -s "$outcome_file" ]]; then
      echo "crossing check failed: node '$node' is missing its StageOutcomeReport: $outcome_file" >&2
      return 1
    fi
    outcome="$(jq -r '.outcome // empty' "$outcome_file" 2>/dev/null)"
    if [[ "$outcome" != "success" ]]; then
      echo "crossing check failed: node '$node' StageOutcomeReport outcome is '$outcome', not success" >&2
      return 1
    fi
  done

  orch_log="$(graph_vertical_slice_orchestrator_log)"
  if [[ ! -s "$orch_log" ]] || [[ "$(grep -c "^\[" "$orch_log" 2>/dev/null || echo 0)" -eq 0 ]]; then
    echo "crossing check failed: real orchestrator.sh log is missing or empty: $orch_log" >&2
    return 1
  fi

  if [[ ! -s "$GVS_RECORD" ]]; then
    echo "crossing check failed: the fake runtime was never invoked: $GVS_RECORD" >&2
    return 1
  fi
  real_invocations="$(grep -c '^REAL_INVOCATION$' "$GVS_RECORD" 2>/dev/null || echo 0)"
  if [[ "$real_invocations" -ne 2 ]]; then
    echo "crossing check failed: expected exactly 2 real fake-runtime invocations, got $real_invocations" >&2
    return 1
  fi

  local events_file
  events_file="$(graph_vertical_slice_events_jsonl)"
  if [[ ! -s "$events_file" ]]; then
    echo "crossing check failed: run-root event journal is missing or empty: $events_file" >&2
    return 1
  fi

  return 0
}

# graph_vertical_slice_cleanup
# Kills leftover processes rooted at the fixture workspace, clears runtime
# overlays, and removes the scenario's temp directory. Call from teardown().
graph_vertical_slice_cleanup() {
  [[ -n "${GVS_WORKSPACE:-}" ]] || return 0

  if command -v pkill >/dev/null 2>&1; then
    pkill -f "$GVS_WORKSPACE" 2>/dev/null || true
  fi

  # Runtime-overlay MCP config/native-hook temp files are written under the
  # node workspace itself for workspaceMode=shared, so removing the fixture
  # tree below also removes them; no separate overlay path exists outside
  # the tree for this harness's shared-mode nodes.

  chmod -R u+w "$GVS_TMPDIR" 2>/dev/null || true
  rm -rf "$GVS_TMPDIR" 2>/dev/null || true

  unset GVS_SCENARIO GVS_TMPDIR GVS_WORKSPACE GVS_BIN_DIR GVS_RECORD GVS_PLAN
  unset GVS_DISPATCH_ORCHESTRATOR_OVERRIDE GVS_STATUS GVS_OUTPUT
}
