#!/usr/bin/env bats
# Table-driven coverage for compaction-gate provenance resolution (PLAN15).

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-compaction-provenance.sh"

setup() {
  source "$LIB"
  unset RALPH_BASH_COMPACT RALPH_NATIVE_RESULT_COMPACT RALPH_PROXY_SHELL_COMPACT RALPH_BASH_REWRITE
}

@test "table: all four modes x all five channels resolve gate and source correctly" {
  # mode:channel:expectedGate:expectedSource
  local -a table=(
    "no:bash_compact:off:unset_default_off"
    "no:native_result_compact:off:unset_default_off"
    "no:proxy_shell_compact:off:unset_default_off"
    "no:bash_rewrite:off:unset_default_off"
    "no:auto_background:off:unset_default_off"
    "native:bash_compact:on:mode_default"
    "native:native_result_compact:off:unset_default_off"
    "native:proxy_shell_compact:off:unset_default_off"
    "native:bash_rewrite:off:unset_default_off"
    "native:auto_background:on:mode_default"
    "ralph:bash_compact:off:unset_default_off"
    "ralph:native_result_compact:off:unset_default_off"
    "ralph:proxy_shell_compact:on:mode_default"
    "ralph:bash_rewrite:off:unset_default_off"
    "ralph:auto_background:off:unset_default_off"
    "hybrid:bash_compact:on:mode_default"
    "hybrid:native_result_compact:off:unset_default_off"
    "hybrid:proxy_shell_compact:on:mode_default"
    "hybrid:bash_rewrite:off:unset_default_off"
    "hybrid:auto_background:on:mode_default"
  )
  local row mode channel exp_gate exp_source record
  for row in "${table[@]}"; do
    IFS=':' read -r mode channel exp_gate exp_source <<<"$row"
    record="$(ralph_compaction_gate_provenance "$channel" "$mode")"
    run jq -r '.gate' <<<"$record"
    [ "$output" = "$exp_gate" ]
    run jq -r '.source' <<<"$record"
    [ "$output" = "$exp_source" ]
  done
}

@test "explicit env override (1) wins over mode default in every mode" {
  export RALPH_PROXY_SHELL_COMPACT=1
  local mode record
  for mode in no native ralph hybrid; do
    record="$(ralph_compaction_gate_provenance proxy_shell_compact "$mode")"
    run jq -r '.gate' <<<"$record"
    [ "$output" = "on" ]
    run jq -r '.source' <<<"$record"
    [ "$output" = "explicit_env" ]
  done
}

@test "explicit env override (0) wins over mode default in every mode" {
  export RALPH_BASH_COMPACT=0
  local mode record
  for mode in no native ralph hybrid; do
    record="$(ralph_compaction_gate_provenance bash_compact "$mode")"
    run jq -r '.gate' <<<"$record"
    [ "$output" = "off" ]
    run jq -r '.source' <<<"$record"
    [ "$output" = "explicit_env" ]
  done
}

@test "workspace-preference-sourced mode reports workspace_preference, not mode_default" {
  local record
  record="$(ralph_compaction_gate_provenance bash_compact "hybrid" "workspace_preference")"
  run jq -r '.gate' <<<"$record"
  [ "$output" = "on" ]
  run jq -r '.source' <<<"$record"
  [ "$output" = "workspace_preference" ]
}

@test "workspace-preference source has no effect when the gate resolves off" {
  local record
  record="$(ralph_compaction_gate_provenance bash_rewrite "hybrid" "workspace_preference")"
  run jq -r '.source' <<<"$record"
  [ "$output" = "unset_default_off" ]
}

@test "explicit env override still wins even when mode_source is workspace_preference" {
  export RALPH_BASH_COMPACT=1
  local record
  record="$(ralph_compaction_gate_provenance bash_compact "no" "workspace_preference")"
  run jq -r '.source' <<<"$record"
  [ "$output" = "explicit_env" ]
}

@test "ralph_compaction_gate_provenance_all returns all five channels" {
  local records
  records="$(ralph_compaction_gate_provenance_all "hybrid")"

  run jq -e 'length == 5' <<<"$records"
  [ "$status" -eq 0 ]
  run jq -e '[.[].channel] | sort == ["auto_background","bash_compact","bash_rewrite","native_result_compact","proxy_shell_compact"]' <<<"$records"
  [ "$status" -eq 0 ]
}

@test "unknown channel returns failure" {
  run ralph_compaction_gate_provenance "not_a_channel" "hybrid"
  [ "$status" -ne 0 ]
}
