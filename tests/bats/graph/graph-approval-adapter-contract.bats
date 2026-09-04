#!/usr/bin/env bats
# Approval-adapter capability discovery and decision-translation contract.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-approval-adapter.sh"

ALL_CAPABILITY_NAMES='liveRequestStreaming
sameOperationResponse
sessionContinuation
lifetime:once
lifetime:run
lifetime:always-policy'

assert_capability_fields() {
  local json="$1"
  [ "$(printf '%s' "$json" | jq -r '.schemaVersion')" = "1" ]
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming | type')" = "boolean" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse | type')" = "boolean" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation | type')" = "boolean" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.once | type')" = "boolean" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.run | type')" = "boolean" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"] | type')" = "boolean" ]
  [ "$(printf '%s' "$json" | jq -r '.supported | type')" = "array" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | type')" = "array" ]
}

assert_partitioned() {
  local json="$1" name in_supported in_unsupported
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    in_supported="$(printf '%s' "$json" | jq -r --arg n "$name" '.supported | index($n) != null')"
    in_unsupported="$(printf '%s' "$json" | jq -r --arg n "$name" '.unsupported | index($n) != null')"
    [ "$in_supported" != "$in_unsupported" ]
  done <<< "$ALL_CAPABILITY_NAMES"
}

assert_all_unsupported_except() {
  local json="$1"
  shift
  local name expected
  for name in liveRequestStreaming sameOperationResponse sessionContinuation; do
    expected=false
    local keep
    for keep in "$@"; do
      [[ "$keep" == "$name" ]] && expected=true
    done
    [ "$(printf '%s' "$json" | jq -r --arg n "$name" '.[$n]')" = "$expected" ]
  done
  for name in once run always-policy; do
    expected=false
    local keep
    for keep in "$@"; do
      [[ "$keep" == "lifetime:$name" ]] && expected=true
    done
    [ "$(printf '%s' "$json" | jq -r --arg n "$name" '.lifetimes[$n]')" = "$expected" ]
  done
}

@test "adapter capabilities unknown runtime lists every capability as explicit unsupported" {
  run ralph_approval_adapter_capabilities "not-a-runtime"
  [ "$status" -eq 0 ]
  assert_capability_fields "$output"
  [ "$(printf '%s' "$output" | jq -r '.runtime')" = "not-a-runtime" ]
  assert_all_unsupported_except "$output"
  assert_partitioned "$output"
  [ "$(printf '%s' "$output" | jq -r '.unsupported | length')" = "6" ]
  [ "$(printf '%s' "$output" | jq -r '.supported | length')" = "0" ]
}

@test "adapter capabilities empty runtime is explicit unsupported not guessed" {
  run ralph_approval_adapter_capabilities ""
  [ "$status" -eq 0 ]
  assert_capability_fields "$output"
  [ "$(printf '%s' "$output" | jq -r '.runtime')" = "" ]
  assert_all_unsupported_except "$output"
  run ralph_approval_adapter_capability_is_supported "$output" sessionContinuation
  [ "$status" -ne 0 ]
}

@test "adapter capabilities always enumerates live request streaming same-operation response session continuation and lifetimes" {
  local runtime json
  for runtime in claude cursor codex opencode antigravity unknown ""; do
    json="$(ralph_approval_adapter_capabilities "$runtime")"
    assert_capability_fields "$json"
    assert_partitioned "$json"
    [ "$(printf '%s' "$json" | jq -r '.lifetimes | keys | sort | join(",")')" = "always-policy,once,run" ]
  done
}

