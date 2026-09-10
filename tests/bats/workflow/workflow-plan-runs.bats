#!/usr/bin/env bats
# Cross-runner workflow acceptance: Sequential (orchestrator) and Dependency (graph)
# engines with stub runtimes. Proves planner artifact -> immutable source ->
# control copy -> two fresh TODO invocations -> progress -> review; Dependency
# continues through approval, QA planner/source/control, handoff, terminal success.
#
# Cost justification (acceptance tier): one bounded real workflow journey per
# mode exercises start/resume, planFrom bind, and engine adapters together.
# RALPH_WAIT_SCALE=0; no network or real model.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/ralph-process-teardown.sh"

WPR_NS="wpr-accept"
WPR_TASK="Workflow plan-runs acceptance fixture"

setup_file() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  WPR_TMP="$(mktemp -d)"
  WPR_HOME="$WPR_TMP/home"
  WPR_WS="$WPR_TMP/workspace"
  WPR_BIN="$WPR_TMP/bin"
  WPR_SHIM="$WPR_TMP/ralph"
  WPR_RECORD="$WPR_TMP/cursor-agent.record"
  WPR_RUN_LOG="$WPR_TMP/run.log"

  mkdir -p \
    "$WPR_HOME/bundle/.ralph" \
    "$WPR_WS/.ralph-workspace/workflows" \
    "$WPR_WS/bundle/.ralph/schemas" \
    "$WPR_BIN"
  cp -R "$REPO_ROOT/bundle/.ralph/." "$WPR_HOME/bundle/.ralph/"
  cp -R "$REPO_ROOT/bundle/.ralph/." "$WPR_WS/.ralph/"
  cp "$REPO_ROOT/bundle/.ralph/schemas/planner-output.schema.json" \
    "$WPR_WS/bundle/.ralph/schemas/"
  cp "$REPO_ROOT/bundle/.ralph/schemas/evaluator-verdict.schema.json" \
    "$WPR_WS/bundle/.ralph/schemas/"
  cp "$REPO_ROOT/bundle/.ralph/schemas/workflow-plan-manifest.schema.json" \
    "$WPR_WS/bundle/.ralph/schemas/" 2>/dev/null || true

  awk '/^  cat > "\$tmp" <<.SHIM.$/ { flag = 1; next } /^SHIM$/ { flag = 0 } flag { print }' \
    "$REPO_ROOT/install.sh" >"$WPR_SHIM"
  chmod +x "$WPR_SHIM"

  wpr_write_cursor_stub
  wpr_write_seq_workflow "$WPR_WS/.ralph-workspace/workflows/wpr-seq.workflow.md"
  wpr_write_dep_workflow "$WPR_WS/.ralph-workspace/workflows/wpr-dep.workflow.md"
  printf '# demo\n' >"$WPR_WS/README.md"
  : >"$WPR_RECORD"
  : >"$WPR_RUN_LOG"
}

teardown() {
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "$WPR_TMP" 2>/dev/null || true
  fi
  # Snapshot bases are captured read-only; make the tree writable before rm.
  [[ -n "${WPR_TMP:-}" ]] && chmod -R u+w "$WPR_TMP" 2>/dev/null
  [[ -n "${WPR_TMP:-}" ]] && rm -rf "$WPR_TMP"
  return 0
}

wpr_write_planner_json() {
  local dest="$1"
  mkdir -p "$(dirname -- "$dest")"
  cat >"$dest" <<'JSON'
{
  "schemaVersion": 2,
  "name": "wpr-generated",
  "overview": "Two-TODO generated implementation plan",
  "rationale": "Minimal cross-runner acceptance fixture.",
  "todos": [
    {
      "id": "implement-core",
      "content": "Update owned files for the demo change.",
      "verification": "test -f README.md",
      "status": "pending"
    },
    {
      "id": "verify-tests",
      "content": "Run the narrow unit tests.",
      "verification": "true",
      "status": "pending"
    }
  ]
}
JSON
}

