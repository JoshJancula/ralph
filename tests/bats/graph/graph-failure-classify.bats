#!/usr/bin/env bats
# Structured-report and legacy-text-fallback tests for the graph failure classifier.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-failure-classify.sh"

PRODUCTION_FIXTURE_DIR="$BATS_TEST_DIRNAME/../../fixtures/graph-production-failure"

assert_classification() {
  local json="$1" class="$2" retryable="$3" action="$4"
  [ "$(printf '%s' "$json" | jq -r '.classification')" = "$class" ]
  [ "$(printf '%s' "$json" | jq -r '.retryable')" = "$retryable" ]
  [ "$(printf '%s' "$json" | jq -r '.operatorAction')" = "$action" ]
  [ "$(printf '%s' "$json" | jq -r '.summary | type')" = "string" ]
  [ "$(printf '%s' "$json" | jq -r '.summary | length')" -le "${GRAPH_FAILURE_SUMMARY_MAX:-200}" ]
}

@test "failure structured class transient-runtime from network kind" {
  run graph_failure_classify '{"kind":"network","summary":"provider connection reset"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "transient-runtime" "true" "none"
  [ "$(printf '%s' "$output" | jq -r '.summary')" = "provider connection reset" ]
}

@test "failure structured class transient-runtime from provider and session kinds" {
  run graph_failure_classify '{"category":"provider"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "transient-runtime" "true" "none"

  run graph_failure_classify '{"failureKind":"session"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "transient-runtime" "true" "none"
}

@test "failure structured class agent-correctable from verification component" {
  run graph_failure_classify '{"component":"verification","summary":"runner verification failed"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "agent-correctable" "true" "none"
}

@test "failure structured class agent-correctable from missing artifact" {
  run graph_failure_classify '{"kind":"artifact","reason":"required-artifact-missing:exchange/out.md"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "agent-correctable" "true" "none"
}

@test "failure structured class operator-permission from exit 4" {
  run graph_failure_classify '{"outcome":"failed","exitCode":4}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "operator-permission" "false" "await-operator"
}

@test "failure structured class operator-permission from permissionRequest" {
  local report
  report="$(jq -c '.fixture' "$PRODUCTION_FIXTURE_DIR/exit-4-permission-request.json")"
  run graph_failure_classify "$report"
  [ "$status" -eq 0 ]
  assert_classification "$output" "operator-permission" "false" "await-operator"
}

@test "failure structured class plan-contract from undeclared paths" {
  local report
  report="$(jq -c '.fixture' "$PRODUCTION_FIXTURE_DIR/undeclared-changed-leaf.json")"
  run graph_failure_classify "$report"
  [ "$status" -eq 0 ]
  assert_classification "$output" "plan-contract" "false" "repair-plan"
}

@test "failure structured class plan-contract from write-scope mismatch" {
  local report
  report="$(jq -c '.fixture' "$PRODUCTION_FIXTURE_DIR/graph-contract-write-scope-mismatch.json")"
  run graph_failure_classify "$report"
  [ "$status" -eq 0 ]
  assert_classification "$output" "plan-contract" "false" "repair-plan"
}

@test "failure structured class terminal-configuration from invalid auth" {
  run graph_failure_classify '{"kind":"auth","summary":"runtime reported authentication_error"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "terminal-configuration" "false" "fix-configuration"
}

@test "failure structured class terminal-configuration from invalid model and schema" {
  run graph_failure_classify '{"failureClass":"model"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "terminal-configuration" "false" "fix-configuration"

  run graph_failure_classify '{"kind":"schema"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "terminal-configuration" "false" "fix-configuration"
}

@test "failure structured class integrity from control path" {
  run graph_failure_classify '{"controlPaths":[".ralph/control.sh"]}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "integrity" "false" "none"
}

@test "failure structured class integrity from sandbox violation" {
  run graph_failure_classify '{"sandboxViolation":true,"summary":"unsafe escaping symlink"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "integrity" "false" "none"
  [ "$(printf '%s' "$output" | jq -r '.summary')" = "unsafe escaping symlink" ]
}

@test "failure structured class cancelled from outcome" {
  run graph_failure_classify '{"outcome":"cancelled","exitCode":130,"reason":"received signal TERM"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "cancelled" "false" "none"
}

@test "failure structured class unknown for empty or unrecognized report" {
  run graph_failure_classify ''
  [ "$status" -eq 0 ]
  assert_classification "$output" "unknown" "false" "inspect"

  run graph_failure_classify 'not-json'
  [ "$status" -eq 0 ]
  assert_classification "$output" "unknown" "false" "inspect"

  run graph_failure_classify '{"outcome":"failed","exitCode":1}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "unknown" "false" "inspect"
}

@test "failure structured class explicit class field wins over other structured fields" {
  run graph_failure_classify '{"class":"integrity","kind":"network","exitCode":4,"permissionRequest":{"tool":"Bash"}}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "integrity" "false" "none"

  run graph_failure_classify '{"classification":"transient-runtime","outcome":"cancelled"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "transient-runtime" "true" "none"
}