@test "adapter capabilities known runtime reports session continuation without guessing live streaming" {
  local runtime json
  for runtime in claude Claude cursor CURSOR codex opencode antigravity; do
    json="$(ralph_approval_adapter_capabilities "$runtime")"
    assert_capability_fields "$json"
    [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "true" ]
    [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "false" ]
    [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "false" ]
    assert_all_unsupported_except "$json" sessionContinuation
    [ "$(printf '%s' "$json" | jq -r '.unsupported | index("liveRequestStreaming") != null')" = "true" ]
    [ "$(printf '%s' "$json" | jq -r '.unsupported | index("sameOperationResponse") != null')" = "true" ]
    [ "$(printf '%s' "$json" | jq -r '.supported | index("sessionContinuation") != null')" = "true" ]
  done
}

@test "adapter capabilities does not infer same-operation response from live request streaming" {
  local json
  json="$(ralph_approval_adapter_capabilities codex '{"liveRequestStreaming":true}')"
  assert_capability_fields "$json"
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("sameOperationResponse") != null')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.supported | index("sameOperationResponse") != null')" = "false" ]
}

@test "adapter capabilities lifetimes always include once run and always-policy as explicit booleans" {
  local json
  json="$(ralph_approval_adapter_capabilities cursor)"
  assert_capability_fields "$json"
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.once')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.run')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("lifetime:once") != null')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("lifetime:run") != null')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("lifetime:always-policy") != null')" = "true" ]
}

@test "adapter capabilities partial proof does not guess omitted fields" {
  local json
  json="$(ralph_approval_adapter_capabilities claude '{"sameOperationResponse":true,"lifetimes":{"once":true}}')"
  assert_capability_fields "$json"
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.once')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.run')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("liveRequestStreaming") != null')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("lifetime:run") != null')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("lifetime:always-policy") != null')" = "true" ]
}

@test "adapter capabilities invalid proof is ignored and stays unsupported" {
  local json
  json="$(ralph_approval_adapter_capabilities unknown 'not-json')"
  assert_capability_fields "$json"
  assert_all_unsupported_except "$json"

  json="$(ralph_approval_adapter_capabilities unknown '["liveRequestStreaming"]')"
  assert_all_unsupported_except "$json"

  json="$(ralph_approval_adapter_capabilities unknown 'true')"
  assert_all_unsupported_except "$json"
}

@test "adapter capabilities proof can enable only explicitly true fields" {
  local json
  json="$(ralph_approval_adapter_capabilities codex "$(jq -nc '{
    liveRequestStreaming: true,
    sameOperationResponse: true,
    sessionContinuation: true,
    lifetimes: {once: true, run: true, "always-policy": true}
  }')")"
  assert_capability_fields "$json"
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.once')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.run')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | length')" = "0" ]
  [ "$(printf '%s' "$json" | jq -r '.supported | length')" = "6" ]
  ralph_approval_adapter_capability_is_supported "$json" liveRequestStreaming
  ralph_approval_adapter_capability_is_supported "$json" lifetime:run
  ralph_approval_adapter_capability_is_supported "$json" always-policy
}

@test "adapter capabilities auto maybe and unknown proof values stay unsupported" {
  local json
  json="$(ralph_approval_adapter_capabilities cursor "$(jq -nc '{
    liveRequestStreaming: "auto",
    sameOperationResponse: "maybe",
    sessionContinuation: "unknown",
    lifetimes: {
      once: "unsupported",
      run: "yes",
      "always-policy": "on"
    }
  }')")"
  assert_capability_fields "$json"
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.once')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.run')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
  assert_all_unsupported_except "$json"
}

@test "adapter capabilities always-policy is not guessed from once or run" {
  local json
  json="$(ralph_approval_adapter_capabilities opencode '{"lifetimes":{"once":true,"run":true}}')"
  assert_capability_fields "$json"
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.once')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.run')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("lifetime:always-policy") != null')" = "true" ]
}

@test "adapter capabilities snake_case and alias proof keys are not guessed as supported" {
  local json
  json="$(ralph_approval_adapter_capabilities claude "$(jq -nc '{
    live_request_streaming: true,
    same_operation_response: true,
    session_continuation: false,
    always: true,
    once: true,
    lifetimes: {always: true, session: true}
  }')")"
  assert_capability_fields "$json"
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.once')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
  assert_all_unsupported_except "$json" sessionContinuation
}

