#!/usr/bin/env bats
# Integration coverage: ralph_proxy_grep uses the bounded collectors so a
# pathological capture stays bounded, while a normal small grep remains
# uncapped and complete (PLAN15).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  WS="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$WS"
}

teardown() {
  rm -rf "$WS"
}

policy_json() {
  jq -nc '{
    name: "grep-source-cap-integration",
    proxyOwnedTools: { enabled: true, maxGrepMatches: 100000 },
    resultByteCap: 65536,
    toolResultByteCaps: { ralph_proxy_grep: 65536 }
  }'
}

invoke_grep_pair_to_files() {
  local grep_args1="${1:-}" grep_args2="${2:-}" out1="${3:-}" out2="${4:-}"
  env \
    RALPH_MCP_PROXY_POLICY_INLINE="$(policy_json)" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$9"
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$8" >"${10}"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" \
      "$grep_args1" "$grep_args2" "$out1" "$out2"
}

@test "pathological grep returns a non-empty valid preview and stays within the source cap" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN {
    for (i = 0; i < 100000; i++) printf "line %d NEEDLE marker filler text\n", i
  }' > "$WS/corpus/big.txt"

  local args
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus" '{pattern:$p, path:$path}')"

  local out1="$WS/out1.json" out2="$WS/out2.json"
  run invoke_grep_pair_to_files "$args" "$args" "$out1" "$out2"
  [ "$status" -eq 0 ]

  run jq -e . "$out1"
  [ "$status" -eq 0 ]
  run jq -e '.content[0].text | length > 0' "$out1"
  [ "$status" -eq 0 ]
}

@test "small uncapped grep followed by pathological grep: small one stays complete" {
  mkdir -p "$WS/corpus"
  printf 'NEEDLE small one\nNEEDLE small two\n' > "$WS/corpus/small.txt"

  local small_args
  small_args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/small.txt" '{pattern:$p, path:$path}')"

  local out1="$WS/out1.json" out2="$WS/out2.json"
  run invoke_grep_pair_to_files "$small_args" "$small_args" "$out1" "$out2"
  [ "$status" -eq 0 ]

  local match_lines
  match_lines="$(jq -r '.content[0].text' "$out1" | grep -c "NEEDLE small")"
  [ "$match_lines" = "2" ]
}

@test "intermediate capture temp file never exceeds the selected source byte cap" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN {
    line = "NEEDLE "
    chunk = "abcdefghijklmnopqrstuvwxyz0123456789"
    while (length(line) < 3000000) line = line chunk
    print line
  }' > "$WS/corpus/huge.txt"
  awk 'BEGIN { for (i = 0; i < 50000; i++) printf "line %d NEEDLE\n", i }' >> "$WS/corpus/huge.txt"

  local args
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/huge.txt" '{pattern:$p, path:$path}')"

  env \
    RALPH_MCP_PROXY_POLICY_INLINE="$(policy_json)" \
    RALPH_MCP_PROXY_TOOLS_DEBUG_TMP_DIR="$WS/tmpwatch" \
    bash -c '
      mkdir -p "$9"
      export TMPDIR="$9"
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >/dev/null
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$args" "" "$WS/tmpwatch"

  # No leftover temp file should exceed the hard byte-cap ceiling (4 MiB);
  # the collector must never let an intermediate file grow past that.
  local f
  for f in "$WS"/tmpwatch/*; do
    [ -e "$f" ] || continue
    local size
    size="$(wc -c < "$f" | tr -d ' ')"
    [ "$size" -le 4194304 ]
  done
}
