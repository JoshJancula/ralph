#!/usr/bin/env bats
# Compact retry-context construction and graph status efficiency signals.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-failure-classify.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-logs.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-status.sh"

setup() {
  TMPD="$(mktemp -d)"
  RUN_DIR="$TMPD/run"
  mkdir -p "$RUN_DIR"
  GRAPH_FILE="$TMPD/graph.json"
  unset GRAPH_SCHEDULE_RETRY_CONTEXT_MAX_BYTES 2>/dev/null || true
  unset GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT GRAPH_SCHEDULE_GRAPH_JSON 2>/dev/null || true
  unset GRAPH_STATUS_NOW_EPOCH GRAPH_HEARTBEAT_NOW_EPOCH 2>/dev/null || true
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD" 2>/dev/null || true
  unset GRAPH_SCHEDULE_RETRY_CONTEXT_MAX_BYTES GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT 2>/dev/null || true
  unset GRAPH_SCHEDULE_GRAPH_JSON GRAPH_SCHEDULE_LEDGER_RUN_DIR GRAPH_SCHEDULE_RUN_ID 2>/dev/null || true
  unset GRAPH_STATUS_NOW_EPOCH GRAPH_HEARTBEAT_NOW_EPOCH 2>/dev/null || true
}

write_efficiency_graph() {
  jq -n '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "efficiency",
      namespace: "efficiency",
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
          role: "implementation",
          workspaceMode: "snapshot",
          outputArtifacts: [
            {path: "exchange/out.md", required: true},
            {path: "notes.md", required: true},
            {path: "optional.md", required: false}
          ]
        }
      }],
      edges: []
    }
  ' >"$GRAPH_FILE"
}

write_prior_attempt_logs() {
  local attempt_id="$1" paths runner agent
  paths="$(graph_logs_attempt_paths_json "$RUN_DIR" "impl" "$attempt_id")"
  runner="$(printf '%s' "$paths" | jq -r '.runner')"
  agent="$(printf '%s' "$paths" | jq -r '.agent')"
  mkdir -p "$(dirname "$RUN_DIR/$runner")"
  printf '%s\n' "FULL PRIOR PROMPT: rewrite the entire module from scratch with this secret transcript" >"$RUN_DIR/$runner"
  printf '%s\n' "agent transcript body that must never be inlined into retry context" >"$RUN_DIR/$agent"
  printf '%s\n' "$paths"
}

