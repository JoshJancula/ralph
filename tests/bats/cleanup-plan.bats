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
  [ "$output" = "/tmp/ws/.ralph-workspace/logs/alpha" ]
}

@test "artifact path builder composes namespace directory" {
  run cleanup_plan_artifact_dir "/tmp/ws" "alpha"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/ws/.ralph-workspace/artifacts/alpha" ]
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

@test "cleanup reports missing targets without error (dry-run edge path)" {
  workspace_root="$(mktemp -d)"
  log_dir="$workspace_root/logs"
  artifact_dir="$workspace_root/artifacts"

  run cleanup_plan_delete_log_files "$log_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "Log directory does not exist: $log_dir" ]

  run cleanup_plan_delete_artifact_dir "$artifact_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "Artifact directory does not exist: $artifact_dir" ]

  rm -rf "$workspace_root"
}

@test "cleanup-plan wrapper removes namespace data and rejects missing namespace" {
  workspace="$(mktemp -d)"
  cleanup_script="$BATS_TEST_DIRNAME/../../bundle/.ralph/cleanup-plan.sh"
  namespace="wrapper"

  log_dir="$workspace/.ralph-workspace/logs/$namespace"
  legacy_log_dir="$workspace/.ralph-workspace/logs/$namespace"
  session_dir="$workspace/.ralph-workspace/sessions/$namespace"
  legacy_session_dir="$workspace/.ralph-workspace/sessions/$namespace"
  artifact_dir="$workspace/.ralph-workspace/artifacts/$namespace"

  mkdir -p "$log_dir" "$legacy_log_dir" "$session_dir" "$legacy_session_dir" "$artifact_dir"
  touch "$log_dir/plan-runner-1" "$legacy_log_dir/plan-runner-old" "$artifact_dir/file"
  touch "$workspace/HUMAN_ACTION_REQUIRED.md"

  run "$cleanup_script" "$namespace" "$workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cleaned logs in $log_dir"* ]]
  [[ "$output" == *"Cleaned logs in $legacy_log_dir"* ]]
  [[ "$output" == *"Removed session directory $session_dir"* ]]
  [[ "$output" == *"Removed legacy session directory $legacy_session_dir"* ]]
  [[ "$output" == *"Removed artifacts in $artifact_dir"* ]]
  [[ "$output" == *"Removed human action file: $workspace/HUMAN_ACTION_REQUIRED.md"* ]]
  [ ! -f "$log_dir/plan-runner-1" ]
  [ ! -f "$legacy_log_dir/plan-runner-old" ]
  [ ! -d "$session_dir" ]
  [ ! -d "$legacy_session_dir" ]
  [ ! -d "$artifact_dir" ]
  [ ! -f "$workspace/HUMAN_ACTION_REQUIRED.md" ]

  run env -u RALPH_ARTIFACT_NS "$cleanup_script" "" "$workspace"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: $cleanup_script <artifact-namespace> [workspace]"* ]]

  rm -rf "$workspace"
}
