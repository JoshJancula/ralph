#!/usr/bin/env bats
# Compact correction records, in-place corrective retry, and plan-contract
# waiting (needs-plan-repair) for graph results.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-failure-classify.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

assert_compact_correction() {
  local record="$1"
  [ -f "$record" ]
  [ "$(jq -r 'keys | sort | join(",")' "$record")" = \
    "failedCompletionComponent,nextAttemptNumber,offendingPaths,verificationResultPath" ]
  [ "$(jq -r 'has("prompt") or has("output") or has("rawOutput") or has("stdout") or has("stderr") or has("text")' "$record")" = "false" ]
}

write_corrective_graph() {
  local out_path="$1" session_resume="${2:-true}"
  jq -n --argjson resume "$session_resume" '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "corrective-retry",
      namespace: "corrective-retry",
      maxParallel: 1,
      failurePolicy: "drain",
      nodes: [{
        id: "impl",
        type: "agent",
        dependsOn: [],
        derivedFrom: "stage",
        stage: {
          id: "impl",
          runtime: "cursor",
          agent: "implementation",
          sessionResume: $resume,
          workspaceMode: "snapshot",
          outputArtifacts: [{path: "stub-output.md", required: true}],
          _inlineTodos: [{id: "impl-1", content: "work impl", status: "pending"}]
        }
      }],
      edges: []
    }
  ' >"$out_path"
}

setup() {
  TMPD="$(mktemp -d)"
  RUN_DIR="$TMPD/run"
  mkdir -p "$RUN_DIR"
  unset RALPH_GRAPH_CORRECTION_RECORD RALPH_GRAPH_PROMPT RALPH_PLAN_PROMPT 2>/dev/null || true
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD" 2>/dev/null || true
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT GRAPH_DISPATCH_ORCHESTRATOR 2>/dev/null || true
  unset RALPH_ALLOW_NESTED_RUNS ORCHESTRATOR_RUNNER_TO_CONSOLE RALPH_MODE 2>/dev/null || true
  unset RALPH_ARTIFACT_NS RALPH_GRAPH_MAX_PARALLEL RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME 2>/dev/null || true
}

@test "corrective record writes compact json for missing artifact" {
  local record
  run graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"artifact","reason":"required-artifact-missing:exchange/out.md"}'
  [ "$status" -eq 0 ]
  record="$output"
  assert_compact_correction "$record"
  [ "$record" = "$RUN_DIR/corrections/impl.json" ]
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "required-artifact-missing" ]
  [ "$(jq -r '.offendingPaths | join(",")' "$record")" = "exchange/out.md" ]
  [ "$(jq -r '.verificationResultPath' "$record")" = "null" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]
}

@test "corrective record omits prompts and raw output" {
  local record
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "2" \
    '{"component":"verification","missingArtifacts":["notes.md"],"prompt":"fix the todo","output":"full agent transcript","rawOutput":"BYTES","stdout":"log","stderr":"err","text":"noise"}')"
  assert_compact_correction "$record"
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "verification" ]
  [ "$(jq -r '.offendingPaths[0]' "$record")" = "notes.md" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "3" ]
  ! jq -e '.prompt or .output or .rawOutput or .stdout or .stderr or .text' "$record" >/dev/null
}

@test "corrective record includes verification-result path and next attempt number" {
  local record
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "gate-node" "4" \
    '{"kind":"verification-failed","offendingPaths":["src/a.ts"],"verificationResultPath":"/tmp/verify/gate-result.json"}')"
  assert_compact_correction "$record"
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "verification-failed" ]
  [ "$(jq -r '.offendingPaths | join(",")' "$record")" = "src/a.ts" ]
  [ "$(jq -r '.verificationResultPath' "$record")" = "/tmp/verify/gate-result.json" ]
  [ "$(jq -r '.nextAttemptNumber | type' "$record")" = "number" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "5" ]
}

@test "corrective record merges offending paths and missing artifacts" {
  local record
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"component":"correctable-scope","offendingPaths":["src/leaked.ts"],"missingArtifacts":["exchange/out.md"]}')"
  assert_compact_correction "$record"
  [ "$(jq -r '.offendingPaths | sort | join(",")' "$record")" = "exchange/out.md,src/leaked.ts" ]
}