@test "failure structured class retryable and operator action for every class" {
  local class retryable action
  local -a classes=(
    transient-runtime:true:none
    agent-correctable:true:none
    operator-permission:false:await-operator
    plan-contract:false:repair-plan
    terminal-configuration:false:fix-configuration
    integrity:false:none
    cancelled:false:none
    unknown:false:inspect
  )
  for spec in "${classes[@]}"; do
    class="${spec%%:*}"
    rest="${spec#*:}"
    retryable="${rest%%:*}"
    action="${rest#*:}"
    run graph_failure_classify "$(jq -nc --arg c "$class" '{class:$c}')"
    [ "$status" -eq 0 ]
    assert_classification "$output" "$class" "$retryable" "$action"
  done
}

@test "failure structured class bounds summary length" {
  local long summary
  long="$(printf 'x%.0s' {1..400})"
  run graph_failure_classify "$(jq -nc --arg s "$long" '{kind:"network",summary:$s}')"
  [ "$status" -eq 0 ]
  assert_classification "$output" "transient-runtime" "true" "none"
  summary="$(printf '%s' "$output" | jq -r '.summary')"
  [ "${#summary}" -eq 200 ]
  [[ "$summary" == *... ]]
}

@test "failure structured class reads a report file" {
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' '{"kind":"verification","summary":"artifact missing"}' >"$tmp"
  run graph_failure_classify "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  assert_classification "$output" "agent-correctable" "true" "none"
  [ "$(printf '%s' "$output" | jq -r '.summary')" = "artifact missing" ]
}

@test "failure legacy fallback classifies permission text when structured fields are absent" {
  run graph_failure_classify '{"message":"Error: permission denied for Bash"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "operator-permission" "false" "await-operator"
}

@test "failure legacy fallback classifies each class from bounded text" {
  run graph_failure_classify '{"text":"provider connection reset mid-turn"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "transient-runtime" "true" "none"

  run graph_failure_classify '{"message":"runner verification failed"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "agent-correctable" "true" "none"

  run graph_failure_classify '{"error":"undeclared path docs/secret.md"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "plan-contract" "false" "repair-plan"

  run graph_failure_classify '{"output":"runtime reported authentication_error"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "terminal-configuration" "false" "fix-configuration"

  run graph_failure_classify '{"stderr":"sandbox violation: unsafe symlink"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "integrity" "false" "none"

  run graph_failure_classify '{"detail":"received signal TERM"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "cancelled" "false" "none"
}

@test "failure legacy fallback structured values always win over conflicting text" {
  run graph_failure_classify '{"kind":"network","summary":"permission denied error"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "transient-runtime" "true" "none"

  run graph_failure_classify '{"class":"integrity","message":"permission denied"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "integrity" "false" "none"

  run graph_failure_classify '{"kind":"not-a-real-kind","message":"permission denied"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "unknown" "false" "inspect"
}

@test "failure legacy fallback successful report with permission denied error remains successful" {
  run graph_failure_classify '{"outcome":"succeeded","summary":"permission denied error in diagnostic log"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "unknown" "false" "inspect"
  [ "$(printf '%s' "$output" | jq -r '.classification')" != "operator-permission" ]

  run graph_failure_classify '{"success":true,"message":"approval required then denied after completion"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "unknown" "false" "inspect"

  run graph_failure_classify '{"exitCode":0,"text":"error: permission denied reading optional diagnostic"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "unknown" "false" "inspect"
}

@test "failure legacy fallback redacts credential-looking text and caps summaries" {
  local long summary
  run graph_failure_classify '{"message":"permission denied api_key=sk-secretvalue123"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "operator-permission" "false" "await-operator"
  summary="$(printf '%s' "$output" | jq -r '.summary')"
  [[ "$summary" != *"sk-secretvalue123"* ]]
  [[ "$summary" != *"api_key="* ]]
  [[ "$summary" == *"[REDACTED]"* ]]

  long="$(printf 'permission denied %s api_key=hunter2' "$(printf 'x%.0s' {1..400})")"
  run graph_failure_classify "$(jq -nc --arg s "$long" '{message:$s}')"
  [ "$status" -eq 0 ]
  assert_classification "$output" "operator-permission" "false" "await-operator"
  summary="$(printf '%s' "$output" | jq -r '.summary')"
  [ "${#summary}" -eq 200 ]
  [[ "$summary" == *... ]]
  [[ "$summary" != *"hunter2"* ]]
}

@test "failure legacy fallback scans only a bounded text window" {
  local prefix
  prefix="$(printf 'x%.0s' {1..40})"
  export GRAPH_FAILURE_TEXT_MAX=40
  run graph_failure_classify "$(jq -nc --arg m "${prefix} permission denied" '{message:$m}')"
  unset GRAPH_FAILURE_TEXT_MAX
  [ "$status" -eq 0 ]
  assert_classification "$output" "unknown" "false" "inspect"
}
