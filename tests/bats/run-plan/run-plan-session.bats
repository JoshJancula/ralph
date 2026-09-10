#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

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
  local run_plan_core_lib="$bash_lib_dir/run-plan/run-plan-core.sh"
  local run_plan_agent_lib="$bash_lib_dir/run-plan/run-plan-agent.sh"
  RUN_PLAN_EXTRA_FUNCS_FILE="$(mktemp)"
  awk '/^ralph_run_plan_log\(\)/,/^ralph_ensure_codex_cli\(\)/ { print; if ($0 ~ /^ralph_ensure_codex_cli\(\)/) exit }' "$run_plan_core_lib" > "$RUN_PLAN_EXTRA_FUNCS_FILE"
  RUN_PLAN_PROMPT_FUNCS_FILE="$(mktemp)"
  cat "$run_plan_agent_lib" > "$RUN_PLAN_PROMPT_FUNCS_FILE"
  RUN_PLAN_PREBUILT_FUNCS_FILE="$(mktemp)"
  cat "$run_plan_agent_lib" > "$RUN_PLAN_PREBUILT_FUNCS_FILE"
  RUN_PLAN_HUMAN_FUNCS_FILE="$(mktemp)"
  sed -n '/^ralph_json_field()/,/^}/p' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_path_to_file_uri()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_should_persist_human_files()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_restart_command_hint()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_operator_has_real_answer()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_operator_response_file_owned_by_current_user()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_remove_human_action_file()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_write_human_action_file()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_sync_human_action_file_state()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  sed -n '/^ralph_try_consume_human_response()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  printf 'source %q\n' "$REPO_ROOT/bundle/.ralph/bash-lib/permission-classify.sh" >> "$RUN_PLAN_HUMAN_FUNCS_FILE"
  RUN_PLAN_HUMAN_ACTION_FUNCS_FILE="$(mktemp)"
  sed -n '/^ralph_json_field()/,/^}/p' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  sed -n '/^ralph_remove_human_action_file()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  sed -n '/^ralph_write_human_action_file()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  sed -n '/^ralph_sync_human_action_file_state()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  sed -n '/^ralph_should_persist_human_files()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  sed -n '/^ralph_restart_command_hint()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  printf 'source %q\n' "$REPO_ROOT/bundle/.ralph/bash-lib/permission-classify.sh" >> "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE="$(mktemp)"
  sed -n '/^ralph_json_field()/,/^}/p' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
  sed -n '/^ralph_operator_has_real_answer()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
  sed -n '/^ralph_try_consume_human_response()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
  sed -n '/^ralph_operator_response_file_owned_by_current_user()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
  printf 'source %q\n' "$REPO_ROOT/bundle/.ralph/bash-lib/permission-classify.sh" >> "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
  printf 'source %q\n' "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh" >> "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
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
  mkdir -p "$shared_root/bash-lib/run-plan"
  touch "$shared_root/ralph-env-safety.sh"
  for helper in run-plan-env.sh run-plan-invoke-cursor.sh run-plan-invoke-claude.sh run-plan-invoke-codex.sh; do
    touch "$shared_root/bash-lib/run-plan/$helper"
  done
  printf '%s' "$shared_root"
}

@test "ralph_session_prompt_cli_resume exposes compact as a session strategy" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local tmp_dir session_lib session_file menu_file
  tmp_dir="$(mktemp -d)"
  session_file="$tmp_dir/session-id.codex.txt"
  menu_file="$tmp_dir/menu-args.txt"
  session_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"

  run bash -c '
    set -euo pipefail
    export _RALPH_PROMPT_SESSION_STRATEGY_INTERACTIVE=1
    export RALPH_SESSION_STRATEGY_PROMPT_ASSUME_TTY=1
    NON_INTERACTIVE_FLAG=0
    RUNTIME=codex
    SESSION_ID_FILE="$2"
    menu_file="$3"
    C_C="" C_BOLD="" C_RST="" C_DIM="" C_G=""
    source "$1"
    ralph_menu_select() {
      printf "%s\n" "$*" >"$menu_file"
      printf "%s" "compact"
    }
    ralph_session_prompt_cli_resume
    printf "STATE=%s:%s\n" "${RALPH_PLAN_SESSION_STRATEGY:-unset}" "${RALPH_PLAN_CLI_RESUME:-unset}"
  ' _ "$session_lib" "$session_file" "$menu_file"

  [ "$status" -eq 0 ]
  [[ "$output" == *"How should Codex handle sessions between TODOs?"* ]]
  [[ "$output" == *"reuse session id with a compact command prefix before each TODO"* ]]
  [[ "$(cat "$menu_file")" == *"--prompt Session strategy --default 1 -- fresh resume reset compact"* ]]
  [[ "$output" == *"STATE=compact:1"* ]]

  rm -rf "$tmp_dir"
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

