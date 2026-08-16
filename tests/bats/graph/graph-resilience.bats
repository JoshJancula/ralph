#!/usr/bin/env bats
# Resilience schema, classified ordinary retry, active-time, and usage budgets.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/atomic-json.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-run-base.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-schedule.sh"

VALIDATE_GRAPH_SCHEMA_SH="$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/validate-graph-schema.sh"

setup() {
  TMPD="$(mktemp -d)"
  unset GRAPH_SCHEDULE_RETRY_NOW_EPOCH GRAPH_SCHEDULE_RETRY_NOW_ISO GRAPH_SCHEDULE_RETRY_SKIP_SLEEP 2>/dev/null || true
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD" 2>/dev/null || true
  unset GRAPH_SCHEDULE_RETRY_NOW_EPOCH GRAPH_SCHEDULE_RETRY_NOW_ISO GRAPH_SCHEDULE_RETRY_SKIP_SLEEP 2>/dev/null || true
  unset RALPH_GRAPH_STATE_ROOT RALPH_PLAN_WORKSPACE_ROOT GRAPH_DISPATCH_ORCHESTRATOR 2>/dev/null || true
  unset RALPH_ALLOW_NESTED_RUNS ORCHESTRATOR_RUNNER_TO_CONSOLE RALPH_MODE 2>/dev/null || true
  unset RALPH_ARTIFACT_NS RALPH_GRAPH_MAX_PARALLEL RALPH_GRAPH_MAX_PARALLEL_PER_RUNTIME 2>/dev/null || true
}

write_base_graph() {
  local dest="$1"
  cat >"$dest" <<'EOF'
{"schemaVersion":1,"ralphVersion":"1.0.0","name":"demo","namespace":"demo","maxParallel":2,"failurePolicy":"drain","nodes":[{"id":"n1","type":"stage","dependsOn":[],"derivedFrom":"stage","stage":{}},{"id":"n2","type":"stage","dependsOn":[],"derivedFrom":"stage","stage":{}}],"edges":[]}
EOF
}

merge_graph() {
  local dest="$1" extra="$2"
  jq -c --argjson extra "$extra" '. * $extra' "$dest" >"$dest.tmp" && mv "$dest.tmp" "$dest"
}

@test "resilience schema accepts omitted resilience and budgets as legacy fail-fast" {
  local graph_file="$TMPD/omitted.graph.json"
  write_base_graph "$graph_file"

  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -eq 0 ]

  run graph_schema_parse_resilience "$graph_file"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "fail-fast" ]
  [ "$(printf '%s' "$output" | jq -r '.transientRetries')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r '.correctiveRetries')" = "0" ]
  [ "$(printf '%s' "$output" | jq -r '.denialRecoveryTurns')" = "0" ]
  [ "$(printf '%s' "$output" | jq -c '.backoffSeconds')" = "[2,10]" ]

  run graph_schema_parse_budgets "$graph_file"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.maxAttempts')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.maxActiveSeconds')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.maxRunActiveSeconds')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.maxInputTokens')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.maxOutputTokens')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.maxEstimatedCostUsd')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.missingUsage')" = "warn" ]
}

@test "resilience schema applies conservative bounded defaults when resilience is present" {
  local graph_file="$TMPD/bounded.graph.json"
  write_base_graph "$graph_file"
  merge_graph "$graph_file" '{"resilience":{}}'

  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -eq 0 ]

  run graph_schema_parse_resilience "$graph_file"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "bounded" ]
  [ "$(printf '%s' "$output" | jq -r '.transientRetries')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.correctiveRetries')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.denialRecoveryTurns')" = "1" ]
  [ "$(printf '%s' "$output" | jq -c '.backoffSeconds')" = "[2,10]" ]
}

@test "resilience schema applies conservative active-time defaults without inventing token or cost ceilings" {
  local graph_file="$TMPD/budgets.graph.json"
  write_base_graph "$graph_file"
  merge_graph "$graph_file" '{"budgets":{}}'

  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -eq 0 ]

  run graph_schema_parse_budgets "$graph_file"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.maxActiveSeconds')" = "3600" ]
  [ "$(printf '%s' "$output" | jq -r '.maxRunActiveSeconds')" = "21600" ]
  [ "$(printf '%s' "$output" | jq -r '.maxAttempts')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.maxInputTokens')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.maxOutputTokens')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.maxEstimatedCostUsd')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.missingUsage')" = "warn" ]
}

@test "resilience schema accepts explicit retry backoff active-time token cost and missing-usage values" {
  local graph_file="$TMPD/explicit.graph.json"
  write_base_graph "$graph_file"
  merge_graph "$graph_file" '{
    "resilience": {
      "transientRetries": 3,
      "correctiveRetries": 1,
      "denialRecoveryTurns": 0,
      "backoffSeconds": [1, 8],
      "mode": "bounded"
    },
    "budgets": {
      "maxAttempts": 6,
      "maxActiveSeconds": 1200,
      "maxRunActiveSeconds": 7200,
      "maxInputTokens": 10000,
      "maxOutputTokens": 4000,
      "maxEstimatedCostUsd": 1.25,
      "missingUsage": "fail"
    }
  }'

  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -eq 0 ]

  run graph_schema_parse_resilience "$graph_file"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.transientRetries')" = "3" ]
  [ "$(printf '%s' "$output" | jq -r '.correctiveRetries')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.denialRecoveryTurns')" = "0" ]
  [ "$(printf '%s' "$output" | jq -c '.backoffSeconds')" = "[1,8]" ]
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "bounded" ]

  run graph_schema_parse_budgets "$graph_file"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.maxAttempts')" = "6" ]
  [ "$(printf '%s' "$output" | jq -r '.maxActiveSeconds')" = "1200" ]
  [ "$(printf '%s' "$output" | jq -r '.maxRunActiveSeconds')" = "7200" ]
  [ "$(printf '%s' "$output" | jq -r '.maxInputTokens')" = "10000" ]
  [ "$(printf '%s' "$output" | jq -r '.maxOutputTokens')" = "4000" ]
  [ "$(printf '%s' "$output" | jq -r '.maxEstimatedCostUsd')" = "1.25" ]
  [ "$(printf '%s' "$output" | jq -r '.missingUsage')" = "fail" ]
}

