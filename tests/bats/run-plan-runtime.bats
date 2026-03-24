#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
RUN_PLAN_FUNCS_FILE=""
RUN_PLAN_EXTRA_FUNCS_FILE=""
RUN_PLAN_PROMPT_FUNCS_FILE=""
RUN_PLAN_PREBUILT_FUNCS_FILE=""
RUN_PLAN_HUMAN_ACTION_FUNCS_FILE=""
RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE=""

setup() {
  if [[ ! -f "$RUN_PLAN_SH" ]]; then
    RUN_PLAN_FUNCS_FILE=""
    RUN_PLAN_EXTRA_FUNCS_FILE=""
    RUN_PLAN_PROMPT_FUNCS_FILE=""
    RUN_PLAN_PREBUILT_FUNCS_FILE=""
    RUN_PLAN_HUMAN_ACTION_FUNCS_FILE=""
    RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE=""
    return 0
  fi
  RUN_PLAN_FUNCS_FILE="$(mktemp)"
  awk '/^_THIS_RUN_PLAN_DIR=/{exit} {print}' "$RUN_PLAN_SH" > "$RUN_PLAN_FUNCS_FILE"
  local bash_lib_dir="$REPO_ROOT/bundle/.ralph/bash-lib"
  local run_plan_core_lib="$bash_lib_dir/run-plan-core.sh"
  local run_plan_cli_helpers_lib="$bash_lib_dir/run-plan-cli-helpers.sh"
  local run_plan_agent_lib="$bash_lib_dir/run-plan-agent.sh"
  RUN_PLAN_EXTRA_FUNCS_FILE="$(mktemp)"
  sed -n '/^ralph_run_plan_log()/,/^}/p' "$run_plan_core_lib" > "$RUN_PLAN_EXTRA_FUNCS_FILE"
  sed -n '/^ralph_ensure_cursor_cli()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_EXTRA_FUNCS_FILE"
  sed -n '/^ralph_ensure_claude_cli()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_EXTRA_FUNCS_FILE"
  sed -n '/^ralph_ensure_codex_cli()/,/^}/p' "$run_plan_core_lib" >> "$RUN_PLAN_EXTRA_FUNCS_FILE"
  cat "$run_plan_cli_helpers_lib" >> "$RUN_PLAN_EXTRA_FUNCS_FILE"
  RUN_PLAN_PROMPT_FUNCS_FILE="$(mktemp)"
  cat "$run_plan_agent_lib" > "$RUN_PLAN_PROMPT_FUNCS_FILE"
  RUN_PLAN_PREBUILT_FUNCS_FILE="$(mktemp)"
  cat "$run_plan_agent_lib" > "$RUN_PLAN_PREBUILT_FUNCS_FILE"
  RUN_PLAN_HUMAN_ACTION_FUNCS_FILE="$(mktemp)"
  awk '/^ralph_remove_human_action_file\(\)/,/^ralph_human_input_write_offline_instructions\(\)/ { print; if ($0 ~ /^ralph_human_input_write_offline_instructions\(\)/) { found=1 } } found && /^}$/ { print; exit }' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE="$(mktemp)"
  awk '/^ralph_operator_has_real_answer\(\)/,/^ralph_human_input_write_offline_instructions\(\)/ { print; if ($0 ~ /^ralph_human_input_write_offline_instructions\(\)/) { found=1 } } found && /^}$/ { print; exit }' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
}

teardown() {
  rm -f "$RUN_PLAN_FUNCS_FILE" "$RUN_PLAN_EXTRA_FUNCS_FILE" "$RUN_PLAN_PROMPT_FUNCS_FILE" "$RUN_PLAN_PREBUILT_FUNCS_FILE"
  rm -f "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE" "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
}

@test "run-plan reexecs under caffeinate when running on macOS" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [[ "$(uname -s)" == "Darwin" ]] || skip "caffeinate guard only relevant on macOS"

  local stub_dir capture_file plan_file
  stub_dir="$(mktemp -d)"
  capture_file="$(mktemp)"
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  cat <<'SHEBANG' > "$stub_dir/caffeinate"
#!/usr/bin/env bash
set -euo pipefail
env > "$CAFFEINATE_CAPTURE"
printf '%s\n' "$@" >> "$CAFFEINATE_CAPTURE"
SHEBANG
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
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
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
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
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
    CLAUDE_PLAN_CLI=""
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
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
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
    CLAUDE_PLAN_CLI=""
    command() {
      if [[ "$1" == "-v" && "$2" == "claude" ]]; then
        return 1
      fi
      builtin command "$@"
    }
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
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
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
    log(){ printf "%s\n" "$*" >>"$LOG_FILE"; }
    ralph_run_plan_log(){ log "$@"; }
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
