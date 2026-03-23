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
  RUN_PLAN_EXTRA_FUNCS_FILE="$(mktemp)"
  awk '/^log\(\)/,/^prompt_for_agent\(/ { if ($0 ~ /^prompt_for_agent\(/) exit; print }' "$RUN_PLAN_SH" > "$RUN_PLAN_EXTRA_FUNCS_FILE"
  RUN_PLAN_PROMPT_FUNCS_FILE="$(mktemp)"
  awk '/^prompt_for_agent\(\)/,/^prebuilt_agents_root\(\)/ { if ($0 ~ /^prebuilt_agents_root\(\)/) exit; print }' "$RUN_PLAN_SH" > "$RUN_PLAN_PROMPT_FUNCS_FILE"
  RUN_PLAN_PREBUILT_FUNCS_FILE="$(mktemp)"
  awk '/^prebuilt_agents_root\(\)/,/^prompt_select_prebuilt_agent\(\)/ { if ($0 ~ /^prompt_select_prebuilt_agent\(\)/) exit; print }' "$RUN_PLAN_SH" > "$RUN_PLAN_PREBUILT_FUNCS_FILE"
  RUN_PLAN_HUMAN_FUNCS_FILE="$(mktemp)"
  awk '/^ralph_operator_has_real_answer\(\)/,/^ralph_remove_human_action_file\(\)/ { if ($0 ~ /^ralph_remove_human_action_file\(\)/) exit; print }' "$RUN_PLAN_SH" > "$RUN_PLAN_HUMAN_FUNCS_FILE"
  RUN_PLAN_HUMAN_ACTION_FUNCS_FILE="$(mktemp)"
  awk '/^ralph_remove_human_action_file\(\)/,/^ralph_human_input_write_offline_instructions\(\)/ { if ($0 ~ /^ralph_human_input_write_offline_instructions\(\)/) exit; print }' "$RUN_PLAN_SH" > "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE="$(mktemp)"
  awk '/^ralph_operator_has_real_answer\(\)/,/^ralph_human_input_write_offline_instructions\(\)/ { if ($0 ~ /^ralph_human_input_write_offline_instructions\(\)/) exit; print }' "$RUN_PLAN_SH" > "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
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

@test "ralph shared helper functions succeed when the shared tree is complete" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  local shared_dir
  shared_dir="$(create_shared_layout)"

  run bash -c '
    set -euo pipefail
    printf() { builtin printf -- "$@"; }
    source "$1"
    if ! ralph_shared_ralph_dir_complete "$2"; then
      echo "shared helper returned non-zero"
      exit 1
    fi
    resolved="$(ralph_resolve_shared_ralph_dir "$2")"
    if [[ "$resolved" != "$2" ]]; then
      echo "unexpected resolution: $resolved"
      exit 1
    fi
  ' _ "$RUN_PLAN_FUNCS_FILE" "$shared_dir"

  [ "$status" -eq 0 ]
  rm -rf "$shared_dir"
}

@test "ralph shared helper functions report missing layout and keep the original path" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  local incomplete_dir
  incomplete_dir="$(mktemp -d)"

  run bash -c '
    set -euo pipefail
    printf() { builtin printf -- "$@"; }
    source "$1"
    if ralph_shared_ralph_dir_complete "$2"; then
      echo "expected missing layout"
      exit 1
    fi
    resolved="$(ralph_resolve_shared_ralph_dir "$2")"
    if [[ "$resolved" != "$2" ]]; then
      echo "resolve changed to $resolved"
      exit 1
    fi
  ' _ "$RUN_PLAN_FUNCS_FILE" "$incomplete_dir"

  [ "$status" -eq 0 ]
  rm -rf "$incomplete_dir"
}