@test "corrective record reads a result file and ignores extra fields" {
  local src record
  src="$TMPD/result.json"
  printf '%s\n' '{"kind":"changeset-verification-failed","offendingPaths":["src/bad.ts"],"verificationResult":"'"$TMPD"'/verify.json","prompt":"do not persist","output":"raw"}' >"$src"
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "build" "1" "$src")"
  assert_compact_correction "$record"
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "changeset-verification-failed" ]
  [ "$(jq -r '.offendingPaths[0]' "$record")" = "src/bad.ts" ]
  [ "$(jq -r '.verificationResultPath' "$record")" = "$TMPD/verify.json" ]
}

@test "corrective record is not written for plan-contract results" {
  run graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"undeclared-path","outOfScope":["docs/secret.md"]}'
  [ "$status" -ne 0 ]
  [ ! -e "$RUN_DIR/corrections/impl.json" ]
}

@test "corrective record is not written for operator-permission results" {
  run graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"outcome":"failed","exitCode":4,"prompt":"allow bash?"}'
  [ "$status" -ne 0 ]
  [ ! -e "$RUN_DIR/corrections/impl.json" ]
}

@test "corrective record is written by the scheduler helper for agent-correctable reap results" {
  local record
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$RUN_DIR"
  GRAPH_NODE_IDS=()
  GRAPH_NODE_ATTEMPT_NUMBERS=()
  GRAPH_NODE_INDEX_KEYS=()
  GRAPH_NODE_INDEX_VALS=()
  _graph_schedule_try_write_correction_record "impl" "impl__run-1__1" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["stub-output.md"],"verificationResultPath":"'"$TMPD"'/verify.json","output":"do-not-store"}'
  record="$RUN_DIR/corrections/impl.json"
  assert_compact_correction "$record"
  [ "$(jq -r '.failedCompletionComponent' "$record")" = "artifact-publish-failed" ]
  [ "$(jq -r '.offendingPaths[0]' "$record")" = "stub-output.md" ]
  [ "$(jq -r '.verificationResultPath' "$record")" = "$TMPD/verify.json" ]
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]
}

@test "corrective retry requeues without deleting the isolated workspace" {
  local graph_file record node_key workspace_path idx
  graph_file="$TMPD/corrective.graph.json"
  write_corrective_graph "$graph_file" true
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""
  GRAPH_SCHEDULE_LEDGER_NAMESPACE=""
  GRAPH_SCHEDULE_WORKSPACE=""
  GRAPH_SCHEDULE_RUN_ID=""

  node_key="$(graph_workspace_node_key impl)"
  workspace_path="$RUN_DIR/workspaces/nodes/$node_key"
  mkdir -p "$workspace_path/src"
  printf 'keep-isolated-work\n' >"$workspace_path/src/partial.ts"

  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["stub-output.md"]}')"
  assert_compact_correction "$record"

  graph_schedule_requeue_corrective_node "$RUN_DIR" "impl" "impl__run-1__1" >"$TMPD/requeued.path"
  [ "$(cat "$TMPD/requeued.path")" = "$record" ]
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]
  idx="$(graph_schedule_index_map_get impl)"
  [ "${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]}" = "1" ]
  [ -d "$workspace_path" ]
  [ -f "$workspace_path/src/partial.ts" ]
  [ "$(cat "$workspace_path/src/partial.ts")" = "keep-isolated-work" ]
}

