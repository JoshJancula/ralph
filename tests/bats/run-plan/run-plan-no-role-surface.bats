#!/usr/bin/env bats
# Removed run-plan --role / *_PLAN_ROLE surfaces and updated agent-removal guidance.
# Asserts exit 2 refusals before filesystem mutation; preserves roles-redesign --agent refusals.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
bats_require_minimum_version 1.5.0

RUN_PLAN_ARGS_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-args.sh"
RUN_PLAN_AGENT_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-agent.sh"
ERROR_HANDLING_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/error-handling.sh"

_parse_prelude() {
  cat <<'EOF'
set -euo pipefail
NON_INTERACTIVE_FLAG=1
CLI_RESUME_FLAG=0
NO_CLI_RESUME_FLAG=0
ALLOW_UNSAFE_RESUME_FLAG=0
RESUME_SESSION_ID_OVERRIDE=""
SESSION_STRATEGY_FLAG=""
RUNTIME=""
PLAN_OVERRIDE=""
PLAN_MODEL_CLI=""
PLAN_REASONING_EFFORT_CLI=""
RALPH_PLAN_TODO_MAX_ITERATIONS=""
_RALPH_CLI_RESUME_ENV_WAS_SET=0
SKIP_MCP_PREFLIGHT_FLAG=1
unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_OPTIMIZATION_MODE 2>/dev/null || true
unset RALPH_AGENT_SOURCE RALPH_AGENT_SOURCE_ORDER RALPH_AGENT_NATIVE_PASSTHROUGH 2>/dev/null || true
unset CURSOR_PLAN_AGENT CLAUDE_PLAN_AGENT CODEX_PLAN_AGENT OPENCODE_PLAN_AGENT ANTIGRAVITY_PLAN_AGENT 2>/dev/null || true
# Do not unset *_PLAN_ROLE here: some cases inject them via env for the child process.
EOF
}

setup() {
  bats_skip_known_ci_flakes
  export RALPH_PLAN_NO_CAFFEINATE=1
  unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_OPTIMIZATION_MODE
  unset RALPH_AGENT_SOURCE RALPH_AGENT_SOURCE_ORDER RALPH_AGENT_NATIVE_PASSTHROUGH
  unset CURSOR_PLAN_AGENT CLAUDE_PLAN_AGENT CODEX_PLAN_AGENT OPENCODE_PLAN_AGENT ANTIGRAVITY_PLAN_AGENT
  unset CURSOR_PLAN_ROLE CLAUDE_PLAN_ROLE CODEX_PLAN_ROLE OPENCODE_PLAN_ROLE ANTIGRAVITY_PLAN_ROLE
}

@test "arguments: --role exits 2 with workflow instructions guidance" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"
  printf '%s\n' "- [ ] pending" >"$workspace/$plan"

  run bash -c '
    '"$(_parse_prelude)"'
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --role research
  ' _ "$ERROR_HANDLING_FILE" "$RUN_PLAN_ARGS_FILE" "$workspace" "$plan"

  [ "$status" -eq 2 ]
  [[ "$output" == *"--role"* ]]
  [[ "$output" == *"was removed"* ]]
  [[ "$output" == *"instructions:"* ]]
  [[ "$output" == *"workflow stage"* ]]
  ralph_test_rm_workspace "$workspace"
}

@test "arguments: --role without value still exits 2" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"
  printf '%s\n' "- [ ] pending" >"$workspace/$plan"

  run bash -c '
    '"$(_parse_prelude)"'
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --role
  ' _ "$ERROR_HANDLING_FILE" "$RUN_PLAN_ARGS_FILE" "$workspace" "$plan"

  [ "$status" -eq 2 ]
  [[ "$output" == *"--role"* ]]
  [[ "$output" == *"instructions:"* ]]
  ralph_test_rm_workspace "$workspace"
}