wpr_write_qa_planner_json() {
  local dest="$1"
  mkdir -p "$(dirname -- "$dest")"
  cat >"$dest" <<'JSON'
{
  "schemaVersion": 2,
  "name": "wpr-qa-generated",
  "overview": "One-TODO QA plan",
  "rationale": "Independent QA handoff fixture.",
  "todos": [
    {
      "id": "qa-check",
      "content": "Verify acceptance criteria on the integrated tree.",
      "verification": "test -f README.md",
      "status": "pending"
    }
  ]
}
JSON
}

wpr_write_cursor_stub() {
  cat >"$WPR_BIN/cursor-agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"WPR_RECORD_PLACEHOLDER"
case "${1:-}" in
  --help)
    printf '%s\n' "Usage: cursor-agent" "  --permission-prompt-tool <name>"
    exit 0
    ;;
esac
printf 'REAL_INVOCATION\n' >>"WPR_RECORD_PLACEHOLDER"
ns="${RALPH_ARTIFACT_NS:-WPR_NS_PLACEHOLDER}"
root="${RALPH_AGENT_WORKSPACE:-${RALPH_PROJECT_ROOT:-$PWD}}"
stage="${RALPH_STAGE_ID:-}"
token_dir="$root/.ralph-workspace/artifacts/{{ARTIFACT_NS}}"
mkdir -p "$root/.ralph-workspace/artifacts/$ns" "$token_dir"
wpr_stub_publish() {
  local name="$1"
  cp -f "$root/.ralph-workspace/artifacts/$ns/$name" "$token_dir/$name"
}
if [[ "${RALPH_PLANNER_STAGE:-0}" == "1" || "$stage" == "plan-implementation" || "$stage" == "plan-qa" ]]; then
  if [[ "$stage" == "plan-qa" ]]; then
    cat >"$root/.ralph-workspace/artifacts/$ns/qa-plan.json" <<'JSON'
{
  "schemaVersion": 2,
  "name": "wpr-qa-generated",
  "overview": "One-TODO QA plan",
  "rationale": "Independent QA handoff fixture.",
  "todos": [
    {
      "id": "qa-check",
      "content": "Verify acceptance criteria on the integrated tree.",
      "verification": "test -f README.md",
      "status": "pending"
    }
  ]
}
JSON
  wpr_stub_publish qa-plan.json
  else
  cat >"$root/.ralph-workspace/artifacts/$ns/impl-plan.json" <<'JSON'
{
  "schemaVersion": 2,
  "name": "wpr-generated",
  "overview": "Two-TODO generated implementation plan",
  "rationale": "Minimal cross-runner acceptance fixture.",
  "todos": [
    {
      "id": "implement-core",
      "content": "Update owned files for the demo change.",
      "verification": "test -f README.md",
      "status": "pending"
    },
    {
      "id": "verify-tests",
      "content": "Run the narrow unit tests.",
      "verification": "true",
      "status": "pending"
    }
  ]
}
JSON
  wpr_stub_publish impl-plan.json
  fi
fi
if [[ "$stage" == "plan-qa" && ! -f "$root/.ralph-workspace/artifacts/$ns/qa-plan.json" ]]; then
  cat >"$root/.ralph-workspace/artifacts/$ns/qa-plan.json" <<'JSON'
{
  "schemaVersion": 2,
  "name": "wpr-qa-generated",
  "overview": "One-TODO QA plan",
  "rationale": "Independent QA handoff fixture.",
  "todos": [
    {
      "id": "qa-check",
      "content": "Verify acceptance criteria on the integrated tree.",
      "verification": "test -f README.md",
      "status": "pending"
    }
  ]
}
JSON
  wpr_stub_publish qa-plan.json
fi
case "$stage" in
  review)
    printf '%s' '{"status":"approved","feedback":[]}' >"$root/.ralph-workspace/artifacts/$ns/review-verdict.json"
    wpr_stub_publish review-verdict.json
    ;;
  implement)
    printf 'handoff ok\n' >"$root/.ralph-workspace/artifacts/$ns/implementation-handoff.md"
    wpr_stub_publish implementation-handoff.md
    ;;
  qa)
    printf 'qa ok\n' >"$root/.ralph-workspace/artifacts/$ns/qa-handoff.md"
    wpr_stub_publish qa-handoff.md
    ;;
