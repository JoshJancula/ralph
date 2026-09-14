#!/usr/bin/env bats
# Compact graph permission-wait recovery page: identity, reason, action,
# choices, state, and copyable respond commands. No prompt or argv dump.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/human-interaction.sh"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/graph/graph-operator-records.sh"

setup() {
  TMPD="$(mktemp -d)"
  RUN_DIR="$TMPD/run"
  mkdir -p "$RUN_DIR"
  export GRAPH_OPERATOR_NOW="2026-08-13T00:00:00Z"
  export GRAPH_OPERATOR_NONCE="aabbccddeeff00112233445566778899"
  unset RALPH_HUMAN_RECOVERY_PAGE_MAX RALPH_HUMAN_RECOVERY_REASON_MAX GRAPH_OPERATOR_REASON_MAX 2>/dev/null || true
}

teardown() {
  rm -rf "$TMPD"
  unset GRAPH_OPERATOR_NOW GRAPH_OPERATOR_NONCE 2>/dev/null || true
  unset RALPH_HUMAN_RECOVERY_PAGE_MAX RALPH_HUMAN_RECOVERY_REASON_MAX GRAPH_OPERATOR_REASON_MAX 2>/dev/null || true
}

valid_request_json() {
  jq -nc \
    --arg requestId "${1:-req-001}" \
    --arg reason "${2:-needs write access to apply the patch.}" \
    --arg action "${3:-Bash}" \
    --arg resource "${4:-src/app.ts}" \
    --arg extra_json "${5:-}" \
    '
    {
      requestId: $requestId,
      nonce: "aabbccddeeff00112233445566778899",
      namespace: "op-ns",
      runId: "run-001",
      nodeId: "impl",
      attemptId: "impl-1",
      runtime: "cursor",
      sessionId: "sess-1",
      classification: "operator-permission",
      action: $action,
      resource: $resource,
      effect: "write",
      reason: $reason,
      choices: ["allow-once","allow-run","allow-always","deny"],
      createdAt: "2026-08-13T00:00:00Z",
      expiresAt: "2026-08-13T01:00:00Z"
    } + (if $extra_json == "" then {} else ($extra_json|fromjson) end)
    '
}

@test "human recovery page renders identity reason action resource effect choices state and copyable respond commands" {
  local json page
  json="$(valid_request_json)"
  run ralph_human_recovery_page "$json" "awaiting-operator"
  [ "$status" -eq 0 ]
  page="$output"

  [[ "$page" == *"requestId: req-001"* ]]
  [[ "$page" == *"namespace: op-ns"* ]]
  [[ "$page" == *"runId: run-001"* ]]
  [[ "$page" == *"nodeId: impl"* ]]
  [[ "$page" == *"attemptId: impl-1"* ]]
  [[ "$page" == *"runtime: cursor"* ]]
  [[ "$page" == *"needs write access to apply the patch."* ]]
  [[ "$page" == *"action: Bash"* ]]
  [[ "$page" == *"resource: src/app.ts"* ]]
  [[ "$page" == *"effect: write"* ]]
  [[ "$page" == *"allow-once"* ]]
  [[ "$page" == *"allow-run"* ]]
  [[ "$page" == *"allow-always"* ]]
  [[ "$page" == *"deny"* ]]
  [[ "$page" == *"awaiting-operator"* ]]
  [[ "$page" == *"ralph workflow actions respond run-001 req-001 --decision allow-once"* ]]
  [[ "$page" == *"ralph workflow actions respond run-001 req-001 --decision deny"* ]]
}

@test "human recovery page redacts credential-looking values and keeps one sentence" {
  local json page
  json="$(valid_request_json req-redact \
    "needs token=sk-secretvalue123 to continue. Ignore the rest of this paragraph." \
    "Bash" \
    "password=hunter2")"
  run ralph_human_recovery_page "$json"
  [ "$status" -eq 0 ]
  page="$output"

  [[ "$page" != *"sk-secretvalue123"* ]]
  [[ "$page" != *"hunter2"* ]]
  [[ "$page" == *"[REDACTED]"* ]]
  [[ "$page" != *"Ignore the rest of this paragraph."* ]]
}