@test "corrective retry consumes one retry attempt and preserves the prior attempt" {
  local graph_file workspace ns run_id node_file aid record idx
  graph_file="$TMPD/corrective.graph.json"
  write_corrective_graph "$graph_file" true
  workspace="$TMPD/ws"
  mkdir -p "$workspace"
  ns="corrective-retry"
  run_id="run-corrective-1"
  printf 'plan\n' >"$workspace/plan.md"
  graph_state_init_run_v2 "$workspace" "$ns" "$run_id" "$workspace/plan.md" "$graph_file" 1

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"
  GRAPH_SCHEDULE_LEDGER_SCHEMA_VERSION=""
  RUN_DIR="$GRAPH_SCHEDULE_LEDGER_RUN_DIR"

  aid="impl__${run_id}__1"
  _graph_schedule_ledger_record "impl" "running" "$aid" "" "" "2026-01-01T00:00:00Z" "" "cursor" "off" ""
  _graph_schedule_ledger_record "impl" "failed" "$aid" "failed" "1" "" "2026-01-01T00:00:01Z" \
    "cursor" "off" "artifact-publish-failed"
  GRAPH_NODE_ATTEMPT_NUMBERS[$(graph_schedule_index_map_get impl)]="1"

  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["stub-output.md"]}')"
  assert_compact_correction "$record"
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]

  graph_schedule_requeue_corrective_node "$RUN_DIR" "impl" "$aid" >"$TMPD/requeued.path"
  [ "$(cat "$TMPD/requeued.path")" = "$record" ]

  node_file="$(graph_state_node_file "$workspace" "$ns" "$run_id" "impl")"
  [ "$(jq -r '.status' "$node_file")" = "pending" ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "failed" ]
  [ "$(jq -r '.attempts[0].exitCode' "$node_file")" = "1" ]
  [ "$(graph_state_max_attempt_number "$node_file")" -eq 1 ]
  idx="$(graph_schedule_index_map_get impl)"
  [ "${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]}" = "1" ]
  [ "${GRAPH_NODE_ATTEMPT_NUMBERS[$idx]}" = "1" ]

  run graph_schedule_requeue_corrective_node "$RUN_DIR" "impl" "$aid"
  [ "$status" -ne 0 ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "$aid" ]
  [ "$(jq -r '.status' "$node_file")" = "pending" ]
}

@test "corrective retry passes only the compact correction record on a supported session turn" {
  local graph_file record turn
  graph_file="$TMPD/corrective.graph.json"
  write_corrective_graph "$graph_file" true
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"required-artifact-missing","missingArtifacts":["stub-output.md"],"prompt":"full prior prompt","output":"raw transcript"}')"
  assert_compact_correction "$record"

  run graph_schedule_node_session_resume_supported "$graph_file" "impl"
  [ "$status" -eq 0 ]

  turn="$(graph_schedule_corrective_retry_turn "$RUN_DIR" "impl" "$graph_file")"
  [ "$turn" = "$record" ]
  assert_compact_correction "$turn"
  [ "$(jq -r 'keys | sort | join(",")' "$turn")" = \
    "failedCompletionComponent,nextAttemptNumber,offendingPaths,verificationResultPath" ]
  ! jq -e '.prompt or .output or .rawOutput or .stdout or .stderr or .text' "$turn" >/dev/null

  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$RUN_DIR"
  GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD=""
  _graph_schedule_prepare_corrective_retry_spawn "impl" "2" ""
  [ "$GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD" = "$record" ]

  _graph_schedule_prepare_corrective_retry_spawn "impl" "1" ""
  [ -z "$GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD" ]
}

@test "corrective retry does not pass a session turn when resume is unsupported" {
  local graph_file record
  graph_file="$TMPD/corrective.graph.json"
  write_corrective_graph "$graph_file" false
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["stub-output.md"]}')"
  assert_compact_correction "$record"

  run graph_schedule_node_session_resume_supported "$graph_file" "impl"
  [ "$status" -ne 0 ]
  run graph_schedule_corrective_retry_turn "$RUN_DIR" "impl" "$graph_file"
  [ "$status" -ne 0 ]
  [ -z "$output" ]

  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$RUN_DIR"
  _graph_schedule_prepare_corrective_retry_spawn "impl" "2" ""
  [ -z "$GRAPH_SCHEDULE_SPAWN_CORRECTION_RECORD" ]

  graph_schedule_load_index "$graph_file"
  graph_schedule_requeue_corrective_node "$RUN_DIR" "impl" "impl__run-1__1" >"$TMPD/requeued.path"
  [ "$(cat "$TMPD/requeued.path")" = "$record" ]
}