@test "adapter capabilities explicit false proof disables known session continuation" {
  local json
  json="$(ralph_approval_adapter_capabilities claude '{"sessionContinuation":false}')"
  assert_capability_fields "$json"
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("sessionContinuation") != null')" = "true" ]
  run ralph_approval_adapter_capability_is_supported "$json" sessionContinuation
  [ "$status" -ne 0 ]
}

exact_request_json() {
  jq -nc '{
    decision: "allow-once",
    request: {action: "Bash", resource: "src/app.ts", effect: "write"}
  }'
}

assert_translation_ok() {
  local json="$1"
  [ "$(printf '%s' "$json" | jq -r '.schemaVersion')" = "1" ]
  [ "$(printf '%s' "$json" | jq -r '.equalOrNarrower')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "$(printf '%s' "$json" | jq -r '.nativeDecision')" ]
}

@test "adapter decision translation maps allow-once allow-run allow-always and deny to native lifetimes" {
  local json
  json="$(ralph_approval_adapter_translate_decision "$(exact_request_json)")"
  assert_translation_ok "$json"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-once" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "once" ]
  [ "$(printf '%s' "$json" | jq -r '.grant.action')" = "Bash" ]
  [ "$(printf '%s' "$json" | jq -r '.grant.resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$json" | jq -r '.grant.effect')" = "write" ]
  [ "$(printf '%s' "$json" | jq -r '.fallback')" = "null" ]

  json="$(ralph_approval_adapter_translate_decision '{"decision":"allow-run","action":"Bash","resource":"src/app.ts","effect":"write"}')"
  assert_translation_ok "$json"
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "run" ]

  json="$(ralph_approval_adapter_translate_decision '{"decision":"allow-always","action":"Bash","resource":"src/app.ts","effect":"write"}')"
  assert_translation_ok "$json"
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "always-policy" ]

  json="$(ralph_approval_adapter_translate_decision '{"decision":"deny"}')"
  assert_translation_ok "$json"
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "deny" ]
  [ "$(printf '%s' "$json" | jq -r '.grant')" = "null" ]
}

@test "adapter decision translation accepts an exact grant as equal" {
  local json
  json="$(ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-run",
    request: {action: "Edit", resource: "./src//app.ts", effect: "WRITE"},
    grant: {action: "Edit", resource: "src/app.ts", effect: "write"}
  }')")"
  assert_translation_ok "$json"
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "run" ]
  [ "$(printf '%s' "$json" | jq -r '.grant.resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$json" | jq -r '.grant.effect')" = "write" ]
}

@test "adapter decision translation accepts a narrower resource and write-to-read effect" {
  local json
  json="$(ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-once",
    request: {action: "Bash", resource: "src/**", effect: "write"},
    nativeGrant: {action: "Bash", resource: "src/app.ts", effect: "read"}
  }')")"
  assert_translation_ok "$json"
  [ "$(printf '%s' "$json" | jq -r '.grant.resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$json" | jq -r '.grant.effect')" = "read" ]
}

@test "adapter decision translation rejects a broader resource grant" {
  run ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-once",
    request: {action: "Bash", resource: "src/app.ts", effect: "write"},
    grant: {action: "Bash", resource: "src/**", effect: "write"}
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broader"* ]]

  run ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-once",
    request: {action: "Bash", resource: "src/**", effect: "write"},
    grant: {action: "Bash", resource: "**", effect: "write"}
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broader"* ]]
}

