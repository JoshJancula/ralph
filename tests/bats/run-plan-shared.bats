#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/test_helper/run-plan-helpers.bash"

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
    ralph_run_plan_log() { :; }
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
    PATH=""
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
    ralph_run_plan_log() { :; }
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
    ralph_run_plan_log() { :; }
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
    ralph_run_plan_log() { :; }
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
  [[ -n "${CI:-}" ]] && skip "Temporarily skipped in CI due agent context formatting variance"
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

  run env RALPH_ARTIFACT_NS=PLAN bash -c '
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
  [[ "$output" == *"repo-context"* ]]
  [[ "$output" == *"SKILL.md"* ]]
  [[ "$output" == *".ralph-workspace/artifacts/PLAN/architecture.md"* ]]
  [[ "$output" == *".ralph-workspace/artifacts/PLAN/research.md"* ]]
  [[ "$output" == *"**Agent config:**"* ]]
}

@test "prompt_select_prebuilt_agent accepts scripted TTY selection" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local runner
  runner="$(mktemp)"

  cat <<'EOS' > "$runner"
#!/usr/bin/env bash
set -euo pipefail
source "$PREBUILT_FUNCS_FILE"
AGENTS_ROOT_REL=".cursor/agents"
AGENT_CONFIG_TOOL="$REPO_ROOT/.ralph/agent-config-tool.sh"
C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
selected="$(prompt_select_prebuilt_agent "$REPO_ROOT")"
printf "\n"
printf "%s\n" "$selected"
EOS
  chmod +x "$runner"

  run env PREBUILT_FUNCS_FILE="$RUN_PLAN_PROMPT_FUNCS_FILE" REPO_ROOT="$REPO_ROOT" ralph-script-pty-bash "$runner" <<'EOF'
2
EOF

  [ "$status" -eq 0 ]
  final_line="$(printf '%s\n' "$output" | awk 'NF { last=$0 } END { printf "%s\n", last }' | tr -d '\r')"
  rm -f "$runner"
  [ "$final_line" = "code-review" ]
}

@test "prompt_agent_source_mode accepts scripted selection" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local runner
  runner="$(mktemp)"

  cat <<'EOS' > "$runner"
#!/usr/bin/env bash
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
printf "\nflag=%s\n" "$INTERACTIVE_SELECT_AGENT_FLAG"
EOS
  chmod +x "$runner"

  run env PROMPT_FUNCS_FILE="$RUN_PLAN_PROMPT_FUNCS_FILE" REPO_ROOT="$REPO_ROOT" ralph-script-pty-bash "$runner" <<'EOF'
2
EOF

  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=0"* ]]
  rm -f "$runner"
}

@test "prompt_cleanup_on_exit prompts for yes and no answers via scripted TTY input" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_CLEANUP_FUNCS_FILE" ] || skip "prompt_cleanup_on_exit helper unavailable"

  local cleanup_marker cleanup_script workspace log_dir output_log log_file
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

  local cleanup_runner
  cleanup_runner="$(mktemp)"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""\n'
    printf 'source %q\n' "$RUN_PLAN_CLEANUP_FUNCS_FILE"
    printf 'prompt_cleanup_on_exit\n'
    printf 'prompt_cleanup_on_exit\n'
  } >"$cleanup_runner"
  chmod +x "$cleanup_runner"

  run env \
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
    ralph-script-pty-bash "$cleanup_runner" <<'EOF'
y
n
EOF

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$cleanup_marker")" -eq 1 ]
  [[ "$output" == *"Cleanup command:"* ]]

  rm -rf "$workspace"
  rm -f "$cleanup_script" "$cleanup_marker" "$cleanup_runner"
}

@test "ralph path to file uri uses sample paths" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_FUNCS_FILE" ] || skip "human helper section unavailable"

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
  ' _ "$RUN_PLAN_HUMAN_FUNCS_FILE" "$path_space"

  [ "$status" -eq 0 ]
  [ "$output" = "file://$encoded" ]

  if command -v python3 >/dev/null; then
    expected="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri(), end="")' "$path_simple")"
    run bash -c '
      set -euo pipefail
      source "$1"
      printf "%s" "$(ralph_path_to_file_uri "$2")"
    ' _ "$RUN_PLAN_HUMAN_FUNCS_FILE" "$path_simple"

    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
  else
    echo "python3 missing; skipping absolute URI check"
  fi

  rm -rf "$path_space_dir" "$path_simple_dir"
}