@test "ralph_try_consume_human_response applies guidance answers and clears request files" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE" ] || skip "human consume helper unavailable"

  local tmp_dir pending human_context operator_response human_request log_file session_dir
  tmp_dir="$(mktemp -d)"
  session_dir="$tmp_dir/session"
  mkdir -p "$session_dir/continuations"
  pending="$tmp_dir/pending-human.txt"
  printf 'how should we proceed?\n' >"$pending"
  human_request="$tmp_dir/human-request.json"
  cat <<'EOF' >"$human_request"
{
  "placeholder": false,
  "kind": "guidance",
  "decision": "answer",
  "runtime": "cursor",
  "classification": "",
  "blocked_command_or_tool": "",
  "blocked_path": "",
  "blocked_tool": "",
  "reason": "",
  "question": "how should we proceed?"
}
EOF
  human_context="$tmp_dir/HUMAN-CONTEXT.md"
  printf '### history entry\n' >"$human_context"
  operator_response="$tmp_dir/operator-response.txt"
  cat <<'EOF' >"$operator_response"
{
  "placeholder": false,
  "kind": "guidance",
  "decision": "answer",
  "runtime": "cursor",
  "classification": "",
  "blocked_command_or_tool": "",
  "blocked_path": "",
  "blocked_tool": "",
  "reason": "",
  "answer": "yes, please continue"
}
EOF
  log_file="$tmp_dir/log.txt"

  run bash -c '
    set -euo pipefail
    printf() { builtin printf -- "$@"; }
    source "$1"
    export RALPH_SESSION_DIR="$7"
    export RALPH_PLAN_KEY="guidance-test"
    export RUNTIME="cursor"
    export RALPH_CURRENT_TODO_LINE="12"
    export RALPH_CURRENT_TODO_ORDINAL="1"
    export RALPH_CURRENT_TODO_ID="guidance-test-todo"
    export RALPH_CURRENT_TODO_HASH="hash-guidance"
    HUMAN_CONTEXT="$2"
    PENDING_HUMAN="$3"
    HUMAN_REQUEST_FILE="$4"
    OPERATOR_RESPONSE_FILE="$5"
    LOG_FILE="$6"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_try_consume_human_response
    printf "RESUME=%s\n" "${RALPH_PLAN_CLI_RESUME:-unset}"
    printf "STRATEGY=%s\n" "${RALPH_PLAN_SESSION_STRATEGY:-unset}"
    printf "CONT=%s\n" "$(ls -1 "$RALPH_SESSION_DIR/continuations"/human-answer-*.json 2>/dev/null | wc -l | tr -d " ")"
  ' _ "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE" "$human_context" "$pending" "$human_request" "$operator_response" "$log_file" "$session_dir"

  [ "$status" -eq 0 ]
  run_output="$output"
  [ ! -f "$pending" ]
  [ ! -f "$operator_response" ]
  [ -f "$human_request" ]
  content="$(<"$human_context")"
  [[ "$content" == *"how should we proceed?"* ]]
  [[ "$content" == *"yes, please continue"* ]]
  [[ "$run_output" == *"CONT=1"* ]]
  [[ "$run_output" != *"STRATEGY=resume"* ]]
  grep -q "Applied guidance answer from operator-response.txt; continuing plan run" "$log_file"

  rm -rf "$tmp_dir"
}