@test "adapter decision translation rejects a broader effect or different action" {
  run ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-once",
    request: {action: "Bash", resource: "src/app.ts", effect: "read"},
    grant: {action: "Bash", resource: "src/app.ts", effect: "write"}
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broader"* ]]

  run ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-once",
    request: {action: "Bash", resource: "src/app.ts", effect: "write"},
    grant: {action: "Bash", resource: "src/app.ts", effect: "network"}
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broader"* ]]

  run ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-once",
    request: {action: "Bash", resource: "src/app.ts", effect: "write"},
    grant: {action: "Edit", resource: "src/app.ts", effect: "write"}
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"action"* ]]
}

@test "adapter decision translation rejects a broader native lifetime" {
  run ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-once",
    action: "Bash",
    resource: "src/app.ts",
    effect: "write",
    nativeDecision: "run"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broader"* ]]

  run ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-run",
    action: "Bash",
    resource: "src/app.ts",
    effect: "write",
    nativeDecision: "always-policy"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broader"* ]]
}

@test "adapter decision translation may narrow lifetime to a supported equal-or-narrower choice" {
  local caps json
  caps="$(ralph_approval_adapter_capabilities cursor '{"lifetimes":{"once":true,"run":true}}')"
  json="$(ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-always",
    action: "Bash",
    resource: "src/app.ts",
    effect: "write"
  }')" "$caps")"
  assert_translation_ok "$json"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-always" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "run" ]

  json="$(ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-run",
    action: "Bash",
    resource: "src/app.ts",
    effect: "write",
    nativeDecision: "once"
  }')" "$caps")"
  assert_translation_ok "$json"
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "once" ]
}

@test "adapter decision translation fails closed when no equal-or-narrower lifetime is supported" {
  local caps
  caps="$(ralph_approval_adapter_capabilities unknown '{"lifetimes":{"always-policy":true}}')"
  run ralph_approval_adapter_translate_decision "$(jq -nc '{
    decision: "allow-run",
    action: "Bash",
    resource: "src/app.ts",
    effect: "write"
  }')" "$caps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"supported lifetime"* ]]
}

@test "adapter decision translation rejects auto force yolo dangerously-skip-permissions and sandbox bypass as fallbacks" {
  local token
  for token in auto force yolo \
    --auto --force --yolo \
    --dangerously-skip-permissions \
    dangerously-skip-permissions \
    --dangerously-bypass-approvals-and-sandbox \
    "sandbox bypass" \
    --sandbox=bypass
  do
    run ralph_approval_adapter_is_dangerous_fallback "$token"
    [ "$status" -eq 0 ]

    run ralph_approval_adapter_reject_dangerous_fallback "$token"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rejects"* ]]
    [[ "$output" == *"fallback"* ]]

    run ralph_approval_adapter_translate_decision "$(jq -nc --arg fb "$token" '{
      decision: "allow-once",
      action: "Bash",
      resource: "src/app.ts",
      effect: "write",
      fallback: $fb
    }')"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rejects"* ]]
  done

  run ralph_approval_adapter_translate_decision '{"decision":"auto","action":"Bash","resource":"src/app.ts","effect":"write"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejects"* ]]

  run ralph_approval_adapter_translate_decision '{"decision":"allow-once","action":"Bash","resource":"src/app.ts","effect":"write","nativeDecision":"yolo"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejects"* ]]

  run ralph_approval_adapter_translate_decision '{"decision":"allow-once","action":"Bash","resource":"src/app.ts","effect":"write","args":["agy","--dangerously-skip-permissions"]}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejects"* ]]

  run ralph_approval_adapter_is_dangerous_fallback ""
  [ "$status" -ne 0 ]
  run ralph_approval_adapter_reject_dangerous_fallback ""
  [ "$status" -eq 0 ]
  run ralph_approval_adapter_is_dangerous_fallback overlay
  [ "$status" -ne 0 ]
}

