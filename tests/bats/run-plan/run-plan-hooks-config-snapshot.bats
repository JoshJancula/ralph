#!/usr/bin/env bats
# Coverage for the per-invocation hooks-config.jsonl snapshot writer (PLAN15).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-hooks-config-snapshot.sh"

setup() {
  _tmp="$(mktemp -d)"
  source "$LIB"
  unset RALPH_BASH_COMPACT RALPH_NATIVE_RESULT_COMPACT RALPH_PROXY_SHELL_COMPACT RALPH_BASH_REWRITE
}

teardown() {
  rm -rf "$_tmp"
}

@test "saved/explicit hybrid mode is recorded enabled even though overlay state was 'initialized' earlier" {
  # Simulate the real ordering bug this TODO fixes: overlay state exists
  # before mode is known, then mode resolves, then we snapshot.
  local overlay_marker="$_tmp/overlay-initialized-first"
  : >"$overlay_marker"
  [[ -f "$overlay_marker" ]]

  ralph_hooks_config_snapshot_append "$_tmp" "plan-a" "1" "claude" "hybrid"

  local snap
  snap="$(ralph_hooks_config_snapshot_path "$_tmp")"
  [ -f "$snap" ]
  local record
  record="$(tail -n1 "$snap")"
  run jq -e '.channels[] | select(.channel == "bash_compact") | .enabled == true' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "no mode: channels are disabled with reasons in the snapshot" {
  ralph_hooks_config_snapshot_append "$_tmp" "plan-b" "1" "claude" "no"
  local snap record
  snap="$(ralph_hooks_config_snapshot_path "$_tmp")"
  record="$(tail -n1 "$snap")"
  run jq -e '.channels[] | select(.channel == "bash_compact") | .enabled == false and .reason == "gate_disabled"' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "explicit opt-out wins in the snapshot even in hybrid mode" {
  export RALPH_BASH_COMPACT=0
  ralph_hooks_config_snapshot_append "$_tmp" "plan-c" "1" "claude" "hybrid"
  local snap record
  snap="$(ralph_hooks_config_snapshot_path "$_tmp")"
  record="$(tail -n1 "$snap")"
  run jq -e '.channels[] | select(.channel == "bash_compact") | .enabled == false and .requestedSource == "explicit_env"' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "two invocation/runtime snapshots coexist without overwriting each other" {
  ralph_hooks_config_snapshot_append "$_tmp" "plan-d" "1" "claude" "hybrid"
  ralph_hooks_config_snapshot_append "$_tmp" "plan-d" "2" "cursor" "hybrid"

  local snap
  snap="$(ralph_hooks_config_snapshot_path "$_tmp")"
  run wc -l < "$snap"
  [ "$(tr -d ' ' <<<"$output")" = "2" ]

  run bash -c "sed -n '1p' '$snap' | jq -r '.iteration + \":\" + .runtime'"
  [ "$output" = "1:claude" ]
  run bash -c "sed -n '2p' '$snap' | jq -r '.iteration + \":\" + .runtime'"
  [ "$output" = "2:cursor" ]
}

@test "every snapshot line is valid JSON with required top-level fields" {
  ralph_hooks_config_snapshot_append "$_tmp" "plan-e" "1" "claude" "hybrid"
  local snap record
  snap="$(ralph_hooks_config_snapshot_path "$_tmp")"
  record="$(tail -n1 "$snap")"
  run jq -e '.timestamp and .planKey and (.iteration != null) and .runtime and (.channels | length == 5)' <<<"$record"
  [ "$status" -eq 0 ]
}

@test "missing workspace_root or plan_key fails open (no snapshot, no error)" {
  run ralph_hooks_config_snapshot_append "" "plan-f" "1" "claude" "hybrid"
  [ "$status" -eq 0 ]
  run ralph_hooks_config_snapshot_append "$_tmp" "" "1" "claude" "hybrid"
  [ "$status" -eq 0 ]
}