@test "run-plan reexecs under caffeinate when running on macOS" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [[ "$(uname -s)" == "Darwin" ]] || skip "caffeinate guard only relevant on macOS"

  local stub_dir capture_file plan_file
  stub_dir="$(mktemp -d)"
  capture_file="$(mktemp)"
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  cat <<'EOF' > "$stub_dir/caffeinate"
#!/usr/bin/env bash
set -euo pipefail
env > "$CAFFEINATE_CAPTURE"
printf '%s\n' "$@" >> "$CAFFEINATE_CAPTURE"
EOF
  chmod +x "$stub_dir/caffeinate"

  run bash -c '
    set -euo pipefail
    PATH="$1"
    export PATH
    export CAFFEINATE_CAPTURE="$2"
    export RALPH_PLAN_NO_CAFFEINATE=0
    export RALPH_PLAN_CAFFEINATED=0
    export CURSOR_PLAN_CAFFEINATED=0
    export CLAUDE_PLAN_CAFFEINATED=0
    export CODEX_PLAN_CAFFEINATED=0
    CURSOR_PLAN_NO_COLOR=1
    CLAUDE_PLAN_NO_COLOR=1
    CODEX_PLAN_NO_COLOR=1
    export CURSOR_PLAN_NO_COLOR CLAUDE_PLAN_NO_COLOR CODEX_PLAN_NO_COLOR
    "$3" --runtime cursor --plan "$4"
  ' _ "$stub_dir:$PATH" "$capture_file" "$RUN_PLAN_SH" "$plan_file"

  [ "$status" -eq 0 ]
  env_output="$(<"$capture_file")"
  [[ "$env_output" == *"RALPH_PLAN_CAFFEINATED=1"* ]]
  [[ "$env_output" == *"CURSOR_PLAN_CAFFEINATED=1"* ]]
  [[ "$env_output" == *"CLAUDE_PLAN_CAFFEINATED=1"* ]]
  [[ "$env_output" == *"CODEX_PLAN_CAFFEINATED=1"* ]]
  [[ "$env_output" == *"/usr/bin/env"* ]]

  rm -rf "$stub_dir"
  rm -f "$capture_file"
  rm -f "$plan_file"
}

@test "ralph ensure cursor cli handles available or missing cursor-agent" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_EXTRA_FUNCS_FILE" ] || skip "run-plan helper section unavailable"

  local stub_dir log_file
  stub_dir="$(mktemp -d)"
  log_file="$(mktemp)"

  cat <<'EOF' > "$stub_dir/cursor-agent"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    LOG_FILE="$2"
    source "$3"
    PATH="$1"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    CURSOR_PLAN_VERBOSE=0
    ralph_ensure_cursor_cli
    printf "%s" "$CURSOR_CLI"
  ' _ "$stub_dir:$PATH" "$log_file" "$RUN_PLAN_EXTRA_FUNCS_FILE"

  [ "$status" -eq 0 ]
  [ "$output" = "cursor-agent" ]

  run bash -c '
    set -euo pipefail
    LOG_FILE="$1"
    source "$2"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    CURSOR_PLAN_VERBOSE=0
    command() {
      if [[ "$1" == "-v" && ( "$2" == "cursor-agent" || "$2" == "agent" ) ]]; then
        return 1
      fi
      builtin command "$@"
    }
    ralph_ensure_cursor_cli
  ' _ "$log_file" "$RUN_PLAN_EXTRA_FUNCS_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cursor CLI is not installed"* ]]

  rm -rf "$stub_dir"
  rm -f "$log_file"
}