@test "adapter decision translation rejects unknown decisions and does not guess aliases" {
  run ralph_approval_adapter_translate_decision '{"decision":"accept","action":"Bash","resource":"src/app.ts","effect":"write"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported"* ]]

  run ralph_approval_adapter_translate_decision '{"decision":"allow","action":"Bash","resource":"src/app.ts","effect":"write"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported"* ]]

  run ralph_approval_adapter_translate_decision '{"decision":"acceptForSession","action":"Bash","resource":"src/app.ts","effect":"write"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported"* ]]

  run ralph_approval_adapter_translate_decision '{"decision":"allow-once","action":"Bash","resource":"src/app.ts","effect":"write","nativeDecision":"accept"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"known lifetime"* || "$output" == *"unsupported"* ]]
}

overlay_workspace() {
  OVERLAY_WS="$(mktemp -d)"
  export WORKSPACE="$OVERLAY_WS"
  export RALPH_PROJECT_ROOT="$OVERLAY_WS"
  export RALPH_PLAN_WORKSPACE_ROOT="$OVERLAY_WS/.ralph-workspace"
  export RALPH_PLAN_KEY="adapter-overlay"
  mkdir -p "$OVERLAY_WS/.ralph-workspace" "$OVERLAY_WS/.claude"
  ralph_approval_adapter_overlay_reset
}

overlay_cleanup() {
  ralph_approval_adapter_overlay_restore success >/dev/null 2>&1 || true
  ralph_approval_adapter_overlay_reset
  rm -rf "${OVERLAY_WS:-}"
}

allow_overlay_json() {
  jq -nc \
    --arg target "${1:-}" \
    --arg session "${2:-sess-1}" \
    '{
      decision: "allow-run",
      runtime: "cursor",
      action: "Bash",
      resource: "src/app.ts",
      effect: "write",
      sessionId: $session
    } + (if $target == "" then {} else {target:$target} end)'
}

@test "adapter overlay fallback applies a run-local reversible overlay and resumes the same session" {
  overlay_workspace
  local original json target backup
  original="$OVERLAY_WS/.claude/settings.json"
  printf '%s' '{"original":true}' >"$original"
  json="$(ralph_approval_adapter_overlay_fallback "$(allow_overlay_json "$original" sess-42)")"
  [ "$(printf '%s' "$json" | jq -r '.fallback')" = "overlay" ]
  [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.continuation')" = "session" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionStrategy')" = "resume" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionId')" = "sess-42" ]
  [ "$(printf '%s' "$json" | jq -r '.equalOrNarrower')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "run" ]
  [ "$(printf '%s' "$json" | jq -r '.grant.resource')" = "src/app.ts" ]
  target="$(printf '%s' "$json" | jq -r '.target')"
  backup="$(printf '%s' "$json" | jq -r '.backup')"
  [ "$target" = "$original" ]
  [ -f "$backup" ]
  [ "$(cat "$backup")" = '{"original":true}' ]
  [ "$(jq -r '.kind' "$original")" = "ralph-approval-overlay" ]
  [[ "$backup" == *"/runtime-config/adapter-overlay/originals/"* ]]
  overlay_cleanup
}

@test "adapter overlay fallback uses one compact continuation turn when session continuation is unsupported" {
  overlay_workspace
  local caps json
  caps="$(ralph_approval_adapter_capabilities cursor '{"sessionContinuation":false,"lifetimes":{"once":true,"run":true}}')"
  json="$(ralph_approval_adapter_overlay_fallback "$(allow_overlay_json)" "$caps")"
  [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.continuation')" = "compact" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionStrategy')" = "compact" ]
  [ "$(printf '%s' "$json" | jq -r '.compactTurns')" = "1" ]
  [ -f "$(printf '%s' "$json" | jq -r '.target')" ]
  run ralph_approval_adapter_overlay_fallback "$(allow_overlay_json)" "$caps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"one compact continuation turn"* ]]
  overlay_cleanup
}

