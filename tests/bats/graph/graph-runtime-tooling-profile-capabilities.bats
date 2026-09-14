#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/graph/graph-runtime-capabilities.sh"

DECLARED_PROFILE_KEYS='RALPH_MODE
RALPH_PROXY_SHELL_COMPACT
RALPH_COMPACT_GENERIC_FALLBACK
RALPH_COMPACT_GENERIC_THRESHOLD_BYTES
RALPH_NATIVE_RESULT_COMPACT'

assert_all_keys_declared() {
  local json="$1" key
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    printf '%s\n' "$DECLARED_PROFILE_KEYS" | grep -qxF "$key" \
      || fail "reported key '$key' is not one of the five declared profile env keys"
  done < <(printf '%s' "$json" | jq -r '.keys | keys[]')
}

assert_reason_codes_present() {
  local json="$1" key
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    local reason
    reason="$(printf '%s' "$json" | jq -r --arg k "$key" '.keys[$k].reason')"
    [[ -n "$reason" && "$reason" != "null" ]] \
      || fail "key '$key' is missing a reason code"
  done < <(printf '%s' "$json" | jq -r '.unsupportedKeys[]')
}

@test "graph_runtime_tooling_profile_capabilities: claude supports all five keys" {
  json="$(graph_runtime_tooling_profile_capabilities claude)"
  [ "$(printf '%s' "$json" | jq -r '.runtime')" = "claude" ]
  [ "$(printf '%s' "$json" | jq -r '.schemaVersion')" = "1" ]
  assert_all_keys_declared "$json"
  assert_reason_codes_present "$json"
  [ "$(printf '%s' "$json" | jq -r '.supportedKeys | length')" = "5" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupportedKeys | length')" = "0" ]
}

@test "graph_runtime_tooling_profile_capabilities: cursor supports all five keys" {
  json="$(graph_runtime_tooling_profile_capabilities cursor)"
  assert_all_keys_declared "$json"
  assert_reason_codes_present "$json"
  [ "$(printf '%s' "$json" | jq -r '.supportedKeys | length')" = "5" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupportedKeys | length')" = "0" ]
}

@test "graph_runtime_tooling_profile_capabilities: codex supports all five keys" {
  json="$(graph_runtime_tooling_profile_capabilities codex)"
  assert_all_keys_declared "$json"
  assert_reason_codes_present "$json"
  [ "$(printf '%s' "$json" | jq -r '.supportedKeys | length')" = "5" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupportedKeys | length')" = "0" ]
}

@test "graph_runtime_tooling_profile_capabilities: opencode supports the shell-compaction keys but not native result compact" {
  json="$(graph_runtime_tooling_profile_capabilities opencode)"
  assert_all_keys_declared "$json"
  assert_reason_codes_present "$json"
  [ "$(printf '%s' "$json" | jq -e '.keys.RALPH_MODE.supported')" = "true" ]
  [ "$(printf '%s' "$json" | jq -e '.keys.RALPH_PROXY_SHELL_COMPACT.supported')" = "true" ]
  [ "$(printf '%s' "$json" | jq -e '.keys.RALPH_COMPACT_GENERIC_FALLBACK.supported')" = "true" ]
  [ "$(printf '%s' "$json" | jq -e '.keys.RALPH_COMPACT_GENERIC_THRESHOLD_BYTES.supported')" = "true" ]
  [ "$(printf '%s' "$json" | jq -e '.keys.RALPH_NATIVE_RESULT_COMPACT.supported')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.keys.RALPH_NATIVE_RESULT_COMPACT.reason')" = "opencode-headless-hook-invocation-unproven" ]
}

@test "graph_runtime_tooling_profile_capabilities: antigravity supports native result compact but not the shell-compaction keys" {
  json="$(graph_runtime_tooling_profile_capabilities antigravity)"
  assert_all_keys_declared "$json"
  assert_reason_codes_present "$json"
  [ "$(printf '%s' "$json" | jq -e '.keys.RALPH_MODE.supported')" = "true" ]
  [ "$(printf '%s' "$json" | jq -e '.keys.RALPH_PROXY_SHELL_COMPACT.supported')" = "false" ]
  [ "$(printf '%s' "$json" | jq -e '.keys.RALPH_COMPACT_GENERIC_FALLBACK.supported')" = "false" ]
  [ "$(printf '%s' "$json" | jq -e '.keys.RALPH_COMPACT_GENERIC_THRESHOLD_BYTES.supported')" = "false" ]
  [ "$(printf '%s' "$json" | jq -e '.keys.RALPH_NATIVE_RESULT_COMPACT.supported')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.keys.RALPH_PROXY_SHELL_COMPACT.reason')" = "not-in-plan49-universal-mcp-matrix" ]
  [ "$(printf '%s' "$json" | jq -r '.keys.RALPH_COMPACT_GENERIC_FALLBACK.reason')" = "not-in-plan49-universal-mcp-matrix" ]
  [ "$(printf '%s' "$json" | jq -r '.keys.RALPH_COMPACT_GENERIC_THRESHOLD_BYTES.reason')" = "not-in-plan49-universal-mcp-matrix" ]
}

@test "graph_runtime_tooling_profile_capabilities: unknown runtime fails closed on every key" {
  json="$(graph_runtime_tooling_profile_capabilities not-a-runtime)"
  [ "$(printf '%s' "$json" | jq -r '.supportedKeys | length')" = "0" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupportedKeys | length')" = "5" ]
  assert_all_keys_declared "$json"
  assert_reason_codes_present "$json"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    [ "$(printf '%s' "$json" | jq -r --arg k "$key" '.keys[$k].reason')" = "unknown-runtime" ]
  done <<< "$DECLARED_PROFILE_KEYS"
}

@test "graph_runtime_tooling_profile_capabilities: empty runtime fails closed" {
  json="$(graph_runtime_tooling_profile_capabilities "")"
  [ "$(printf '%s' "$json" | jq -r '.supportedKeys | length')" = "0" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupportedKeys | length')" = "5" ]
}

@test "graph_runtime_tooling_profile_key_is_supported: reflects supportedKeys" {
  json="$(graph_runtime_tooling_profile_capabilities claude)"
  run graph_runtime_tooling_profile_key_is_supported "$json" RALPH_MODE
  [ "$status" -eq 0 ]

  json="$(graph_runtime_tooling_profile_capabilities antigravity)"
  run graph_runtime_tooling_profile_key_is_supported "$json" RALPH_PROXY_SHELL_COMPACT
  [ "$status" -ne 0 ]
}