@test "corrective retry scheduler reuses the isolated workspace and session turn" {
  local graph_file state_root run_id run_dir roots_json marker_dir node_key workspace_path
  local node_file record orch passed_record
  graph_file="$TMPD/corrective.graph.json"
  write_corrective_graph "$graph_file" true

  DISPATCH_WORKSPACE="$TMPD/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"
  printf 'plan\n' >"$DISPATCH_WORKSPACE/corrective-retry.plan.md"
  printf 'source\n' >"$DISPATCH_WORKSPACE/src.txt"

  marker_dir="$TMPD/markers"
  mkdir -p "$marker_dir"
  orch="$TMPD/orchestrator.sh"
  cat >"$orch" <<EOF
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
workspace="\${RALPH_AGENT_WORKSPACE:-\$PWD}"
ns="\${RALPH_ARTIFACT_NS:-corrective-retry}"
state_root="\${RALPH_PLAN_WORKSPACE_ROOT:?}"
report="\$state_root/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "$marker_dir"
if [[ -n "\${RALPH_GRAPH_CORRECTION_RECORD:-}" ]]; then
  printf '%s\n' "\$RALPH_GRAPH_CORRECTION_RECORD" >"$marker_dir/correction-path"
  printf '%s\n' "\${RALPH_PLAN_SESSION_STRATEGY:-}" >"$marker_dir/session-strategy"
  printf '%s\n' "\${RALPH_PLAN_CLI_RESUME:-}" >"$marker_dir/cli-resume"
  printf '%s\n' "\${RALPH_GRAPH_PROMPT-__unset__}" >"$marker_dir/graph-prompt"
  printf '%s\n' "\${RALPH_PLAN_PROMPT-__unset__}" >"$marker_dir/plan-prompt"
  printf '%s\n' "\${RALPH_GRAPH_RAW_OUTPUT-__unset__}" >"$marker_dir/raw-output"
  printf 'stub artifact\n' >"\$workspace/stub-output.md"
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"corrective-retry-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"success\",\"exitCode\":0,\"startedAt\":\"2026-01-01T00:00:02Z\",\"finishedAt\":\"2026-01-01T00:00:03Z\"}" >"\$report"
  exit 0
fi
printf 'attempt-1-partial\n' >"\$workspace/keep-me.txt"
printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"corrective-retry-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"failed\",\"exitCode\":1,\"kind\":\"artifact-publish-failed\",\"missingArtifacts\":[\"stub-output.md\"],\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
exit 1
EOF
  chmod +x "$orch"
  export GRAPH_DISPATCH_ORCHESTRATOR="$orch"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0

  state_root="$TMPD/state"
  run_id="corrective-retry-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run_v2 "$DISPATCH_WORKSPACE" corrective-retry "$run_id" \
    "$DISPATCH_WORKSPACE/corrective-retry.plan.md" "$graph_file" 1
  run_dir="$state_root/graph-runs/corrective-retry/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]

  node_key="$(graph_workspace_node_key impl)"
  workspace_path="$(graph_workspace_prepare_node "$run_dir" "$graph_file" impl)"
  [ -f "$workspace_path/keep-me.txt" ]
  [ "$(cat "$workspace_path/keep-me.txt")" = "attempt-1-partial" ]
  [[ "$workspace_path" == "$(cd "$run_dir" && pwd -P)/workspaces/nodes/$node_key" ]]

  record="$run_dir/corrections/impl.json"
  assert_compact_correction "$record"
  [ "$(jq -r '.nextAttemptNumber' "$record")" = "2" ]
  [ -f "$marker_dir/correction-path" ]
  passed_record="$(cat "$marker_dir/correction-path")"
  [ -f "$passed_record" ]
  assert_compact_correction "$passed_record"
  [ "$(jq -c . "$passed_record")" = "$(jq -c . "$record")" ]
  [ "$(cat "$marker_dir/session-strategy")" = "resume" ]
  [ "$(cat "$marker_dir/cli-resume")" = "1" ]
  [ "$(cat "$marker_dir/graph-prompt")" = "__unset__" ]
  [ "$(cat "$marker_dir/plan-prompt")" = "__unset__" ]
  [ "$(cat "$marker_dir/raw-output")" = "__unset__" ]

  node_file="$(graph_state_node_file "$DISPATCH_WORKSPACE" corrective-retry "$run_id" impl)"
  [ "$(jq '.attempts | length' "$node_file")" -eq 2 ]
  [ "$(jq -r '.attempts[0].attemptId' "$node_file")" = "impl__${run_id}__1" ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "failed" ]
  [ "$(jq -r '.attempts[1].attemptId' "$node_file")" = "impl__${run_id}__2" ]
  [ "$(jq -r '.attempts[1].outcome' "$node_file")" = "success" ]
  [ "$(jq -r '.status' "$node_file")" = "succeeded" ]
}