@test "ralph_try_consume_human_response allow updates overlays and resumes the session" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE" ] || skip "human consume helper unavailable"

  local tmp_dir pending human_request human_context operator_response log_file
  local session_dir
  tmp_dir="$(mktemp -d)"
  session_dir="$tmp_dir/session"
  mkdir -p "$session_dir/continuations"
  pending="$tmp_dir/pending-human.txt"
  printf 'permission required\n' >"$pending"
  human_request="$tmp_dir/human-request.json"
  cat <<'EOF' >"$human_request"
{
  "placeholder": false,
  "kind": "permission",
  "decision": "allow",
  "runtime": "opencode",
  "classification": "external_directory",
  "blocked_command_or_tool": "",
  "blocked_path": "/tmp/*",
  "blocked_tool": "",
  "reason": "approved",
  "question": "permission required"
}
EOF
  cp "$human_request" "$session_dir/permission-remediation.json"
  human_context="$tmp_dir/HUMAN-CONTEXT.md"
  printf '### history entry\n' >"$human_context"
  operator_response="$tmp_dir/operator-response.txt"
  cat <<'EOF' >"$operator_response"
{
  "placeholder": false,
  "kind": "permission",
  "decision": "allow",
  "runtime": "opencode",
  "classification": "external_directory",
  "blocked_command_or_tool": "",
  "blocked_path": "/tmp/*",
  "blocked_tool": "",
  "reason": "approved",
  "answer": ""
}
EOF
  log_file="$tmp_dir/log.txt"

  run bash -c '
    set -euo pipefail
    source "$1"
    export RALPH_SESSION_DIR="$6"
    export RALPH_PLAN_KEY="permission-test"
    export RUNTIME="opencode"
    export RALPH_CURRENT_TODO_LINE="14"
    export RALPH_CURRENT_TODO_ORDINAL="1"
    export RALPH_CURRENT_TODO_ID="permission-test-todo"
    export RALPH_CURRENT_TODO_HASH="hash-permission"
    HUMAN_CONTEXT="$2"
    PENDING_HUMAN="$3"
    HUMAN_REQUEST_FILE="$4"
    OPERATOR_RESPONSE_FILE="$5"
    LOG_FILE="$7"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_try_consume_human_response
    printf "RESUME=%s\n" "${RALPH_PLAN_CLI_RESUME:-unset}"
    printf "STRATEGY=%s\n" "${RALPH_PLAN_SESSION_STRATEGY:-unset}"
    printf "CONT=%s\n" "$(ls -1 "$RALPH_SESSION_DIR/continuations"/human-answer-*.json 2>/dev/null | wc -l | tr -d " ")"
    printf "OVERLAY=%s\n" "${OPENCODE_PLAN_PERMISSION_CONFIG_PATH:-unset}"
  ' _ "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE" "$human_context" "$pending" "$human_request" "$operator_response" "$session_dir" "$log_file"

  [ "$status" -eq 0 ]
  [ ! -f "$pending" ]
  [ ! -f "$operator_response" ]
  [ -f "$human_request" ]
  [[ "$output" == *"CONT=1"* ]]
  [[ "$output" != *"STRATEGY=resume"* ]]
  [ -f "$session_dir/permission-remediation.json" ]
  jq -e '.kind == "permission"' "$session_dir/permission-remediation.json"
  jq -e '.blocked_path == "/tmp/*"' "$session_dir/permission-remediation.json"

  rm -rf "$tmp_dir"
}

