#!/usr/bin/env bats
# Coverage for v2 inlineCandidateBytes/inlineCandidateTokens telemetry
# (PLAN15): the inline candidate is the result after max_matches/head_limit,
# not the full captured source, and must differ from sourceCapturedBytes when
# a pathological corpus produces far more matches than max_matches allows.

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
  local max_matches="${1:-20}"
  jq -nc --argjson mm "$max_matches" '{
    name: "inline-candidate-metrics",
    proxyOwnedTools: { enabled: true, maxGrepMatches: $mm },
    resultByteCap: 65536,
    toolResultByteCaps: { ralph_proxy_grep: 65536 }
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

@test "large capture, small max_matches: inlineCandidateBytes is far smaller than sourceCapturedBytes" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 5000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus" '{pattern:$p, path:$path}')"

  run invoke_grep "$(policy_json 20)" "$args" "$out"
  [ "$status" -eq 0 ]

  [ -f "$RALPH_RESULT_WINDOWING_LOG" ]
  local record
  record="$(tail -n1 "$RALPH_RESULT_WINDOWING_LOG")"

  run jq -e '.measurementVersion == 2' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e '.sourceCapturedBytes > .inlineCandidateBytes' <<<"$record"
  [ "$status" -eq 0 ]
  run jq -e '.inlineCandidateTokens > 0' <<<"$record"
  [ "$status" -eq 0 ]

  # Candidate accounting must not include matches beyond max_matches: the
  # inline candidate byte count should be in the same order of magnitude as
  # 20 short matching lines (even with an absolute temp-dir path prefix on
  # each line), not the full ~5000-line capture.
  run jq -e '.inlineCandidateBytes < 10000' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "normal small grep: sourceCapturedBytes and inlineCandidateBytes are equal (nothing eligible was excluded)" {
  mkdir -p "$WS/corpus"
  printf 'NEEDLE one\nNEEDLE two\nNEEDLE three\n' > "$WS/corpus/small.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/small.txt" '{pattern:$p, path:$path}')"

  run invoke_grep "$(policy_json 100)" "$args" "$out"
  [ "$status" -eq 0 ]

  # A small uncapped grep may not need an envelope at all (below byte cap),
  # in which case no windowing record is written; that is fine, but if one
  # was written its source/candidate bytes must be equal.
  if [[ -s "$RALPH_RESULT_WINDOWING_LOG" ]]; then
    local record
    record="$(tail -n1 "$RALPH_RESULT_WINDOWING_LOG")"
    run jq -e '.sourceCapturedBytes == .inlineCandidateBytes' <<<"$record"
    [ "$status" -eq 0 ]
  fi
}