@test "ralph restart command hint exposes restart instructions" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_HUMAN_FUNCS_FILE" ] || skip "human helper section unavailable"

  run bash -c '
    set -euo pipefail
    unset RALPH_ORCH_FILE
    RALPH_RUN_PLAN_RELATIVE=".ralph/run-plan.sh --runtime cursor"
    PLAN_PATH="plan path.md"
    WORKSPACE="/tmp/workspace dir"
    PREBUILT_AGENT=""
    source "$1"
    printf "%s" "$(ralph_restart_command_hint)"
  ' _ "$RUN_PLAN_HUMAN_FUNCS_FILE"

  [ "$status" -eq 0 ]
  [ "$output" = ".ralph/run-plan.sh --runtime cursor --non-interactive --plan plan\\ path.md --agent agent --workspace /tmp/workspace\\ dir" ]

  run bash -c '
    set -euo pipefail
    RALPH_ORCH_FILE="/tmp/restart plan/orch.json"
    source "$1"
    printf "%s" "$(ralph_restart_command_hint)"
  ' _ "$RUN_PLAN_HUMAN_FUNCS_FILE"

  [ "$status" -eq 0 ]
  [ "$output" = ".ralph/orchestrator.sh --orchestration /tmp/restart\\ plan/orch.json" ]

}

@test "prebuilt agent CURSOR_PLAN_MODEL env var overrides agent config model" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PREBUILT_FUNCS_FILE" ] || skip "prebuilt helper unavailable"

  local tmp_dir agents_root cfg_dir
  tmp_dir="$(mktemp -d)"
  agents_root="$tmp_dir/.cursor/agents"
  cfg_dir="$agents_root/test-agent"
  mkdir -p "$cfg_dir"
  cat > "$cfg_dir/config.json" <<'CFG'
{
  "name": "test-agent",
  "model": "agent-default-model",
  "description": "regression test agent",
  "rules": [],
  "skills": [],
  "output_artifacts": [
    { "path": ".ralph-workspace/artifacts/test/out.md", "required": true }
  ]
}
CFG

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".cursor/agents"
    AGENT_CONFIG_TOOL="$3"
    RUNTIME=cursor
    export CURSOR_PLAN_MODEL="env-override-model"
    unset PLAN_MODEL_CLI
    ws="$2"
    SELECTED_MODEL="$(read_prebuilt_agent_model "$ws" "test-agent")"
    _runtime_env_model=""
    case "$RUNTIME" in
      cursor) _runtime_env_model="${CURSOR_PLAN_MODEL:-}" ;;
    esac
    if [[ -n "$_runtime_env_model" ]]; then
      SELECTED_MODEL="$_runtime_env_model"
    fi
    printf "%s" "$SELECTED_MODEL"
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$tmp_dir" "$REPO_ROOT/.ralph/agent-config-tool.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "env-override-model" ]
  rm -rf "$tmp_dir"
}

@test "prebuilt agent PLAN_MODEL_CLI takes priority over CURSOR_PLAN_MODEL and config" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PREBUILT_FUNCS_FILE" ] || skip "prebuilt helper unavailable"

  local tmp_dir agents_root cfg_dir
  tmp_dir="$(mktemp -d)"
  agents_root="$tmp_dir/.cursor/agents"
  cfg_dir="$agents_root/test-agent"
  mkdir -p "$cfg_dir"
  cat > "$cfg_dir/config.json" <<'CFG'
{
  "name": "test-agent",
  "model": "agent-default-model",
  "description": "regression test agent",
  "rules": [],
  "skills": [],
  "output_artifacts": [
    { "path": ".ralph-workspace/artifacts/test/out.md", "required": true }
  ]
}
CFG

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".cursor/agents"
    AGENT_CONFIG_TOOL="$3"
    RUNTIME=cursor
    export CURSOR_PLAN_MODEL="env-override-model"
    PLAN_MODEL_CLI="cli-flag-model"
    ws="$2"
    SELECTED_MODEL="$(read_prebuilt_agent_model "$ws" "test-agent")"
    _runtime_env_model=""
    case "$RUNTIME" in
      cursor) _runtime_env_model="${CURSOR_PLAN_MODEL:-}" ;;
    esac
    if [[ -n "$_runtime_env_model" ]]; then
      SELECTED_MODEL="$_runtime_env_model"
    fi
    if [[ -n "${PLAN_MODEL_CLI:-}" ]]; then
      SELECTED_MODEL="$PLAN_MODEL_CLI"
    fi
    printf "%s" "$SELECTED_MODEL"
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$tmp_dir" "$REPO_ROOT/.ralph/agent-config-tool.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "cli-flag-model" ]
  rm -rf "$tmp_dir"
}

