#!/usr/bin/env bats
# Table-driven coverage for the pure grep source-cap policy helper (PLAN15).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"

setup() {
  source "$POLICY_LIB"
  unset RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_BYTE_CAP
  unset RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_LINE_CAP
  unset RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_PER_LINE_BYTE_CAP
}

_assert_within_ceiling() {
  local policy="$1"
  run jq -e '.byteCap > 0 and .byteCap <= 4194304' <<<"$policy"
  [ "$status" -eq 0 ]
  run jq -e '.lineCap > 0 and .lineCap <= 20000' <<<"$policy"
  [ "$status" -eq 0 ]
  run jq -e '.perLineCap > 0 and .perLineCap <= 65536' <<<"$policy"
  [ "$status" -eq 0 ]
}

@test "default policy (no overrides, no result cap) returns the selected defaults" {
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json)"
  run jq -c '[.byteCap, .lineCap, .perLineCap]' <<<"$policy"
  [ "$output" = "[262144,2000,4096]" ]
  _assert_within_ceiling "$policy"
}

@test "small result byte cap does not lower the byte cap below the default floor" {
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json 1024)"
  run jq -r '.byteCap' <<<"$policy"
  [ "$output" = "262144" ]
  _assert_within_ceiling "$policy"
}

@test "large result byte cap raises the floor but is clamped to the ceiling" {
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json 999999999)"
  run jq -r '.byteCap' <<<"$policy"
  [ "$output" = "4194304" ]
  _assert_within_ceiling "$policy"
}

@test "moderate result byte cap above the default raises the byte floor" {
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json 500000)"
  run jq -r '.byteCap' <<<"$policy"
  [ "$output" = "500000" ]
  _assert_within_ceiling "$policy"
}

@test "explicit valid overrides are honored and clamped to ceilings" {
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_BYTE_CAP=131072
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_LINE_CAP=1000
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_PER_LINE_BYTE_CAP=8192
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json)"
  run jq -c '[.byteCap, .lineCap, .perLineCap]' <<<"$policy"
  [ "$output" = "[131072,1000,8192]" ]
  _assert_within_ceiling "$policy"
}

@test "invalid override strings fall back to defaults" {
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_BYTE_CAP="not-a-number"
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_LINE_CAP="NaN"
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_PER_LINE_BYTE_CAP="-4096"
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json)"
  run jq -c '[.byteCap, .lineCap, .perLineCap]' <<<"$policy"
  [ "$output" = "[262144,2000,4096]" ]
  _assert_within_ceiling "$policy"
}

@test "zero override values fall back to defaults" {
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_BYTE_CAP=0
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_LINE_CAP=0
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_PER_LINE_BYTE_CAP=0
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json)"
  run jq -c '[.byteCap, .lineCap, .perLineCap]' <<<"$policy"
  [ "$output" = "[262144,2000,4096]" ]
  _assert_within_ceiling "$policy"
}

@test "override values exactly at the ceiling are accepted unchanged" {
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_BYTE_CAP=4194304
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_LINE_CAP=20000
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_PER_LINE_BYTE_CAP=65536
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json)"
  run jq -c '[.byteCap, .lineCap, .perLineCap]' <<<"$policy"
  [ "$output" = "[4194304,20000,65536]" ]
  _assert_within_ceiling "$policy"
}

@test "override values one above the ceiling are clamped down" {
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_BYTE_CAP=4194305
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_LINE_CAP=20001
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_PER_LINE_BYTE_CAP=65537
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json)"
  run jq -c '[.byteCap, .lineCap, .perLineCap]' <<<"$policy"
  [ "$output" = "[4194304,20000,65536]" ]
  _assert_within_ceiling "$policy"
}

@test "grossly oversized override is clamped to the ceiling, not passed through" {
  export RALPH_MCP_PROXY_POLICY_OWNED_GREP_SOURCE_BYTE_CAP=99999999999
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json)"
  run jq -r '.byteCap' <<<"$policy"
  [ "$output" = "4194304" ]
  _assert_within_ceiling "$policy"
}

@test "invalid result cap argument (non-numeric) is ignored, defaults apply" {
  local policy
  policy="$(ralph_mcp_proxy_grep_source_cap_policy_json "bogus")"
  run jq -r '.byteCap' <<<"$policy"
  [ "$output" = "262144" ]
  _assert_within_ceiling "$policy"
}

@test "helper is pure: same args and env produce identical output across calls" {
  local a b
  a="$(ralph_mcp_proxy_grep_source_cap_policy_json 500000)"
  b="$(ralph_mcp_proxy_grep_source_cap_policy_json 500000)"
  [ "$a" = "$b" ]
}

@test "unrelated tool result byte cap resolution is unaffected by the new helper" {
  run ralph_mcp_proxy_result_byte_cap_for_tool "ralph_proxy_read"
  [ "$status" -eq 0 ]
}