@test "ralph_apply_permission_operator_response allow persists proxy allowlist for retry" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local tmp_dir workspace session_dir blocked_dir blocked_file response_json
  tmp_dir="$(mktemp -d)"
  workspace="$tmp_dir/workspace"
  blocked_dir="$tmp_dir/blocked"
  mkdir -p "$workspace" "$blocked_dir"
  blocked_file="$blocked_dir/blocked.txt"
  printf 'blocked\n' >"$blocked_file"
  response_json="$tmp_dir/operator-response.json"
  cat <<EOF >"$response_json"
{
  "placeholder": false,
  "kind": "permission",
  "decision": "allow",
  "runtime": "opencode",
  "classification": "external_directory",
  "blocked_command_or_tool": "",
  "blocked_path": "$blocked_file",
  "blocked_tool": "",
  "reason": "approved",
  "answer": ""
}
EOF
  session_dir="$workspace/.ralph-workspace/sessions/proxy-allow-test"

  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    source "$3"
    export SCRIPT_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    export WORKSPACE="$4"
    export RALPH_PLAN_KEY="proxy-allow-test"
    export RUNTIME="opencode"
    export RALPH_PLAN_WORKSPACE_ROOT="$4/.ralph-workspace"
    ralph_session_init "$4" "plan.log"
    result_file="$(mktemp)"
    ralph_apply_permission_operator_response \
      "$RALPH_SESSION_DIR" \
      "opencode" \
      "external_directory" \
      "" \
      "$6" \
      "" \
      "$(cat "$7")" >"$result_file"
    decision="$(cat "$result_file")"
    rm -f "$result_file"
    printf 'decision=%s\n' "$decision"
    printf 'allowlist=%s\n' "${RALPH_MCP_ALLOWLIST:-unset}"
    printf 'file=%s\n' "$RALPH_MCP_ALLOWLIST_FILE"
    if ! ralph_mcp_proxy_path_is_allowed "$6" 1 >/dev/null 2>&1; then
      echo "path not allowed" >&2
      exit 1
    fi
  ' _ \
    "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/permission-classify.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh" \
    "$workspace" \
    "$session_dir" \
    "$blocked_file" \
    "$response_json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"allowlist="*"$blocked_file"* ]]
  [ -f "$session_dir/mcp-allowlist.txt" ]
  grep -Fxq "$blocked_file" "$session_dir/mcp-allowlist.txt"
  grep -Fxq "$blocked_dir" "$session_dir/mcp-allowlist.txt"

  rm -rf "$tmp_dir"
}

@test "ralph_apply_permission_operator_response keeps allow when no blocked path was extracted" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local tmp_dir workspace session_dir response_json
  tmp_dir="$(mktemp -d)"
  workspace="$tmp_dir/workspace"
  mkdir -p "$workspace"
  response_json="$tmp_dir/operator-response.json"
  cat <<EOF >"$response_json"
{
  "placeholder": false,
  "kind": "permission",
  "decision": "allow",
  "runtime": "opencode",
  "classification": "external_directory",
  "blocked_command_or_tool": "",
  "blocked_path": "",
  "blocked_tool": "",
  "reason": "terminal bridge response",
  "answer": ""
}
EOF
  session_dir="$workspace/.ralph-workspace/sessions/proxy-allow-nopath"

  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    export SCRIPT_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    export WORKSPACE="$3"
    export RALPH_PLAN_KEY="proxy-allow-nopath"
    export RUNTIME="opencode"
    export RALPH_PLAN_WORKSPACE_ROOT="$3/.ralph-workspace"
    ralph_session_init "$3" "plan.log"
    result_file="$(mktemp)"
    ralph_apply_permission_operator_response \
      "$RALPH_SESSION_DIR" \
      "opencode" \
      "external_directory" \
      "" \
      "" \
      "" \
      "$(cat "$5")" >"$result_file"
    decision="$(cat "$result_file")"
    rm -f "$result_file"
    printf "decision=%s\n" "$decision"
    printf "degraded=%s\n" "${RALPH_PERMISSION_APPLY_DEGRADED:-none}"
  ' _ \
    "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/permission-classify.sh" \
    "$workspace" \
    "$session_dir" \
    "$response_json"

  [ "$status" -eq 0 ]
  # An operator approval must never be reported back as a denial just because
  # the denial excerpt carried no concrete path to allowlist.
  [[ "$output" == *"decision=allow"* ]]
  [[ "$output" == *"degraded="*"no-blocked-path"* ]]

  rm -rf "$tmp_dir"
}

