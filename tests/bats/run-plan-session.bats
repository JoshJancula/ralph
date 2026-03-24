#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
RUN_PLAN_FUNCS_FILE=""
RUN_PLAN_EXTRA_FUNCS_FILE=""
RUN_PLAN_PREBUILT_FUNCS_FILE=""
RUN_PLAN_HUMAN_ACTION_FUNCS_FILE=""
RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE=""

setup() {
  if [[ ! -f "$RUN_PLAN_SH" ]]; then
    RUN_PLAN_FUNCS_FILE=""
    RUN_PLAN_EXTRA_FUNCS_FILE=""
    RUN_PLAN_HUMAN_FUNCS_FILE=""
    RUN_PLAN_HUMAN_ACTION_FUNCS_FILE=""
    RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE=""
    return 0
  fi
  RUN_PLAN_FUNCS_FILE="$(mktemp)"
  awk '/^_THIS_RUN_PLAN_DIR=/{exit} {print}' "$RUN_PLAN_SH" > "$RUN_PLAN_FUNCS_FILE"
  local bash_lib_dir="$REPO_ROOT/bundle/.ralph/bash-lib"
  local run_plan_core_lib="$bash_lib_dir/run-plan-core.sh"
  local run_plan_agent_lib="$bash_lib_dir/run-plan-agent.sh"
  RUN_PLAN_EXTRA_FUNCS_FILE="$(mktemp)"
  awk '/^ralph_run_plan_log\(\)/,/^ralph_ensure_codex_cli\(\)/ { print; if ($0 ~ /^ralph_ensure_codex_cli\(\)/) exit }' "$run_plan_core_lib" > "$RUN_PLAN_EXTRA_FUNCS_FILE"
  RUN_PLAN_PROMPT_FUNCS_FILE="$(mktemp)"
  cat "$run_plan_agent_lib" > "$RUN_PLAN_PROMPT_FUNCS_FILE"
  RUN_PLAN_PREBUILT_FUNCS_FILE="$(mktemp)"
  cat "$run_plan_agent_lib" > "$RUN_PLAN_PREBUILT_FUNCS_FILE"
  RUN_PLAN_HUMAN_FUNCS_FILE="$(mktemp)"
  sed -n '/^ralph_path_to_file_uri()/,/^}/p' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_should_persist_human_files()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_restart_command_hint()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_operator_has_real_answer()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_operator_response_file_owned_by_current_user()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_remove_human_action_file()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_write_human_action_file()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_sync_human_action_file_state()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_try_consume_human_response()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  RUN_PLAN_HUMAN_ACTION_FUNCS_FILE="$(mktemp)"
  sed -n '/^ralph_remove_human_action_file()/,/^}/p' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  sed -n '/^ralph_write_human_action_file()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  sed -n '/^ralph_sync_human_action_file_state()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  sed -n '/^ralph_should_persist_human_files()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  sed -n '/^ralph_restart_command_hint()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE="$(mktemp)"
  sed -n '/^ralph_operator_has_real_answer()/,/^}/p' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
  sed -n '/^ralph_try_consume_human_response()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
  sed -n '/^ralph_operator_response_file_owned_by_current_user()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
}

teardown() {
  rm -f "$RUN_PLAN_FUNCS_FILE" "$RUN_PLAN_EXTRA_FUNCS_FILE" "$RUN_PLAN_PROMPT_FUNCS_FILE" "$RUN_PLAN_PREBUILT_FUNCS_FILE"
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
  for helper in run-plan-env.sh run-plan-invoke-cursor.sh run-plan-invoke-claude.sh run-plan-invoke-codex.sh; do
    touch "$shared_root/bash-lib/$helper"
  done
  printf '%s' "$shared_root"
}