assert_no_forbidden_fields() {
  local json="$1"
  [ "$(printf '%s' "$json" | jq -n -r 'input |
    [paths as $p | $p[] | tostring] |
    map(select(. == "prompt" or . == "output" or . == "rawOutput" or
               . == "stdout" or . == "stderr" or . == "text" or
               . == "transcript" or . == "messages" or . == "priorPrompt" or
               . == "fullLog" or . == "body")) |
    length
  ')" = "0" ]
}

@test "efficiency retry context includes node identity attempt classification compact correction required artifacts and previous log refs" {
  local prev_id ctx logs record
  write_efficiency_graph
  prev_id="impl__efficiency-run__1"
  logs="$(write_prior_attempt_logs "$prev_id")"
  record="$(graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"required-artifact-missing","missingArtifacts":["exchange/out.md"],"verificationResultPath":"logs/nodes/impl/impl__efficiency-run__1/usage.json"}')"
  [ -f "$record" ]

  ctx="$(graph_schedule_build_retry_context "$RUN_DIR" "impl" "$GRAPH_FILE" \
    "$prev_id" "agent-correctable" "$record")"
  [ -n "$ctx" ]
  assert_no_forbidden_fields "$ctx"

  [ "$(printf '%s' "$ctx" | jq -r '.nodeId')" = "impl" ]
  [ "$(printf '%s' "$ctx" | jq -r '.runtime')" = "cursor" ]
  [ "$(printf '%s' "$ctx" | jq -r '.role')" = "implementation" ]
  [ "$(printf '%s' "$ctx" | jq -r '.attemptNumber')" = "2" ]
  [ "$(printf '%s' "$ctx" | jq -r '.previousAttemptId')" = "$prev_id" ]
  [ "$(printf '%s' "$ctx" | jq -r '.classification')" = "agent-correctable" ]
  [ "$(printf '%s' "$ctx" | jq -r '.correction.failedCompletionComponent')" = "required-artifact-missing" ]
  [ "$(printf '%s' "$ctx" | jq -r '.correction.offendingPaths | join(",")')" = "exchange/out.md" ]
  [ "$(printf '%s' "$ctx" | jq -r '.correction.verificationResultPath')" = "logs/nodes/impl/impl__efficiency-run__1/usage.json" ]
  [ "$(printf '%s' "$ctx" | jq -r '.correction.nextAttemptNumber')" = "2" ]
  [ "$(printf '%s' "$ctx" | jq -r '.requiredArtifactPaths | sort | join(",")')" = "exchange/out.md,notes.md" ]
  [ "$(printf '%s' "$ctx" | jq -r '.previousLogs.runner')" = "$(printf '%s' "$logs" | jq -r '.runner')" ]
  [ "$(printf '%s' "$ctx" | jq -r '.previousLogs.agent')" = "$(printf '%s' "$logs" | jq -r '.agent')" ]
  [ "$(printf '%s' "$ctx" | jq -r '.previousLogs.usage')" = "$(printf '%s' "$logs" | jq -r '.usage')" ]
}

@test "efficiency retry context excludes full prior prompts and transcripts" {
  local prev_id ctx
  write_efficiency_graph
  prev_id="impl__efficiency-run__1"
  write_prior_attempt_logs "$prev_id" >/dev/null

  ctx="$(graph_schedule_build_retry_context "$RUN_DIR" "impl" "$GRAPH_FILE" \
    "$prev_id" "agent-correctable" \
    '{"kind":"verification-failed","offendingPaths":["src/a.ts"],"prompt":"FULL PRIOR PROMPT: rewrite everything","output":"raw agent transcript","rawOutput":"BYTES","stdout":"log","stderr":"err","text":"noise","transcript":"session dump","messages":["user","assistant"]}')"
  [ -n "$ctx" ]
  assert_no_forbidden_fields "$ctx"

  [[ "$ctx" != *"FULL PRIOR PROMPT"* ]]
  [[ "$ctx" != *"raw agent transcript"* ]]
  [[ "$ctx" != *"session dump"* ]]
  [[ "$ctx" != *"rewrite the entire module"* ]]
  [[ "$ctx" != *"agent transcript body"* ]]
  [[ "$ctx" != *"secret transcript"* ]]
  [ "$(printf '%s' "$ctx" | jq -r '.correction.failedCompletionComponent')" = "verification-failed" ]
  [ "$(printf '%s' "$ctx" | jq -r '.correction.offendingPaths[0]')" = "src/a.ts" ]
  [ "$(printf '%s' "$ctx" | jq 'has("prompt") or has("output") or has("rawOutput") or has("transcript")')" = "false" ]
}

@test "efficiency retry context references previous logs by path only" {
  local prev_id ctx runner_rel
  write_efficiency_graph
  prev_id="impl__efficiency-run__3"
  runner_rel="$(write_prior_attempt_logs "$prev_id" | jq -r '.runner')"

  ctx="$(graph_schedule_build_retry_context "$RUN_DIR" "impl" "$GRAPH_FILE" \
    "$prev_id" "transient-runtime")"
  [ "$(printf '%s' "$ctx" | jq -r '.previousLogs.runner')" = "$runner_rel" ]
  [ "$(printf '%s' "$ctx" | jq -r '.previousLogs.runner | startswith("logs/")')" = "true" ]
  [[ "$ctx" != *"FULL PRIOR PROMPT"* ]]
  [[ "$ctx" != *"must never be inlined"* ]]
  [ "$(wc -c <"$RUN_DIR/$runner_rel" | tr -d ' ')" -gt 40 ]
  [ "$(printf '%s' "$ctx" | jq -r '.previousLogs | keys | sort | join(",")')" = "agent,runner,usage" ]
}

@test "efficiency retry context caps bytes and drops overflow without reintroducing prompts" {
  local prev_id ctx i paths_json huge
  write_efficiency_graph
  prev_id="impl__efficiency-run__1"
  write_prior_attempt_logs "$prev_id" >/dev/null

  paths_json='['
  for i in $(seq 1 40); do
    [[ "$i" -eq 1 ]] || paths_json+=','
    paths_json+="\"very/long/offending/path/segment-${i}/that-inflates-the-retry-context.json\""
  done
  paths_json+=']'
  huge="$(jq -cn --argjson p "$paths_json" \
    '{kind:"verification-failed",offendingPaths:$p,prompt:"FULL PRIOR PROMPT overflow",transcript:"do not keep"}')"

  GRAPH_SCHEDULE_RETRY_CONTEXT_MAX_BYTES=280
  ctx="$(graph_schedule_build_retry_context "$RUN_DIR" "impl" "$GRAPH_FILE" \
    "$prev_id" "agent-correctable" "$huge")"
  [ -n "$ctx" ]
  [ "$(printf '%s' "$ctx" | wc -c | tr -d ' ')" -le 280 ]
  [ "$(printf '%s' "$ctx" | jq -r '.truncated')" = "true" ]
  assert_no_forbidden_fields "$ctx"
  [[ "$ctx" != *"FULL PRIOR PROMPT"* ]]
  [[ "$ctx" != *"do not keep"* ]]
  [ "$(printf '%s' "$ctx" | jq -r '.nodeId // empty')" != "" ] || \
    [ "$(printf '%s' "$ctx" | jq -r '.truncated')" = "true" ]
}

@test "efficiency retry context write is contained and spawn helper skips first attempts" {
  local prev_id dest
  write_efficiency_graph
  prev_id="impl__efficiency-run__1"
  write_prior_attempt_logs "$prev_id" >/dev/null
  graph_schedule_write_correction_record "$RUN_DIR" "impl" "1" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["exchange/out.md"]}' >/dev/null

  dest="$(graph_schedule_write_retry_context "$RUN_DIR" "impl" "$GRAPH_FILE" \
    "$prev_id" "agent-correctable")"
  [ "$dest" = "$RUN_DIR/retry-context/impl.json" ]
  [ -f "$dest" ]
  [ "$(jq -r '.nodeId' "$dest")" = "impl" ]
  [ "$(jq -r '.classification' "$dest")" = "agent-correctable" ]
  assert_no_forbidden_fields "$(cat "$dest")"

  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$RUN_DIR"
  GRAPH_SCHEDULE_GRAPH_JSON="$GRAPH_FILE"
  GRAPH_SCHEDULE_RUN_ID="efficiency-run"
  GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT="stale"
  _graph_schedule_prepare_retry_context_spawn "impl" "1"
  [ -z "$GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT" ]

  _graph_schedule_prepare_retry_context_spawn "impl" "2"
  [ "$GRAPH_SCHEDULE_SPAWN_RETRY_CONTEXT" = "$dest" ]
}