@test "ralph_try_consume_human_response deny clears the request and does not apply overlays" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE" ] || skip "human consume helper unavailable"

  local tmp_dir pending human_request human_context operator_response log_file
  tmp_dir="$(mktemp -d)"
  pending="$tmp_dir/pending-human.txt"
  printf 'permission required\n' >"$pending"
  human_request="$tmp_dir/human-request.json"
  cat <<'EOF' >"$human_request"
{
  "placeholder": false,
  "kind": "permission",
  "decision": "deny",
  "runtime": "opencode",
  "classification": "external_directory",
  "blocked_command_or_tool": "",
  "blocked_path": "/tmp/*",
  "blocked_tool": "",
  "reason": "do not allow",
  "question": "permission required"
}
EOF
  human_context="$tmp_dir/HUMAN-CONTEXT.md"
  printf '### history entry\n' >"$human_context"
  operator_response="$tmp_dir/operator-response.txt"
  cat <<'EOF' >"$operator_response"
{
  "placeholder": false,
  "kind": "permission",
  "decision": "deny",
  "runtime": "opencode",
  "classification": "external_directory",
  "blocked_command_or_tool": "",
  "blocked_path": "/tmp/*",
  "blocked_tool": "",
  "reason": "do not allow",
  "answer": ""
}
EOF
  log_file="$tmp_dir/log.txt"

  run bash -c '
    set -euo pipefail
    source "$1"
    HUMAN_CONTEXT="$2"
    PENDING_HUMAN="$3"
    HUMAN_REQUEST_FILE="$4"
    OPERATOR_RESPONSE_FILE="$5"
    RALPH_SESSION_DIR="$6"
    LOG_FILE="$7"
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_try_consume_human_response
    printf "DECISION=%s\n" "${RALPH_PERMISSION_RESPONSE_DECISION:-unset}"
    printf "RESUME=%s\n" "${RALPH_PLAN_CLI_RESUME:-unset}"
    printf "OVERLAY=%s\n" "${OPENCODE_PLAN_PERMISSION_CONFIG_PATH:-unset}"
  ' _ "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE" "$human_context" "$pending" "$human_request" "$operator_response" "$tmp_dir/session" "$log_file"

  [ "$status" -eq 0 ]
  # A deny stops the current run only. The request and the consumed answer must
  # be cleared, otherwise every later run re-consumes the stale deny and exits
  # immediately without ever prompting the operator again.
  [ ! -f "$pending" ]
  [ ! -f "$operator_response" ]
  [ -f "$human_request" ]
  [[ "$output" == *"DECISION=deny"* ]]
  [[ "$output" == *"RESUME=unset"* || "$output" == *"RESUME=0"* ]]
  [[ "$output" == *"OVERLAY=unset"* ]]
  [ ! -f "$tmp_dir/session/permission-remediation.json" ]

  rm -rf "$tmp_dir"
}

@test "ralph_human_input_write_offline_instructions writes expected content" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper tmp_dir human_input pending operator_response human_action
  local plan_file log_file output_log session_dir

  helper="$(mktemp)"
  local run_plan_core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  cat <<'EOF' > "$helper"
C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_RST="" C_DIM=""
log(){ :; }
ralph_run_plan_log(){ log "$@"; }
ralph_restart_command_hint(){ printf "%s" "restart hint"; }
ralph_write_human_action_file(){ :; }
ralph_write_operator_response_template() {
  cat >"$2" <<'TEMPLATE_EOF'
{
  "placeholder": true,
  "kind": "guidance",
  "decision": "answer",
  "runtime": "",
  "classification": "",
  "blocked_command_or_tool": "",
  "blocked_path": "",
  "blocked_tool": "",
  "reason": "",
  "answer": ""
}
TEMPLATE_EOF
}
ralph_path_to_file_uri() {
  printf 'file://%s' "$1"
}
EOF
  sed -n '/^ralph_human_input_write_offline_instructions()/,/^}/p' "$run_plan_core_lib" >> "$helper"
  sed -n '/^ralph_json_field()/,/^}/p' "$run_plan_core_lib" >> "$helper"
  printf 'source %q\n' "$REPO_ROOT/bundle/.ralph/bash-lib/permission-classify.sh" >> "$helper"

  tmp_dir="$(mktemp -d)"
  human_input="$tmp_dir/HUMAN-INPUT-REQUIRED.md"
  pending="$tmp_dir/pending-human.txt"
  operator_response="$tmp_dir/operator-response.txt"
  human_action="$tmp_dir/HUMAN-ACTION.md"
  plan_file="$tmp_dir/PLAN.md"
  log_file="$tmp_dir/log.txt"
  output_log="$tmp_dir/output.log"
  human_request="$tmp_dir/human-request.json"
  session_dir="$tmp_dir/session"
  mkdir -p "$session_dir"
  human_request="$session_dir/human-request.json"
  printf 'plan instructions\n' >"$plan_file"
  printf 'agent question\n' >"$pending"

  run bash -c '
    set -euo pipefail
    source "$1"
    export SCRIPT_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    HUMAN_INPUT_MD="$2"
    PENDING_HUMAN="$3"
    OPERATOR_RESPONSE_FILE="$4"
    HUMAN_ACTION_FILE="$5"
    HUMAN_REQUEST_FILE="$6"
    RALPH_SESSION_DIR="$7"
    PLAN_PATH="$8"
    LOG_FILE="$9"
    OUTPUT_LOG="${10}"
    HUMAN_PROMPT_NO_OPEN_FLAG=1
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_write_human_action_file(){ :; }
    ralph_human_input_write_offline_instructions
  ' _ "$helper" "$human_input" "$pending" "$operator_response" "$human_action" "$human_request" "$session_dir" "$plan_file" "$log_file" "$output_log"

  [ "$status" -eq 0 ]
  [ -f "$human_input" ]
  content="$(<"$human_input")"
  [[ "$content" == *"# Paused for human input"* ]]
  [[ "$content" == *"## Question from the agent"* ]]
  [[ "$content" == *"agent question"* ]]
  [[ "$content" == *"## What to do"* ]]
  [[ "$content" == *"This instruction page:"* ]]
  [[ "$content" == *"file://"*"HUMAN-INPUT-REQUIRED.md"* ]]
  [[ "$content" == *"structured human-request record"* ]]
  [[ "$content" == *"- Plan file:"*"$plan_file"* ]]
  [ -f "$operator_response" ]
  [ -f "$human_request" ]
  jq -e '.kind == "guidance"' "$human_request"
  jq -e '.placeholder == true and .kind == "guidance"' "$operator_response"

  rm -f "$helper"
  rm -rf "$tmp_dir"
}