@test "resilience schema accepts pipeline-nested resilience and budgets" {
  local graph_file="$TMPD/pipeline.graph.json"
  write_base_graph "$graph_file"
  merge_graph "$graph_file" '{
    "pipeline": {
      "resilience": {"mode": "fail-fast"},
      "budgets": {"missingUsage": "zero", "maxActiveSeconds": 900}
    }
  }'

  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -eq 0 ]

  run graph_schema_parse_resilience "$graph_file"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "fail-fast" ]
  [ "$(printf '%s' "$output" | jq -r '.transientRetries')" = "0" ]

  run graph_schema_parse_budgets "$graph_file"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.missingUsage')" = "zero" ]
  [ "$(printf '%s' "$output" | jq -r '.maxActiveSeconds')" = "900" ]
  [ "$(printf '%s' "$output" | jq -r '.maxRunActiveSeconds')" = "21600" ]
}

@test "resilience schema node overrides win over graph defaults" {
  local graph_file="$TMPD/override.graph.json"
  write_base_graph "$graph_file"
  merge_graph "$graph_file" '{
    "resilience": {"transientRetries": 2, "mode": "bounded"},
    "budgets": {"maxActiveSeconds": 3600, "missingUsage": "warn"},
    "nodes": [
      {"id":"n1","type":"stage","dependsOn":[],"derivedFrom":"stage","stage":{},
       "resilience":{"transientRetries": 5},
       "budgets":{"maxActiveSeconds": 600, "missingUsage": "fail"}},
      {"id":"n2","type":"stage","dependsOn":[],"derivedFrom":"stage","stage":{}}
    ]
  }'

  run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
  [ "$status" -eq 0 ]

  run graph_schema_parse_resilience "$graph_file" n1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.transientRetries')" = "5" ]
  [ "$(printf '%s' "$output" | jq -r '.correctiveRetries')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.mode')" = "bounded" ]

  run graph_schema_parse_resilience "$graph_file" n2
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.transientRetries')" = "2" ]

  run graph_schema_parse_budgets "$graph_file" n1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.maxActiveSeconds')" = "600" ]
  [ "$(printf '%s' "$output" | jq -r '.missingUsage')" = "fail" ]
  [ "$(printf '%s' "$output" | jq -r '.maxRunActiveSeconds')" = "21600" ]
}

@test "resilience schema rejects negative retry counts backoff active-time token and cost values" {
  local graph_file="$TMPD/negative.graph.json" field
  for field in \
    '.resilience={"transientRetries":-1}' \
    '.resilience={"correctiveRetries":-1}' \
    '.resilience={"denialRecoveryTurns":-2}' \
    '.resilience={"backoffSeconds":[-1,10]}' \
    '.budgets={"maxActiveSeconds":-1}' \
    '.budgets={"maxRunActiveSeconds":-5}' \
    '.budgets={"maxAttempts":-1}' \
    '.budgets={"maxInputTokens":-3}' \
    '.budgets={"maxOutputTokens":-1}' \
    '.budgets={"maxEstimatedCostUsd":-0.01}'
  do
    write_base_graph "$graph_file"
    jq "$field" "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
    run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Graph schema validation failed:"* ]]
  done
}

@test "resilience schema rejects malformed retry backoff limit and policy values" {
  local graph_file="$TMPD/malformed.graph.json" field
  for field in \
    '.resilience={"transientRetries":"2"}' \
    '.resilience={"correctiveRetries":1.5}' \
    '.resilience={"backoffSeconds":[]}' \
    '.resilience={"backoffSeconds":[2,10,20]}' \
    '.resilience={"backoffSeconds":"2,10"}' \
    '.resilience={"mode":true}' \
    '.resilience=[]' \
    '.budgets={"maxInputTokens":"100"}' \
    '.budgets={"maxActiveSeconds":3.5}' \
    '.budgets={"maxEstimatedCostUsd":"1.25"}' \
    '.budgets={"missingUsage":1}' \
    '.budgets=null'
  do
    write_base_graph "$graph_file"
    jq "$field" "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
    run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Graph schema validation failed:"* ]]
  done
}

@test "resilience schema rejects unknown resilience and budget fields and enums" {
  local graph_file="$TMPD/unknown.graph.json" field
  for field in \
    '.resilience={"retryForever":true}' \
    '.resilience={"mode":"retry-forever"}' \
    '.budgets={"maxCost":1}' \
    '.budgets={"missingUsage":"treat-as-zero"}' \
    '.nodes[0].resilience={"extra":1}' \
    '.nodes[0].budgets={"maxRunActiveSeconds":100}'
  do
    write_base_graph "$graph_file"
    jq "$field" "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
    run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown"* || "$output" == *"must be"* ]]
  done
}

@test "resilience schema accepts missing-usage warn fail and zero" {
  local graph_file="$TMPD/usage.graph.json" policy
  for policy in warn fail zero; do
    write_base_graph "$graph_file"
    jq --arg policy "$policy" '.budgets = {missingUsage: $policy}' \
      "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
    run bash "$VALIDATE_GRAPH_SCHEMA_SH" "$graph_file"
    [ "$status" -eq 0 ]
    run graph_schema_parse_budgets "$graph_file"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.missingUsage')" = "$policy" ]
  done
}

@test "resilience schema parse rejects invalid objects" {
  run graph_schema_parse_resilience_object '{"transientRetries":-1}'
  [ "$status" -ne 0 ]

  run graph_schema_parse_budgets_object '{"missingUsage":"maybe"}'
  [ "$status" -ne 0 ]

  run graph_schema_parse_resilience_object '{"mode":"bounded","unknownKey":1}'
  [ "$status" -ne 0 ]
}

write_retry_graph() {
  local dest="$1"
  jq -n '
    {
      schemaVersion: 1,
      ralphVersion: "test",
      name: "resilience-retry",
      namespace: "resilience-retry",
      maxParallel: 1,
      failurePolicy: "drain",
      resilience: {
        mode: "bounded",
        transientRetries: 2,
        correctiveRetries: 2,
        denialRecoveryTurns: 0,
        backoffSeconds: [2, 10]
      },
      nodes: [{
        id: "impl",
        type: "agent",
        dependsOn: [],
        derivedFrom: "stage",
        stage: {
          id: "impl",
          runtime: "cursor",
          agent: "implementation",
          sessionResume: true,
          workspaceMode: "snapshot",
          outputArtifacts: [{path: "stub-output.md", required: true}],
          _inlineTodos: [{id: "impl-1", content: "work impl", status: "pending"}]
        }
      }],
      edges: []
    }
  ' >"$dest"
}