@test "ralph_write_human_action_file renders the template with pending question and history" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE" ] || skip "human action helper unavailable"

  local tmp_dir human_action pending human_context plan_file operator_response log_file output_log
  tmp_dir="$(mktemp -d)"
  plan_file="$tmp_dir/PLAN.md"
  printf 'plan instructions\n' >"$plan_file"
  pending="$tmp_dir/pending-human.txt"
  printf 'operator question\n' >"$pending"
  human_context="$tmp_dir/HUMAN-CONTEXT.md"
  printf '### history entry\n' >"$human_context"
  human_action="$tmp_dir/HUMAN-ACTION.md"
  operator_response="$tmp_dir/operator-response.txt"
  log_file="$tmp_dir/log.txt"
  output_log="$tmp_dir/output.log"

  run bash -c '
    set -euo pipefail
    printf() { builtin printf -- "$@"; }
    source "$1"
    source "$2"
    HUMAN_ACTION_FILE="$3"
    PENDING_HUMAN="$4"
    HUMAN_CONTEXT="$5"
    PLAN_PATH="$6"
    OPERATOR_RESPONSE_FILE="$7"
    RALPH_SESSION_DIR="$8"
    LOG_FILE="$9"
    OUTPUT_LOG="${10}"
    PREBUILT_AGENT="agent"
    WORKSPACE="${11}"
    RALPH_RUN_PLAN_REL="run-plan.sh"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_restart_command_hint(){ printf "restart %s" "$PLAN_PATH"; }
    ralph_write_human_action_file ""
  ' _ "$RUN_PLAN_HUMAN_FUNCS_FILE" "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE" "$human_action" "$pending" "$human_context" "$plan_file" "$operator_response" "$tmp_dir" "$log_file" "$output_log" "$tmp_dir"

  [ "$status" -eq 0 ]
  [ -f "$human_action" ]
  output="$(<"$human_action")"
  [[ "$output" == *"operator question"* ]]
  [[ "$output" == *"## Plan file"* ]]
  [[ "$output" == *"$plan_file"* ]]
  [[ "$output" == *"### history entry"* ]]

  rm -rf "$tmp_dir"
}

@test "ralph_sync_human_action_file_state writes then clears the human action file" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE" ] || skip "human action helper unavailable"

  local tmp_dir human_action pending human_context plan_file operator_response log_file output_log session_dir
  tmp_dir="$(mktemp -d)"
  human_action="$tmp_dir/HUMAN-ACTION.md"
  pending="$tmp_dir/pending-human.txt"
  human_context="$tmp_dir/HUMAN-CONTEXT.md"
  plan_file="$tmp_dir/PLAN.md"
  operator_response="$tmp_dir/operator-response.txt"
  log_file="$tmp_dir/log.txt"
  output_log="$tmp_dir/output.log"
  session_dir="$tmp_dir/session"
  mkdir -p "$session_dir"

  printf 'plan instructions\n' >"$plan_file"
  printf 'operator question\n' >"$pending"
  printf '### history entry\n' >"$human_context"
  printf '%s\n' '(Replace this line with your answer to the question above, then save.)' >"$operator_response"

  run bash -c '
    set -euo pipefail
    printf() { builtin printf -- "$@"; }
    source "$1"
    source "$2"
    HUMAN_ACTION_FILE="$3"
    PENDING_HUMAN="$4"
    HUMAN_CONTEXT="$5"
    PLAN_PATH="$6"
    OPERATOR_RESPONSE_FILE="$7"
    RALPH_SESSION_DIR="$8"
    LOG_FILE="$9"
    OUTPUT_LOG="${10}"
    PREBUILT_AGENT="agent"
    WORKSPACE="${11}"
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_restart_command_hint(){ printf "restart %s" "$PLAN_PATH"; }
    ralph_should_persist_human_files(){ return 0; }

    ralph_sync_human_action_file_state
    if [[ ! -f "$HUMAN_ACTION_FILE" ]]; then
      echo "expected human action file" >&2
      exit 1
    fi

    if ! grep -q "operator question" "$HUMAN_ACTION_FILE"; then
      echo "human action file missing pending question" >&2
      exit 1
    fi

    printf '%s\n' "Operator answer available." >"$OPERATOR_RESPONSE_FILE"
    ralph_sync_human_action_file_state

    if [[ -f "$HUMAN_ACTION_FILE" ]]; then
      echo "human action file should have been removed" >&2
      exit 1
    fi
  ' _ "$RUN_PLAN_HUMAN_FUNCS_FILE" "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE" "$human_action" "$pending" "$human_context" "$plan_file" "$operator_response" "$session_dir" "$log_file" "$output_log" "$tmp_dir"

  [ "$status" -eq 0 ]
  rm -rf "$tmp_dir"
}

