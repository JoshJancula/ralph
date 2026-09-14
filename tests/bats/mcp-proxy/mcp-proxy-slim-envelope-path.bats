#!/usr/bin/env bats
# Coverage for the slim-envelope path: when tool-level limits (max_matches /
# head_limit / maxReadBytes) have already reduced the output below the byte cap,
# the result is stored for readback but delivered in a slim envelope -- valid
# JSON with truncated/preview/resultId and none of the retrieval scaffolding.
#
# The full envelope runs ~1,155 bytes per result (breakpoints, three nextActions,
# guidance, compactedRef/rawRef). Wrapping an already-small result in it delivered
# MORE bytes than inlining did, which is what made result windowing a net context
# loss on real plan runs (PLAN23: grep -158,742 bytes, read -33,631 bytes).
#
# The response must stay JSON: grep dedupe and the result follow-up tools parse
# it with fromjson.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  WS="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_MCP_EXPLORATION_RESULT_COMPACT=1
  RALPH_RESULT_WINDOWING_LOG="$WS/windowing.jsonl"
  export RALPH_RESULT_WINDOWING_LOG
}

teardown() {
  rm -rf "$WS"
}

# Byte cap sits above the 20-match preview but far below the full grep capture,
# so the result is stored while the inline candidate still fits.
policy_json() {
  jq -nc '{
    name: "slim-envelope-path",
    proxyOwnedTools: { enabled: true, maxGrepMatches: 20 },
    resultByteCap: 8192,
    toolResultByteCaps: { ralph_proxy_grep: 8192, ralph_proxy_result_read: 262144 }
  }'
}

call_tool() {
  local policy="$1" tool="$2" tool_args="$3" out="$4"
  env \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy" \
    RALPH_RESULT_WINDOWING_LOG="$RALPH_RESULT_WINDOWING_LOG" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "$7" "$8" >"$9"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" \
      "$WS" "$tool" "$tool_args" "$out"
}

seed_corpus() {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 5000; i++) printf "line %d NEEDLE marker filler text\n", i }' \
    > "$WS/corpus/big.txt"
}

run_grep() {
  local args
  args="$(jq -nc '{pattern:"NEEDLE", path:"corpus"}')"
  call_tool "$(policy_json)" "ralph_proxy_grep" "$args" "$WS/out.json"
}

payload() {
  jq -r '.content[0].text' "$WS/out.json" | jq -c '.'
}

@test "inline candidate under cap: delivers a slim envelope, not the full one" {
  seed_corpus
  run run_grep
  [ "$status" -eq 0 ]

  local body
  body="$(payload)"

  # The fields every consumer actually reads survive.
  printf '%s\n' "$body" | jq -e '.truncated == true'
  printf '%s\n' "$body" | jq -e '.preview | test("NEEDLE")'
  printf '%s\n' "$body" | jq -e '.resultId | test("^[a-f0-9]{16}$")'
  printf '%s\n' "$body" | jq -e '.originalBytes > .returnedBytes'

  # The expensive retrieval scaffolding does not. (Any guidance present here is
  # grep's source-cap narrowing hint riding in extra_envelope_json, which must
  # survive; what must not survive is the compactedRef/rawRef retrieval guidance.)
  printf '%s\n' "$body" | jq -e 'has("nextActions") | not'
  printf '%s\n' "$body" | jq -e 'has("breakpoints") | not'
  printf '%s\n' "$body" | jq -e 'has("compactedRef") | not'
  printf '%s\n' "$body" | jq -e 'has("rawRef") | not'
  printf '%s\n' "$body" | jq -e 'has("recommendedReadView") | not'
}

@test "slim envelope overhead is a fraction of the full envelope it replaces" {
  seed_corpus
  run run_grep
  [ "$status" -eq 0 ]

  local candidate delivered overhead
  candidate="$(jq -r 'select(.event=="envelope") | .inlineCandidateBytes' "$RALPH_RESULT_WINDOWING_LOG" | tail -n 1)"
  delivered="$(jq -r 'select(.event=="envelope") | .deliveredBytes' "$RALPH_RESULT_WINDOWING_LOG" | tail -n 1)"

  [ -n "$candidate" ]
  [ -n "$delivered" ]

  # On this exact fixture the full envelope delivered 3,149 bytes against a
  # 1,460-byte candidate: 1,689 bytes of overhead. The slim envelope carries JSON
  # keys plus grep's source-cap metadata and narrowing guidance, and lands near
  # 700. Anything approaching the old figure means the full envelope crept back
  # onto this path.
  overhead=$((delivered - candidate))
  [ "$overhead" -lt 900 ]
}

@test "slim envelope path still stores the full source for readback" {
  seed_corpus
  run run_grep
  [ "$status" -eq 0 ]

  local result_id
  result_id="$(payload | jq -r '.resultId')"
  [[ "$result_id" =~ ^[a-f0-9]{16}$ ]]

  local read_args read_out="$WS/read.json"
  read_args="$(jq -nc --arg id "$result_id" '{resultId:$id, view:"raw", byteStart:0, byteEnd:4096}')"

  run call_tool "$(policy_json)" "ralph_proxy_result_read" "$read_args" "$read_out"
  [ "$status" -eq 0 ]

  # The stored source holds matches far beyond the 20 the preview inlined.
  local stored_text
  stored_text="$(jq -r '.content[0].text' "$read_out")"
  [[ "$stored_text" == *"NEEDLE"* ]]
}

@test "source-capped grep keeps its honesty signal in the slim envelope" {
  seed_corpus
  run run_grep
  [ "$status" -eq 0 ]

  local capped
  capped="$(jq -r 'select(.event=="envelope") | .sourceCapped' "$RALPH_RESULT_WINDOWING_LOG" | tail -n 1)"

  # When the source was capped, the agent must still be told so on the cheap
  # path; silently delivering a partial result is the one thing it may not do.
  if [ "$capped" = "true" ]; then
    payload | jq -e '.sourceCapped == true'
  fi
}

@test "slim envelope is an allowlist: search, repomap and shell are never slimmed" {
  local tool
  for tool in ralph_proxy_search ralph_proxy_repomap ralph_proxy_shell ralph_proxy_glob; do
    run bash -c 'source "$1"; ralph_mcp_proxy_result_tool_supports_slim_envelope "$2"' _ "$RESULT_LIB" "$tool"
    [ "$status" -ne 0 ]
  done

  for tool in ralph_proxy_grep ralph_proxy_read; do
    run bash -c 'source "$1"; ralph_mcp_proxy_result_tool_supports_slim_envelope "$2"' _ "$RESULT_LIB" "$tool"
    [ "$status" -eq 0 ]
  done
}