@test "ralph ensure claude cli handles available or missing claude" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_EXTRA_FUNCS_FILE" ] || skip "run-plan helper section unavailable"

  local stub_dir log_file
  stub_dir="$(mktemp -d)"
  log_file="$(mktemp)"

  cat <<'EOF' > "$stub_dir/claude"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir/claude"

  run bash -c '
    set -euo pipefail
    LOG_FILE="$2"
    source "$3"
    PATH="$1"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    # default to PATH lookup when no CLAUDE_PLAN_CLI is provided
    CLAUDE_PLAN_CLI=""
    ralph_ensure_claude_cli
    printf "%s" "$CLAUDE_CLI"
  ' _ "$stub_dir:$PATH" "$log_file" "$RUN_PLAN_EXTRA_FUNCS_FILE"

  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]

  run bash -c '
    set -euo pipefail
    LOG_FILE="$1"
    source "$2"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    # force `command -v claude` to fail even if a real CLI exists
    command() {
      if [[ "$1" == "-v" && "$2" == "claude" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    CLAUDE_PLAN_CLI=""
    ralph_ensure_claude_cli
  ' _ "$log_file" "$RUN_PLAN_EXTRA_FUNCS_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude Code CLI is not installed"* ]]

  rm -rf "$stub_dir"
  rm -f "$log_file"
}

@test "ralph ensure codex cli handles available or missing codex" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_EXTRA_FUNCS_FILE" ] || skip "run-plan helper section unavailable"

  local stub_dir log_file
  stub_dir="$(mktemp -d)"
  log_file="$(mktemp)"

  cat <<'EOF' > "$stub_dir/codex"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_dir/codex"

  run bash -c '
    set -euo pipefail
    LOG_FILE="$2"
    source "$3"
    PATH="$1"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    CODEX_PLAN_CLI=""
    ralph_ensure_codex_cli
    printf "%s" "$CODEX_CLI"
  ' _ "$stub_dir:$PATH" "$log_file" "$RUN_PLAN_EXTRA_FUNCS_FILE"

  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]

  run bash -c '
    set -euo pipefail
    LOG_FILE="$1"
    source "$2"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    CODEX_PLAN_CLI=""
    command() {
      if [[ "$1" == "-v" && "$2" == "codex" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    ralph_ensure_codex_cli
  ' _ "$log_file" "$RUN_PLAN_EXTRA_FUNCS_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Codex CLI is not installed"* ]]

  rm -rf "$stub_dir"
  rm -f "$log_file"
}

@test "ralph_operator_has_real_answer rejects the default placeholder response" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_FUNCS_FILE" ] || skip "human helper section unavailable"

  local response_file
  response_file="$(mktemp)"
  printf '%s\n' '(Replace this line with your answer to the question above, then save.)' >"$response_file"

  run_operator_has_real_answer_from_file "$response_file"
  [ "$status" -eq 1 ]

  rm -f "$response_file"
}

@test "ralph_operator_has_real_answer rejects whitespace-only responses" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_FUNCS_FILE" ] || skip "human helper section unavailable"

  local response_file
  response_file="$(mktemp)"
  printf ' \t\n' >"$response_file"

  run_operator_has_real_answer_from_file "$response_file"
  [ "$status" -eq 1 ]

  rm -f "$response_file"
}

@test "ralph_operator_has_real_answer accepts a real answer" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_FUNCS_FILE" ] || skip "human helper section unavailable"

  local response_file
  response_file="$(mktemp)"
  printf '%s\n' 'The operator confirms I may continue.' >"$response_file"

  run_operator_has_real_answer_from_file "$response_file"
  [ "$status" -eq 0 ]

  rm -f "$response_file"
}

@test "ralph_remove_human_action_file deletes any leftover action file" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE" ] || skip "human action helper unavailable"

  local action_file
  action_file="$(mktemp)"

  run bash -c '
    set -euo pipefail
    printf() { builtin printf -- "$@"; }
    source "$1"
    HUMAN_ACTION_FILE="$2"
    log(){ :; }
    touch "$HUMAN_ACTION_FILE"
    if [[ ! -f "$HUMAN_ACTION_FILE" ]]; then
      exit 1
    fi
    ralph_remove_human_action_file
    if [[ -e "$HUMAN_ACTION_FILE" ]]; then
      exit 1
    fi
    ralph_remove_human_action_file
  ' _ "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE" "$action_file"

  [ "$status" -eq 0 ]
  rm -f "$action_file"
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
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
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
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
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
  cat <<'EOF' > "$helper"
C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_RST="" C_DIM=""
log(){ :; }
ralph_path_to_file_uri(){ printf "%s" "file://%s" "$1"; }
ralph_restart_command_hint(){ printf "%s" "restart hint"; }
ralph_write_human_action_file(){ :; }
EOF
  sed -n '/^ralph_human_input_write_offline_instructions()/,/^}/p' "$RUN_PLAN_SH" >> "$helper"

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
    ralph_human_input_write_offline_instructions
  ' _ "$helper" "$human_input" "$pending" "$operator_response" "$human_action" "$session_dir" "$plan_file" "$log_file" "$output_log"

  [ "$status" -eq 0 ]
  [ -f "$human_input" ]
  content="$(<"$human_input")"
  [[ "$content" == *"# Paused for human input"* ]]
  [[ "$content" == *"## Question from the agent"* ]]
  [[ "$content" == *"agent question"* ]]
  [[ "$content" == *"## What to do"* ]]
  [[ "$content" == *"Instruction page: file://$human_input"* ]]
  [[ "$content" == *"- Plan file: $plan_file"* ]]
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
  cat <<'EOF' > "$helper"
