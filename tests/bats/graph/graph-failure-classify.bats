#!/usr/bin/env bats
# Structured-report and text-fallback tests for the graph failure classifier.
# Also owns G10/G11 termination-branch coverage: runner timeout, operator
# cancel, supervisor signal, native permission, generic 143, and unknown.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-failure-classify.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/permission-classify.sh"

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

@test "failure text fallback classifies permission text when structured fields are absent" {
  run graph_failure_classify '{"message":"Error: permission denied for Bash"}'
  [ "$status" -eq 0 ]
  assert_classification "$output" "operator-permission" "false" "await-operator"
}

@test "failure text fallback classifies each class from bounded text" {
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

@test "failure text fallback structured values always win over conflicting text" {
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

@test "failure text fallback successful report with permission denied error remains successful" {
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

@test "failure text fallback redacts credential-looking text and caps summaries" {
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

@test "failure text fallback scans only a bounded text window" {
  local prefix
  prefix="$(printf 'x%.0s' {1..40})"
  export GRAPH_FAILURE_TEXT_MAX=40
  run graph_failure_classify "$(jq -nc --arg m "${prefix} permission denied" '{message:$m}')"
  unset GRAPH_FAILURE_TEXT_MAX
  [ "$status" -eq 0 ]
  assert_classification "$output" "unknown" "false" "inspect"
}

# ---------------------------------------------------------------------------
# G10/G11 termination branch: six distinct causes, markers outrank wording.
# ---------------------------------------------------------------------------

assert_v2_no_permission_request() {
  local json="$1"
  [ "$(printf '%s' "$json" | jq 'has("permissionRequest")')" = "false" ]
}

@test "termination: runner timeout marker classifies as invocation-timeout and outranks permission wording" {
  run graph_failure_classify_v2 '{"timeoutMarker":{"owner":"run-plan","seconds":2,"signal":"TERM"},"text":"permission denied for Bash","exitCode":143}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "transient-runtime" ]
  [ "$(jq -r '.cause' <<<"$output")" = "invocation-timeout" ]
  [ "$(jq -r '.source' <<<"$output")" = "run-plan" ]
  [ "$(jq -r '.timeout.seconds' <<<"$output")" = "2" ]
  assert_v2_no_permission_request "$output"
}

@test "termination: operator cancel vs supervisor signal vs generic 143 vs unknown stay distinct" {
  run graph_failure_classify_v2 '{"cancelMarker":{"owner":"scheduler","operator":true},"text":"permission denied"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "cancelled" ]
  [ "$(jq -r '.cause' <<<"$output")" = "operator-cancel" ]
  assert_v2_no_permission_request "$output"

  run graph_failure_classify_v2 '{"cancelMarker":{"owner":"orchestrator","signal":"TERM"},"text":"permission denied"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "cancelled" ]
  [ "$(jq -r '.cause' <<<"$output")" = "supervisor-signal" ]
  assert_v2_no_permission_request "$output"

  run graph_failure_classify_v2 '{"exitCode":143,"text":"permission denied for Bash"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "cancelled" ]
  [ "$(jq -r '.cause' <<<"$output")" = "unknown" ]
  summary="$(jq -r '.summary' <<<"$output")"
  [[ "$summary" == *"generic signal exit"* ]]
  assert_v2_no_permission_request "$output"

  run graph_failure_classify_v2 '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "unknown" ]
  [ "$(jq -r '.cause' <<<"$output")" = "unknown" ]
  assert_v2_no_permission_request "$output"
}

@test "termination: proved native permission is distinct and is the only path that carries permissionRequest" {
  run graph_failure_classify_v2 '{"nativePermission":{"tool":"bash","action":"execute","resource":"npm test","effect":"write","proved":true}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" = "operator-permission" ]
  [ "$(jq -r '.cause' <<<"$output")" = "native-permission" ]
  [ "$(jq -r '.permissionRequest.tool' <<<"$output")" = "bash" ]

  # Exit 143 alone never fabricates a permission request even with wording.
  run graph_failure_classify_v2 '{"exitCode":143,"summary":"Error: permission denied"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.classification' <<<"$output")" != "operator-permission" ]
  assert_v2_no_permission_request "$output"
}

@test "termination: permission classifier short-circuits signal and runner-timeout exits" {
  local tag
  tag="$(ralph_permission_block_type "Error: permission denied for Bash" 143 cursor)"
  [ "$tag" = "none" ]

  tag="$(ralph_permission_block_type "Error: permission denied for Bash" 124 cursor)"
  [ "$tag" = "none" ]

  tag="$(ralph_permission_block_type $'--- Invocation terminated due to timeout (elapsed 5s > 2s) ---\npermission denied' 4 cursor)"
  [ "$tag" = "none" ]

  # A real permission denial on a non-termination exit still classifies.
  tag="$(ralph_permission_block_type "Error: permission denied for Bash" 1 cursor)"
  [ "$tag" = "permission_unknown" ]
}

@test "Codex app-server bootstrap failure is not an operator permission pause" {
  local tag
  tag="$(ralph_permission_block_type $'Error: failed to initialize in-process app-server client: Operation not permitted (os error 1)' 1 codex)"
  [ "$tag" = "none" ]
}

@test "termination vertical: progressing fake timeout plus cancel/SIGTERM/143 leave no fabricated permission and a clean process tree" {
  local tmpd bin progress_marker fake_log fake_pid class_json tag leftover waited fake_ec segment
  tmpd="$(mktemp -d)"
  bin="$tmpd/bin"
  progress_marker="$tmpd/progressed"
  fake_log="$tmpd/fake.log"
  mkdir -p "$bin"

  # Progressing fake: writes a marker, emits permission-shaped noise, then
  # sleeps. The test applies a short timeout and SIGTERM, mirroring a
  # runner-owned invocation timeout without depending on ambient plan-env
  # flags that can abort run-plan before the fake starts.
  cat >"$bin/progress-fake" <<FAKE
#!/usr/bin/env bash
printf 'progress: starting work\n'
touch "$progress_marker"
printf 'diagnostic: permission denied reading optional cache\n'
sleep 30
printf 'done\n'
exit 0
FAKE
  chmod +x "$bin/progress-fake"

  # --- Case A: short progressing fake timeout ---
  "$bin/progress-fake" >"$fake_log" 2>&1 &
  fake_pid=$!
  waited=0
  while [[ ! -f "$progress_marker" && "$waited" -lt 40 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$progress_marker" ]
  # Runner-owned timeout: TERM the progressing fake after it has advanced.
  kill -TERM "$fake_pid" 2>/dev/null || true
  fake_ec=0
  wait "$fake_pid" || fake_ec=$?
  # Bash reports 143 for SIGTERM; accept 137 (SIGKILL) if the platform reaped hard.
  [[ "$fake_ec" -eq 143 || "$fake_ec" -eq 137 || "$fake_ec" -eq 0 ]] || [[ "$fake_ec" -gt 128 ]]

  segment="$(cat "$fake_log")
--- Invocation terminated due to timeout (elapsed 2s > 2s) ---"
  class_json="$(graph_failure_classify_v2 "$(jq -nc \
    --arg text "$segment" \
    --argjson seconds 2 \
    '{timeoutMarker:{owner:"run-plan",seconds:$seconds,signal:"TERM"},text:$text,exitCode:4}')")"
  [ "$(jq -r '.classification' <<<"$class_json")" = "transient-runtime" ]
  [ "$(jq -r '.cause' <<<"$class_json")" = "invocation-timeout" ]
  assert_v2_no_permission_request "$class_json"

  tag="$(ralph_permission_block_type "$segment" 4 cursor)"
  [ "$tag" = "none" ]

  # --- Case B: separate cancel / SIGTERM (cancelMarker) / bare 143 ---
  class_json="$(graph_failure_classify_v2 '{"cancelMarker":{"owner":"scheduler","operator":true},"text":"permission denied"}')"
  [ "$(jq -r '.cause' <<<"$class_json")" = "operator-cancel" ]
  assert_v2_no_permission_request "$class_json"

  class_json="$(graph_failure_classify_v2 '{"cancelMarker":{"owner":"orchestrator","signal":"TERM"},"exitCode":143,"text":"permission denied"}')"
  [ "$(jq -r '.cause' <<<"$class_json")" = "supervisor-signal" ]
  assert_v2_no_permission_request "$class_json"

  class_json="$(graph_failure_classify_v2 '{"exitCode":143,"text":"permission denied"}')"
  [ "$(jq -r '.classification' <<<"$class_json")" = "cancelled" ]
  [ "$(jq -r '.cause' <<<"$class_json")" = "unknown" ]
  assert_v2_no_permission_request "$class_json"

  # --- Clean process tree: no leftover fake children ---
  leftover="$(pgrep -f "$bin/progress-fake" 2>/dev/null || true)"
  [ -z "$leftover" ]

  rm -rf "$tmpd"
}