@test "environment: each non-empty *_PLAN_ROLE exits 2 with instructions guidance" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan runtime env_name
  workspace="$(mktemp -d)"
  plan="plan.md"
  printf '%s\n' "- [ ] pending" >"$workspace/$plan"

  for runtime in cursor claude codex opencode antigravity; do
    case "$runtime" in
      cursor) env_name=CURSOR_PLAN_ROLE ;;
      claude) env_name=CLAUDE_PLAN_ROLE ;;
      codex) env_name=CODEX_PLAN_ROLE ;;
      opencode) env_name=OPENCODE_PLAN_ROLE ;;
      antigravity) env_name=ANTIGRAVITY_PLAN_ROLE ;;
    esac

    run env "$env_name=research" bash -c '
      '"$(_parse_prelude)"'
      source "$1"
      source "$2"
      WORKSPACE="$3"
      ralph_run_plan_parse_args --runtime '"$runtime"' --plan "$4" --workspace "$WORKSPACE"
    ' _ "$ERROR_HANDLING_FILE" "$RUN_PLAN_ARGS_FILE" "$workspace" "$plan"

    [ "$status" -eq 2 ]
    [[ "$output" == *"$env_name"* ]]
    [[ "$output" == *"instructions:"* ]]
    [[ "$output" == *"workflow stage"* ]]
  done

  ralph_test_rm_workspace "$workspace"
}

@test "environment: empty *_PLAN_ROLE is ignored" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"
  printf '%s\n' "- [ ] pending" >"$workspace/$plan"

  run bash -c '
    '"$(_parse_prelude)"'
    export CURSOR_PLAN_ROLE=""
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE"
    printf "ok\n"
  ' _ "$ERROR_HANDLING_FILE" "$RUN_PLAN_ARGS_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  ralph_test_rm_workspace "$workspace"
}

@test "help: omits --role and *_PLAN_ROLE; keeps agent-workspace" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    print_usage
  ' _ "$ERROR_HANDLING_FILE" "$RUN_PLAN_ARGS_FILE"

  [ "$status" -eq 0 ]
  [[ "$output" != *"--role"* ]]
  [[ "$output" != *"CURSOR_PLAN_ROLE"* ]]
  [[ "$output" != *"CLAUDE_PLAN_ROLE"* ]]
  [[ "$output" != *"CODEX_PLAN_ROLE"* ]]
  [[ "$output" != *"OPENCODE_PLAN_ROLE"* ]]
  [[ "$output" != *"ANTIGRAVITY_PLAN_ROLE"* ]]
  [[ "$output" == *"--agent-workspace"* ]]
  [[ "$output" == *"RALPH_AGENT_WORKSPACE"* ]]
  [[ "$output" != *"--agent <name>"* ]]
  [[ "$output" != *"--select-agent"* ]]
  [[ "$output" != *"--agent-source"* ]]
}

@test "agent guidance: --agent still refused with instructions guidance (no role migrate)" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"
  printf '%s\n' "- [ ] pending" >"$workspace/$plan"

  run bash -c '
    '"$(_parse_prelude)"'
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --agent research
  ' _ "$ERROR_HANDLING_FILE" "$RUN_PLAN_ARGS_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--agent"* ]]
  [[ "$output" == *"was removed"* ]]
  [[ "$output" == *"instructions:"* ]]
  [[ "$output" != *"--role"* ]]
  [[ "$output" != *"ralph migrate"* ]]
  ralph_test_rm_workspace "$workspace"
}

@test "agent guidance: removed agent env and helper messages avoid role migrate text" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"
  [ -f "$RUN_PLAN_AGENT_FILE" ] || skip "run-plan agent helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"
  printf '%s\n' "- [ ] pending" >"$workspace/$plan"

  run bash -c '
    '"$(_parse_prelude)"'
    export CURSOR_PLAN_AGENT=research
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE"
  ' _ "$ERROR_HANDLING_FILE" "$RUN_PLAN_ARGS_FILE" "$workspace" "$plan"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CURSOR_PLAN_AGENT"* ]]
  [[ "$output" == *"instructions:"* ]]
  [[ "$output" != *"--role"* ]]
  [[ "$output" != *"ralph migrate"* ]]
  [[ "$output" != *"CURSOR_PLAN_ROLE"* ]]

  run bash -c '
    set -euo pipefail
    source "$1"
    validate_prebuilt_agent_config
  ' _ "$RUN_PLAN_AGENT_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"instructions:"* ]]
  [[ "$output" != *"--role"* ]]
  [[ "$output" != *"ralph migrate"* ]]

  run bash -c '
    set -euo pipefail
    source "$1"
    prompt_select_prebuilt_agent
  ' _ "$RUN_PLAN_AGENT_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"instructions:"* ]]
  [[ "$output" != *"--role"* ]]
  [[ "$output" != *"ralph migrate"* ]]

  ralph_test_rm_workspace "$workspace"
}