C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
ralph_path_to_file_uri(){ printf "%s" "$1"; }
ralph_restart_command_hint(){ printf "%s" "restart hint"; }
EOF
  sed -n '/^ralph_human_input_write_offline_instructions()/,/^}/p' "$RUN_PLAN_SH" >> "$helper"
  sed -n '/^ralph_human_pause_for_operator_offline()/,/^}/p' "$RUN_PLAN_SH" >> "$helper"

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
    _call_count=0
    log(){ printf "%s\n" "$*" >> "$LOG_FILE"; }
    sleep(){ printf "%s\n" "$1" >> "$SLEEP_LOG"; }
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

@test "prompt_for_agent trims carriage returns from interactive selection" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PROMPT_FUNCS_FILE" ] || skip "prompt_for_agent helper unavailable"

  run bash -c '
    set -euo pipefail
    source "$1"
    RUNTIME=cursor
    NON_INTERACTIVE_FLAG=0
    select_model_cursor() {
      local selection
      read -r selection
      printf "%s\r" "$selection"
    }
    prompt_for_agent
  ' _ "$RUN_PLAN_PROMPT_FUNCS_FILE" <<'EOF'
scripted-model
EOF

  [ "$status" -eq 0 ]
  [ "$output" = "scripted-model" ]
}

@test "prebuilt_agents_root constructs the runtime agents path" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PREBUILT_FUNCS_FILE" ] || skip "prebuilt helper unavailable"

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".cursor/agents"
    RUNTIME=cursor
    ws="$2"
    root="$(prebuilt_agents_root "$ws")"
    printf "%s" "$root"
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$REPO_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_ROOT/.cursor/agents" ]
}

@test "list_prebuilt_agent_ids enumerates agents from the fixture" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PREBUILT_FUNCS_FILE" ] || skip "prebuilt helper unavailable"

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".cursor/agents"
    AGENT_CONFIG_TOOL="$3"
    ws="$2"
    list_prebuilt_agent_ids "$ws"
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$REPO_ROOT" "$REPO_ROOT/.ralph/agent-config-tool.sh"

  [ "$status" -eq 0 ]
  ids=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ids+=("$line")
  done <<< "$output"

  expected=("architect" "code-review" "implementation" "qa" "research" "security")
  [ "${#ids[@]}" -eq "${#expected[@]}" ]
  for idx in "${!expected[@]}"; do
    [ "${ids[idx]}" = "${expected[idx]}" ]
  done
}

@test "validate_prebuilt_agent_config succeeds for a known agent" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PREBUILT_FUNCS_FILE" ] || skip "prebuilt helper unavailable"

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".cursor/agents"
    AGENT_CONFIG_TOOL="$3"
    ws="$2"
    validate_prebuilt_agent_config "$ws" "research"
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$REPO_ROOT" "$REPO_ROOT/.ralph/agent-config-tool.sh"

  [ "$status" -eq 0 ]
}

@test "validate_prebuilt_agent_config reports missing configs" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PREBUILT_FUNCS_FILE" ] || skip "prebuilt helper unavailable"

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".cursor/agents"
    AGENT_CONFIG_TOOL="$3"
    ws="$2"
    validate_prebuilt_agent_config "$ws" "does-not-exist"
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$REPO_ROOT" "$REPO_ROOT/.ralph/agent-config-tool.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"config not found:"* ]]
}