prepare_retry_ledger() {
  local graph_file="$1"
  local workspace="$TMPD/ws"
  local ns="resilience-retry"
  local run_id="run-retry-1"
  mkdir -p "$workspace"
  printf 'plan\n' >"$workspace/plan.md"
  graph_state_init_run_v2 "$workspace" "$ns" "$run_id" "$workspace/plan.md" "$graph_file" 1
  graph_schedule_load_index "$graph_file"
  GRAPH_SCHEDULE_GRAPH_JSON="$graph_file"
  GRAPH_SCHEDULE_WORKSPACE="$workspace"
  GRAPH_SCHEDULE_LEDGER_NAMESPACE="$ns"
  GRAPH_SCHEDULE_RUN_ID="$run_id"
  GRAPH_SCHEDULE_LEDGER_RUN_DIR="$(graph_state_run_dir "$workspace" "$ns" "$run_id")"
  GRAPH_SCHEDULE_NAMESPACE="$ns"
  GRAPH_SCHEDULE_LEDGER_SCHEMA_VERSION=""
  GRAPH_SCHEDULE_FAILED_NODE=""
  GRAPH_SCHEDULE_STOP_DISPATCH=0
  GRAPH_SCHEDULE_EXIT_CODE=0
}

record_failed_attempt() {
  local reason="${1:-timeout}"
  local aid="impl__${GRAPH_SCHEDULE_RUN_ID}__1"
  _graph_schedule_ledger_record "impl" "running" "$aid" "" "" "2026-08-13T00:00:00Z" "" "cursor" "off" ""
  _graph_schedule_ledger_record "impl" "failed" "$aid" "failed" "1" "" "2026-08-13T00:00:01Z" \
    "cursor" "off" "$reason"
  GRAPH_NODE_ATTEMPT_NUMBERS[$(graph_schedule_index_map_get impl)]="1"
  GRAPH_NODE_STATES[$(graph_schedule_index_map_get impl)]="failed"
  printf '%s\n' "$aid"
}

@test "resilience retry grants transient-runtime within configured limits and persists retry-wait" {
  local graph_file node_file aid idx
  graph_file="$TMPD/retry.graph.json"
  write_retry_graph "$graph_file"
  prepare_retry_ledger "$graph_file"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T00:16:40Z"
  aid="$(record_failed_attempt timeout)"

  rc=0
  graph_schedule_try_ordinary_retry "impl" 1 "timeout" "$aid" \
    '{"kind":"timeout","outcome":"failed","exitCode":1}' || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "retry-wait" ]
  [ -z "$GRAPH_SCHEDULE_FAILED_NODE" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 0 ]

  idx="$(graph_schedule_index_map_get impl)"
  [ "${GRAPH_NODE_TRANSIENT_RETRIES_USED[$idx]}" = "1" ]

  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.status' "$node_file")" = "retry-wait" ]
  [ "$(jq -r '.retry.classification' "$node_file")" = "transient-runtime" ]
  [ "$(jq -r '.retry.retryOrdinal' "$node_file")" = "1" ]
  [ "$(jq -r '.retry.backoffSeconds' "$node_file")" = "2" ]
  [ "$(jq -r '.retry.scheduledAt' "$node_file")" = "2026-08-13T00:16:40Z" ]
  [ "$(jq -r '.retry.retryAt' "$node_file")" = "2026-08-13T00:16:42Z" ]
  [ "$(jq -r '.retry.transientUsed' "$node_file")" = "1" ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "failed" ]
}

@test "resilience retry grants agent-correctable within configured limits and persists retry-wait" {
  local graph_file node_file aid idx record
  graph_file="$TMPD/retry.graph.json"
  write_retry_graph "$graph_file"
  prepare_retry_ledger "$graph_file"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T00:33:20Z"
  aid="$(record_failed_attempt artifact-publish-failed)"
  record="$(graph_schedule_write_correction_record "$GRAPH_SCHEDULE_LEDGER_RUN_DIR" "impl" "1" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["stub-output.md"]}')"
  [ -f "$record" ]

  rc=0
  graph_schedule_try_ordinary_retry "impl" 1 "artifact-publish-failed" "$aid" \
    '{"kind":"artifact-publish-failed","missingArtifacts":["stub-output.md"]}' || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "retry-wait" ]

  idx="$(graph_schedule_index_map_get impl)"
  [ "${GRAPH_NODE_CORRECTIVE_RETRIES_USED[$idx]}" = "1" ]

  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.status' "$node_file")" = "retry-wait" ]
  [ "$(jq -r '.retry.classification' "$node_file")" = "agent-correctable" ]
  [ "$(jq -r '.retry.retryOrdinal' "$node_file")" = "1" ]
  [ "$(jq -r '.retry.backoffSeconds' "$node_file")" = "2" ]
  [ "$(jq -r '.retry.correctiveUsed' "$node_file")" = "1" ]
  [ "$(jq -r '.retry.retryAt' "$node_file")" = "2026-08-13T00:33:22Z" ]
}

