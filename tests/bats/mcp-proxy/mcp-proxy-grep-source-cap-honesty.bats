#!/usr/bin/env bats
# Coverage for honest source-capped storage/envelope metadata (PLAN15):
# a capped grep must never claim storageLayout:"full" or complete/exact
# source output, and must recommend narrowing rather than escalating to raw.

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
    name: "grep-source-cap-honesty",
    proxyOwnedTools: { enabled: true, maxGrepMatches: 100000 },
    resultByteCap: 65536,
    toolResultByteCaps: { ralph_proxy_grep: 65536 }
  }'
}

invoke_grep_to_file() {
  local grep_args="${1:-}" out="${2:-}"
  env \
    RALPH_MCP_PROXY_POLICY_INLINE="$(policy_json)" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$8"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" "$grep_args" "$out"
}

@test "capped grep: envelope reports sourceComplete false, sourceCapped true, and a narrowing guidance" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 100000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus" '{pattern:$p, path:$path}')"

  run invoke_grep_to_file "$args" "$out"
  [ "$status" -eq 0 ]

  local envelope
  envelope="$(jq -r '.content[0].text' "$out")"
  run jq -e '.sourceComplete == false' <<<"$envelope"
  [ "$status" -eq 0 ]
  run jq -e '.sourceCapped == true' <<<"$envelope"
  [ "$status" -eq 0 ]
  run jq -e '.sourceCapReason | length > 0' <<<"$envelope"
  [ "$status" -eq 0 ]
  run jq -e '.truncated == true' <<<"$envelope"
  [ "$status" -eq 0 ]
  run jq -e '.guidance | test("narrow"; "i")' <<<"$envelope"
  [ "$status" -eq 0 ]
  run jq -e '.guidance | test("is exhaustive|is complete|fully searched|guaranteed complete")' <<<"$envelope"
  [ "$status" -ne 0 ]
}

@test "capped grep: no claim of exact/full/complete source output anywhere in the envelope" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 100000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus" '{pattern:$p, path:$path}')"

  run invoke_grep_to_file "$args" "$out"
  [ "$status" -eq 0 ]

  local envelope
  envelope="$(jq -r '.content[0].text' "$out")"
  run jq -e '[.., ""] | flatten | map(select(type == "string")) | join(" ") | test("exact/full|full exact output"; "i")' <<<"$envelope"
  [ "$status" -ne 0 ]
}

@test "capped grep: stored dedupe metadata is not storageLayout full" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 100000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus" '{pattern:$p, path:$path}')"

  run invoke_grep_to_file "$args" "$out"
  [ "$status" -eq 0 ]
  local result_id
  result_id="$(jq -r '.content[0].text' "$out" | jq -r '.resultId')"
  [ -n "$result_id" ]

  local meta_file
  meta_file="$(find "$WS" -path "*result-store*" -name "*.json" 2>/dev/null | xargs grep -l "$result_id" 2>/dev/null | head -1)"
  if [[ -n "$meta_file" ]]; then
    run jq -e '.storageLayout == "full"' "$meta_file"
    [ "$status" -ne 0 ]
  fi
}

@test "uncapped small grep: envelope/preview path is unaffected (no sourceCapped field forced true)" {
  mkdir -p "$WS/corpus"
  printf 'NEEDLE small one\nNEEDLE small two\n' > "$WS/corpus/small.txt"
  local args out="$WS/out.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/small.txt" '{pattern:$p, path:$path}')"

  run invoke_grep_to_file "$args" "$out"
  [ "$status" -eq 0 ]

  local text
  text="$(jq -r '.content[0].text' "$out")"
  run jq -e . <<<"$text"
  if [ "$status" -eq 0 ]; then
    run jq -e '.sourceCapped == true' <<<"$text"
    [ "$status" -ne 0 ]
  fi
}