@test "ralph_human_input_write_offline_instructions forwards permission pauses to human ack bridge" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper tmp_dir human_input pending operator_response human_action
  local plan_file log_file output_log session_dir bridge_log human_request

  helper="$(mktemp)"
  local run_plan_core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  cat <<'EOF' > "$helper"
C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_RST="" C_DIM=""
log(){ :; }
ralph_run_plan_log(){ log "$@"; }
ralph_restart_command_hint(){ printf "%s" "restart hint"; }
ralph_write_human_action_file(){ :; }
ralph_write_operator_response_template() {
  cat >"$2" <<'TEMPLATE_EOF'
{
  "placeholder": true,
  "kind": "permission",
  "decision": "allow",
  "runtime": "",
  "classification": "",
  "blocked_command_or_tool": "",
  "blocked_path": "",
  "blocked_tool": "",
  "reason": "",
  "answer": ""
}
TEMPLATE_EOF
}
ralph_path_to_file_uri() {
  printf 'file://%s' "$1"
}
ralph_forward_human_question_to_orchestrator() {
  printf 'bridge:%s:%s\n' "$1" "$2" >>"$BRIDGE_LOG"
}
EOF
  sed -n '/^ralph_human_input_write_offline_instructions()/,/^}/p' "$run_plan_core_lib" >> "$helper"
  sed -n '/^ralph_json_field()/,/^}/p' "$run_plan_core_lib" >> "$helper"
  printf 'source %q\n' "$REPO_ROOT/bundle/.ralph/bash-lib/permission-classify.sh" >> "$helper"

  tmp_dir="$(mktemp -d)"
  human_input="$tmp_dir/HUMAN-INPUT-REQUIRED.md"
  pending="$tmp_dir/pending-human.txt"
  operator_response="$tmp_dir/operator-response.txt"
  human_action="$tmp_dir/HUMAN-ACTION.md"
  plan_file="$tmp_dir/PLAN.md"
  log_file="$tmp_dir/log.txt"
  output_log="$tmp_dir/output.log"
  bridge_log="$tmp_dir/bridge.log"
  human_request="$tmp_dir/human-request.json"
  session_dir="$tmp_dir/session"
  mkdir -p "$session_dir"
  human_request="$session_dir/human-request.json"
  printf 'plan instructions\n' >"$plan_file"
  printf 'permission question\n' >"$pending"
  printf '%s\n' '{"placeholder":true,"kind":"permission","decision":"allow"}' >"$human_request"

  run bash -c '
    set -euo pipefail
    source "$1"
    export SCRIPT_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    HUMAN_INPUT_MD="$2"
    PENDING_HUMAN="$3"
    OPERATOR_RESPONSE_FILE="$4"
    HUMAN_ACTION_FILE="$5"
    HUMAN_REQUEST_FILE="$6"
    RALPH_SESSION_DIR="$7"
    PLAN_PATH="$8"
    LOG_FILE="$9"
    OUTPUT_LOG="${10}"
    BRIDGE_LOG="${11}"
    HUMAN_PROMPT_NO_OPEN_FLAG=1
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    ralph_write_human_action_file(){ :; }
    ralph_human_input_write_offline_instructions
  ' _ "$helper" "$human_input" "$pending" "$operator_response" "$human_action" "$human_request" "$session_dir" "$plan_file" "$log_file" "$output_log" "$bridge_log"

  [ "$status" -eq 0 ]
  [ -f "$human_input" ]
  [ -f "$operator_response" ]
  [ -f "$bridge_log" ]
  grep -Fq "bridge:$pending:$plan_file" "$bridge_log"

  rm -f "$helper"
  rm -rf "$tmp_dir"
}