@test "adapter overlay fallback deny skips overlay and uses one compact continuation turn" {
  overlay_workspace
  local json
  json="$(ralph_approval_adapter_overlay_fallback '{"decision":"deny","runtime":"cursor"}')"
  [ "$(printf '%s' "$json" | jq -r '.applied')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.continuation')" = "compact" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionStrategy')" = "compact" ]
  [ "$(printf '%s' "$json" | jq -r '.target')" = "null" ]
  [ "$(printf '%s' "$json" | jq -r '.grant')" = "null" ]
  overlay_cleanup
}

@test "adapter overlay fallback restores originals on success denial failure and timeout" {
  overlay_workspace
  local original json reason restored
  original="$OVERLAY_WS/.claude/settings.json"
  for reason in success denial failure timeout; do
    printf '%s' '{"original":true}' >"$original"
    json="$(ralph_approval_adapter_overlay_fallback "$(allow_overlay_json "$original")")"
    [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
    [ "$(jq -r '.kind' "$original")" = "ralph-approval-overlay" ]
    restored="$(ralph_approval_adapter_overlay_restore "$reason")"
    [ "$(printf '%s' "$restored" | jq -r '.restored')" = "true" ]
    [ "$(printf '%s' "$restored" | jq -r '.reason')" = "$reason" ]
    [ "$(cat "$original")" = '{"original":true}' ]
    ralph_approval_adapter_overlay_reset
  done
  overlay_cleanup
}

@test "adapter overlay fallback restores originals on signal" {
  overlay_workspace
  local original script status_file request_file
  original="$OVERLAY_WS/.claude/settings.json"
  printf '%s' '{"original":true}' >"$original"
  status_file="$OVERLAY_WS/signal-status"
  request_file="$OVERLAY_WS/request.json"
  script="$OVERLAY_WS/signal-child.sh"
  allow_overlay_json "$original" >"$request_file"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-approval-adapter.sh"
export WORKSPACE="$OVERLAY_WS"
export RALPH_PROJECT_ROOT="$OVERLAY_WS"
export RALPH_PLAN_WORKSPACE_ROOT="$OVERLAY_WS/.ralph-workspace"
export RALPH_PLAN_KEY="adapter-overlay"
ralph_approval_adapter_overlay_fallback "\$(cat "$request_file")" >/dev/null
kill -TERM \$\$
echo still-running >"$status_file"
EOF
  chmod +x "$script"
  run bash "$script"
  [ "$status" -ne 0 ]
  [ ! -f "$status_file" ]
  [ "$(cat "$original")" = '{"original":true}' ]
  overlay_cleanup
}

@test "adapter overlay fallback rejects ambient user paths and dangerous fallbacks" {
  overlay_workspace
  run ralph_approval_adapter_overlay_fallback "$(jq -nc --arg target "$HOME/.claude/settings.json" '{
    decision: "allow-once",
    runtime: "claude",
    action: "Bash",
    resource: "src/app.ts",
    effect: "write",
    target: $target
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ambient"* ]]

  run ralph_approval_adapter_overlay_fallback "$(jq -nc '{
    decision: "allow-once",
    runtime: "cursor",
    action: "Bash",
    resource: "src/app.ts",
    effect: "write",
    fallback: "--dangerously-skip-permissions"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejects"* ]]

  run ralph_approval_adapter_overlay_fallback "$(jq -nc '{
    decision: "allow-once",
    runtime: "cursor",
    action: "Bash",
    resource: "src/app.ts",
    effect: "write",
    fallback: "yolo"
  }')"
  [ "$status" -ne 0 ]
  overlay_cleanup
}

@test "adapter overlay fallback rejects a broader native grant" {
  overlay_workspace
  run ralph_approval_adapter_overlay_fallback "$(jq -nc '{
    decision: "allow-once",
    runtime: "cursor",
    action: "Bash",
    resource: "src/app.ts",
    effect: "write",
    grant: {action: "Bash", resource: "src/**", effect: "write"}
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"broader"* ]]
  overlay_cleanup
}