@test "resilience retry uses deterministic capped backoff" {
  [ "$(graph_schedule_retry_backoff_seconds 1 '[2,10]')" = "2" ]
  [ "$(graph_schedule_retry_backoff_seconds 2 '[2,10]')" = "4" ]
  [ "$(graph_schedule_retry_backoff_seconds 3 '[2,10]')" = "8" ]
  [ "$(graph_schedule_retry_backoff_seconds 4 '[2,10]')" = "10" ]
  [ "$(graph_schedule_retry_backoff_seconds 5 '[2,10]')" = "10" ]
  [ "$(graph_schedule_retry_backoff_seconds 1 '[1,8]')" = "1" ]
  [ "$(graph_schedule_retry_backoff_seconds 2 '[1,8]')" = "2" ]
  [ "$(graph_schedule_retry_backoff_seconds 4 '[1,8]')" = "8" ]
  [ "$(graph_schedule_retry_backoff_seconds 1 '[0,0]')" = "0" ]

  local graph_file aid node_file
  graph_file="$TMPD/retry.graph.json"
  write_retry_graph "$graph_file"
  jq '.resilience.backoffSeconds = [2,10]' "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T00:50:00Z"
  aid="$(record_failed_attempt timeout)"
  graph_schedule_try_ordinary_retry "impl" 1 "timeout" "$aid" '{"kind":"timeout"}'
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T00:50:02Z"
  graph_schedule_release_due_retry_waits
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]
  GRAPH_NODE_STATES[$(graph_schedule_index_map_get impl)]="running"
  _graph_schedule_ledger_record "impl" "running" "impl__${GRAPH_SCHEDULE_RUN_ID}__2" \
    "" "" "2026-08-13T00:50:02Z" "" "cursor" "off" ""
  GRAPH_NODE_STATES[$(graph_schedule_index_map_get impl)]="failed"
  _graph_schedule_ledger_record "impl" "failed" "impl__${GRAPH_SCHEDULE_RUN_ID}__2" "failed" "1" \
    "" "2026-08-13T00:50:03Z" "cursor" "off" "timeout"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T00:50:03Z"
  graph_schedule_try_ordinary_retry "impl" 1 "timeout" "impl__${GRAPH_SCHEDULE_RUN_ID}__2" \
    '{"kind":"timeout"}'
  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.retry.retryOrdinal' "$node_file")" = "2" ]
  [ "$(jq -r '.retry.backoffSeconds' "$node_file")" = "4" ]
  [ "$(jq -r '.retry.retryAt' "$node_file")" = "2026-08-13T00:50:07Z" ]
}

@test "resilience retry refuses operator plan-contract configuration integrity and cancelled" {
  local graph_file class report
  graph_file="$TMPD/retry.graph.json"
  write_retry_graph "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt "denied"

  for class in operator-permission plan-contract terminal-configuration integrity cancelled; do
    case "$class" in
      operator-permission) report='{"exitCode":4,"permissionRequest":{"tool":"Bash"}}' ;;
      plan-contract) report='{"kind":"undeclared-path","undeclaredPaths":["secret.txt"]}' ;;
      terminal-configuration) report='{"kind":"invalid-model"}' ;;
      integrity) report='{"kind":"sandbox-violation"}' ;;
      cancelled) report='{"outcome":"cancelled"}' ;;
    esac
    run graph_schedule_ordinary_retry_eligible "$class"
    [ "$status" -ne 0 ]
    run graph_schedule_try_ordinary_retry "impl" 1 "$class" "impl__run-retry-1__1" "$report"
    [ "$status" -ne 0 ]
    [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]
  done

  local node_file
  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.status' "$node_file")" = "failed" ]
  [ "$(jq -r '.retry // empty' "$node_file")" = "" ]
}

@test "resilience retry exhausts after configured limit" {
  local graph_file idx aid
  graph_file="$TMPD/retry.graph.json"
  write_retry_graph "$graph_file"
  jq '.resilience.transientRetries = 1 | .resilience.backoffSeconds = [0,0]' \
    "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T01:06:40Z"
  aid="$(record_failed_attempt timeout)"

  graph_schedule_try_ordinary_retry "impl" 1 "timeout" "$aid" '{"kind":"timeout"}'
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]
  idx="$(graph_schedule_index_map_get impl)"
  [ "${GRAPH_NODE_TRANSIENT_RETRIES_USED[$idx]}" = "1" ]

  GRAPH_NODE_STATES[$idx]="failed"
  run graph_schedule_try_ordinary_retry "impl" 1 "timeout" "impl__${GRAPH_SCHEDULE_RUN_ID}__2" \
    '{"kind":"timeout"}'
  [ "$status" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]
  [ "${GRAPH_NODE_TRANSIENT_RETRIES_USED[$idx]}" = "1" ]
}

@test "resilience retry fail-fast grants no ordinary retry" {
  local graph_file
  graph_file="$TMPD/retry.graph.json"
  write_base_graph "$graph_file"
  jq '.nodes = [{
    id:"impl",type:"agent",dependsOn:[],derivedFrom:"stage",
    stage:{id:"impl",runtime:"cursor",agent:"implementation",workspaceMode:"snapshot",
      outputArtifacts:[{path:"stub-output.md",required:true}],
      _inlineTodos:[{id:"impl-1",content:"work",status:"pending"}]}
  }] | .namespace = "resilience-retry" | .name = "resilience-retry"' \
    "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  run graph_schedule_try_ordinary_retry "impl" 1 "timeout" "impl__run-retry-1__1" \
    '{"kind":"timeout"}'
  [ "$status" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]
}

@test "resilience retry releases persisted wait after backoff elapses" {
  local graph_file node_file aid
  graph_file="$TMPD/retry.graph.json"
  write_retry_graph "$graph_file"
  prepare_retry_ledger "$graph_file"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T01:23:20Z"
  aid="$(record_failed_attempt timeout)"
  graph_schedule_try_ordinary_retry "impl" 1 "timeout" "$aid" '{"kind":"timeout"}'
  [ "$(graph_schedule_node_state_by_id impl)" = "retry-wait" ]

  graph_schedule_release_due_retry_waits
  [ "$(graph_schedule_node_state_by_id impl)" = "retry-wait" ]

  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T01:23:22Z"
  graph_schedule_release_due_retry_waits
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]

  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.status' "$node_file")" = "pending" ]
  [ "$(jq -r '.retry.transientUsed' "$node_file")" = "1" ]
  [ "$(jq '.attempts | length' "$node_file")" -eq 1 ]
}