@test "ralph_try_consume_human_response applies answers and clears pending files" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE" ] || skip "human consume helper unavailable"

  local tmp_dir pending human_context operator_response log_file
  tmp_dir="$(mktemp -d)"
  pending="$tmp_dir/pending-human.txt"
  printf 'how should we proceed?\n' >"$pending"
  human_context="$tmp_dir/HUMAN-CONTEXT.md"
  printf '### history entry\n' >"$human_context"
  operator_response="$tmp_dir/operator-response.txt"
  printf 'yes, please continue\n' >"$operator_response"
  log_file="$tmp_dir/log.txt"

  run bash -c '
    set -euo pipefail
    printf() { builtin printf -- "$@"; }
    source "$1"
    HUMAN_CONTEXT="$2"
    PENDING_HUMAN="$3"
    OPERATOR_RESPONSE_FILE="$4"
    LOG_FILE="$5"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_try_consume_human_response
  ' _ "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE" "$human_context" "$pending" "$operator_response" "$log_file"

  [ "$status" -eq 0 ]
  [ ! -f "$pending" ]
  [ ! -f "$operator_response" ]
  output="$(<"$human_context")"
  [[ "$output" == *"how should we proceed?"* ]]
  [[ "$output" == *"yes, please continue"* ]]
  grep -q "Applied answer from operator-response.txt; continuing plan run" "$log_file"

  rm -rf "$tmp_dir"
}

@test "ralph_human_input_write_offline_instructions writes expected content" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper tmp_dir human_input pending operator_response human_action
  local plan_file log_file output_log session_dir

  helper="$(mktemp)"
  local run_plan_core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-core.sh"
  cat <<'EOF' > "$helper"
C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_RST="" C_DIM=""
log(){ :; }
ralph_run_plan_log(){ log "$@"; }
ralph_restart_command_hint(){ printf "%s" "restart hint"; }
ralph_write_human_action_file(){ :; }
ralph_path_to_file_uri() {
  printf 'file://%s' "$1"
}
EOF
  sed -n '/^ralph_human_input_write_offline_instructions()/,/^}/p' "$run_plan_core_lib" >> "$helper"

  tmp_dir="$(mktemp -d)"
  human_input="$tmp_dir/HUMAN-INPUT-REQUIRED.md"
  pending="$tmp_dir/pending-human.txt"
  operator_response="$tmp_dir/operator-response.txt"
  human_action="$tmp_dir/HUMAN-ACTION.md"
  plan_file="$tmp_dir/PLAN.md"
  log_file="$tmp_dir/log.txt"
  output_log="$tmp_dir/output.log"
  session_dir="$tmp_dir/session"
  mkdir -p "$session_dir"
  printf 'plan instructions\n' >"$plan_file"
  printf 'agent question\n' >"$pending"

  run bash -c '
    set -euo pipefail
    source "$1"
    HUMAN_INPUT_MD="$2"
    PENDING_HUMAN="$3"
    OPERATOR_RESPONSE_FILE="$4"
    HUMAN_ACTION_FILE="$5"
    RALPH_SESSION_DIR="$6"
    PLAN_PATH="$7"
    LOG_FILE="$8"
    OUTPUT_LOG="$9"
    HUMAN_PROMPT_NO_OPEN_FLAG=1
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_write_human_action_file(){ :; }
    ralph_human_input_write_offline_instructions
  ' _ "$helper" "$human_input" "$pending" "$operator_response" "$human_action" "$session_dir" "$plan_file" "$log_file" "$output_log"

  [ "$status" -eq 0 ]
  [ -f "$human_input" ]
  content="$(<"$human_input")"
  [[ "$content" == *"# Paused for human input"* ]]
  [[ "$content" == *"## Question from the agent"* ]]
  [[ "$content" == *"agent question"* ]]
  [[ "$content" == *"## What to do"* ]]
  [[ "$content" == *"This instruction page:"* ]]
  [[ "$content" == *"file://"*"HUMAN-INPUT-REQUIRED.md"* ]]
  [[ "$content" == *"- Plan file:"*"$plan_file"* ]]
  [ -f "$operator_response" ]
  [[ "$( <"$operator_response")" == *"Replace this line"* ]]

  rm -f "$helper"
  rm -rf "$tmp_dir"
}

