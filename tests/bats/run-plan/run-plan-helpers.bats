#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUN_PLAN_ARGS_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-args.sh"
RUN_PLAN_RUNTIME_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-runtime.sh"
RUN_PLAN_AGENT_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-agent.sh"
RUN_PLAN_SESSION_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
RUN_PLAN_CLEANUP_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-cleanup.sh"
ERROR_HANDLING_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/error-handling.sh"

@test "ralph_run_plan_parse_args records required inputs" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE"
    printf "%s|%s|%s" "$RUNTIME" "$PLAN_OVERRIDE" "$WORKSPACE"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [ "$output" = "cursor|$plan|$workspace" ]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects missing plan" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace
  workspace="$(mktemp -d)"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --workspace "$WORKSPACE"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--plan <path> is required."* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args exports RALPH_AGENT_WORKSPACE distinct from WORKSPACE" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE"
    # Verify RALPH_AGENT_WORKSPACE is exported and equals cwd
    export -p | grep -q "declare -x RALPH_AGENT_WORKSPACE="
    # RALPH_AGENT_WORKSPACE should be set (default to pwd when no --agent-workspace)
    if [[ -z "$RALPH_AGENT_WORKSPACE" ]]; then
      echo "FAIL: RALPH_AGENT_WORKSPACE is empty"
      exit 1
    fi
    # With no --agent-workspace flag, RALPH_AGENT_WORKSPACE defaults to pwd
    # which is not necessarily the same as WORKSPACE
    echo "OK: RALPH_AGENT_WORKSPACE=$RALPH_AGENT_WORKSPACE WORKSPACE=$WORKSPACE"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
  [[ "$output" == *"RALPH_AGENT_WORKSPACE="* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args accepts custom --agent-workspace" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan custom_agent_workspace
  workspace="$(mktemp -d)"
  custom_agent_workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    unset RALPH_AGENT_TOOL_ACCESS 2>/dev/null || true
    unset RALPH_NATIVE_HOOKS 2>/dev/null || true
    source "$1"
    source "$2"
    WORKSPACE="$3"
    CUSTOM_AGENT="$5"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --agent-workspace "$CUSTOM_AGENT"
    # Verify RALPH_AGENT_WORKSPACE is exported with custom value
    export -p | grep -q "declare -x RALPH_AGENT_WORKSPACE=" || { echo "FAIL: RALPH_AGENT_WORKSPACE not exported"; exit 1; }
    # Verify custom agent workspace is used
    if [[ "$RALPH_AGENT_WORKSPACE" != "$CUSTOM_AGENT" ]]; then
      echo "FAIL: RALPH_AGENT_WORKSPACE is not the custom path: got $RALPH_AGENT_WORKSPACE expected $CUSTOM_AGENT"
      exit 1
    fi
    echo "OK: custom agent workspace set"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan" "$custom_agent_workspace"

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
  rm -rf "$workspace" "$custom_agent_workspace"
}

@test "ralph_run_plan_parse_args accepts --max-iterations" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --max-iterations 7
    printf "%s" "$RALPH_PLAN_TODO_MAX_ITERATIONS"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects invalid --max-iterations" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --max-iterations 0
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--max-iterations must be a positive integer."* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args accepts --codex-sandbox and exports it" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime codex --plan "$4" --workspace "$WORKSPACE" --codex-sandbox danger-full-access
    export -p | grep -F "declare -x CODEX_PLAN_SANDBOX=\"danger-full-access\""
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [[ "$output" == *'declare -x CODEX_PLAN_SANDBOX="danger-full-access"'* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args accepts --claude-bare and exports it" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE" --claude-bare
    export -p | grep -F "declare -x CLAUDE_PLAN_BARE=\"1\""
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [[ "$output" == *'declare -x CLAUDE_PLAN_BARE="1"'* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args accepts --no-claude-bare and exports CLAUDE_PLAN_BARE=0" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE" --no-claude-bare
    export -p | grep -F "declare -x CLAUDE_PLAN_BARE=\"0\""
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [[ "$output" == *'declare -x CLAUDE_PLAN_BARE="0"'* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args accepts --claude-minimal and exports CLAUDE_PLAN_MINIMAL=1" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE" --claude-minimal
    export -p | grep -F "declare -x CLAUDE_PLAN_MINIMAL=\"1\""
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [[ "$output" == *'declare -x CLAUDE_PLAN_MINIMAL="1"'* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args accepts --no-claude-minimal and exports CLAUDE_PLAN_MINIMAL=0" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE" --no-claude-minimal
    export -p | grep -F "declare -x CLAUDE_PLAN_MINIMAL=\"0\""
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [[ "$output" == *'declare -x CLAUDE_PLAN_MINIMAL="0"'* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args accepts --claude-allow-mcp and exports CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE" --claude-allow-mcp
    export -p | grep -F "declare -x CLAUDE_PLAN_MINIMAL_DISABLE_MCP=\"0\""
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [[ "$output" == *'declare -x CLAUDE_PLAN_MINIMAL_DISABLE_MCP="0"'* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args accepts --no-claude-allow-mcp and exports CLAUDE_PLAN_MINIMAL_DISABLE_MCP=1" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE" --no-claude-allow-mcp
    export -p | grep -F "declare -x CLAUDE_PLAN_MINIMAL_DISABLE_MCP=\"1\""
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [[ "$output" == *'declare -x CLAUDE_PLAN_MINIMAL_DISABLE_MCP="1"'* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects invalid CLAUDE_PLAN_MINIMAL value" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    CLAUDE_PLAN_MINIMAL="maybe"
    export CLAUDE_PLAN_MINIMAL
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--claude-minimal / CLAUDE_PLAN_MINIMAL must be one of 1, true, yes, on, 0, false, no, or off."* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects invalid CLAUDE_PLAN_MINIMAL_DISABLE_MCP value" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    CLAUDE_PLAN_MINIMAL_DISABLE_MCP="maybe"
    export CLAUDE_PLAN_MINIMAL_DISABLE_MCP
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAUDE_PLAN_MINIMAL_DISABLE_MCP / --claude-allow-mcp must be one of"* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args accepts --claude-permission-mode and exports it" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE" --claude-permission-mode bypassPermissions
    export -p | grep -F "declare -x CLAUDE_PLAN_PERMISSION_MODE=\"bypassPermissions\""
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [[ "$output" == *'declare -x CLAUDE_PLAN_PERMISSION_MODE="bypassPermissions"'* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects invalid --claude-permission-mode" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE" --claude-permission-mode invalid-mode
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--claude-permission-mode / CLAUDE_PLAN_PERMISSION_MODE must be one of default, acceptEdits, auto, bypassPermissions, dontAsk, or plan."* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args leaves RALPH_MODE unset without flag or env" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    unset RALPH_MODE RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE"
    printf "%s" "${RALPH_MODE:-unset}"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [ "$output" = "unset" ]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects removed --tool-access flag" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime claude --plan "$4" --workspace "$WORKSPACE" --tool-access ralph
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--tool-access is removed"* ]] && [[ "$output" == *"--ralph-mode"* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects repeated --tool-access flags" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime codex --plan "$4" --workspace "$WORKSPACE" --tool-access ralph --tool-access native
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--tool-access is removed"* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects removed RALPH_AGENT_TOOL_ACCESS env var" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    export RALPH_AGENT_TOOL_ACCESS=maybe
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"RALPH_AGENT_TOOL_ACCESS is no longer supported"* ]] && [[ "$output" == *"RALPH_MODE"* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects removed --mcp-proxy-policy flags" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan policy_file
  workspace="$(mktemp -d)"
  plan="plan.md"
  policy_file="$workspace/policy.json"
  printf '%s\n' '{"name":"inline-policy"}' >"$policy_file"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime opencode --plan "$4" --workspace "$WORKSPACE" \
      --mcp-proxy --mcp-proxy-policy stage-policy \
      --mcp-proxy-policy-file "$5" --mcp-proxy-policy-inline "{\"name\":\"inline-policy\"}"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan" "$policy_file"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--mcp-proxy is no longer supported"* ]]
  [[ "$output" == *"--ralph-mode"* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects invalid --codex-sandbox" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime codex --plan "$4" --workspace "$WORKSPACE" --codex-sandbox invalid-mode
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--codex-sandbox / CODEX_PLAN_SANDBOX must be one of read-only, workspace-write, or danger-full-access."* ]]
  rm -rf "$workspace"
}

@test "ralph_shared_ralph_dir_complete succeeds when layout is present" {
  [ -f "$RUN_PLAN_RUNTIME_FILE" ] || skip "run-plan runtime helper missing"

  local shared
  shared="$(mktemp -d)"
  mkdir -p "$shared/bash-lib/run-plan"
  touch "$shared/ralph-env-safety.sh"
  for helper in run-plan-env.sh run-plan-invoke-cursor.sh run-plan-invoke-claude.sh run-plan-invoke-codex.sh run-plan-invoke-opencode.sh run-plan-invoke-antigravity.sh; do
    touch "$shared/bash-lib/run-plan/$helper"
  done

  run bash -c '
    set -euo pipefail
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    source "$1"
    ralph_shared_ralph_dir_complete "$2"
  ' _ "$RUN_PLAN_RUNTIME_FILE" "$shared"

  [ "$status" -eq 0 ]
  rm -rf "$shared"
}

@test "ralph_shared_ralph_dir_complete fails when a helper is missing" {
  [ -f "$RUN_PLAN_RUNTIME_FILE" ] || skip "run-plan runtime helper missing"

  local shared
  shared="$(mktemp -d)"
  mkdir -p "$shared/bash-lib/run-plan"
  touch "$shared/ralph-env-safety.sh"
  touch "$shared/bash-lib/run-plan/run-plan-env.sh"
  touch "$shared/bash-lib/run-plan/run-plan-invoke-cursor.sh"
  touch "$shared/bash-lib/run-plan/run-plan-invoke-claude.sh"

  run bash -c '
    set -euo pipefail
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    source "$1"
    ralph_shared_ralph_dir_complete "$2"
  ' _ "$RUN_PLAN_RUNTIME_FILE" "$shared"

  [ "$status" -eq 1 ]
  rm -rf "$shared"
}

@test "list_prebuilt_agent_ids calls the agent-config-tool" {
  [ -f "$RUN_PLAN_AGENT_FILE" ] || skip "run-plan agent helper missing"

  local workspace stub
  workspace="$(mktemp -d)"
  stub="$(mktemp)"
  cat <<'SCRIPT' >"$stub"
#!/usr/bin/env bash
if [[ "$1" == "list" ]]; then
  printf 'alpha-agent\nbeta-agent\n'
  exit 0
fi
exit 1
SCRIPT
  chmod +x "$stub"

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENT_CONFIG_TOOL="$2"
    AGENTS_ROOT_REL="$3"
    WORKSPACE="$4"
    list_prebuilt_agent_ids "$WORKSPACE"
  ' _ "$RUN_PLAN_AGENT_FILE" "$stub" "agents" "$workspace"

  [ "$status" -eq 0 ]
  [ "$output" = $'alpha-agent\nbeta-agent' ]
  rm -rf "$workspace"
  rm -f "$stub"
}

@test "list_prebuilt_agent_ids errors when the agent-config-tool is missing" {
  [ -f "$RUN_PLAN_AGENT_FILE" ] || skip "run-plan agent helper missing"

  local workspace
  workspace="$(mktemp -d)"

  run bash -c '
    set -euo pipefail
    source "$1"
    AGENT_CONFIG_TOOL="/tmp/missing-agent-config-tool"
    AGENTS_ROOT_REL="agents"
    WORKSPACE="$2"
    list_prebuilt_agent_ids "$WORKSPACE"
  ' _ "$RUN_PLAN_AGENT_FILE" "$workspace"

  [ "$status" -eq 1 ]
  [[ "$output" == *"shared agent tool missing"* ]]
  rm -rf "$workspace"
}

@test "ralph_session_init establishes a session directory" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"

  local workspace session_home
  workspace="$(mktemp -d)"
  session_home="$workspace/sessions"

  run bash -c '
    set -euo pipefail
    log(){ :; }
    ralph_run_plan_log(){ :; }
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    _RALPH_PROMPT_CLI_RESUME_INTERACTIVE=0
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    RUNTIME="cursor"
    source "$1"
    RALPH_PLAN_KEY="test-session"
    export RALPH_PLAN_KEY
    RALPH_PLAN_SESSION_HOME="$2"
    export RALPH_PLAN_SESSION_HOME
    ralph_session_init "$3" "plan.log"
    printf "%s|%s" "$RALPH_SESSION_DIR" "$SESSION_ID_FILE"
  ' _ "$RUN_PLAN_SESSION_FILE" "$session_home" "$workspace"

  [ "$status" -eq 0 ]
  session_dir="${output%%|*}"
  [ -d "$session_dir" ]
  [[ "$output" == *"/session-id.cursor.txt" ]]
  rm -rf "$workspace"
}

@test "ralph_session_init scopes session ids by runtime" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"

  local workspace session_home
  workspace="$(mktemp -d)"
  session_home="$workspace/sessions"

  run bash -c '
    set -euo pipefail
    log(){ :; }
    ralph_run_plan_log(){ :; }
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    _RALPH_PROMPT_CLI_RESUME_INTERACTIVE=0
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    RALPH_PLAN_KEY="test-session"
    export RALPH_PLAN_KEY
    RALPH_PLAN_SESSION_HOME="$2"
    export RALPH_PLAN_SESSION_HOME
    RUNTIME="opencode"
    export RUNTIME
    ralph_session_init "$3" "plan.log"
    printf "%s" "$SESSION_ID_FILE"
  ' _ "$RUN_PLAN_SESSION_FILE" "$session_home" "$workspace"

  [ "$status" -eq 0 ]
  [ "$output" = "$session_home/test-session/session-id.opencode.txt" ]
  rm -rf "$workspace"
}

@test "ralph_session_init ignores legacy shared session ids" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"

  local workspace session_home legacy_file
  workspace="$(mktemp -d)"
  session_home="$workspace/sessions"

  run bash -c '
    set -euo pipefail
    log(){ :; }
    ralph_run_plan_log(){ :; }
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    _RALPH_PROMPT_CLI_RESUME_INTERACTIVE=0
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    RALPH_PLAN_KEY="test-session"
    export RALPH_PLAN_KEY
    RALPH_PLAN_SESSION_HOME="$2"
    export RALPH_PLAN_SESSION_HOME
    RUNTIME="opencode"
    export RUNTIME
    mkdir -p "$3/.ralph-workspace/sessions/test-session"
    printf '%s\n' "shared-legacy-id" > "$3/.ralph-workspace/sessions/test-session/session-id.txt"
    ralph_session_init "$3" "plan.log"
    [[ ! -s "$SESSION_ID_FILE" ]]
  ' _ "$RUN_PLAN_SESSION_FILE" "$session_home" "$workspace"

  [ "$status" -eq 0 ]
  legacy_file="$workspace/.ralph-workspace/sessions/test-session/session-id.txt"
  [ -f "$legacy_file" ]
  [ ! -s "$session_home/test-session/session-id.opencode.txt" ]
  rm -rf "$workspace"
}

@test "ralph_session_apply_resume_strategy uses bare resume when allowed without a stored id" {
  [ -f "$RUN_PLAN_SESSION_FILE" ] || skip "run-plan session helper missing"

  local session_dir
  session_dir="$(mktemp -d)"

  run bash -c '
    set -euo pipefail
    log(){ :; }
    ralph_run_plan_log(){ :; }
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    _RALPH_PROMPT_CLI_RESUME_INTERACTIVE=0
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    RUNTIME="cursor"
    source "$1"
    log() { :; }
    RALPH_PLAN_CLI_RESUME=1
    RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
    export RALPH_PLAN_CLI_RESUME RALPH_PLAN_ALLOW_UNSAFE_RESUME
    SESSION_ID_FILE="$2/session-id.txt"
    mkdir -p "$(dirname "$SESSION_ID_FILE")"
    export SESSION_ID_FILE
    ralph_session_apply_resume_strategy
    printf "%s|%s" "${RALPH_RUN_PLAN_RESUME_BARE:-}" "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}"
  ' _ "$RUN_PLAN_SESSION_FILE" "$session_dir"

  [ "$status" -eq 0 ]
  final_line="$(printf '%s\n' "$output" | awk 'NF { last=$0 } END { printf "%s", last }')"
  [ "$final_line" = "1|" ]
  rm -rf "$session_dir"
}

@test "prompt_cleanup_on_exit describes cleanup after a complete run" {
  [ -f "$RUN_PLAN_CLEANUP_FILE" ] || skip "run-plan cleanup helper missing"

  run bash -c '
    set -euo pipefail
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    NON_INTERACTIVE_FLAG=0
    source "$1"
    ALLOW_CLEANUP_PROMPT=1
    EXIT_STATUS=complete
    RALPH_LOG_DIR="/tmp/logs"
    OUTPUT_LOG="/tmp/output.log"
    LOG_FILE="/tmp/plan.log"
    WORKSPACE="/tmp/workspace"
    RALPH_ARTIFACT_NS="demo"
    prompt_cleanup_on_exit
  ' _ "$RUN_PLAN_CLEANUP_FILE"

  [ "$status" -eq 0 ]
  [[ "$output" == *"All TODOs are complete."* ]]
  [[ "$output" == *"cleanup-plan.sh demo /tmp/workspace"* ]]
}

@test "prompt_cleanup_on_exit prints the cleanup command when non-interactive" {
  [ -f "$RUN_PLAN_CLEANUP_FILE" ] || skip "run-plan cleanup helper missing"

  run bash -c '
    set -euo pipefail
    C_R="" C_G="" C_Y="" C_B="" C_C="" C_BOLD="" C_DIM="" C_RST=""
    CLEANUP_SCRIPT=""
    NON_INTERACTIVE_FLAG=1
    source "$1"
    ALLOW_CLEANUP_PROMPT=1
    EXIT_STATUS=running
    WORKSPACE="/tmp/workspace"
    RALPH_ARTIFACT_NS="ns"
    prompt_cleanup_on_exit
  ' _ "$RUN_PLAN_CLEANUP_FILE"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ralph_run_plan_parse_args accepts --timeout with valid duration 30m" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --timeout 30m
    printf "%s" "$RALPH_PLAN_INVOCATION_TIMEOUT_RAW"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [ "$output" = "30m" ]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args accepts --timeout with valid duration 1800s" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --timeout 1800s
    printf "%s" "$RALPH_PLAN_INVOCATION_TIMEOUT_RAW"
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 0 ]
  [ "$output" = "1800s" ]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects --timeout with missing value" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --timeout
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--timeout requires a duration string"* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects --timeout with invalid format (non-numeric)" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --timeout abc
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--timeout must be a positive integer with a unit"* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects --timeout with invalid format (zero duration)" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --timeout 0m
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--timeout duration must be positive"* ]]
  rm -rf "$workspace"
}

@test "ralph_run_plan_parse_args rejects --timeout with unsupported unit" {
  [ -f "$RUN_PLAN_ARGS_FILE" ] || skip "run-plan args helper missing"

  local workspace plan
  workspace="$(mktemp -d)"
  plan="plan.md"

  run bash -c '
    set -euo pipefail
    PREBUILT_AGENT=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    source "$1"
    source "$2"
    WORKSPACE="$3"
    ralph_run_plan_parse_args --runtime cursor --plan "$4" --workspace "$WORKSPACE" --timeout 30x
  ' _ "$RUN_PLAN_ARGS_FILE" "$ERROR_HANDLING_FILE" "$workspace" "$plan"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--timeout must be a positive integer with a unit"* ]]
  rm -rf "$workspace"
}