@test "ralph_human_pause_for_operator_offline returns 0 when TTY grants permission" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper tmp_dir plan_file log_file
  helper="$(mktemp)"
  tmp_dir="$(mktemp -d)"
  plan_file="$tmp_dir/PLAN.md"
  log_file="$tmp_dir/log.txt"
  printf '%s\n' '- [x] done' '- [ ] pending' >"$plan_file"

  local run_plan_core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  cat <<'EOF' > "$helper"
ralph_run_plan_log(){ :; }
ralph_human_input_write_offline_instructions() {
  RALPH_PERMISSION_RESPONSE_DECISION="allow"
  export RALPH_PERMISSION_RESPONSE_DECISION
  return 0
}
count_todos() { printf '1 2\n'; }
_ralph_write_plan_usage_summary() { :; }
EOF
  sed -n '/^ralph_human_pause_for_operator_offline()/,/^}/p' "$run_plan_core_lib" >> "$helper"

  run bash -c '
    set -euo pipefail
    source "$1"
    PLAN_PATH="$2"
    LOG_FILE="$3"
    RALPH_PERMISSION_RESPONSE_DECISION=""
    ralph_human_pause_for_operator_offline
  ' _ "$helper" "$plan_file" "$log_file"

  [ "$status" -eq 0 ]

  rm -f "$helper"
  rm -rf "$tmp_dir"
}

@test "ralph_human_pause_for_operator_offline returns 0 when TTY denies permission" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper tmp_dir plan_file log_file
  helper="$(mktemp)"
  tmp_dir="$(mktemp -d)"
  plan_file="$tmp_dir/PLAN.md"
  log_file="$tmp_dir/log.txt"
  printf '%s\n' '- [x] done' '- [ ] pending' >"$plan_file"

  local run_plan_core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  cat <<'EOF' > "$helper"
ralph_run_plan_log(){ :; }
ralph_human_input_write_offline_instructions() {
  RALPH_PERMISSION_RESPONSE_DECISION="deny"
  export RALPH_PERMISSION_RESPONSE_DECISION
  return 0
}
count_todos() { printf '1 2\n'; }
_ralph_write_plan_usage_summary() { :; }
EOF
  sed -n '/^ralph_human_pause_for_operator_offline()/,/^}/p' "$run_plan_core_lib" >> "$helper"

  run bash -c '
    set -euo pipefail
    source "$1"
    PLAN_PATH="$2"
    LOG_FILE="$3"
    RALPH_PERMISSION_RESPONSE_DECISION=""
    ralph_human_pause_for_operator_offline
  ' _ "$helper" "$plan_file" "$log_file"

  [ "$status" -eq 0 ]

  rm -f "$helper"
  rm -rf "$tmp_dir"
}

@test "operator-denial exit path does not crash when _ralph_write_plan_usage_summary is not yet defined" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  # run-plan-core.sh is sourced top-to-bottom: the deny branch runs long
  # before the file reaches the _ralph_write_plan_usage_summary function
  # definition further down, so this block must guard the call the same way
  # its sibling branch a few lines above already does, or every operator
  # denial crashes with "command not found" instead of exiting cleanly.
  local run_plan_core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  local helper tmp_dir plan_file
  helper="$(mktemp)"
  tmp_dir="$(mktemp -d)"
  plan_file="$tmp_dir/PLAN.md"
  printf '%s\n' '- [x] done' '- [ ] pending' >"$plan_file"

  cat <<'EOF' > "$helper"