@test "ralph_human_pause_for_operator_offline polls for answers with stubbed sleep" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper tmp_dir human_input pending operator_response human_action plan_file
  local log_file output_log session_dir sleep_log workspace
  helper="$(mktemp)"
  local run_plan_core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-core.sh"
  cat <<'EOF' > "$helper"
C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
log(){ :; }
ralph_run_plan_log(){ log "$@"; }
ralph_path_to_file_uri(){ printf "%s" "$1"; }
ralph_restart_command_hint(){ printf "%s" "restart hint"; }
ralph_write_human_action_file(){ :; }
EOF
  sed -n '/^ralph_human_input_write_offline_instructions()/,/^}/p' "$run_plan_core_lib" >> "$helper"
  sed -n '/^ralph_human_pause_for_operator_offline()/,/^}/p' "$run_plan_core_lib" >> "$helper"

  tmp_dir="$(mktemp -d)"
  human_input="$tmp_dir/HUMAN-INPUT-REQUIRED.md"
  pending="$tmp_dir/pending-human.txt"
  operator_response="$tmp_dir/operator-response.txt"
  human_action="$tmp_dir/HUMAN-ACTION.md"
  plan_file="$tmp_dir/PLAN.md"
  log_file="$tmp_dir/log.txt"
  output_log="$tmp_dir/output.log"
  session_dir="$tmp_dir/session"
  sleep_log="$tmp_dir/sleep.log"
  workspace="$tmp_dir/workspace"
  mkdir -p "$session_dir" "$workspace"
  printf 'plan instructions\n' >"$plan_file"
  printf 'operator question\n' >"$pending"

  run bash -c '
    set -euo pipefail
    source "$1"
    HUMAN_INPUT_MD="$2"
    PENDING_HUMAN="$3"
    OPERATOR_RESPONSE_FILE="$4"
    HUMAN_ACTION_FILE="$5"
    RALPH_SESSION_DIR="$6"
    PLAN_PATH="$7"
    LOG_FILE="$8"
    OUTPUT_LOG="$9"
    SLEEP_LOG="${10}"
    WORKSPACE="${11}"
    HUMAN_PROMPT_NO_OPEN_FLAG=1
    RALPH_HUMAN_POLL_INTERVAL=0
    PREBUILT_AGENT="agent"
    RALPH_RUN_PLAN_REL="run-plan.sh"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    _call_count=0
    log(){ printf "%s\n" "$*" >> "$LOG_FILE"; }
    sleep(){ printf "%s\n" "$1" >> "$SLEEP_LOG"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_operator_has_real_answer(){
      _call_count=$((_call_count + 1))
      if (( _call_count >= 2 )); then
        return 0
      fi
      return 1
    }
    ralph_try_consume_human_response(){
      printf "%s\n" "consuming answer" >> "$LOG_FILE"
      return 0
    }
    ralph_sync_human_action_file_state(){ :; }
    ralph_write_human_action_file(){ :; }
    ralph_human_pause_for_operator_offline
    printf "%s" "done"
  ' _ "$helper" "$human_input" "$pending" "$operator_response" "$human_action" "$session_dir" "$plan_file" "$log_file" "$output_log" "$sleep_log" "$workspace"

  [ "$status" -eq 0 ]
  [ -f "$sleep_log" ]
  grep -q "consuming answer" "$log_file"
  [[ "$output" == *"Waiting for a saved answer"* ]]
  [[ "$output" == *"Answer received. Continuing."* ]]
  grep -q "0" "$sleep_log"
  [ -f "$human_input" ]
  rm -f "$helper"
  rm -rf "$tmp_dir"
}

