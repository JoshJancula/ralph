#!/usr/bin/env bats
# Coverage for planKeyFallback/planKeyFallbackReason markers across the Bash
# hook, native result hook, and proxy telemetry writers (PLAN15).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

FIXTURE_DIR="$REPO_ROOT/tests/fixtures/native-hook"
RESULT_HOOK="$REPO_ROOT/bundle/.claude/hooks/native-result-compact.sh"
BASH_HOOK="$REPO_ROOT/bundle/.claude/hooks/compact-bash-output.sh"

setup() {
  _tmp="$(mktemp -d)"
  export WORKSPACE="$_tmp/workspace"
  mkdir -p "$WORKSPACE"
  export CLAUDE_PROJECT_DIR="$REPO_ROOT"
  export RALPH_NATIVE_RESULT_COMPACT=1
  export RALPH_BASH_COMPACT=1
  export RALPH_BASH_COMPACT_LOG="$_tmp/compact.jsonl"
  export RALPH_RESULT_WINDOWING_LOG="$_tmp/windowing.jsonl"
  unset RALPH_PLAN_KEY RALPH_ARTIFACT_NS
}

teardown() {
  rm -rf "$_tmp"
  unset WORKSPACE CLAUDE_PROJECT_DIR RALPH_NATIVE_RESULT_COMPACT RALPH_BASH_COMPACT
  unset RALPH_BASH_COMPACT_LOG RALPH_RESULT_WINDOWING_LOG RALPH_PLAN_KEY RALPH_ARTIFACT_NS
}

