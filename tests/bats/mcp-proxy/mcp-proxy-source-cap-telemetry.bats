#!/usr/bin/env bats
# Coverage for wiring bounded-collector source-cap state into v2 windowing
# telemetry (PLAN15): capped records carry sourceCapped/sourceComplete/
# capReason/capLimits; uncapped records explicitly report a complete source
# and never leak stale cap state from a prior capped call.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  WS="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$WS"
  RALPH_RESULT_WINDOWING_LOG="$WS/windowing.jsonl"
  export RALPH_RESULT_WINDOWING_LOG
}

teardown() {
  rm -rf "$WS"
}

policy_json() {
  local byte_cap="${1:-65536}"
  jq -nc --argjson bc "$byte_cap" '{
    name: "source-cap-telemetry",
    proxyOwnedTools: { enabled: true, maxGrepMatches: 100000 },
    resultByteCap: $bc,
    toolResultByteCaps: { ralph_proxy_grep: $bc }
  }'
}

invoke_grep() {
  local policy="${1:-}" grep_args="${2:-}" out="${3:-}"
  env \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy" \
    RALPH_RESULT_WINDOWING_LOG="$RALPH_RESULT_WINDOWING_LOG" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$8"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$grep_args" "$out"
}

@test "capped record carries sourceCapped, sourceComplete false, reason, and limits" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 5000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus" '{pattern:$p, path:$path}')"

  run invoke_grep "$(policy_json 65536)" "$args" "$out"
  [ "$status" -eq 0 ]

  [ -f "$RALPH_RESULT_WINDOWING_LOG" ]
  local record
  record="$(tail -n1 "$RALPH_RESULT_WINDOWING_LOG")"
  run jq -e '.sourceCapped == true' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e '.sourceComplete == false' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e '.capReason | length > 0' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e '.capLimitBytes > 0 and .capLimitLines > 0 and .capLimitPerLineBytes > 0' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e '.storedBytes > 0' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e . <<<"$record"
  [ "$status" -eq 0 ]
}

@test "uncapped record after a capped one does not leak sourceCapped state" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 5000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  printf 'NEEDLE small one\nNEEDLE small two\n' > "$WS/corpus/small.txt"

  local capped_args small_args
  capped_args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/big.txt" '{pattern:$p, path:$path}')"
  small_args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/small.txt" '{pattern:$p, path:$path}')"

  run invoke_grep "$(policy_json 65536)" "$capped_args" "$WS/out1.json"
  [ "$status" -eq 0 ]
  # A tiny result byte cap forces the small, uncapped-source grep through the
  # envelope path too, so it actually writes a second windowing record.
  run invoke_grep "$(policy_json 16)" "$small_args" "$WS/out2.json"
  [ "$status" -eq 0 ]

  local n
  n="$(wc -l < "$RALPH_RESULT_WINDOWING_LOG" | tr -d ' ')"
  [ "$n" -ge 1 ]

  local last
  last="$(tail -n1 "$RALPH_RESULT_WINDOWING_LOG")"
  run jq -e '.sourceCapped == true' <<<"$last"
  [ "$status" -ne 0 ]
  run jq -e 'has("capReason")' <<<"$last"
  [ "$status" -ne 0 ]
}
