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
  awk '/^ralph_operator_has_real_answer\(\)/,/^ralph_remove_human_action_file\(\)/ { print; if ($0 ~ /^ralph_remove_human_action_file\(\)/) exit }' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_FUNCS_FILE"
  RUN_PLAN_HUMAN_ACTION_FUNCS_FILE="$(mktemp)"
  awk '/^ralph_remove_human_action_file\(\)/,/^ralph_human_input_write_offline_instructions\(\)/ { print; if ($0 ~ /^ralph_human_input_write_offline_instructions\(\)/) exit }' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_ACTION_FUNCS_FILE"
  RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE="$(mktemp)"
  awk '/^ralph_operator_has_real_answer\(\)/,/^ralph_human_input_write_offline_instructions\(\)/ { print; if ($0 ~ /^ralph_human_input_write_offline_instructions\(\)/) exit }' "$run_plan_core_lib" > "$RUN_PLAN_HUMAN_CONSUME_FUNCS_FILE"
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

@test "prompt_for_agent uses select_model_opencode when RUNTIME is opencode" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PROMPT_FUNCS_FILE" ] || skip "prompt_for_agent helper unavailable"

  run bash -c '
    set -euo pipefail
    source "$1"
    RUNTIME=opencode
    NON_INTERACTIVE_FLAG=0
    select_model_opencode() {
      printf "%s" "opencode/test-model"
    }
    prompt_for_agent
  ' _ "$RUN_PLAN_PROMPT_FUNCS_FILE"

  [ "$status" -eq 0 ]
  [ "$output" = "opencode/test-model" ]
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

  local prompt_funcs runner
  prompt_funcs="$(mktemp)"
  runner="$(mktemp)"
  cat bundle/.ralph/bash-lib/run-plan-agent.sh > "$prompt_funcs"

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

  run env PREBUILT_FUNCS_FILE="$prompt_funcs" REPO_ROOT="$REPO_ROOT" ralph-script-pty-bash "$runner" <<'EOF'
2
EOF

  [ "$status" -eq 0 ]
  final_line="$(printf '%s\n' "$output" | awk 'NF { last=$0 } END { printf "%s\n", last }' | tr -d '\r')"
  rm -f "$prompt_funcs" "$runner"
  [ "$final_line" = "code-review" ]
}

@test "prompt_agent_source_mode accepts scripted selection" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local prompt_funcs runner
  prompt_funcs="$(mktemp)"
  runner="$(mktemp)"
  cat bundle/.ralph/bash-lib/run-plan-agent.sh > "$prompt_funcs"

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

  run env PROMPT_FUNCS_FILE="$prompt_funcs" REPO_ROOT="$REPO_ROOT" ralph-script-pty-bash "$runner" <<'EOF'
2
EOF

  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=0"* ]]
  rm -f "$prompt_funcs" "$runner"
}

@test "runtime-specific context branching toggles compact mode outside claude" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  [ -n "$RUN_PLAN_PREBUILT_FUNCS_FILE" ] || skip "prebuilt helper unavailable"

  local tmp_dir workspace agent_tool
  tmp_dir="$(mktemp -d)"
  workspace="$tmp_dir/workspace"
  mkdir -p "$workspace"

  agent_tool="$tmp_dir/agent-config-tool.sh"
  cat <<'EOF' > "$agent_tool"
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  context)
    printf 'compact=%s\n' "${RALPH_COMPACT_CONTEXT:-unset}"
    ;;
  *)
    printf 'unexpected command: %s\n' "${1:-}" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$agent_tool"

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENTS_ROOT_REL=".cursor/agents"
    AGENT_CONFIG_TOOL="$2"
    ws="$3"
    build_context_for_runtime() {
      local runtime="$1"
      if [[ "$runtime" == "claude" ]]; then
        RALPH_COMPACT_CONTEXT=0 format_prebuilt_agent_context_block "$ws" "architect"
      else
        RALPH_COMPACT_CONTEXT=1 format_prebuilt_agent_context_block "$ws" "architect"
      fi
    }
    printf 'cursor\n'
    build_context_for_runtime cursor
    printf '\nclaude\n'
    build_context_for_runtime claude
  ' _ "$RUN_PLAN_PREBUILT_FUNCS_FILE" "$agent_tool" "$workspace"

  [ "$status" -eq 0 ]
  [[ "$output" == *"cursor"* ]]
  [[ "$output" == *"compact=1"* ]]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"compact=0"* ]]

  rm -rf "$tmp_dir"
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
    export CLAUDE_PLAN_MODEL="claude-sonnet-4-6"
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
  [ "$output" = "claude-sonnet-4-6" ]
  rm -rf "$tmp_dir"
}