@test "builder: explicit plan_key_fallback=false omits the reason and marks false" {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/hook-telemetry.sh"
  local record
  record="$(ralph_hook_telemetry_windowing_record_json \
    ws plankey Read 5000 1000 1250 250 0 abc1234567890123 "" "" "" "" "false" "")"
  run jq -e '.planKeyFallback == false' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e 'has("planKeyFallbackReason") | not' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "builder: plan_key_fallback=true includes the reason" {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/hook-telemetry.sh"
  local record
  record="$(ralph_hook_telemetry_windowing_record_json \
    ws plankey Read 5000 1000 1250 250 0 abc1234567890123 "" "" "" "" "true" "no_plan_key_or_artifact_ns_env")"
  run jq -e '.planKeyFallback == true' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -r '.planKeyFallbackReason' <<<"$record"
  [ "$output" = "no_plan_key_or_artifact_ns_env" ]
}

@test "builder: omitted fallback args leave no marker (legacy compatibility)" {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/hook-telemetry.sh"
  local record
  record="$(ralph_hook_telemetry_windowing_record_json \
    ws plankey Read 5000 1000 1250 250 0 abc1234567890123)"
  run jq -e 'has("planKeyFallback") | not' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "bash hook: explicit RALPH_PLAN_KEY produces planKeyFallback:false" {
  export RALPH_PLAN_KEY="explicit-plan"
  local bash_input
  bash_input="$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"grep foo -r ."}, tool_response:{stdout:(([range(400)] | map("line \(.) FOO match\n") | join(""))), stderr:"", interrupted:false, isImage:false}}')"
  run bash -c "bash '$BASH_HOOK' <<<'$bash_input'"
  [ "$status" -eq 0 ]
  [ -f "$RALPH_BASH_COMPACT_LOG" ]
  run jq -r '.planKey' "$RALPH_BASH_COMPACT_LOG"
  [ "$output" = "explicit-plan" ]
  run jq -r '.planKeyFallback' "$RALPH_BASH_COMPACT_LOG"
  [ "$output" = "false" ]
}

@test "bash hook: RALPH_ARTIFACT_NS only produces planKeyFallback:false" {
  export RALPH_ARTIFACT_NS="artifact-only"
  local bash_input
  bash_input="$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"grep foo -r ."}, tool_response:{stdout:(([range(400)] | map("line \(.) FOO match\n") | join(""))), stderr:"", interrupted:false, isImage:false}}')"
  run bash -c "bash '$BASH_HOOK' <<<'$bash_input'"
  [ "$status" -eq 0 ]
  run jq -r '.planKey' "$RALPH_BASH_COMPACT_LOG"
  [ "$output" = "artifact-only" ]
  run jq -r '.planKeyFallback' "$RALPH_BASH_COMPACT_LOG"
  [ "$output" = "false" ]
}

@test "bash hook: neither key set produces planKeyFallback:true with a stable reason" {
  local bash_input
  bash_input="$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"grep foo -r ."}, tool_response:{stdout:(([range(400)] | map("line \(.) FOO match\n") | join(""))), stderr:"", interrupted:false, isImage:false}}')"
  run bash -c "bash '$BASH_HOOK' <<<'$bash_input'"
  [ "$status" -eq 0 ]
  run jq -r '.planKey' "$RALPH_BASH_COMPACT_LOG"
  [ "$output" = "bash-hook" ]
  run jq -r '.planKeyFallback' "$RALPH_BASH_COMPACT_LOG"
  [ "$output" = "true" ]
  run jq -r '.planKeyFallbackReason' "$RALPH_BASH_COMPACT_LOG"
  [ "$output" = "no_plan_key_or_artifact_ns_env" ]
}

@test "bash hook: fallback event followed by attributed event does not leak stale fallback state" {
  local bash_input
  bash_input="$(jq -n '{hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"grep foo -r ."}, tool_response:{stdout:(([range(400)] | map("line \(.) FOO match\n") | join(""))), stderr:"", interrupted:false, isImage:false}}')"

  run bash -c "bash '$BASH_HOOK' <<<'$bash_input'"
  [ "$status" -eq 0 ]

  export RALPH_PLAN_KEY="attributed-plan"
  run bash -c "bash '$BASH_HOOK' <<<'$bash_input'"
  [ "$status" -eq 0 ]

  run wc -l < "$RALPH_BASH_COMPACT_LOG"
  [ "$(tr -d ' ' <<<"$output")" = "2" ]

  run bash -c "sed -n '1p' '$RALPH_BASH_COMPACT_LOG' | jq -r '.planKeyFallback'"
  [ "$output" = "true" ]
  run bash -c "sed -n '2p' '$RALPH_BASH_COMPACT_LOG' | jq -r '.planKeyFallback'"
  [ "$output" = "false" ]
  run bash -c "sed -n '2p' '$RALPH_BASH_COMPACT_LOG' | jq -e 'has(\"planKeyFallbackReason\")'"
  [ "$status" -ne 0 ]
}

@test "proxy/native-result windowing telemetry: fallback marker on default plan key" {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result-store.sh" 2>/dev/null || true
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh" 2>/dev/null || true
  source "$REPO_ROOT/bundle/.ralph/bash-lib/hook-telemetry.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh" 2>/dev/null || true

  ralph_mcp_proxy_append_windowing_telemetry "$WORKSPACE" "Read" 5000 1000 1250 250 0 "abc1234567890123"

  [ -f "$RALPH_RESULT_WINDOWING_LOG" ]
  run jq -r '.planKey' "$RALPH_RESULT_WINDOWING_LOG"
  [ "$output" = "default" ]
  run jq -r '.planKeyFallback' "$RALPH_RESULT_WINDOWING_LOG"
  [ "$output" = "true" ]
  run jq -r '.planKeyFallbackReason' "$RALPH_RESULT_WINDOWING_LOG"
  [ "$output" = "no_plan_key_or_artifact_ns_env" ]
}

@test "proxy/native-result windowing telemetry: explicit plan key has no fallback marker set to true" {
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result-store.sh" 2>/dev/null || true
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh" 2>/dev/null || true
  source "$REPO_ROOT/bundle/.ralph/bash-lib/hook-telemetry.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh" 2>/dev/null || true

  export RALPH_PLAN_KEY="proxy-explicit-plan"
  ralph_mcp_proxy_append_windowing_telemetry "$WORKSPACE" "Grep" 5000 1000 1250 250 0 "def1234567890123"

  run jq -r '.planKey' "$RALPH_RESULT_WINDOWING_LOG"
  [ "$output" = "proxy-explicit-plan" ]
  run jq -r '.planKeyFallback' "$RALPH_RESULT_WINDOWING_LOG"
  [ "$output" = "false" ]
}
