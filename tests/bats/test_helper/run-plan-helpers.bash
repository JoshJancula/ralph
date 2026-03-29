#!/usr/bin/env bash
set -euo pipefail

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
RUN_PLAN_FUNCS_FILE=""
RUN_PLAN_EXTRA_FUNCS_FILE=""
RUN_PLAN_PREBUILT_FUNCS_FILE=""
RUN_PLAN_CLEANUP_FUNCS_FILE=""
RUN_PLAN_HUMAN_ACTION_FUNCS_FILE=""
RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE=""
RUN_PLAN_PROMPT_FUNCS_FILE=""

write_source_bundle() {
  local dst="$1"
  shift
  : >"$dst"
  local src
  for src in "$@"; do
    printf 'source %q\n' "$src" >>"$dst"
  done
}

append_function_block() {
  local src="$1"
  local start_regex="$2"
  local end_regex="$3"
  local dst="$4"
  sed -n "/$start_regex/,/$end_regex/p" "$src" >>"$dst"
}

setup() {
  if [[ ! -f "$RUN_PLAN_SH" ]]; then
    RUN_PLAN_FUNCS_FILE=""
    RUN_PLAN_EXTRA_FUNCS_FILE=""
    RUN_PLAN_PROMPT_FUNCS_FILE=""
    RUN_PLAN_PREBUILT_FUNCS_FILE=""
    RUN_PLAN_CLEANUP_FUNCS_FILE=""
    RUN_PLAN_HUMAN_FUNCS_FILE=""
    RUN_PLAN_HUMAN_ACTION_FUNCS_FILE=""
    RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE=""
    return 0
  fi
  local bash_lib_dir="$REPO_ROOT/bundle/.ralph/bash-lib"
  local run_plan_runtime_lib="$bash_lib_dir/run-plan-runtime.sh"
  local run_plan_agent_lib="$bash_lib_dir/run-plan-agent.sh"
  local run_plan_cleanup_lib="$bash_lib_dir/run-plan-cleanup.sh"
  local run_plan_core_lib="$bash_lib_dir/run-plan-core.sh"

  RUN_PLAN_FUNCS_FILE="$(mktemp)"
  write_source_bundle "$RUN_PLAN_FUNCS_FILE" "$run_plan_runtime_lib"

  RUN_PLAN_EXTRA_FUNCS_FILE="$(mktemp)"
  write_source_bundle "$RUN_PLAN_EXTRA_FUNCS_FILE" "$run_plan_runtime_lib"

  RUN_PLAN_PROMPT_FUNCS_FILE="$(mktemp)"
  write_source_bundle "$RUN_PLAN_PROMPT_FUNCS_FILE" "$run_plan_agent_lib"

  RUN_PLAN_PREBUILT_FUNCS_FILE="$(mktemp)"
  write_source_bundle "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$run_plan_agent_lib"

  RUN_PLAN_CLEANUP_FUNCS_FILE="$(mktemp)"
  append_function_block "$run_plan_cleanup_lib" '^prompt_cleanup_on_exit()' '^}$' "$RUN_PLAN_CLEANUP_FUNCS_FILE"

  RUN_PLAN_HUMAN_FUNCS_FILE="$(mktemp)"
  write_source_bundle "$RUN_PLAN_HUMAN_FUNCS_FILE" "$run_plan_runtime_lib"
  append_function_block "$run_plan_core_lib" '^ralph_path_to_file_uri()' '^}$' "$RUN_PLAN_HUMAN_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_should_persist_human_files()' '^}$' "$RUN_PLAN_HUMAN_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_restart_command_hint()' '^}$' "$RUN_PLAN_HUMAN_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_operator_has_real_answer()' '^}$' "$RUN_PLAN_HUMAN_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_operator_response_file_owned_by_current_user()' '^}$' "$RUN_PLAN_HUMAN_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_remove_human_action_file()' '^}$' "$RUN_PLAN_HUMAN_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_write_human_action_file()' '^}$' "$RUN_PLAN_HUMAN_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_sync_human_action_file_state()' '^}$' "$RUN_PLAN_HUMAN_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_try_consume_human_response()' '^}$' "$RUN_PLAN_HUMAN_FUNCS_FILE"

  RUN_PLAN_HUMAN_ACTION_FUNCS_FILE="$(mktemp)"
  write_source_bundle "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE" "$run_plan_runtime_lib"
  append_function_block "$run_plan_core_lib" '^ralph_remove_human_action_file()' '^}$' "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_write_human_action_file()' '^}$' "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_sync_human_action_file_state()' '^}$' "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_should_persist_human_files()' '^}$' "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_restart_command_hint()' '^}$' "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"

  RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE="$(mktemp)"
  write_source_bundle "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE" "$run_plan_runtime_lib"
  append_function_block "$run_plan_core_lib" '^ralph_operator_has_real_answer()' '^}$' "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_try_consume_human_response()' '^}$' "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
  append_function_block "$run_plan_core_lib" '^ralph_operator_response_file_owned_by_current_user()' '^}$' "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
}

teardown() {
  rm -f "$RUN_PLAN_FUNCS_FILE" "$RUN_PLAN_EXTRA_FUNCS_FILE" "$RUN_PLAN_PROMPT_FUNCS_FILE" "$RUN_PLAN_PREBUILT_FUNCS_FILE"
  rm -f "$RUN_PLAN_CLEANUP_FUNCS_FILE"
  rm -f "$RUN_PLAN_HUMAN_FUNCS_FILE" "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  rm -f "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
}

run_operator_has_real_answer_from_file() {
  local response_file="$1"
  run bash -c '
    set -euo pipefail
    printf() { builtin printf -- "$@"; }
    source "$1"
    OPERATOR_RESPONSE_FILE="$2"
    ralph_operator_has_real_answer
  ' _ "$RUN_PLAN_HUMAN_FUNCS_FILE" "$response_file"
}

create_shared_layout() {
  local shared_root
  shared_root="$(mktemp -d)"
  mkdir -p "$shared_root/bash-lib"
  touch "$shared_root/ralph-env-safety.sh"
  for helper in run-plan-env.sh run-plan-invoke-cursor.sh run-plan-invoke-claude.sh run-plan-invoke-codex.sh run-plan-invoke-opencode.sh; do
    touch "$shared_root/bash-lib/$helper"
  done
  printf '%s' "$shared_root"
}