write_plan_contract_graph() {
  local out_path="$1"
  jq -n '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "plan-contract",
      namespace: "plan-contract",
      maxParallel: 1,
      failurePolicy: "drain",
      nodes: [
        {
          id: "contract",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "contract",
            runtime: "cursor",
            agent: "implementation",
            workspaceMode: "snapshot",
            writeScopes: ["src/allowed/**"],
            outputArtifacts: [{path: "stub-output.md", required: true}],
            _inlineTodos: [{id: "contract-1", content: "work contract", status: "pending"}]
          }
        },
        {
          id: "independent",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "independent",
            runtime: "claude",
            agent: "implementation",
            workspaceMode: "snapshot",
            outputArtifacts: [{path: "independent.md", required: true}],
            _inlineTodos: [{id: "independent-1", content: "work independent", status: "pending"}]
          }
        },
        {
          id: "child",
          type: "agent",
          dependsOn: ["contract"],
          derivedFrom: "stage",
          stage: {
            id: "child",
            runtime: "cursor",
            agent: "implementation",
            workspaceMode: "snapshot",
            _inlineTodos: [{id: "child-1", content: "work child", status: "pending"}]
          }
        }
      ],
      edges: [{from: "contract", to: "child", reasons: ["declared"]}]
    }
  ' >"$out_path"
}

write_plan_contract_diamond_graph() {
  local out_path="$1"
  jq -n '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "plan-contract-diamond",
      namespace: "plan-contract-diamond",
      maxParallel: 1,
      failurePolicy: "drain",
      nodes: [
        {
          id: "source",
          type: "agent",
          dependsOn: [],
          derivedFrom: "stage",
          stage: {
            id: "source",
            runtime: "cursor",
            agent: "implementation",
            _inlineTodos: [{id: "source-1", content: "work source", status: "pending"}]
          }
        },
        {
          id: "left",
          type: "agent",
          dependsOn: ["source"],
          derivedFrom: "stage",
          stage: {
            id: "left",
            runtime: "claude",
            agent: "implementation",
            writeScopes: ["src/left/**"],
            _inlineTodos: [{id: "left-1", content: "work left", status: "pending"}]
          }
        },
        {
          id: "right",
          type: "agent",
          dependsOn: ["source"],
          derivedFrom: "stage",
          stage: {
            id: "right",
            runtime: "codex",
            agent: "implementation",
            _inlineTodos: [{id: "right-1", content: "work right", status: "pending"}]
          }
        },
        {
          id: "sink",
          type: "agent",
          dependsOn: ["left", "right"],
          derivedFrom: "stage",
          stage: {
            id: "sink",
            runtime: "cursor",
            agent: "implementation",
            _inlineTodos: [{id: "sink-1", content: "work sink", status: "pending"}]
          }
        }
      ],
      edges: [
        {from: "source", to: "left", reasons: ["declared"]},
        {from: "source", to: "right", reasons: ["declared"]},
        {from: "left", to: "sink", reasons: ["declared"]},
        {from: "right", to: "sink", reasons: ["declared"]}
      ]
    }
  ' >"$out_path"
}

