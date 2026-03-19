#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$RALPH_LIB_ROOT/cleanup-plan.sh"

@test "namespace prefers argument over env fallback" {
  run cleanup_plan_namespace_from_arg_or_env "alpha" "env"
  [ "$status" -eq 0 ]
  [ "$output" = "alpha" ]
}

@test "namespace falls back to env when argument missing" {
  run cleanup_plan_namespace_from_arg_or_env "" "env"
  [ "$status" -eq 0 ]
  [ "$output" = "env" ]
}

@test "namespace helper returns empty when both inputs missing" {
  run cleanup_plan_namespace_from_arg_or_env "" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "valid namespace reports success" {
  run cleanup_plan_validate_namespace "alpha"
  [ "$status" -eq 0 ]
}

@test "invalid namespace reports failure" {
  run cleanup_plan_validate_namespace ""
  [ "$status" -ne 0 ]
}

@test "workspace helper uses explicit workspace argument" {
  workspace="$(mktemp -d)"
  run cleanup_plan_workspace_root "/tmp/script" "$workspace"
  [ "$status" -eq 0 ]
  [ "$output" = "$workspace" ]
  rm -rf "$workspace"
}

@test "workspace helper falls back to script parent" {
  base="$(mktemp -d)"
  script_dir="$base/script"
  mkdir -p "$script_dir"
  run cleanup_plan_workspace_root "$script_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "$base" ]
  rm -rf "$base"
}

@test "log path builder composes namespace directory" {
  run cleanup_plan_log_dir "/tmp/ws" "alpha"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/ws/.agents/logs/alpha" ]
}

@test "artifact path builder composes namespace directory" {
  run cleanup_plan_artifact_dir "/tmp/ws" "alpha"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/ws/.agents/artifacts/alpha" ]
}

@test "log cleanup removes matching files and reports" {
  log_dir="$(mktemp -d)"
  touch "$log_dir/plan-runner-1" "$log_dir/.plan-runner-exit.1" "$log_dir/keep"
  run cleanup_plan_delete_log_files "$log_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "Cleaned logs in $log_dir" ]
  [ -f "$log_dir/keep" ]
  [ ! -f "$log_dir/plan-runner-1" ]
  [ ! -f "$log_dir/.plan-runner-exit.1" ]
  rm -rf "$log_dir"
}

@test "artifact cleanup removes directory and reports" {
  artifact_dir="$(mktemp -d)"
  touch "$artifact_dir/file"
  run cleanup_plan_delete_artifact_dir "$artifact_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "Removed artifacts in $artifact_dir" ]
  [ ! -d "$artifact_dir" ]
}