@test "adapter overlay fallback helper restores recorded originals after mutation" {
  overlay_workspace
  local original
  original="$OVERLAY_WS/.claude/settings.json"
  printf '%s' '{"original":true}' >"$original"
  ralph_approval_adapter_ensure_overlay_state cursor
  runtime_overlay_record_original_file "$original" "" 1
  printf '%s' '{"mutated":true}' >"$original"
  runtime_overlay_restore_recorded_files
  [ "$(cat "$original")" = '{"original":true}' ]
  overlay_cleanup
}

# G16: reproduce the repeated OpenCode allow-once request against the shared
# continuation/overlay adapter. One continuation, one consume, distinct later
# request, and byte-exact config restoration.
@test "adapter continuation reproduces repeated OpenCode allow-once with one consume and byte-exact restore" {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"

  local ws config original_bytes json consume continuation
  local caps later defect_status restore_json
  local fixture

  ws="$(mktemp -d)"
  export WORKSPACE="$ws"
  export RALPH_PROJECT_ROOT="$ws"
  export RALPH_PLAN_WORKSPACE_ROOT="$ws/.ralph-workspace"
  export RALPH_PLAN_KEY="approval-continuation"
  export RALPH_GRAPH_NODE_ID="implement-cli-bootstrap"
  mkdir -p "$ws/.ralph-workspace" "$ws/.opencode"
  ralph_approval_adapter_overlay_reset

  fixture="$REPO_ROOT/.ralph-workspace/artifacts/graph-mode-recovery/fixtures/repeated-allow-once-request.json"
  [ -f "$fixture" ]
  [ "$(jq -r '.category' "$fixture")" = "repeated-allow-once-request" ]

  config="$ws/.ralph-workspace/runtime-config/approval-continuation/opencode-permission-override.json"
  mkdir -p "$(dirname "$config")"
  printf '%s' '{"model":"project-model","theme":"keep-me","permission":{"edit":{"secret.ts":"ask"}}}' >"$config"
  original_bytes="$(cat "$config")"

  caps="$(run_plan_invoke_opencode_graph_approval_capabilities)"
  [ "$(printf '%s' "$caps" | jq -r '.sameOperationResponse')" = "true" ]
  [ "$(printf '%s' "$caps" | jq -r '.lifetimes.once')" = "true" ]
  [ "$(printf '%s' "$caps" | jq -r '.lifetimes.run')" = "true" ]
  [ "$(printf '%s' "$caps" | jq -r '.lifetimes["always-policy"]')" = "true" ]

  # Attempt 1: allow-once without a live serve session installs a narrow overlay
  # before retry (the historical gap that caused a second operator prompt).
  json="$(run_plan_invoke_opencode_graph_approval_apply "$(jq -nc --arg t "$config" '{
    decision: "allow-once",
    runtime: "opencode",
    sessionId: "ses-bootstrap-1",
    nativeRequestId: "op-implement-cli-bootstrap-1",
    tool: "bash",
    action: "execute",
    resource: "npm test -- focused",
    effect: "write",
    target: $t
  }')")"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-once" ]
  [ "$(printf '%s' "$json" | jq -r '.path')" = "overlay" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationReply')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.continuation')" = "session" ]
  consume="$(printf '%s' "$json" | jq -r '.consumeRecord')"
  continuation="$(printf '%s' "$json" | jq -r '.continuationRecord')"
  [ -n "$consume" ] && [ -f "$consume" ]
  [ -n "$continuation" ] && [ -f "$continuation" ]
  [ "$(jq -r '.decision' "$consume")" = "allow-once" ]
  [ "$(jq -r '.requestId' "$consume")" = "op-implement-cli-bootstrap-1" ]
  [ "$(jq -r '.path' "$continuation")" = "overlay" ]
  [ "$(jq -r '.permission.bash["npm test -- focused"]' "$config")" = "allow" ]
  [ "$(jq -r '.model' "$config")" = "project-model" ]
  [ "$(jq -r '.theme' "$config")" = "keep-me" ]
  [ "$(jq -r '.permission.edit["secret.ts"]' "$config")" = "ask" ]

  # Exactly one consume and one continuation for the original request.
  [ "$(find "$(dirname "$consume")" -type f -name '*.json' | wc -l | tr -d ' ')" = "1" ]
  [ "$(find "$(dirname "$continuation")" -type f -name '*.json' | wc -l | tr -d ' ')" = "1" ]

  # Immediate recreation of the same normalized tuple is an adapter defect,
  # not a fresh operator prompt (the repeated-allow-once failure mode).
  run ralph_approval_adapter_assert_not_recreated "$(jq -nc '{
    runtime: "opencode",
    sessionId: "ses-bootstrap-2",
    nativeRequestId: "op-implement-cli-bootstrap-2",
    tool: "bash",
    action: "execute",
    resource: "npm test -- focused",
    effect: "write"
  }')"
  defect_status="$status"
  [ "$defect_status" -ne 0 ]
  [[ "$output" == *"continuation defect"* || "$output" == *"recreated"* ]]

  # Byte-exact restoration of the pre-continuation config.
  restore_json="$(run_plan_invoke_opencode_graph_approval_restore success)"
  [ "$(printf '%s' "$restore_json" | jq -r '.restored')" = "true" ]
  [ "$(cat "$config")" = "$original_bytes" ]

  # After restore, the previously blocked same-tuple request is no longer an
  # active-continuation defect (operator may decide again on a new cycle).
  run ralph_approval_adapter_assert_not_recreated "$(jq -nc '{
    runtime: "opencode",
    nativeRequestId: "op-implement-cli-bootstrap-2",
    tool: "bash",
    action: "execute",
    resource: "npm test -- focused",
    effect: "write"
  }')"
  [ "$status" -eq 0 ]

  # A distinct later request (different resource) remains a separate cycle.
  later="$(run_plan_invoke_opencode_graph_approval_apply "$(jq -nc --arg t "$config" '{
    decision: "allow-once",
    runtime: "opencode",
    sessionId: "ses-later",
    nativeRequestId: "op-implement-cli-bootstrap-later",
    tool: "read",
    action: "read",
    resource: "docs/GRAPH.md",
    effect: "read",
    target: $t
  }')")"
  [ "$(printf '%s' "$later" | jq -r '.decision')" = "allow-once" ]
  [ "$(printf '%s' "$later" | jq -r '.consumeRecord')" != "$consume" ]
  [ -f "$(printf '%s' "$later" | jq -r '.consumeRecord')" ]
  [ "$(jq -r '.permission.read["docs/GRAPH.md"]' "$config")" = "allow" ]
  [ "$(find "$(dirname "$consume")" -type f -name '*.json' | wc -l | tr -d ' ')" = "2" ]

  run_plan_invoke_opencode_graph_approval_restore success >/dev/null
  [ "$(cat "$config")" = "$original_bytes" ]

  ralph_approval_adapter_overlay_reset
  unset RALPH_GRAPH_NODE_ID
  rm -rf "$ws"
}

@test "adapter continuation refuses allow-once when once is explicitly unsupported" {
  overlay_workspace
  local caps
  caps="$(ralph_approval_adapter_capabilities opencode '{"sameOperationResponse":false,"lifetimes":{"once":false,"run":true}}')"
  run ralph_approval_adapter_can_enforce_once "$caps"
  [ "$status" -ne 0 ]
  run ralph_approval_adapter_continue "$(jq -nc '{
    decision: "allow-once",
    runtime: "opencode",
    action: "execute",
    resource: "npm test",
    effect: "write",
    nativeRequestId: "req-refuse-once",
    sessionId: "ses-refuse"
  }')" "$caps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not offer"* || "$output" == *"cannot enforce allow-once"* || "$output" == *"unsupported"* ]]
  overlay_cleanup
}