init_efficiency_status_run() {
  WORKSPACE="$TMPD/ws"
  NAMESPACE="efficiency"
  RUN_ID="efficiency-run"
  mkdir -p "$WORKSPACE"
  write_efficiency_graph
  printf '# efficiency status plan\n' >"$TMPD/plan.md"
  graph_state_init_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "$TMPD/plan.md" "$GRAPH_FILE" 1 >/dev/null
}

write_efficiency_status_node() {
  local reliable="${1:-true}"
  local node_file
  node_file="$(graph_state_node_file "$WORKSPACE" "$NAMESPACE" "$RUN_ID" "impl")"
  jq -n --argjson reliable "$reliable" '
    {
      schemaVersion: 3,
      nodeId: "impl",
      status: "succeeded",
      lastAttemptId: "impl__efficiency-run__2",
      budget: {activeSeconds: 90, activeStartedAt: null},
      retryClassification: "transient-runtime",
      attempts: [
        {
          attemptId: "impl__efficiency-run__1",
          startedAt: "2026-01-01T00:00:00Z",
          finishedAt: "2026-01-01T00:01:00Z",
          outcome: "failed",
          exitCode: 1,
          runtime: "cursor",
          retryClassification: "transient-runtime",
          usageReliable: $reliable,
          usageSnapshot: {
            input_tokens: 10,
            output_tokens: 4,
            repeated_read_extra_calls: 3,
            adjacent_duplicate_tool_calls: 2
          },
          logPaths: {
            runner: "logs/nodes/impl/impl__efficiency-run__1/runner.log",
            agent: "logs/nodes/impl/impl__efficiency-run__1/agent.log",
            usage: "logs/nodes/impl/impl__efficiency-run__1/usage.json"
          }
        },
        {
          attemptId: "impl__efficiency-run__2",
          startedAt: "2026-01-01T00:01:30Z",
          finishedAt: "2026-01-01T00:02:00Z",
          outcome: "succeeded",
          exitCode: 0,
          runtime: "cursor",
          usageReliable: $reliable,
          usageSnapshot: {
            input_tokens: 6,
            output_tokens: 2,
            repeated_read_extra_calls: 1
          }
        }
      ]
    }
  ' >"$node_file"
}