@test "resilience retry scheduler requeues transient-runtime after zero backoff" {
  local graph_file state_root run_id run_dir orch node_file
  graph_file="$TMPD/retry.graph.json"
  write_retry_graph "$graph_file"
  jq '.resilience.backoffSeconds = [0,0] | .resilience.transientRetries = 1' \
    "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"

  DISPATCH_WORKSPACE="$TMPD/workspace"
  mkdir -p "$DISPATCH_WORKSPACE/.ralph" "$DISPATCH_WORKSPACE/.ralph-workspace"
  printf 'plan\n' >"$DISPATCH_WORKSPACE/resilience-retry.plan.md"
  printf 'source\n' >"$DISPATCH_WORKSPACE/src.txt"

  orch="$TMPD/orchestrator.sh"
  cat >"$orch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
attempt=""
stage=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--attempt-id" ]]; then
    attempt="$arg"
  elif [[ "$prev" == "--single-stage" ]]; then
    stage="$arg"
  fi
  prev="$arg"
done
workspace="${RALPH_AGENT_WORKSPACE:-$PWD}"
ns="${RALPH_ARTIFACT_NS:-resilience-retry}"
state_root="${RALPH_PLAN_WORKSPACE_ROOT:?}"
report="$state_root/artifacts/$ns/stage-outcomes/${attempt}.json"
mkdir -p "$(dirname "$report")"
if [[ "$attempt" == *__2 ]]; then
  printf 'stub artifact\n' >"$workspace/stub-output.md"
  printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"resilience-retry-run\",\"stageId\":\"$stage\",\"attemptId\":\"$attempt\",\"outcome\":\"success\",\"exitCode\":0,\"startedAt\":\"2026-08-13T00:00:02Z\",\"finishedAt\":\"2026-08-13T00:00:03Z\"}" >"$report"
  exit 0
fi
printf '%s\n' "{\"schemaVersion\":1,\"runId\":\"resilience-retry-run\",\"stageId\":\"$stage\",\"attemptId\":\"$attempt\",\"outcome\":\"failed\",\"exitCode\":1,\"kind\":\"timeout\",\"startedAt\":\"2026-08-13T00:00:00Z\",\"finishedAt\":\"2026-08-13T00:00:01Z\"}" >"$report"
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
  run_id="resilience-retry-run"
  export RALPH_GRAPH_STATE_ROOT="$state_root"
  export RALPH_PLAN_WORKSPACE_ROOT="$state_root"
  graph_state_init_run_v2 "$DISPATCH_WORKSPACE" resilience-retry "$run_id" \
    "$DISPATCH_WORKSPACE/resilience-retry.plan.md" "$graph_file" 1
  run_dir="$state_root/graph-runs/resilience-retry/$run_id"
  graph_run_base_prepare "$run_dir" \
    "$(jq -cn --arg project "$DISPATCH_WORKSPACE" --arg state "$state_root" \
      '{projectRoot:$project,stateRoot:$state,agentWorkspace:$project}')" \
    '["snapshot"]'
  graph_workspace_prepare_run "$run_dir" "$graph_file"

  graph_schedule_run "$graph_file" "$run_id" "$DISPATCH_WORKSPACE" "$run_dir"
  [ "$GRAPH_SCHEDULE_EXIT_CODE" -eq 0 ]

  node_file="$(graph_state_node_file "$DISPATCH_WORKSPACE" resilience-retry "$run_id" impl)"
  [ "$(jq '.attempts | length' "$node_file")" -eq 2 ]
  [ "$(jq -r '.attempts[0].outcome' "$node_file")" = "failed" ]
  [ "$(jq -r '.attempts[1].outcome' "$node_file")" = "success" ]
  [ "$(jq -r '.status' "$node_file")" = "succeeded" ]
  [ "$(jq -r '.retry.classification' "$node_file")" = "transient-runtime" ]
  [ "$(jq -r '.retry.transientUsed' "$node_file")" = "1" ]
}

write_active_time_graph() {
  local dest="$1"
  write_retry_graph "$dest"
  jq '.budgets = {maxActiveSeconds: 3600, maxRunActiveSeconds: 21600}' \
    "$dest" >"$dest.tmp" && mv "$dest.tmp" "$dest"
}

@test "resilience active time accumulates across attempts and excludes operator wait" {
  local graph_file idx
  graph_file="$TMPD/active.graph.json"
  write_active_time_graph "$graph_file"
  prepare_retry_ledger "$graph_file"
  idx="$(graph_schedule_index_map_get impl)"

  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T02:00:00Z"
  graph_schedule_start_active_clock impl "2026-08-13T02:00:00Z"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T02:00:05Z"
  graph_schedule_commit_active_time impl
  [ "$(graph_schedule_node_active_seconds impl)" = "5" ]

  GRAPH_NODE_STATES[$idx]="running"
  graph_schedule_apply_operator_permission impl 4 "operator-permission" \
    "impl__${GRAPH_SCHEDULE_RUN_ID}__1" '{"exitCode":4,"permissionRequest":{"tool":"Bash"}}'
  [ "$(graph_schedule_node_state_by_id impl)" = "awaiting-operator" ]
  [ -z "${GRAPH_NODE_ACTIVE_STARTED_AT[$idx]:-}" ]

  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T02:10:00Z"
  [ "$(graph_schedule_node_active_seconds impl)" = "5" ]

  graph_schedule_start_active_clock impl "2026-08-13T02:10:00Z"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T02:10:03Z"
  graph_schedule_commit_active_time impl
  [ "$(graph_schedule_node_active_seconds impl)" = "8" ]
  [ "${GRAPH_NODE_ACTIVE_SECONDS[$idx]}" = "8" ]
}

@test "resilience active time excludes checkpoint wait and retry backoff" {
  local graph_file idx aid
  graph_file="$TMPD/active.graph.json"
  write_active_time_graph "$graph_file"
  jq '.resilience.backoffSeconds = [2,10]' "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  idx="$(graph_schedule_index_map_get impl)"

  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T03:00:00Z"
  graph_schedule_start_active_clock impl
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T03:00:04Z"
  graph_schedule_commit_active_time impl
  [ "$(graph_schedule_node_active_seconds impl)" = "4" ]

  GRAPH_NODE_TYPES[$idx]="checkpoint"
  GRAPH_NODE_STATES[$idx]="pending"
  GRAPH_SCHEDULE_NAMESPACE="${GRAPH_SCHEDULE_LEDGER_NAMESPACE}"
  _graph_schedule_handle_checkpoint_node impl
  [ "$(graph_schedule_node_state_by_id impl)" = "awaiting-ack" ]
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T03:05:00Z"
  [ "$(graph_schedule_node_active_seconds impl)" = "4" ]

  GRAPH_NODE_TYPES[$idx]="agent"
  GRAPH_NODE_STATES[$idx]="failed"
  aid="$(record_failed_attempt timeout)"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T03:05:00Z"
  graph_schedule_try_ordinary_retry impl 1 "timeout" "$aid" '{"kind":"timeout"}'
  [ "$(graph_schedule_node_state_by_id impl)" = "retry-wait" ]
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T03:05:02Z"
  [ "$(graph_schedule_node_active_seconds impl)" = "4" ]

  graph_schedule_release_due_retry_waits
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]
  graph_schedule_start_active_clock impl "2026-08-13T03:05:02Z"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T03:05:04Z"
  graph_schedule_commit_active_time impl
  [ "$(graph_schedule_node_active_seconds impl)" = "6" ]
}