esac
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: SKIPPED"
exit 0
EOF
  sed -i '' "s|WPR_RECORD_PLACEHOLDER|$WPR_RECORD|g" "$WPR_BIN/cursor-agent" 2>/dev/null || \
    sed -i "s|WPR_RECORD_PLACEHOLDER|$WPR_RECORD|g" "$WPR_BIN/cursor-agent"
  sed -i '' "s|WPR_NS_PLACEHOLDER|$WPR_NS|g" "$WPR_BIN/cursor-agent" 2>/dev/null || \
    sed -i "s|WPR_NS_PLACEHOLDER|$WPR_NS|g" "$WPR_BIN/cursor-agent"
  chmod +x "$WPR_BIN/cursor-agent"
}

wpr_write_seq_workflow() {
  cat >"$1" <<'EOF'
---
name: wpr-seq
namespace: wpr-accept
overview: Sequential plan-runs acceptance
kind: workflow
mode: sequential
pipeline:
  stages:
    - id: plan-implementation
      instructions: |
        Plan {{TASK}}.
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: approve-plan
      type: approval
      question: Approve the plan?
      changesTarget: plan-implementation
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: implement
      instructions: |
        Implement {{TASK}}.
      dependsOn:
        - approve-plan
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
      planFrom: plan-implementation
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: review
      instructions: |
        Review {{TASK}}.
      dependsOn:
        - implement
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      loopBackTo: implement
      maxIterations: 1
      loopCheck:
        path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
        schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
      onExhausted: fail
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan {{TASK}}.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json exists.
    status: pending
  - id: review-work
    stage: review
    content: |
      Review {{TASK}}.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json exists.
    status: pending
---
EOF
}

wpr_write_dep_workflow() {
  cat >"$1" <<'EOF'
---
name: wpr-dep
namespace: wpr-accept
overview: Dependency plan-runs acceptance
kind: workflow
mode: dependency
pipeline:
  maxParallel: 1
  maxReworkIterations: 1
  publishMode: on-verified
  stages:
    - id: plan-implementation
      instructions: |
        Plan {{TASK}}.
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: approve-plan
      type: approval
      question: Approve the plan?
      changesTarget: plan-implementation
      dependsOn:
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: implement
      instructions: |
        Implement {{TASK}}.
      dependsOn:
        - approve-plan
        - plan-implementation
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json
          required: true
      planFrom: plan-implementation
      workspaceMode: snapshot
      writeScopes: ["**"]
      agentGitAccess: off
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
    - id: review
      instructions: |
        Review {{TASK}}.
      dependsOn:
        - implement
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
      workspaceMode: snapshot
      writeScopes: ["**"]
      agentGitAccess: off
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/{{STAGE_ID}}-verdict.json
          required: true
          schema: bundle/.ralph/schemas/evaluator-verdict.schema.json
    - id: integrate
      type: integrate
      workspaceMode: snapshot
      dependsOn:
        - implement
        - review
    - id: plan-qa
      instructions: |
        Plan QA for {{TASK}}.
      dependsOn:
        - integrate
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/implementation-handoff.md
          required: true
      planner:
        outputMode: plan-file
        maxTodos: 40
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-plan.json
          required: true
          schema: bundle/.ralph/schemas/planner-output.schema.json
    - id: qa
      instructions: |
        Execute QA for {{TASK}}.
      dependsOn:
        - plan-qa
      requires:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-plan.json
          required: true
      planFrom: plan-qa
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/qa-handoff.md
          required: true
todos:
  - id: plan-work
    stage: plan-implementation
    content: |
      Plan {{TASK}}.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/impl-plan.json exists.
    status: pending
  - id: review-work
    stage: review
    content: |
      Review {{TASK}}.
    verification: Confirm .ralph-workspace/artifacts/{{ARTIFACT_NS}}/review-verdict.json exists.
    status: pending
---
EOF
}