@test "ralph_write_human_action_file succeeds without printf wrapper on format strings with leading dash" {
  # Regression: printf '- text' crashed on macOS bash 3.2 with "invalid option" because
  # the leading '-' was misinterpreted as a flag. Fixed by adding '--' to those calls.
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE" ] || skip "human action helper unavailable"

  local tmp_dir human_action pending human_context plan_file operator_response log_file output_log
  tmp_dir="$(mktemp -d)"
  plan_file="$tmp_dir/PLAN.md"
  printf 'plan instructions\n' >"$plan_file"
  pending="$tmp_dir/pending-human.txt"
  printf 'operator question\n' >"$pending"
  human_context="$tmp_dir/HUMAN-CONTEXT.md"
  printf '### history entry\n' >"$human_context"
  human_action="$tmp_dir/HUMAN-ACTION.md"
  operator_response="$tmp_dir/operator-response.txt"
  log_file="$tmp_dir/log.txt"
  output_log="$tmp_dir/output.log"

  # Deliberately do NOT override printf — this tests the actual fixed code path
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    HUMAN_ACTION_FILE="$3"
    PENDING_HUMAN="$4"
    HUMAN_CONTEXT="$5"
    PLAN_PATH="$6"
    OPERATOR_RESPONSE_FILE="$7"
    RALPH_SESSION_DIR="$8"
    LOG_FILE="$9"
    OUTPUT_LOG="${10}"
    PREBUILT_AGENT="agent"
    WORKSPACE="${11}"
    RALPH_RUN_PLAN_REL="run-plan.sh"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_restart_command_hint(){ printf "restart %s" "$PLAN_PATH"; }
    ralph_write_human_action_file ""
  ' _ "$RUN_PLAN_HUMAN_FUNCS_FILE" "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE" \
    "$human_action" "$pending" "$human_context" "$plan_file" "$operator_response" \
    "$tmp_dir" "$log_file" "$output_log" "$tmp_dir"

  [ "$status" -eq 0 ]
  [ -f "$human_action" ]
  local content
  content="$(<"$human_action")"
  [[ "$content" == *"- Pending question:"* ]]
  [[ "$content" == *"- Session directory:"* ]]
  [[ "$content" == *"- Plan log:"* ]]
  [[ "$content" == *"- Output log:"* ]]

  rm -rf "$tmp_dir"
}

@test "ralph should persist human files only when tty attached" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper out_file
  helper="$(mktemp)"
  sed -n '/^ralph_should_persist_human_files()/,/^}/p' "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-core.sh" > "$helper"
  out_file="$(mktemp)"

  local persist_runner
  persist_runner="$(mktemp)"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'source %q\n' "$helper"
    printf 'ralph_should_persist_human_files\n'
  } >"$persist_runner"
  chmod +x "$persist_runner"

  run ralph-pty-exec "$persist_runner"

  [ "$status" -eq 1 ]

  run bash -c '
    set -euo pipefail
    source "$1"
    exec 0</dev/null
    ralph_should_persist_human_files
  ' _ "$helper"

  [ "$status" -eq 0 ]

  run bash -c '
    set -euo pipefail
    source "$1"
    exec 1>"$2"
    ralph_should_persist_human_files
  ' _ "$helper" "$out_file"

  [ "$status" -eq 0 ]

  rm -f "$helper" "$out_file" "$persist_runner"
}