@test "resilience active time persists committed seconds for resume" {
  local graph_file node_file idx
  graph_file="$TMPD/active.graph.json"
  write_active_time_graph "$graph_file"
  prepare_retry_ledger "$graph_file"
  idx="$(graph_schedule_index_map_get impl)"

  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T04:00:00Z"
  graph_schedule_start_active_clock impl
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T04:00:07Z"
  graph_schedule_commit_active_time impl
  [ "$(graph_schedule_node_active_seconds impl)" = "7" ]

  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.budget.activeSeconds' "$node_file")" = "7" ]
  [ "$(jq -r '.budget.activeStartedAt' "$node_file")" = "null" ]

  GRAPH_NODE_ACTIVE_SECONDS[$idx]="0"
  GRAPH_NODE_ACTIVE_STARTED_AT[$idx]=""
  [ "$(graph_schedule_node_active_seconds impl)" = "0" ]

  _graph_schedule_restore_active_time
  [ "${GRAPH_NODE_ACTIVE_SECONDS[$idx]}" = "7" ]
  [ -z "${GRAPH_NODE_ACTIVE_STARTED_AT[$idx]:-}" ]
  [ "$(graph_schedule_node_active_seconds impl)" = "7" ]

  graph_schedule_start_active_clock impl "2026-08-13T04:00:07Z"
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T04:00:10Z"
  [ "$(graph_schedule_node_active_seconds impl)" = "10" ]
  graph_schedule_start_active_clock impl "2026-08-13T04:00:20Z"
  [ "$(graph_schedule_node_active_seconds impl)" = "10" ]
}

@test "resilience active time exhaustion terminalizes through classifier and emits event" {
  local graph_file node_file events classified
  graph_file="$TMPD/active.graph.json"
  write_active_time_graph "$graph_file"
  jq '.budgets.maxActiveSeconds = 5 | .resilience.transientRetries = 2' \
    "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T05:00:00Z"
  graph_schedule_start_active_clock impl
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T05:00:05Z"
  graph_schedule_commit_active_time impl
  [ "$(graph_schedule_node_active_seconds impl)" = "5" ]
  graph_schedule_active_time_exhausted impl

  rc=0
  graph_schedule_try_ordinary_retry impl 1 "timeout" \
    "impl__${GRAPH_SCHEDULE_RUN_ID}__1" '{"kind":"timeout"}' || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 1 ]

  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.budget.activeSeconds' "$node_file")" = "5" ]
  [ "$(jq -r '.budget.exhausted' "$node_file")" = "true" ]
  [ "$(jq -r '.budget.classification' "$node_file")" = "terminal-configuration" ]
  [ "$(jq -r '.budget.scope' "$node_file")" = "maxActiveSeconds" ]

  classified="$(graph_failure_classify "$(jq -nc '{
    class:"terminal-configuration",kind:"configuration",reason:"budget-exhausted",outcome:"failed"
  }')")"
  [ "$(printf '%s' "$classified" | jq -r '.classification')" = "terminal-configuration" ]
  [ "$(printf '%s' "$classified" | jq -r '.retryable')" = "false" ]

  events="$GRAPH_SCHEDULE_LEDGER_RUN_DIR/events.jsonl"
  [ -f "$events" ]
  [ "$(jq -s '[.[] | select(.event == "budget-exhausted")] | length' "$events")" -ge 1 ]
  [ "$(jq -s -r '[.[] | select(.event == "budget-exhausted")] | last | .details.classification' "$events")" = "terminal-configuration" ]
  [ "$(jq -s -r '[.[] | select(.event == "budget-exhausted")] | last | .details.retryable' "$events")" = "false" ]
}

@test "resilience active time omitted budgets do not enforce a limit" {
  local graph_file node_file
  graph_file="$TMPD/active.graph.json"
  write_retry_graph "$graph_file"
  jq 'del(.budgets) | .resilience.backoffSeconds = [0,0]' \
    "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T06:00:00Z"
  graph_schedule_start_active_clock impl
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T07:00:00Z"
  graph_schedule_commit_active_time impl
  [ "$(graph_schedule_node_active_seconds impl)" = "3600" ]
  run graph_schedule_active_time_exhausted impl
  [ "$status" -ne 0 ]

  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T07:00:00Z"
  rc=0
  graph_schedule_try_ordinary_retry impl 1 "timeout" \
    "impl__${GRAPH_SCHEDULE_RUN_ID}__1" '{"kind":"timeout"}' || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]
  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.budget.exhausted // false' "$node_file")" = "false" ]
}

@test "resilience active time run budget exhaustion stops further attempts" {
  local graph_file node_file
  graph_file="$TMPD/active.graph.json"
  write_active_time_graph "$graph_file"
  jq '.budgets = {maxActiveSeconds: 3600, maxRunActiveSeconds: 5} | .resilience.transientRetries = 2' \
    "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T08:00:00Z"
  graph_schedule_start_active_clock impl
  export GRAPH_SCHEDULE_RETRY_NOW_ISO="2026-08-13T08:00:05Z"
  graph_schedule_commit_active_time impl
  [ "$(graph_schedule_run_active_seconds)" = "5" ]
  graph_schedule_active_time_exhausted impl

  rc=0
  graph_schedule_try_ordinary_retry impl 1 "timeout" \
    "impl__${GRAPH_SCHEDULE_RUN_ID}__1" '{"kind":"timeout"}' || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 1 ]

  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.budget.exhausted' "$node_file")" = "true" ]
  [ "$(jq -r '.budget.scope' "$node_file")" = "maxRunActiveSeconds" ]
  [ "$(jq -s '[.[] | select(.event == "budget-exhausted")] | length' \
    "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/events.jsonl")" -ge 1 ]
}

write_usage_graph() {
  local dest="$1"
  write_retry_graph "$dest"
  jq '.budgets = {
    maxInputTokens: 1000,
    maxOutputTokens: 400,
    maxEstimatedCostUsd: 1.25,
    missingUsage: "warn"
  }' "$dest" >"$dest.tmp" && mv "$dest.tmp" "$dest"
}