wpr_env() {
  env \
    RALPH_HOME="$WPR_HOME" \
    RALPH_PROJECT_ROOT="$WPR_WS" \
    RALPH_PLAN_WORKSPACE_ROOT="$WPR_WS/.ralph-workspace" \
    RALPH_AGENT_WORKSPACE="$WPR_WS" \
    RALPH_ALLOW_NESTED_RUNS=1 \
    RALPH_WAIT_SCALE=0 \
    RALPH_PLAN_CLI_RESUME=0 \
    RALPH_PLAN_AGENT_POLL_INTERVAL=0.1 \
    RALPH_MODE=no \
    RALPH_ARTIFACT_SCHEMA_VALIDATION=0 \
    RALPH_ARTIFACT_NS="$WPR_NS" \
    CURSOR_PLAN_MODEL="wpr-stub-model" \
    GRAPH_HEARTBEAT_TTL_SECONDS=0 \
    PATH="$WPR_BIN:${PATH}" \
    "$@"
}

wpr_only_run_dir() {
  find "$WPR_WS/.ralph-workspace/workflow-runs" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1 || true
}

wpr_wait_graph_quiescent() {
  local run_id="$1"
  local state_root="$WPR_WS/.ralph-workspace" ns owner_class=""
  # shellcheck source=/dev/null
  source "$WPR_HOME/bundle/.ralph/bash-lib/graph/graph-heartbeat.sh"
  ns="$(jq -r '.engine.namespace // empty' "$state_root/workflow-runs/$run_id/run.json")"
  [[ -n "$ns" ]] || return 1
  # Wall-clock deadline, not an iteration count. This previously span up to
  # 200000 times with no sleep; when the condition did not clear promptly the
  # loop turned a ~5 minute test into a ~59 minute one (measured: 290983ms vs
  # 3539582ms across two runs of the same tier) while forking hard enough to
  # load the host. agents/rules/test-design.md: wait on the real condition
  # against a deadline.
  local deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    owner_class="$(graph_heartbeat_classify_run "$state_root" "$ns" "$run_id" 2>/dev/null || echo none)"
    [[ "$owner_class" != "healthy" ]] && return 0
    sleep 0.1
  done
  return 1
}

wpr_clear_graph_owner() {
  local run_id="$1" graph_dir outer_state="${2:-waiting}"
  graph_dir="$(
    jq -r '.engine.statePath // empty' "$WPR_WS/.ralph-workspace/workflow-runs/$run_id/run.json"
  )"
  if [[ -n "$graph_dir" && -f "$graph_dir/run.json" ]]; then
    jq '.supervisorPid = null
      | .ownerProcessStartId = null
      | .ownerHostname = null
      | .heartbeatAt = null' \
      "$graph_dir/run.json" >"$graph_dir/run.json.tmp" \
      && mv "$graph_dir/run.json.tmp" "$graph_dir/run.json"
  fi
  # shellcheck source=/dev/null
  source "$WPR_HOME/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
  export WORKFLOW_STATE_SKIP_FSYNC=1
  workflow_state_clear_owner_and_set_state "$WPR_WS/.ralph-workspace" "$run_id" "$outer_state"
}

wpr_sync_dependency_run() {
  local run_id="$1"
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "$WPR_TMP" 2>/dev/null || true
  fi
  wpr_wait_graph_quiescent "$run_id" || true
  wpr_clear_graph_owner "$run_id"
}

wpr_dep_resume() {
  local run_id="$1" rc=0
  export RALPH_WORKFLOW_RUN_ID="$run_id"
  export RALPH_WORKFLOW_REGISTRY_RUN="$WPR_WS/.ralph-workspace/workflow-runs/$run_id"
  wpr_sync_dependency_run "$run_id"
  wpr_run_cli resume "$run_id" --yes || rc=$?
  return "$rc"
}