@test "prebuilt agent falls back to config model when no env or CLI override" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PREBUILT_FUNCS_FILE" ] || skip "prebuilt helper unavailable"

  local tmp_dir agents_root cfg_dir
  tmp_dir="$(mktemp -d)"
  agents_root="$tmp_dir/.cursor/agents"
  cfg_dir="$agents_root/test-agent"
  mkdir -p "$cfg_dir"
  cat > "$cfg_dir/config.json" <<'CFG'
{
  "name": "test-agent",
  "model": "agent-default-model",
  "description": "regression test agent",
  "rules": [],
  "skills": [],
  "output_artifacts": [
    { "path": ".ralph-workspace/artifacts/test/out.md", "required": true }
  ]
}
CFG

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".cursor/agents"
    AGENT_CONFIG_TOOL="$3"
    RUNTIME=cursor
    unset CURSOR_PLAN_MODEL
    unset PLAN_MODEL_CLI
    ws="$2"
    SELECTED_MODEL="$(read_prebuilt_agent_model "$ws" "test-agent")"
    _runtime_env_model=""
    case "$RUNTIME" in
      cursor) _runtime_env_model="${CURSOR_PLAN_MODEL:-}" ;;
    esac
    if [[ -n "$_runtime_env_model" ]]; then
      SELECTED_MODEL="$_runtime_env_model"
    fi
    printf "%s" "$SELECTED_MODEL"
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$tmp_dir" "$REPO_ROOT/.ralph/agent-config-tool.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "agent-default-model" ]
  rm -rf "$tmp_dir"
}

@test "CLAUDE_PLAN_MODEL env var overrides config model for claude runtime" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PREBUILT_FUNCS_FILE" ] || skip "prebuilt helper unavailable"

  local tmp_dir agents_root cfg_dir
  tmp_dir="$(mktemp -d)"
  agents_root="$tmp_dir/.claude/agents"
  cfg_dir="$agents_root/test-agent"
  mkdir -p "$cfg_dir"
  cat > "$cfg_dir/config.json" <<'CFG'
{
  "name": "test-agent",
  "model": "claude-default",
  "description": "regression test agent",
  "rules": [],
  "skills": [],
  "output_artifacts": [
    { "path": ".ralph-workspace/artifacts/test/out.md", "required": true }
  ]
}
CFG

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".claude/agents"
    AGENT_CONFIG_TOOL="$3"
    RUNTIME=claude
    export CLAUDE_PLAN_MODEL="claude-sonnet-4-5"
    unset CURSOR_PLAN_MODEL
    unset PLAN_MODEL_CLI
    ws="$2"
    SELECTED_MODEL="$(read_prebuilt_agent_model "$ws" "test-agent")"
    _runtime_env_model=""
    case "$RUNTIME" in
      claude) _runtime_env_model="${CLAUDE_PLAN_MODEL:-${CURSOR_PLAN_MODEL:-}}" ;;
    esac
    if [[ -n "$_runtime_env_model" ]]; then
      SELECTED_MODEL="$_runtime_env_model"
    fi
    printf "%s" "$SELECTED_MODEL"
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$tmp_dir" "$REPO_ROOT/.ralph/agent-config-tool.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "claude-sonnet-4-5" ]
  rm -rf "$tmp_dir"
}