@test "resilience usage budget aggregates reliable usage without double-counting attempts" {
  local graph_file usage node_file
  graph_file="$TMPD/usage.graph.json"
  write_usage_graph "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  graph_schedule_record_attempt_usage impl "impl__${GRAPH_SCHEDULE_RUN_ID}__1" \
    '{"inputTokens":100,"outputTokens":20,"estimatedCostUsd":0.10}' true
  graph_schedule_record_attempt_usage impl "impl__${GRAPH_SCHEDULE_RUN_ID}__1" \
    '{"inputTokens":100,"outputTokens":20,"estimatedCostUsd":0.10}' true
  graph_schedule_record_attempt_usage impl "impl__${GRAPH_SCHEDULE_RUN_ID}__2" \
    '{"input_tokens":50,"output_tokens":10,"estimated_cost_usd":0.05}' true

  usage="$(graph_schedule_node_usage impl)"
  [ "$(printf '%s' "$usage" | jq -r '.inputTokens')" = "150" ]
  [ "$(printf '%s' "$usage" | jq -r '.outputTokens')" = "30" ]
  [ "$(printf '%s' "$usage" | jq -r '.estimatedCostUsd == 0.15')" = "true" ]
  [ "$(printf '%s' "$usage" | jq -r '.reliability')" = "authoritative" ]
  [ "$(printf '%s' "$usage" | jq '.countedAttemptIds | length')" -eq 2 ]

  GRAPH_NODE_USAGE_JSON[$(graph_schedule_index_map_get impl)]=""
  [ "$(graph_schedule_node_usage impl | jq -r '.inputTokens')" = "null" ]
  _graph_schedule_restore_usage
  usage="$(graph_schedule_node_usage impl)"
  [ "$(printf '%s' "$usage" | jq -r '.inputTokens')" = "150" ]
  [ "$(printf '%s' "$usage" | jq '.countedAttemptIds | length')" -eq 2 ]

  graph_schedule_record_attempt_usage impl "impl__${GRAPH_SCHEDULE_RUN_ID}__1" \
    '{"inputTokens":999}' true
  [ "$(graph_schedule_node_usage impl | jq -r '.inputTokens')" = "150" ]

  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.budget.usage.reliability' "$node_file")" = "authoritative" ]
  [ "$(jq -r '.budget.usage.inputTokens' "$node_file")" = "150" ]
}

@test "resilience usage budget missing usage warn does not treat missing as zero" {
  local graph_file usage node_file events
  graph_file="$TMPD/usage.graph.json"
  write_usage_graph "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  graph_schedule_record_attempt_usage impl "impl__${GRAPH_SCHEDULE_RUN_ID}__1" "" false
  usage="$(graph_schedule_node_usage impl)"
  [ "$(printf '%s' "$usage" | jq -r '.inputTokens')" = "null" ]
  [ "$(printf '%s' "$usage" | jq -r '.outputTokens')" = "null" ]
  [ "$(printf '%s' "$usage" | jq -r '.estimatedCostUsd')" = "null" ]
  [ "$(printf '%s' "$usage" | jq -r '.reliability')" = "unavailable" ]
  [ "$(printf '%s' "$usage" | jq -r '.missingAttempts')" = "1" ]
  [ "$(printf '%s' "$usage" | jq -r '.warned')" = "true" ]
  run graph_schedule_usage_should_stop impl
  [ "$status" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]

  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.budget.usage.inputTokens' "$node_file")" = "null" ]
  [ "$(jq -r '.budget.usage.reliability' "$node_file")" = "unavailable" ]
  [ "$(jq -r '.budget.exhausted // false' "$node_file")" = "false" ]

  events="$GRAPH_SCHEDULE_LEDGER_RUN_DIR/events.jsonl"
  [ -f "$events" ]
  [ "$(jq -s '[.[] | select(.event == "budget-warning")] | length' "$events")" -ge 1 ]
  [ "$(jq -s -r '[.[] | select(.event == "budget-warning")] | last | .details.budget' "$events")" = "missingUsage" ]
  [ "$(jq -s -r '[.[] | select(.event == "budget-warning")] | last | .details.reliability' "$events")" = "unavailable" ]
  [ "$(jq -s '[.[] | select(.event == "budget-exhausted")] | length' "$events")" -eq 0 ]
}

@test "resilience usage budget missing usage fail terminalizes through classifier" {
  local graph_file node_file events classified
  graph_file="$TMPD/usage.graph.json"
  write_usage_graph "$graph_file"
  jq '.budgets.missingUsage = "fail"' "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  graph_schedule_record_attempt_usage impl "impl__${GRAPH_SCHEDULE_RUN_ID}__1" "" false
  [ "$(graph_schedule_node_usage impl | jq -r '.inputTokens')" = "null" ]
  [ "$(graph_schedule_node_usage impl | jq -r '.reliability')" = "unavailable" ]
  graph_schedule_usage_should_stop impl
  [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 1 ]

  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.budget.exhausted' "$node_file")" = "true" ]
  [ "$(jq -r '.budget.scope' "$node_file")" = "missingUsage" ]
  [ "$(jq -r '.budget.classification' "$node_file")" = "terminal-configuration" ]
  [ "$(jq -r '.budget.usageReliability' "$node_file")" = "unavailable" ]
  [ "$(jq -r '.budget.usage.reliability' "$node_file")" = "unavailable" ]

  classified="$(graph_failure_classify "$(jq -nc '{
    class:"terminal-configuration",kind:"configuration",reason:"budget-exhausted",outcome:"failed"
  }')")"
  [ "$(printf '%s' "$classified" | jq -r '.classification')" = "terminal-configuration" ]
  [ "$(printf '%s' "$classified" | jq -r '.retryable')" = "false" ]

  events="$GRAPH_SCHEDULE_LEDGER_RUN_DIR/events.jsonl"
  [ "$(jq -s '[.[] | select(.event == "budget-exhausted")] | length' "$events")" -ge 1 ]
  [ "$(jq -s -r '[.[] | select(.event == "budget-exhausted")] | last | .details.reliability' "$events")" = "unavailable" ]
  [ "$(jq -s -r '[.[] | select(.event == "budget-exhausted")] | last | .details.retryable' "$events")" = "false" ]
}

