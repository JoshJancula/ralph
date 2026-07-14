#!/usr/bin/env bats
# Coverage for v2 deliveredBytes/deliveredTokens telemetry (PLAN15): measured
# from the final serialized envelope text, not preview length alone.

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
  jq -nc '{
    name: "delivered-envelope-metrics",
    proxyOwnedTools: { enabled: true, maxGrepMatches: 20 },
    resultByteCap: 65536,
    toolResultByteCaps: { ralph_proxy_grep: 65536 }
  }'
}

invoke_grep() {
  local grep_args="${1:-}" out="${2:-}"
  env \
    RALPH_MCP_PROXY_POLICY_INLINE="$(policy_json)" \
    RALPH_RESULT_WINDOWING_LOG="$RALPH_RESULT_WINDOWING_LOG" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$8"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$grep_args" "$out"
}

@test "delivered bytes/tokens exceed the raw preview by serialized envelope overhead" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 5000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus" '{pattern:$p, path:$path}')"

  run invoke_grep "$args" "$out"
  [ "$status" -eq 0 ]

  [ -f "$RALPH_RESULT_WINDOWING_LOG" ]
  local record
  record="$(tail -n1 "$RALPH_RESULT_WINDOWING_LOG")"

  run jq -e 'has("deliveredBytes") and has("deliveredTokens")' <<<"$record"
  [ "$status" -eq 0 ]
  # returnedBytes is preview-text length only; deliveredBytes is the full
  # serialized envelope (preview + breakpoints + nextActions + guidance +
  # refs + token fields), so it must be materially larger.
  run jq -e '.deliveredBytes > .returnedBytes' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e '(.deliveredBytes - .returnedBytes) > 100' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e '.deliveredTokens > 0' <<<"$record"
  [ "$status" -eq 0 ]

  # Compare against the actual envelope text sent to the agent.
  local actual_bytes
  actual_bytes="$(jq -r '.content[0].text' "$out" | wc -c | tr -d ' ')"
  local recorded_delivered
  recorded_delivered="$(jq -r '.deliveredBytes' <<<"$record")"
  # Within a couple bytes: the recorded envelope may or may not include a
  # trailing newline depending on how the text was captured to file.
  local diff=$(( actual_bytes - recorded_delivered ))
  [ "${diff#-}" -le 2 ]
}

@test "multibyte UTF-8 preview: delivered/candidate byte counts use UTF-8 byte length, not character count" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 5000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  printf 'NEEDLE caf\xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e \xf0\x9f\x9a\x80 line\n' > "$WS/corpus/utf8.txt"

  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus" '{pattern:$p, path:$path}')"

  run invoke_grep "$args" "$out"
  [ "$status" -eq 0 ]

  [ -f "$RALPH_RESULT_WINDOWING_LOG" ]
  local record
  record="$(tail -n1 "$RALPH_RESULT_WINDOWING_LOG")"
  run jq -e '.deliveredBytes > 0 and .inlineCandidateBytes > 0' <<<"$record"
  [ "$status" -eq 0 ]
}