install_plan_contract_orchestrator() {
  local orch="$1" marker_dir="$2" contract_stage="${3:-contract}"
  mkdir -p "$marker_dir"
  cat >"$orch" <<EOF
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
workspace="\${RALPH_AGENT_WORKSPACE:-\$PWD}"
ns="\${RALPH_ARTIFACT_NS:-plan-contract}"
state_root="\${RALPH_PLAN_WORKSPACE_ROOT:-\$workspace/.ralph-workspace}"
report="\$state_root/artifacts/\$ns/stage-outcomes/\${attempt}.json"
mkdir -p "\$(dirname "\$report")" "$marker_dir"
: >"$marker_dir/\$stage.started"
if [[ "\$stage" == "$contract_stage" ]]; then
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"plan-contract-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"failed\",\"exitCode\":1,\"kind\":\"undeclared-path\",\"outOfScope\":[\"docs/secret.md\"],\"startedAt\":\"2026-01-01T00:00:00Z\",\"finishedAt\":\"2026-01-01T00:00:01Z\"}" >"\$report"
  : >"$marker_dir/\$stage.finished"
  exit 1
fi
printf 'ok\n' >"\$workspace/\${stage}.md"
printf 'stub artifact\n' >"\$workspace/stub-output.md"
printf 'independent\n' >"\$workspace/independent.md"
printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"plan-contract-run\",\"stageId\":\"\$stage\",\"attemptId\":\"\$attempt\",\"outcome\":\"success\",\"exitCode\":0,\"startedAt\":\"2026-01-01T00:00:02Z\",\"finishedAt\":\"2026-01-01T00:00:03Z\"}" >"\$report"
: >"$marker_dir/\$stage.finished"
exit 0
EOF
  chmod +x "$orch"
}

@test "corrective plan contract maps undeclared path to needs-plan-repair" {
  local graph_file class
  graph_file="$TMPD/plan-contract.graph.json"
  write_plan_contract_graph "$graph_file"
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_EXIT_CODE=0
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""

  class="$(_graph_schedule_result_classification \
    '{"kind":"undeclared-path","outOfScope":["docs/secret.md"]}')"
  [ "$class" = "plan-contract" ]

  graph_schedule_apply_plan_contract "contract" 1 "undeclared-path"
  [ "$(graph_schedule_node_state_by_id contract)" = "needs-plan-repair" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]
  [ "$GRAPH_SCHEDULE_FAILED_NODE" = "contract" ]
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 1 ]
}

@test "corrective plan contract maps write-scope mismatch without widening scopes" {
  local graph_file before after
  graph_file="$TMPD/plan-contract.graph.json"
  write_plan_contract_graph "$graph_file"
  before="$(jq -c --arg id contract '.nodes[] | select(.id == $id) | .stage.writeScopes' "$graph_file")"
  [ "$before" = '["src/allowed/**"]' ]
  cp "$graph_file" "$TMPD/graph.before.json"

  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""

  graph_schedule_apply_plan_contract "contract" 1 "write-scope-mismatch"
  [ "$(graph_schedule_node_state_by_id contract)" = "needs-plan-repair" ]
  [ "$(graph_schedule_node_state_by_id child)" = "blocked" ]
  [ "$(graph_schedule_node_state_by_id independent)" = "pending" ]

  after="$(jq -c --arg id contract '.nodes[] | select(.id == $id) | .stage.writeScopes' "$graph_file")"
  [ "$after" = "$before" ]
  cmp -s "$graph_file" "$TMPD/graph.before.json"
}

@test "corrective plan contract blocks only descendants" {
  local graph_file
  graph_file="$TMPD/plan-contract.graph.json"
  write_plan_contract_graph "$graph_file"
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_LEDGER_RUN_DIR=""

  graph_schedule_apply_plan_contract "contract" 1 "undeclared-changed-leaf"
  [ "$(graph_schedule_node_state_by_id contract)" = "needs-plan-repair" ]
  [ "$(graph_schedule_node_state_by_id child)" = "blocked" ]
  [ "$(graph_schedule_node_state_by_id independent)" = "pending" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]
}