@test "resilience usage budget missing usage zero counts as zero" {
  local graph_file usage
  graph_file="$TMPD/usage.graph.json"
  write_usage_graph "$graph_file"
  jq '.budgets.missingUsage = "zero"' "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  graph_schedule_record_attempt_usage impl "impl__${GRAPH_SCHEDULE_RUN_ID}__1" "" false
  usage="$(graph_schedule_node_usage impl)"
  [ "$(printf '%s' "$usage" | jq -r '.inputTokens')" = "0" ]
  [ "$(printf '%s' "$usage" | jq -r '.outputTokens')" = "0" ]
  [ "$(printf '%s' "$usage" | jq -r '.estimatedCostUsd')" = "0" ]
  [ "$(printf '%s' "$usage" | jq -r '.missingAttempts')" = "1" ]
  run graph_schedule_usage_should_stop impl
  [ "$status" -ne 0 ]
  [ "$(jq -s '[.[] | select(.event == "budget-warning")] | length' \
    "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/events.jsonl")" -eq 0 ]
  [ "$(jq -s '[.[] | select(.event == "budget-exhausted")] | length' \
    "$GRAPH_SCHEDULE_LEDGER_RUN_DIR/events.jsonl")" -eq 0 ]
}

@test "resilience usage budget exhaustion emits event and exposes reliability" {
  local graph_file node_file events
  graph_file="$TMPD/usage.graph.json"
  write_usage_graph "$graph_file"
  jq '.budgets.maxInputTokens = 100 | .resilience.transientRetries = 2' \
    "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  graph_schedule_record_attempt_usage impl "impl__${GRAPH_SCHEDULE_RUN_ID}__1" \
    '{"inputTokens":100,"outputTokens":5}' true
  [ "$(graph_schedule_node_usage impl | jq -r '.inputTokens')" = "100" ]
  [ "$(graph_schedule_node_usage impl | jq -r '.reliability')" = "authoritative" ]
  graph_schedule_usage_should_stop impl
  [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]
  [ "$GRAPH_SCHEDULE_STOP_DISPATCH" -eq 1 ]

  rc=0
  graph_schedule_try_ordinary_retry impl 1 "timeout" \
    "impl__${GRAPH_SCHEDULE_RUN_ID}__1" '{"kind":"timeout"}' || rc=$?
  [ "$rc" -ne 0 ]

  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.budget.exhausted' "$node_file")" = "true" ]
  [ "$(jq -r '.budget.scope' "$node_file")" = "maxInputTokens" ]
  [ "$(jq -r '.budget.classification' "$node_file")" = "terminal-configuration" ]
  [ "$(jq -r '.budget.usageReliability' "$node_file")" = "authoritative" ]
  [ "$(jq -r '.budget.usage.reliability' "$node_file")" = "authoritative" ]
  [ "$(jq -r '.budget.usage.inputTokens' "$node_file")" = "100" ]

  events="$GRAPH_SCHEDULE_LEDGER_RUN_DIR/events.jsonl"
  [ "$(jq -s '[.[] | select(.event == "budget-exhausted")] | length' "$events")" -ge 1 ]
  [ "$(jq -s -r '[.[] | select(.event == "budget-exhausted")] | last | .details.classification' "$events")" = "terminal-configuration" ]
  [ "$(jq -s -r '[.[] | select(.event == "budget-exhausted")] | last | .details.reliability' "$events")" = "authoritative" ]
  [ "$(jq -s -r '[.[] | select(.event == "budget-exhausted")] | last | .details.retryable' "$events")" = "false" ]
}

@test "resilience usage budget estimated usage warns and does not hard-stop" {
  local graph_file usage events
  graph_file="$TMPD/usage.graph.json"
  write_usage_graph "$graph_file"
  jq '.budgets.maxInputTokens = 50' "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  graph_schedule_record_attempt_usage impl "impl__${GRAPH_SCHEDULE_RUN_ID}__1" \
    '{"inputTokens":80,"reliability":"estimated"}' false
  usage="$(graph_schedule_node_usage impl)"
  [ "$(printf '%s' "$usage" | jq -r '.inputTokens')" = "null" ]
  [ "$(printf '%s' "$usage" | jq -r '.reliability')" = "estimated" ]
  run graph_schedule_usage_should_stop impl
  [ "$status" -ne 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "failed" ]
  [ "$(jq -r '.budget.exhausted // false' "$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)")" = "false" ]

  events="$GRAPH_SCHEDULE_LEDGER_RUN_DIR/events.jsonl"
  [ "$(jq -s '[.[] | select(.event == "budget-warning")] | length' "$events")" -ge 1 ]
  [ "$(jq -s -r '[.[] | select(.event == "budget-warning")] | last | .details.budget' "$events")" = "estimated" ]
  [ "$(jq -s '[.[] | select(.event == "budget-exhausted")] | length' "$events")" -eq 0 ]
}

@test "resilience usage budget omitted ceilings do not enforce token limits" {
  local graph_file node_file
  graph_file="$TMPD/usage.graph.json"
  write_retry_graph "$graph_file"
  jq 'del(.budgets) | .resilience.backoffSeconds = [0,0]' \
    "$graph_file" >"$graph_file.tmp" && mv "$graph_file.tmp" "$graph_file"
  prepare_retry_ledger "$graph_file"
  record_failed_attempt timeout

  graph_schedule_record_attempt_usage impl "impl__${GRAPH_SCHEDULE_RUN_ID}__1" \
    '{"inputTokens":99999,"outputTokens":99999,"estimatedCostUsd":99}' true
  [ "$(graph_schedule_node_usage impl | jq -r '.inputTokens')" = "99999" ]
  [ "$(graph_schedule_node_usage impl | jq -r '.reliability')" = "authoritative" ]
  run graph_schedule_usage_should_stop impl
  [ "$status" -ne 0 ]

  rc=0
  graph_schedule_try_ordinary_retry impl 1 "timeout" \
    "impl__${GRAPH_SCHEDULE_RUN_ID}__1" '{"kind":"timeout"}' || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(graph_schedule_node_state_by_id impl)" = "pending" ]
  node_file="$(graph_state_node_file "$GRAPH_SCHEDULE_WORKSPACE" \
    "$GRAPH_SCHEDULE_LEDGER_NAMESPACE" "$GRAPH_SCHEDULE_RUN_ID" impl)"
  [ "$(jq -r '.budget.exhausted // false' "$node_file")" = "false" ]
}