wpr_dep_wait_for_approval() {
  local run_id="$1" req_dir
  req_dir="$WPR_WS/.ralph-workspace/workflow-runs/$run_id/actions/requests"
  # Wall-clock deadline, not an iteration count. Each iteration forks `find`
  # and `grep`, so the old 200000-iteration bound was both unbounded in time
  # and a process-spawn storm.
  local deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    if [[ -d "$req_dir" ]] && find "$req_dir" -name '*.json' -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wpr_run_cli() {
  (
    cd "$WPR_WS"
    # This acceptance suite drives stages via resume / single-stage orch after
    # durable start init. Skip the start-time supervisor so ownership stays
    # with the explicit driver below.
    wpr_env RALPH_WORKFLOW_START_SKIP_SUPERVISOR=1 \
      bash "$WPR_HOME/bundle/.ralph/workflow-cli.sh" "$@"
  ) >>"$WPR_RUN_LOG" 2>&1
}

wpr_bind_ns() {
  # Each run now gets its own artifact namespace (<declared-or-workflow-id>-<run
  # token>) so runs cannot overwrite each other's artifacts or satisfy a
  # requires: gate on a previous run's file. Read the run's own value rather
  # than assuming the declared namespace is the whole directory name.
  local run_id="$1" ns
  ns="$(jq -r '.artifactNamespace // empty' \
    "$WPR_WS/.ralph-workspace/workflow-runs/$run_id/run.json" 2>/dev/null || true)"
  [[ -n "$ns" ]] && WPR_NS="$ns"
  return 0
}

wpr_mirror_token_artifact_paths() {
  local token_dir="$WPR_WS/.ralph-workspace/artifacts/{{ARTIFACT_NS}}"
  local ns_dir="$WPR_WS/.ralph-workspace/artifacts/$WPR_NS"
  mkdir -p "$token_dir"
  if [[ -f "$ns_dir/impl-plan.json" ]]; then
    cp -f "$ns_dir/impl-plan.json" "$token_dir/impl-plan.json"
  fi
  if [[ -f "$ns_dir/implementation-handoff.md" ]]; then
    cp -f "$ns_dir/implementation-handoff.md" "$token_dir/implementation-handoff.md"
  fi
  if [[ -f "$ns_dir/review-verdict.json" ]]; then
    cp -f "$ns_dir/review-verdict.json" "$token_dir/review-verdict.json"
  fi
  if [[ -f "$ns_dir/qa-plan.json" ]]; then
    cp -f "$ns_dir/qa-plan.json" "$token_dir/qa-plan.json"
  fi
}

wpr_orch_writable() {
  local run_dir="$1" stage="$2"
  local orch="$WPR_TMP/orch-${stage}.json" stub_plan="$run_dir/stages/${stage}.plan.md"
  cp "$run_dir/input.orch.json" "$orch"
  jq --arg ns "$WPR_NS" --arg stage "$stage" '
    walk(
      if type == "string" then
        gsub("\\{\\{ARTIFACT_NS\\}\\}"; $ns)
        | gsub("\\{\\{STAGE_ID\\}\\}"; $stage)
      else . end
    )
  ' "$orch" >"$orch.tmp" && mv "$orch.tmp" "$orch"
  if ! jq -e --arg id "$stage" '
      .stages[]? | select(.id == $id) | (.plan // "") != "" and .plan != null
    ' "$orch" >/dev/null 2>&1; then
    mkdir -p "$run_dir/stages"
    printf '%s\n' '---' "name: ${stage}" '---' '- [ ] stage-work' >"$stub_plan"
    jq --arg id "$stage" --arg plan "$stub_plan" \
      '.stages = [.stages[]? | if .id == $id then . + {plan: $plan} else . end]' \
      "$orch" >"$orch.tmp" && mv "$orch.tmp" "$orch"
  fi
  printf '%s\n' "$orch"
}

wpr_orch_single() {
  local stage="$1" run_id="$2"
  local run_dir="$WPR_WS/.ralph-workspace/workflow-runs/$run_id" orch rc=0
  orch="$(wpr_orch_writable "$run_dir" "$stage")"
  set +e
  (
    cd "$WPR_WS"
    wpr_env \
      RALPH_WORKFLOW_REGISTRY_RUN="$run_dir" \
      RALPH_WORKFLOW_RUN_ID="$run_id" \
      RALPH_WORKFLOW_TASK="$WPR_TASK" \
      RALPH_WORKFLOW_STAGE_ATTEMPT=1 \
      bash "$WPR_WS/.ralph/orchestrator.sh" \
        --orchestration "$orch" \
        --single-stage "$stage" \
        --run-id "$run_id" \
        --attempt-id "${stage}-attempt-1" \
        "$WPR_WS"
  ) >>"$WPR_RUN_LOG" 2>&1
  rc=$?
  set -e
  if [[ "$stage" == "approve-plan" && "$rc" -eq 3 ]]; then
    return 0
  fi
  [[ "$rc" -eq 0 ]]
}

wpr_approve_gate() {
  local run_id="$1"
  local req_dir="$WPR_WS/.ralph-workspace/workflow-runs/$run_id/actions/requests"
  local req=""
  if [[ -d "$req_dir" ]]; then
    req="$(find "$req_dir" -name '*.json' -print -quit 2>/dev/null || true)"
  fi
  [[ -n "$req" ]] || return 1
  local rid
  rid="$(basename "$req" .json)"
  (
    cd "$WPR_WS"
    wpr_env bash "$WPR_HOME/bundle/.ralph/workflow-cli.sh" \
      actions respond "$run_id" "$rid" --decision approve --yes
  ) >/dev/null 2>&1
}

# wpr_assert_planner_published <registry-run> <planner> [expected-todo-id...]
# Defaults to the two-TODO implementation plan the planner stub emits.
wpr_assert_planner_published() {
  local registry_run="$1" planner="$2"
  shift 2
  local source manifest todo
  local expected=("$@")
  [ "${#expected[@]}" -gt 0 ] || expected=(implement-core verify-tests)
  source="$registry_run/plans/$planner/attempt-1.plan.md"
  manifest="$registry_run/plans/$planner/attempt-1.manifest.json"
  [ -f "$source" ]
  [ -f "$manifest" ]
  [ ! -w "$source" ]
  for todo in "${expected[@]}"; do
    grep -q "id: $todo" "$source"
  done
  grep -q 'status: pending' "$source"
}

# wpr_assert_planfrom_chain <registry-run> <consumer> <planner> [expected-todo-id...]
wpr_assert_planfrom_chain() {
  local registry_run="$1" consumer="$2" planner="$3"
  shift 3
  local control
  wpr_assert_planner_published "$registry_run" "$planner" "$@"
  control="$registry_run/plans/$consumer/attempt-1/control.plan.md"
  [ -f "$control" ]
  [ -w "$control" ]
}

@test "Sequential planFrom crosses planner source control two TODOs progress and review" {
  wpr_run_cli start --file "$WPR_WS/.ralph-workspace/workflows/wpr-seq.workflow.md" \
    --task "$WPR_TASK" --runtime cursor --yes || true

  local run_dir run_id
  run_dir="$(wpr_only_run_dir)"
  [ -n "$run_dir" ] || { cat "$WPR_RUN_LOG"; return 1; }
  run_id="$(basename "$run_dir")"
  wpr_bind_ns "$run_id"

  wpr_orch_single plan-implementation "$run_id" || { cat "$WPR_RUN_LOG"; return 1; }
  wpr_mirror_token_artifact_paths
  wpr_assert_planner_published "$run_dir" plan-implementation

  wpr_orch_single approve-plan "$run_id" || { cat "$WPR_RUN_LOG"; return 1; }
  wpr_approve_gate "$run_id" || { cat "$WPR_RUN_LOG"; return 1; }

  wpr_orch_single implement "$run_id" || { cat "$WPR_RUN_LOG"; return 1; }
  wpr_mirror_token_artifact_paths
  wpr_assert_planfrom_chain "$run_dir" implement plan-implementation
  local control="$run_dir/plans/implement/attempt-1/control.plan.md"
  [ -f "$control" ]
  [ "$(grep -c 'status: completed' "$control" || true)" -ge 1 ]

  wpr_orch_single review "$run_id" || { cat "$WPR_RUN_LOG"; return 1; }
  [ -f "$WPR_WS/.ralph-workspace/artifacts/$WPR_NS/review-verdict.json" ]
  [ "$(grep -c '^REAL_INVOCATION$' "$WPR_RECORD" || true)" -ge 2 ]
}

@test "Dependency planFrom attribution interruption resume QA handoff and terminal success" {
  wpr_run_cli start --file "$WPR_WS/.ralph-workspace/workflows/wpr-dep.workflow.md" \
    --task "$WPR_TASK" --runtime cursor --yes || true

  local run_dir run_id graph_dir rc=0 before_invocations mid_invocations node_json
  run_dir="$(wpr_only_run_dir)"
  [ -n "$run_dir" ] || { cat "$WPR_RUN_LOG"; return 1; }
  run_id="$(basename "$run_dir")"
  wpr_bind_ns "$run_id"
  graph_dir="$(
    jq -r '.engine.statePath // empty' "$run_dir/run.json"
  )"
  [ -n "$graph_dir" ] && [ -d "$graph_dir" ]

  wpr_dep_resume "$run_id" || {
    find "$WPR_WS/.ralph-workspace/graph-runs" -name 'agent.log' -exec cat {} \; >>"$WPR_RUN_LOG" 2>/dev/null || true
    find "$WPR_WS/.ralph-workspace/logs" -name 'orchestrator*.log' -exec tail -80 {} \; >>"$WPR_RUN_LOG" 2>/dev/null || true
    ls -la "$WPR_WS/.ralph-workspace/artifacts/$WPR_NS/" >>"$WPR_RUN_LOG" 2>/dev/null || true
    find "$WPR_WS/.ralph-workspace/artifacts" -path '*stage-outcomes*' -name '*.json' -exec cat {} \; >>"$WPR_RUN_LOG" 2>/dev/null || true
    cat "$WPR_RUN_LOG"
    return 1
  }
  wpr_dep_wait_for_approval "$run_id" || { cat "$WPR_RUN_LOG"; return 1; }
  wpr_sync_dependency_run "$run_id"
  wpr_mirror_token_artifact_paths
  wpr_approve_gate "$run_id" || { cat "$WPR_RUN_LOG"; return 1; }

  rc=0
  wpr_dep_resume "$run_id" || rc=$?
  [ "$rc" -eq 0 ] || { cat "$WPR_RUN_LOG"; return 1; }

  wpr_mirror_token_artifact_paths
  wpr_assert_planfrom_chain "$run_dir" implement plan-implementation

  node_json="$graph_dir/nodes/implement.json"
  [ -f "$node_json" ]
  [[ "$(jq -r '.planSourceKind,.planSourceStageId,.sourcePlanPath,.controlPlanPath' "$node_json" | paste -sd, -)" == *"generated,plan-implementation"* ]]
  [[ "$(jq -r '.sourcePlanPath' "$node_json")" == *"/plans/plan-implementation/attempt-1.plan.md" ]]
  [[ "$(jq -r '.controlPlanPath' "$node_json")" == *"/plans/implement/attempt-1/control.plan.md" ]]

  # The runner must transition the registry control copy itself, not a private
  # per-node copy under orchestration-plans/nodes/.  Mirrors the Sequential
  # assertion above: without it a succeeded stage reports 0/N on the ledger and
  # a resume replays TODOs that already ran.
  local dep_control="$run_dir/plans/implement/attempt-1/control.plan.md"
  [ -f "$dep_control" ]
  [ "$(grep -c 'status: completed' "$dep_control" || true)" -ge 1 ]
  [ "$(jq -r '.completedTodos' "$node_json")" -ge 1 ]
  [ "$(jq -r '.completedTodos' "$node_json")" -eq "$(jq -r '.totalTodos' "$node_json")" ]

  before_invocations="$(grep -c '^REAL_INVOCATION$' "$WPR_RECORD" 2>/dev/null || echo 0)"

  wpr_dep_resume "$run_id" || true
  wpr_sync_dependency_run "$run_id"
  mid_invocations="$(grep -c '^REAL_INVOCATION$' "$WPR_RECORD" 2>/dev/null || echo 0)"
  [ "$mid_invocations" -ge "$before_invocations" ]

  rc=0
  wpr_dep_resume "$run_id" || rc=$?
  [ "$rc" -eq 0 ] || { cat "$WPR_RUN_LOG"; return 1; }

  wpr_assert_planfrom_chain "$run_dir" qa plan-qa qa-check
  [ -f "$WPR_WS/.ralph-workspace/artifacts/$WPR_NS/qa-handoff.md" ]
  [ "$(jq -r '.state' "$run_dir/run.json")" = "succeeded" ]
  [ "$(jq -r '.status' "$graph_dir/run.json")" = "succeeded" ]
}
