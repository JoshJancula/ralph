#!/usr/bin/env bats
# Coverage for the effective hook-config resolver (PLAN15): combines gate
# provenance with per-runtime capability to report enabled vs effective.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-effective-hook-config.sh"

setup() {
  source "$LIB"
  unset RALPH_BASH_COMPACT RALPH_NATIVE_RESULT_COMPACT RALPH_PROXY_SHELL_COMPACT RALPH_BASH_REWRITE
}

@test "claude in hybrid mode: proven channels are enabled and effective" {
  local record
  record="$(ralph_effective_hook_config_resolve "bash_compact" "claude" "hybrid")"
  run jq -r '.enabled' <<<"$record"
  [ "$output" = "true" ]
  run jq -r '.effective' <<<"$record"
  [ "$output" = "true" ]
  run jq -r '.reason' <<<"$record"
  [[ "$output" == proven_channel:* ]]
}

@test "bare claude (mode=no): channels disabled, effective false, reason gate_disabled" {
  local record
  record="$(ralph_effective_hook_config_resolve "native_result_compact" "claude" "no")"
  run jq -r '.enabled' <<<"$record"
  [ "$output" = "false" ]
  run jq -r '.effective' <<<"$record"
  [ "$output" = "false" ]
  run jq -r '.reason' <<<"$record"
  [ "$output" = "gate_disabled" ]
}

@test "cursor in hybrid mode: native_result_compact remains disabled unless explicitly enabled" {
  local record
  record="$(ralph_effective_hook_config_resolve "native_result_compact" "cursor" "hybrid")"
  run jq -r '.enabled' <<<"$record"
  [ "$output" = "false" ]
  run jq -r '.effective' <<<"$record"
  [ "$output" = "false" ]
  run jq -r '.reason' <<<"$record"
  [ "$output" = "gate_disabled" ]
}

@test "cursor in hybrid mode: proxy_shell_compact and bash_rewrite are enabled and effective" {
  local record
  record="$(ralph_effective_hook_config_resolve "proxy_shell_compact" "cursor" "hybrid")"
  run jq -r '.effective' <<<"$record"
  [ "$output" = "true" ]

  export RALPH_BASH_REWRITE=1
  record="$(ralph_effective_hook_config_resolve "bash_rewrite" "cursor" "hybrid")"
  run jq -r '.effective' <<<"$record"
  [ "$output" = "true" ]
}

@test "codex in hybrid mode: bash_compact measured-only, proxy_shell_compact effective" {
  local record
  record="$(ralph_effective_hook_config_resolve "bash_compact" "codex" "hybrid")"
  run jq -r '.effective' <<<"$record"
  [ "$output" = "false" ]
  run jq -r '.reason' <<<"$record"
  [ "$output" = "runtime_cannot_mutate_output" ]

  record="$(ralph_effective_hook_config_resolve "proxy_shell_compact" "codex" "hybrid")"
  run jq -r '.effective' <<<"$record"
  [ "$output" = "true" ]
}

@test "opencode fallback: only proxy_shell_compact is effective, native channels unsupported" {
  local record
  record="$(ralph_effective_hook_config_resolve "bash_compact" "opencode" "hybrid")"
  run jq -r '.enabled' <<<"$record"
  [ "$output" = "true" ]
  run jq -r '.effective' <<<"$record"
  [ "$output" = "false" ]
  run jq -r '.reason' <<<"$record"
  [ "$output" = "channel_unsupported_on_runtime" ]

  record="$(ralph_effective_hook_config_resolve "proxy_shell_compact" "opencode" "hybrid")"
  run jq -r '.effective' <<<"$record"
  [ "$output" = "true" ]
}

@test "no mode: all channels disabled regardless of runtime" {
  local record
  record="$(ralph_effective_hook_config_resolve "proxy_shell_compact" "claude" "no")"
  run jq -r '.enabled' <<<"$record"
  [ "$output" = "false" ]
}

@test "explicit opt-out (gate=0) wins even when the runtime is fully capable" {
  export RALPH_PROXY_SHELL_COMPACT=0
  local record
  record="$(ralph_effective_hook_config_resolve "proxy_shell_compact" "claude" "hybrid")"
  run jq -r '.requestedSource' <<<"$record"
  [ "$output" = "explicit_env" ]
  run jq -r '.enabled' <<<"$record"
  [ "$output" = "false" ]
  run jq -r '.effective' <<<"$record"
  [ "$output" = "false" ]
}

@test "invalid/missing runtime: effective is the string unknown, not false" {
  export RALPH_PROXY_SHELL_COMPACT=1
  local record
  record="$(ralph_effective_hook_config_resolve "proxy_shell_compact" "" "hybrid")"
  run jq -r '.enabled' <<<"$record"
  [ "$output" = "true" ]
  run jq -r '.effective' <<<"$record"
  [ "$output" = "unknown" ]
  run jq -r '.reason' <<<"$record"
  [ "$output" = "runtime_capability_unknown" ]
}

@test "native_result_compact does not couple to bash compaction" {
  export RALPH_BASH_COMPACT=1
  local record
  record="$(ralph_effective_hook_config_resolve "native_result_compact" "claude" "no")"
  run jq -r '.enabled' <<<"$record"
  [ "$output" = "false" ]
  run jq -r '.reason' <<<"$record"
  [ "$output" = "gate_disabled" ]
}

@test "resolve_all returns exactly four channel records for a runtime" {
  local records
  records="$(ralph_effective_hook_config_resolve_all "claude" "hybrid")"
  run jq -e 'length == 4' <<<"$records"
  [ "$status" -eq 0 ]
}
