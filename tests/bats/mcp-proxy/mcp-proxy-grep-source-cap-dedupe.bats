#!/usr/bin/env bats
# Coverage: a duplicate (deduped) source-capped grep must keep reporting
# incompleteness on replay, never silently upgrading to a complete result
# (PLAN15). Replay returns the cached body with the d2 repeat prefix rather
# than the old "(duplicate ... suppressed ...)" stub.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

SEARCH_DEDUPE_GREP_PREFIX='(repeat of an earlier identical grep in this session; no writes since)'

setup() {
  WS="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$WS"
  bats_skip_known_ci_flakes
}

teardown() {
  rm -rf "$WS"
}

policy_json() {
  jq -nc '{
    name: "grep-source-cap-dedupe",
    proxyOwnedTools: { enabled: true, maxGrepMatches: 100000 },
    resultByteCap: 65536,
    toolResultByteCaps: { ralph_proxy_grep: 65536 }
  }'
}

invoke_grep_pair_to_files() {
  local grep_args="${1:-}" out1="${2:-}" out2="${3:-}"
  env \
    RALPH_MCP_PROXY_POLICY_INLINE="$(policy_json)" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$8"
      ralph_mcp_proxy_call_owned_tool "$6" "ralph_proxy_grep" "$7" >"$9"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$WS" \
      "$grep_args" "$out1" "$out2"
}

@test "duplicate of a source-capped grep stays deduped AND still reports partial-source state" {
  mkdir -p "$WS/corpus"
  # Keep the source comfortably above the 64 KiB cap without creating a
  # multi-megabyte fixture on constrained CI runners.
  awk 'BEGIN { for (i = 0; i < 20000; i++) printf "line %d NEEDLE marker filler text\n", i }' > "$WS/corpus/big.txt"
  local args out1="$WS/out1.json" out2="$WS/out2.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus" '{pattern:$p, path:$path}')"

  run invoke_grep_pair_to_files "$args" "$out1" "$out2"
  [ "$status" -eq 0 ]

  local first_env second_env
  first_env="$(jq -r '.content[0].text' "$out1")"
  second_env="$(jq -r '.content[0].text' "$out2")"

  run jq -e '.sourceCapped == true' <<<"$first_env"
  [ "$status" -eq 0 ]

  run jq -e \
    --arg prefix "$SEARCH_DEDUPE_GREP_PREFIX" '
    .deduped == true
    and (.preview | startswith($prefix))
    and (.preview | test("stopped early"))
    and (.preview | test("duplicate grep suppressed") | not)
  ' <<<"$second_env"
  [ "$status" -eq 0 ]
  run jq -e '.sourceComplete == false' <<<"$second_env"
  [ "$status" -eq 0 ]
  run jq -e '.sourceCapped == true' <<<"$second_env"
  [ "$status" -eq 0 ]
  run jq -e '.guidance | test("narrow"; "i")' <<<"$second_env"
  [ "$status" -eq 0 ]
  run jq -e '.guidance | test("is exhaustive|is complete|fully searched")' <<<"$second_env"
  [ "$status" -ne 0 ]
}

@test "duplicate of an uncapped grep remains complete on replay" {
  mkdir -p "$WS/corpus"
  awk 'BEGIN { for (i = 0; i < 500; i++) printf "line %d NEEDLE\n", i }' > "$WS/corpus/small.txt"
  local args out1="$WS/out1.json" out2="$WS/out2.json"
  args="$(jq -nc --arg p "NEEDLE" --arg path "corpus/small.txt" '{pattern:$p, path:$path}')"

  run invoke_grep_pair_to_files "$args" "$out1" "$out2"
  [ "$status" -eq 0 ]

  local second_text
  second_text="$(jq -r '.content[0].text' "$out2")"
  # Complete (uncapped) first deliveries are inline; the repeat stays inline with
  # the prefix and must not invent source-cap incompleteness.
  if [[ "$second_text" == "{"* ]]; then
    run jq -e \
      --arg prefix "$SEARCH_DEDUPE_GREP_PREFIX" '
      .deduped == true
      and (.preview | startswith($prefix))
      and ((.sourceCapped // false) == false)
    ' <<<"$second_text"
    [ "$status" -eq 0 ]
  else
    [[ "$second_text" == "$SEARCH_DEDUPE_GREP_PREFIX"$'\n'* ]]
    [[ "$second_text" == *"line 0 NEEDLE"* ]]
    [[ "$second_text" != *"duplicate grep suppressed"* ]]
    [[ "$second_text" != *"stopped early"* ]]
  fi
}