@test "prebuilt agent helpers expose model id and context block" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PREBUILT_FUNCS_FILE" ] || skip "prebuilt helper unavailable"

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".cursor/agents"
    AGENT_CONFIG_TOOL="$3"
    ws="$2"
    read_prebuilt_agent_model "$ws" "architect"
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$REPO_ROOT" "$REPO_ROOT/.ralph/agent-config-tool.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "auto" ]

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".cursor/agents"
    AGENT_CONFIG_TOOL="$3"
    ws="$2"
    format_prebuilt_agent_context_block "$ws" "architect"
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$REPO_ROOT" "$REPO_ROOT/.ralph/agent-config-tool.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Prebuilt agent profile**"* ]]
  [[ "$output" == *"- **name:** architect"* ]]
  [[ "$output" == *"**Skill paths"* ]]
  [[ "$output" == *"**Declared output artifacts:**"* ]]
  [[ "$output" == *"**Rules (read and follow; full text inlined below):**"* ]]
  [[ "$output" == *"(none configured)"* ]]
  [[ "$output" == *".ralph-workspace/artifacts/PLAN/architecture.md"* ]]
  [[ "$output" == *".ralph-workspace/artifacts/PLAN/research.md"* ]]
  [[ "$output" == *"**Agent config:**"* ]]
}

@test "prompt_select_prebuilt_agent accepts scripted TTY selection" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local prompt_funcs
  prompt_funcs="$(mktemp)"
  awk 'BEGIN{flag=0} /^prebuilt_agents_root\(\)/ { flag=1 } flag { if (/^# If prebuilt agents exist/) exit; print }' "$RUN_PLAN_SH" > "$prompt_funcs"

  run script -q /dev/null env PREBUILT_FUNCS_FILE="$prompt_funcs" REPO_ROOT="$REPO_ROOT" bash -c '
    set -euo pipefail
    source "$PREBUILT_FUNCS_FILE"
    AGENTS_ROOT_REL=".cursor/agents"
    AGENT_CONFIG_TOOL="$REPO_ROOT/.ralph/agent-config-tool.sh"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    selected="$(prompt_select_prebuilt_agent "$REPO_ROOT")"
    printf "\n"
    printf "%s\n" "$selected"
  ' <<'EOF'
2
EOF

  [ "$status" -eq 0 ]
  final_line="$(printf '%s\n' "$output" | awk 'NF { last=$0 } END { printf "%s\n", last }' | tr -d '\r')"
  rm -f "$prompt_funcs"
  [ "$final_line" = "code-review" ]
}

@test "prompt_agent_source_mode accepts scripted selection" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local prompt_funcs
  prompt_funcs="$(mktemp)"
  python3 - <<'PY' > "$prompt_funcs"
with open("bundle/.ralph/run-plan.sh") as f:
    for idx, line in enumerate(f, 1):
        if 602 <= idx <= 643:
            print(line, end="")
PY

  run script -q /dev/null env PROMPT_FUNCS_FILE="$prompt_funcs" REPO_ROOT="$REPO_ROOT" bash -c '
    set -euo pipefail
    source "$PROMPT_FUNCS_FILE"
    list_prebuilt_agent_ids() {
      printf "%s\n" "architect"
    }
    AGENTS_ROOT_REL=".cursor/agents"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    NON_INTERACTIVE_FLAG=0
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    PLAN_MODEL_CLI=""
    prompt_agent_source_mode "$REPO_ROOT"
    printf "\\nflag=%s\\n" "$INTERACTIVE_SELECT_AGENT_FLAG"
  ' <<'EOF'
2
EOF

  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=0"* ]]
  rm -f "$prompt_funcs"
}

@test "prompt_cleanup_on_exit prompts for yes and no answers via scripted TTY input" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper cleanup_marker cleanup_script workspace log_dir output_log log_file
  helper="$(mktemp)"
  sed -n '/^prompt_cleanup_on_exit()/,/^}/p' "$RUN_PLAN_SH" > "$helper"

  cleanup_marker="$(mktemp)"
  cleanup_script="$(mktemp)"
  cat <<'EOF' > "$cleanup_script"