C_R=""; C_BOLD=""; C_RST=""; C_DIM=""
ralph_try_consume_human_response() {
  RALPH_PERMISSION_RESPONSE_DECISION="deny"
  export RALPH_PERMISSION_RESPONSE_DECISION
  return 0
}
count_todos() { printf '1 2\n'; }
ralph_runtime_overlay_cleanup_if_needed() { :; }
# Deliberately do NOT define _ralph_write_plan_usage_summary, reproducing
# the forward-reference gap this test guards against.
EOF
  sed -n '/^RALPH_PERMISSION_RESPONSE_DECISION=""$/,/^ralph_sync_human_action_file_state$/p' "$run_plan_core_lib" \
    | sed '$d' >> "$helper"

  # The extracted block is top-level script code that runs immediately on
  # `source` (this file is sourced, not invoked as a function), so PLAN_PATH
  # must already be set before sourcing -- not after.
  run bash -c '
    set -euo pipefail
    PLAN_PATH="$2"
    source "$1"
  ' _ "$helper" "$plan_file"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Permission request was denied by the operator"* ]]
  [[ "$output" != *"command not found"* ]]

  rm -f "$helper"
  rm -rf "$tmp_dir"
}

@test "ralph_human_pause_for_operator_offline exits 4 when no TTY decision was made" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper tmp_dir plan_file log_file
  helper="$(mktemp)"
  tmp_dir="$(mktemp -d)"
  plan_file="$tmp_dir/PLAN.md"
  log_file="$tmp_dir/log.txt"
  printf '%s\n' '- [x] done' '- [ ] pending' >"$plan_file"

  local run_plan_core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  cat <<'EOF' > "$helper"
ralph_run_plan_log(){ :; }
ralph_human_input_write_offline_instructions() {
  return 0
}
count_todos() { printf '1 2\n'; }
_ralph_write_plan_usage_summary() { :; }
EOF
  sed -n '/^ralph_human_pause_for_operator_offline()/,/^}/p' "$run_plan_core_lib" >> "$helper"

  run bash -c '
    source "$1"
    PLAN_PATH="$2"
    LOG_FILE="$3"
    RALPH_PERMISSION_RESPONSE_DECISION=""
    ralph_human_pause_for_operator_offline
  ' _ "$helper" "$plan_file" "$log_file"

  [ "$status" -eq 4 ]

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
  sed -n '/^ralph_should_persist_human_files()/,/^}/p' "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh" > "$helper"
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

@test "grader stage rejects resume session strategy at run-plan args" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper
  helper="$(mktemp)"
  cat <<'EOF' > "$helper"
ralph_die() { printf '%s\n' "$*" >&2; exit 1; }
RALPH_GRADER_STAGE=1
RALPH_PLAN_SESSION_STRATEGY=resume
case "${RALPH_PLAN_SESSION_STRATEGY:-fresh}" in
  fresh) exit 0 ;;
  *)
    ralph_die "Error: grader stages require sessionStrategy fresh (not resume, reset, or compact)."
    ;;
esac
EOF
  run bash "$helper"
  [ "$status" -ne 0 ]
  [[ "$output" == *"grader stages require sessionStrategy fresh"* ]]
  rm -f "$helper"
}

@test "ralph_rubric_grader_apply_session_isolation clears resume session" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local helper
  helper="$(mktemp)"
  cat <<EOF > "$helper"
set -euo pipefail
SCRIPT_DIR="$REPO_ROOT/bundle/.ralph"
source "\$SCRIPT_DIR/bash-lib/rubric-grader.sh"
RALPH_GRADER_STAGE=1
RALPH_MODE=ralph
RALPH_PLAN_SESSION_STRATEGY=resume
RALPH_PLAN_CLI_RESUME=1
RALPH_RUN_PLAN_RESUME_SESSION_ID=test-session
ralph_rubric_grader_apply_session_isolation
[[ "\${RALPH_PLAN_SESSION_STRATEGY}" == "fresh" ]]
[[ "\${RALPH_PLAN_CLI_RESUME}" == "0" ]]
[[ -z "\${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]
EOF
  run bash "$helper"
  [ "$status" -eq 0 ]
  rm -f "$helper"
}