@test "corrective plan contract lets independent branches drain" {
  local graph_file state_root run_id run_dir roots_json marker_dir orch graph_before rc
  graph_file="$TMPD/plan-contract.graph.json"
  write_plan_contract_graph "$graph_file"
  cp "$graph_file" "$TMPD/graph.before.json"
  graph_before="$(jq -c . "$graph_file")"

  DISPATCH_WORKSPACE="$TMPD/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"
  printf 'plan\n' >"$DISPATCH_WORKSPACE/plan-contract.plan.md"
  printf 'source\n' >"$DISPATCH_WORKSPACE/src.txt"

  marker_dir="$TMPD/markers"
  orch="$TMPD/orchestrator.sh"
  install_plan_contract_orchestrator "$orch" "$marker_dir" "contract"
  export GRAPH_DISPATCH_ORCHESTRATOR="$orch"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  export RALPH_GRAPH_MAX_PARALLEL=1
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1

  state_root="$TMPD/state"
  run_id="plan-contract-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run_v2 "$DISPATCH_WORKSPACE" plan-contract "$run_id" \
    "$DISPATCH_WORKSPACE/plan-contract.plan.md" "$graph_file" 1
  run_dir="$state_root/graph-runs/plan-contract/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"

  rc=0
  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir" || rc=$?
  [ "$rc" -ne 0 ]
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id contract)" = "needs-plan-repair" ]
  [ "$(graph_schedule_node_state_by_id independent)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id child)" = "blocked" ]
  [ -f "$marker_dir/independent.finished" ]
  [ ! -f "$marker_dir/child.started" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]
  [ ! -e "$run_dir/corrections/contract.json" ]

  [ "$(jq -c . "$graph_file")" = "$graph_before" ]
  cmp -s "$graph_file" "$TMPD/graph.before.json"
  [ "$(jq -c --arg id contract '.nodes[] | select(.id == $id) | .stage.writeScopes' "$graph_file")" = '["src/allowed/**"]' ]
  [ "$(jq -c --arg id contract '.nodes[] | select(.id == $id) | .stage.writeScopes' "$run_dir/graph.json")" = '["src/allowed/**"]' ]
  cmp -s "$run_dir/graph.json" "$TMPD/graph.before.json"
}

@test "corrective plan contract does not block a descendant with another path" {
  local graph_file state_root run_id run_dir roots_json marker_dir orch rc
  graph_file="$TMPD/plan-contract-diamond.graph.json"
  write_plan_contract_diamond_graph "$graph_file"
  cp "$graph_file" "$TMPD/graph.before.json"

  DISPATCH_WORKSPACE="$TMPD/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"
  printf 'plan\n' >"$DISPATCH_WORKSPACE/plan-contract-diamond.plan.md"

  marker_dir="$TMPD/markers"
  orch="$TMPD/orchestrator.sh"
  install_plan_contract_orchestrator "$orch" "$marker_dir" "left"
  export GRAPH_DISPATCH_ORCHESTRATOR="$orch"
  export RALPH_ALLOW_NESTED_RUNS=1
  export ORCHESTRATOR_RUNNER_TO_CONSOLE=0
  export RALPH_MODE=no
  export RALPH_ARTIFACT_SCHEMA_VALIDATION=0
  export RALPH_ARTIFACT_PROVENANCE=0
  export RALPH_GRAPH_MAX_PARALLEL=1
  export RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME=1
  export RALPH_ARTIFACT_NS=plan-contract-diamond

  state_root="$TMPD/state"
  run_id="plan-contract-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run_v2 "$DISPATCH_WORKSPACE" plan-contract-diamond "$run_id" \
    "$DISPATCH_WORKSPACE/plan-contract-diamond.plan.md" "$graph_file" 1
  run_dir="$state_root/graph-runs/plan-contract-diamond/$run_id"
  roots_json="$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
    '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')"
  graph_run_base_prepare "$run_dir" "$roots_json" '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"

  rc=0
  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir" || rc=$?
  [ "$rc" -ne 0 ]
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id source)" = "succeeded" ]
  [ "$(graph_schedule_node_state_by_id left)" = "needs-plan-repair" ]
  [ "$(graph_schedule_node_state_by_id right)" = "succeeded" ]
  # Sink still depends on left, so it stays pending rather than blocked.
  # Independent sibling right still drains because dispatch is not stopped.
  [ "$(graph_schedule_node_state_by_id sink)" = "pending" ]
  [ -f "$marker_dir/right.finished" ]
  [ ! -f "$marker_dir/sink.started" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]
  cmp -s "$graph_file" "$TMPD/graph.before.json"
  cmp -s "$run_dir/graph.json" "$TMPD/graph.before.json"
  [ "$(jq -c --arg id left '.nodes[] | select(.id == $id) | .stage.writeScopes' "$graph_file")" = '["src/left/**"]' ]
}