#!/usr/bin/env bash
printf '%s\n' "cleanup-invoked" >> "$CLEANUP_MARKER"
EOF
  chmod +x "$cleanup_script"

  workspace="$(mktemp -d)"
  log_dir="$workspace/logs"
  mkdir -p "$log_dir"
  output_log="$workspace/output.log"
  log_file="$workspace/plan.log"

  run script -q /dev/null env \
    HELPER="$helper" \
    CLEANUP_SCRIPT="$cleanup_script" \
    CLEANUP_MARKER="$cleanup_marker" \
    RALPH_LOG_DIR="$log_dir" \
    OUTPUT_LOG="$output_log" \
    LOG_FILE="$log_file" \
    WORKSPACE="$workspace" \
    RALPH_ARTIFACT_NS="PLAN" \
    NON_INTERACTIVE_FLAG=0 \
    ALLOW_CLEANUP_PROMPT=1 \
    EXIT_STATUS="incomplete" \
    bash -c '
      set -euo pipefail
      C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
      source "$HELPER"
      prompt_cleanup_on_exit
      prompt_cleanup_on_exit
    ' <<'EOF'
y
n
EOF

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$cleanup_marker")" -eq 1 ]
  [[ "$output" == *"Cleanup command:"* ]]

  rm -rf "$workspace"
  rm -f "$helper" "$cleanup_script" "$cleanup_marker"
}

@test "ralph path to file uri uses sample paths" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper
  helper="$(mktemp)"
  sed -n '/^ralph_path_to_file_uri()/,/^}/p' "$RUN_PLAN_SH" > "$helper"

  local path_space_dir path_space path_simple_dir path_simple encoded
  path_space_dir="$(mktemp -d)"
  path_space="$path_space_dir/with space"
  touch "$path_space"

  path_simple_dir="$(mktemp -d)"
  path_simple="$path_simple_dir/simple-file"
  touch "$path_simple"

  encoded="${path_space// /%20}"

  run bash -c '
    set -euo pipefail
    PATH=""
    source "$1"
    printf "%s" "$(ralph_path_to_file_uri "$2")"
  ' _ "$helper" "$path_space"

  [ "$status" -eq 0 ]
  [ "$output" = "file://$encoded" ]

  if command -v python3 >/dev/null; then
    expected="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri(), end="")' "$path_simple")"
    run bash -c '
      set -euo pipefail
      source "$1"
      printf "%s" "$(ralph_path_to_file_uri "$2")"
    ' _ "$helper" "$path_simple"

    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
  else
    echo "python3 missing; skipping absolute URI check"
  fi

  rm -f "$helper"
  rm -rf "$path_space_dir" "$path_simple_dir"
}

@test "ralph restart command hint exposes restart instructions" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper
  helper="$(mktemp)"
  sed -n '/^ralph_restart_command_hint()/,/^}/p' "$RUN_PLAN_SH" > "$helper"

  run bash -c '
    set -euo pipefail
    RALPH_RUN_PLAN_RELATIVE=".ralph/run-plan.sh --runtime cursor"
    PLAN_PATH="plan path.md"
    WORKSPACE="/tmp/workspace dir"
    PREBUILT_AGENT=""
    source "$1"
    printf "%s" "$(ralph_restart_command_hint)"
  ' _ "$helper"

  [ "$status" -eq 0 ]
  [ "$output" = ".ralph/run-plan.sh --runtime cursor --non-interactive --plan plan\\ path.md --agent agent /tmp/workspace\\ dir" ]

  run bash -c '
    set -euo pipefail
    RALPH_ORCH_FILE="/tmp/restart plan/orch.json"
    source "$1"
    printf "%s" "$(ralph_restart_command_hint)"
  ' _ "$helper"

  [ "$status" -eq 0 ]
  [ "$output" = ".ralph/orchestrator.sh --orchestration /tmp/restart\\ plan/orch.json" ]

  rm -f "$helper"
}

@test "ralph should persist human files only when tty attached" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper out_file
  helper="$(mktemp)"
  sed -n '/^ralph_should_persist_human_files()/,/^}/p' "$RUN_PLAN_SH" > "$helper"
  out_file="$(mktemp)"

  run script -q /dev/null bash -c '
    set -euo pipefail
    source "$1"
    ralph_should_persist_human_files
  ' _ "$helper"

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

  rm -f "$helper" "$out_file"
}