@test "efficiency status default remains concise" {
  init_efficiency_status_run
  write_efficiency_status_node true

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^== COMPLETION =='
  printf '%s\n' "$output" | grep -q 'succeeded: 1'
  ! printf '%s\n' "$output" | grep -q '^impl '
  ! printf '%s\n' "$output" | grep -q 'efficiency:'
  ! printf '%s\n' "$output" | grep -q 'repeated-tool-calls'
  ! printf '%s\n' "$output" | grep -q 'retry=transient-runtime'
  ! printf '%s\n' "$output" | grep -q 'active=00:'
  ! printf '%s\n' "$output" | grep -q 'wait=00:'
}

@test "efficiency status details shows attempts elapsed active wait reliable usage retry classification and repeated-tool-call hints" {
  init_efficiency_status_run
  write_efficiency_status_node true

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --details
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'impl efficiency: attempts=2'
  printf '%s\n' "$output" | grep -q 'active=00:01:30'
  printf '%s\n' "$output" | grep -q 'wait=00:00:30'
  printf '%s\n' "$output" | grep -q 'retry=transient-runtime'
  printf '%s\n' "$output" | grep -q 'inputTokens'
  ! printf '%s\n' "$output" | grep -q 'impl efficiency:.*usage="n/a"'
  printf '%s\n' "$output" | grep -q 'repeated-tool-calls:'
  printf '%s\n' "$output" | grep -q 'repeated read'
  printf '%s\n' "$output" | grep -q 'adjacent duplicate tool call'
}

@test "efficiency status json includes attempts elapsed active wait reliable usage retry classification and repeated-tool-call hints" {
  init_efficiency_status_run
  write_efficiency_status_node true

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --json
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s\n' "$output" | jq -e '.nodes | map(select(.id == "impl")) | length == 1' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .attempts == 2' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .activeSeconds == 90' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .waitSeconds == 30' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .retryClassification == "transient-runtime"' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | (.usage | type) == "object"' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .usage.reliability == "authoritative"' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .usage.inputTokens == 16' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | (.repeatedToolCallHints | length) > 0' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .repeatedToolCallHints | any(test("repeated read"))' >/dev/null
  printf '%s\n' "$output" | jq -e '.efficiency.attempts == 2' >/dev/null
  printf '%s\n' "$output" | jq -e '.efficiency.activeSeconds == 90' >/dev/null
  printf '%s\n' "$output" | jq -e '.efficiency.waitSeconds == 30' >/dev/null
  printf '%s\n' "$output" | jq -e '.efficiency.retryClassifications == ["transient-runtime"]' >/dev/null
  printf '%s\n' "$output" | jq -e '(.efficiency.usage | type) == "object"' >/dev/null
}

@test "efficiency status details and json show n/a when usage is not reliable" {
  init_efficiency_status_run
  write_efficiency_status_node false

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --details
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'impl efficiency: attempts=2'
  printf '%s\n' "$output" | grep -q 'usage="n/a"'
  printf '%s\n' "$output" | grep -q 'retry=transient-runtime'
  printf '%s\n' "$output" | grep -q 'repeated-tool-calls:'

  run graph_status_run "$WORKSPACE" "$NAMESPACE" "$RUN_ID" --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .usage == "n/a"' >/dev/null
  printf '%s\n' "$output" | jq -e '.efficiency.usage == "n/a"' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .retryClassification == "transient-runtime"' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .activeSeconds == 90' >/dev/null
  printf '%s\n' "$output" | jq -e '.nodes[] | select(.id == "impl") | .waitSeconds == 30' >/dev/null
}
