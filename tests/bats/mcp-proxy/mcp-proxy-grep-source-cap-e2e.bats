#!/usr/bin/env bats
# End-to-end regression suite for grep source caps (PLAN15): exercises the
# real MCP tool call path (ralph_mcp_proxy_call_owned_tool) end to end,
# across the ripgrep and pure-Bash fallback collectors, generated temporary
# corpora, and the full envelope/telemetry/dedupe pipeline.

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
  _no_rg_stub="$WS/no-rg-path"
  mkdir -p "$_no_rg_stub"
  for tool in bash cat mkdir rm ls date dirname mktemp printf sh tr grep find sed awk basename wc head env seq jq; do
    local real
    real="$(type -P "$tool" 2>/dev/null)" || continue
    ln -sf "$real" "$_no_rg_stub/$tool"
  done
}

teardown() {
  rm -rf "$WS"
}

policy_json() {
  local byte_cap="${1:-65536}" max_matches="${2:-100000}"
  jq -nc --argjson bc "$byte_cap" --argjson mm "$max_matches" '{
    name: "grep-source-cap-e2e",
    proxyOwnedTools: { enabled: true, maxGrepMatches: $mm },
    resultByteCap: $bc,
    toolResultByteCaps: { ralph_proxy_grep: $bc }
  }'
}

invoke_grep() {
  local policy="${1:-}" grep_args="${2:-}" out="${3:-}" path_override="${4:-}"
  env \
    RALPH_MCP_PROXY_POLICY_INLINE="$policy" \
    RALPH_RESULT_WINDOWING_LOG="$RALPH_RESULT_WINDOWING_LOG" \
    PATH="${path_override:-$PATH}" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$8"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$grep_args" "$out"
}

@test "e2e: rg path, many short matches, capped with honest telemetry" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 5000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/big.txt" '{pattern:$p, path:$path}')"

  run invoke_grep "$(policy_json 65536)" "$args" "$out"
  [ "$status" -eq 0 ]
  run jq -e '.content[0].text | length > 0' "$out"
  [ "$status" -eq 0 ]
}

@test "e2e: fallback (no rg on PATH) path, many short matches, capped with honest telemetry" {
  command -v rg >/dev/null 2>&1 || skip "rg required to prove fallback differs"
  mkdir -p "$WS/corpus"
  local i
  for i in $(seq 1 300); do
    printf 'NEEDLE match one\nNEEDLE match two\n' > "$WS/corpus/f$i.txt"
  done
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus" '{pattern:$p, path:$path}')"

  run invoke_grep "$(policy_json 65536 5)" "$args" "$out" "$_no_rg_stub"
  [ "$status" -eq 0 ]
  run jq -e '.content[0].text | length > 0' "$out"
  [ "$status" -eq 0 ]
}

@test "e2e: one huge line is bounded and reported truncated" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN {
    line = "NEEDLE "
    chunk = "abcdefghijklmnopqrstuvwxyz0123456789"
    while (length(line) < 3000000) line = line chunk
    print line
  }' > "$WS/corpus/huge.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/huge.txt" '{pattern:$p, path:$path}')"

  run invoke_grep "$(policy_json 65536)" "$args" "$out"
  [ "$status" -eq 0 ]
  run jq -e '.content[0].text | length > 0' "$out"
  [ "$status" -eq 0 ]
}

@test "e2e: UTF-8 matches are handled without corruption" {
  mkdir -p "$WS/corpus"
  printf 'NEEDLE caf\xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e \xf0\x9f\x9a\x80 line\n' > "$WS/corpus/utf8.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/utf8.txt" '{pattern:$p, path:$path}')"

  run invoke_grep "$(policy_json 65536)" "$args" "$out"
  [ "$status" -eq 0 ]
  run jq -e . "$out"
  [ "$status" -eq 0 ]
}

@test "e2e: dedupe replay of a capped grep still reports incompleteness" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 5000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  local args
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/big.txt" '{pattern:$p, path:$path}')"

  run env \
    RALPH_MCP_PROXY_POLICY_INLINE="$(policy_json 65536)" \
    RALPH_RESULT_WINDOWING_LOG="$RALPH_RESULT_WINDOWING_LOG" \
    bash -c '
      source "$1"; source "$2"; source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$8"
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$9"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$args" "$WS/out1.json" "$WS/out2.json"
  [ "$status" -eq 0 ]

  local second
  second="$(jq -r '.content[0].text' "$WS/out2.json")"
  run jq -e '.deduped == true and .sourceComplete == false' <<<"$second"
  [ "$status" -eq 0 ]
}

@test "e2e: small uncapped follow-up call after a capped call stays complete" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 5000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  printf 'NEEDLE small one\nNEEDLE small two\n' > "$WS/corpus/small.txt"

  local capped_args small_args
  capped_args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/big.txt" '{pattern:$p, path:$path}')"
  small_args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/small.txt" '{pattern:$p, path:$path}')"

  run invoke_grep "$(policy_json 65536)" "$capped_args" "$WS/out1.json"
  [ "$status" -eq 0 ]
  run invoke_grep "$(policy_json 65536)" "$small_args" "$WS/out2.json"
  [ "$status" -eq 0 ]

  local match_lines
  match_lines="$(jq -r '.content[0].text' "$WS/out2.json" | grep -c "NEEDLE small")"
  [ "$match_lines" = "2" ]
}

@test "e2e: intermediate and stored temp files never exceed the hard byte-cap ceiling" {
  mkdir -p "$WS/corpus" "$WS/tmpwatch"
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
    RALPH_MCP_PROXY_POLICY_INLINE="$(policy_json 65536)" \
    TMPDIR="$WS/tmpwatch" \
    bash -c '
      source "$1"; source "$2"; source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" >/dev/null || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >/dev/null
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$args"

  local largest=0 f size
  for f in "$WS"/tmpwatch/*; do
    [ -e "$f" ] || continue
    size="$(wc -c < "$f" | tr -d ' ')"
    [ "$size" -le 4194304 ]
    if [ "$size" -gt "$largest" ]; then largest="$size"; fi
  done
  echo "largest intermediate/stored byte size observed: $largest" >&3
}