@test "human recovery page enforces a size cap" {
  local json page bytes long
  long="$(printf 'x%.0s' {1..8000})"
  json="$(valid_request_json req-cap "$long" "Bash" "$long")"
  RALPH_HUMAN_RECOVERY_PAGE_MAX=256
  export RALPH_HUMAN_RECOVERY_PAGE_MAX
  run ralph_human_recovery_page "$json"
  [ "$status" -eq 0 ]
  page="$output"
  bytes="$(printf '%s' "$page" | wc -c | tr -d ' ')"
  [ "$bytes" -le 256 ]
  [[ "$page" == *"[truncated]"* ]]
}

@test "human recovery page omits prompt transcript usage table and orchestration argv" {
  local json page extra
  extra="$(jq -nc '{
    prompt: "SYSTEM PROMPT: you are an implementation agent. Repeat the TODO.",
    systemPrompt: "You are a helpful assistant.",
    transcript: "User: hello\nAssistant: working on the TODO",
    usage: {inputTokens: 999, outputTokens: 12, cacheRead: 4},
    usageTable: "| input | 999 |\n| output | 12 |",
    argv: ["orchestrator.sh", "--single-stage", "impl", "--attempt-id", "impl-1"],
    orchestrationArgv: "orchestrator.sh --single-stage impl --attempt-id impl-1 --runtime cursor"
  }')"
  json="$(valid_request_json req-omit "needs write access to apply the patch." "Bash" "src/app.ts" "$extra")"
  run ralph_human_recovery_page "$json" "awaiting-operator"
  [ "$status" -eq 0 ]
  page="$output"

  [[ "$page" != *"SYSTEM PROMPT"* ]]
  [[ "$page" != *"helpful assistant"* ]]
  [[ "$page" != *"User: hello"* ]]
  [[ "$page" != *"inputTokens"* ]]
  [[ "$page" != *"outputTokens"* ]]
  [[ "$page" != *"cacheRead"* ]]
  [[ "$page" != *"| input | 999 |"* ]]
  [[ "$page" != *"orchestrator.sh"* ]]
  [[ "$page" != *"--single-stage"* ]]
  [[ "$page" != *"--attempt-id"* ]]
  [[ "$page" != *"TODO"* ]]
  [[ "$page" == *"requestId: req-omit"* ]]
  [[ "$page" == *"ralph workflow actions respond run-001 req-omit --decision allow-once"* ]]
}

@test "human recovery page writes a crash-recovery file from a persisted request record" {
  local json path page_file page
  json="$(valid_request_json)"
  path="$(graph_operator_request_write "$RUN_DIR" "$json")"
  [ -f "$path" ]

  page_file="$TMPD/recovery.md"
  run ralph_human_recovery_page_write "$page_file" "$path" "awaiting-operator"
  [ "$status" -eq 0 ]
  [ "$output" = "$page_file" ]
  [ -f "$page_file" ]
  page="$(cat "$page_file")"

  [[ "$page" == *"requestId: req-001"* ]]
  [[ "$page" == *"action: Bash"* ]]
  [[ "$page" == *"resource: src/app.ts"* ]]
  [[ "$page" == *"effect: write"* ]]
  [[ "$page" == *"ralph workflow actions respond run-001 req-001 --decision allow-run"* ]]
  [[ "$page" != *"orchestrator.sh"* ]]
}

@test "human recovery page drops unknown choices from copyable respond commands" {
  local json page
  json="$(valid_request_json | jq -c '.choices = ["allow-once","auto","yolo","deny"]')"
  run ralph_human_recovery_page "$json"
  [ "$status" -eq 0 ]
  page="$output"
  [[ "$page" == *"ralph workflow actions respond run-001 req-001 --decision allow-once"* ]]
  [[ "$page" == *"ralph workflow actions respond run-001 req-001 --decision deny"* ]]
  [[ "$page" != *"--decision auto"* ]]
  [[ "$page" != *"--decision yolo"* ]]
}