@test "before mutation: --role fails before resolving a missing workspace path" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local parent missing_ws plan_path
  parent="$(mktemp -d)"
  missing_ws="$parent/does-not-exist"
  plan_path="plan.md"

  run bash -c '
    '"$(_parse_prelude)"'
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --role research
  ' _ "$ERROR_HANDLING_FILE" "$RUN_PLAN_ARGS_FILE" "$missing_ws" "$plan_path"

  [ "$status" -eq 2 ]
  [[ "$output" == *"--role"* ]]
  [[ "$output" == *"instructions:"* ]]
  [[ "$output" != *"No such file"* ]]
  [[ "$output" != *"does-not-exist"* ]]
  [ ! -e "$missing_ws" ]
  rm -rf "$parent"
}

@test "before mutation: non-empty *_PLAN_ROLE fails before resolving a missing workspace path" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local parent missing_ws plan_path
  parent="$(mktemp -d)"
  missing_ws="$parent/does-not-exist"
  plan_path="plan.md"

  run env CURSOR_PLAN_ROLE=qa bash -c '
    '"$(_parse_prelude)"'
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE"
  ' _ "$ERROR_HANDLING_FILE" "$RUN_PLAN_ARGS_FILE" "$missing_ws" "$plan_path"

  [ "$status" -eq 2 ]
  [[ "$output" == *"CURSOR_PLAN_ROLE"* ]]
  [[ "$output" == *"instructions:"* ]]
  [[ "$output" != *"No such file"* ]]
  [ ! -e "$missing_ws" ]
  rm -rf "$parent"
}

@test "agent workspace: --agent-workspace and poll/marks env remain accepted" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan custom_agent_workspace
  workspace="$(mktemp -d)"
  custom_agent_workspace="$(mktemp -d)"
  plan="plan.md"
  printf '%s\n' "- [ ] pending" >"$workspace/$plan"

  run bash -c '
    '"$(_parse_prelude)"'
    export RALPH_PLAN_AGENT_POLL_INTERVAL=0.2
    export RALPH_PLAN_AGENT_MARKS_TODOS=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    CUSTOM_AGENT="$5"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --agent-workspace "$CUSTOM_AGENT"
    if [[ "$RALPH_AGENT_WORKSPACE" != "$CUSTOM_AGENT" ]]; then
      echo "FAIL: RALPH_AGENT_WORKSPACE=$RALPH_AGENT_WORKSPACE"
      exit 1
    fi
    printf "ok\n"
  ' _ "$ERROR_HANDLING_FILE" "$RUN_PLAN_ARGS_FILE" "$workspace" "$plan" "$custom_agent_workspace"

  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  rm -rf "$workspace" "$custom_agent_workspace"
}

@test "prompt order: workflow stage instructions precede TODO content" {
  # Contract: stage guidance stays ahead of the TODO body after role removal.
  # Cheapest level: sourced prompt helpers (no run-plan entry).
  local plan_todo_lib core_lib
  plan_todo_lib="$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  [ -f "$plan_todo_lib" ] || skip "plan-todo missing"
  [ -f "$core_lib" ] || skip "run-plan-core missing"

  run bash -c '
    set -euo pipefail
    source "$1"
    eval "$(sed -n "/^ralph_run_plan_join_prompt_parts()/,/^}$/p;/^ralph_run_plan_assemble_prompt_ordered()/,/^}$/p;/^ralph_run_plan_assemble_prompt_static()/,/^}$/p;/^ralph_run_plan_apply_ordered_prompt_assembly()/,/^}$/p" "$2")"
    wsi="$(ralph_workflow_stage_instructions_prompt_block "Prefer evidence over claims.")"
    [[ -n "$wsi" ]]
    task="$(printf "%s\n\n%s\n\n%s" "$wsi" "Complete exactly this TODO and nothing else:" "Do the work.")"
    PROMPT="$task"
    ralph_run_plan_apply_ordered_prompt_assembly cursor "PREAMBLE" "CONTRACTS"
    i_wsi="${PROMPT%%<!-- WORKFLOW_STAGE_INSTRUCTIONS: START -->*}"
    i_todo="${PROMPT%%Complete exactly this TODO*}"
    [[ "${#i_wsi}" -lt "${#i_todo}" ]]
    i_preamble="${PROMPT%%PREAMBLE*}"
    i_contracts="${PROMPT%%CONTRACTS*}"
    [[ "${#i_preamble}" -lt "${#i_contracts}" ]]
    [[ "${#i_contracts}" -lt "${#i_todo}" ]]
    printf "ok\n"
  ' _ "$plan_todo_lib" "$core_lib"

  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
