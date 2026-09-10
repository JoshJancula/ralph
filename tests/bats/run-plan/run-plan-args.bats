#!/usr/bin/env bats
# Test suite for run-plan.sh CLI argument parsing and runtime setup.
#
# This suite covers:
# - Basic CLI parsing for flags like --runtime, --plan, --model, etc.
# - Agent tool access mode defaults and overrides.
# - Native hooks and shell compaction (three-knob model).
# - Validation and error handling for invalid arguments.
# - Preference persistence and loading.
# - Native hooks and shell compaction interaction.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
bats_require_minimum_version 1.5.0

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"

setup() {
  bats_skip_known_ci_flakes
  # Prevent caffeinate re-exec on macOS so parallel runs do not race on the cache file.
  export RALPH_PLAN_NO_CAFFEINATE=1
  # Unset removed env vars so they do not pollute test cases that expect clean state.
  unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_OPTIMIZATION_MODE RALPH_MCP_TOOLS_ENABLED RALPH_TOOL_ACCESS_FLAG_SET RALPH_PLAN_TRANSCRIPT_EVICTION
}

@test "run-plan --help shows usage" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash "$RUN_PLAN_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"run-plan"* ]] || [[ "$output" == *"Usage"* ]]
}

@test "run-plan with no args shows usage and exits non-zero" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash "$RUN_PLAN_SH" 2>&1
  [ "$status" -ne 0 ]
}

@test "run-plan --plan requires an argument" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash "$RUN_PLAN_SH" --plan 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"--plan"* ]]
}

@test "run-plan --plan must reference a file" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run -1 bash "$RUN_PLAN_SH" --plan /nonexistent/file/path.md --runtime cursor 2>&1
  [[ "$output" == *"Plan file not found:"* ]]
}

@test "run-plan accepts agy as shorthand for antigravity" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -eo pipefail
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    WORKSPACE="$(pwd)"
    PROJECT_ROOT_OVERRIDE=""
    WORKSPACE_ROOT_OVERRIDE=""
    AGENT_WORKSPACE_OVERRIDE=""
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    INTERACTIVE_SELECT_MODEL_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RALPH_PLAN_RUNTIME=""
    PLAN_OVERRIDE=""
    RUNTIME=""
    ralph_run_plan_parse_args --runtime agy --plan "$2"
    printf "%s\n" "$RUNTIME"
  ' _ "$(dirname "$RUN_PLAN_SH")" "$plan_file"

  [ "$status" -eq 0 ]
  [ "$output" = "antigravity" ]
}

@test "run-plan --model overrides default model and CLAUDE_DEFAULT_MODEL" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    export WORKSPACE="$(pwd)"
    CLAUDE_DEFAULT_MODEL="model-old"
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime claude --plan "$plan" --model claude-3.5-sonnet
    printf "%s" "${PLAN_MODEL_CLI:-}"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"3.5-sonnet"* ]]

  rm -f "$plan_file"
}

@test "run-plan --ralph-mode sets RALPH_MODE" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  for mode in no native ralph hybrid; do
    run bash -c '
      set -euo pipefail
      WORKSPACE="$(pwd)"
      export WORKSPACE
      PREBUILT_AGENT=""
      PLAN_MODEL_CLI=""
      INTERACTIVE_SELECT_AGENT_FLAG=0
      NON_INTERACTIVE_FLAG=1
      SKIP_MCP_PREFLIGHT_FLAG=1
      CLI_RESUME_FLAG=0
      NO_CLI_RESUME_FLAG=0
      ALLOW_UNSAFE_RESUME_FLAG=0
      RESUME_SESSION_ID_OVERRIDE=""
      SESSION_STRATEGY_FLAG=""
      RUNTIME=""
      RALPH_PLAN_TODO_MAX_ITERATIONS=""
      CLAUDE_TOOLS_FROM_AGENT=""
      _RALPH_CLI_RESUME_ENV_WAS_SET=0
      plan="$1"
      ralph_root="$2"
      mode="$3"
      source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
      source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
      ralph_run_plan_parse_args --runtime cursor --plan "$plan" --ralph-mode "$mode"
      printf "%s" "${RALPH_MODE:-}"
    ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")" "$mode"

    [ "$status" -eq 0 ]
    [ "$output" = "$mode" ]
  done

  rm -f "$plan_file"
}

@test "RALPH_MODE env var is honored" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    WORKSPACE="$(pwd)"
    export WORKSPACE
    export RALPH_MODE=ralph
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan"
    printf "%s" "${RALPH_MODE:-}"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "ralph" ]

  rm -f "$plan_file"
}

@test "parse_args leaves RALPH_MODE unresolved without flag or env" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    WORKSPACE="$(pwd)"
    export WORKSPACE
    unset RALPH_MODE
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan"
    printf "%s" "${RALPH_MODE:-unset}"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "unset" ]

  rm -f "$plan_file"
}

@test "parse_args leaves saved ralph_mode_default preference reachable" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local tmpdir plan_file
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/.ralph-workspace"
  printf '%s\n' '{"ralph_mode_default": "hybrid"}' >"$tmpdir/.ralph-workspace/preferences.json"
  plan_file="$tmpdir/PLAN.md"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    WORKSPACE="$3"
    export WORKSPACE
    unset RALPH_MODE
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan"
    if [[ -z "${RALPH_MODE:-}" ]]; then
      ralph_load_workspace_preferences "$WORKSPACE" "$WORKSPACE/.ralph-workspace"
    fi
    printf "%s" "${RALPH_MODE:-unset}"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")" "$tmpdir"

  [ "$status" -eq 0 ]
  [ "$output" = "hybrid" ]

  rm -rf "$tmpdir"
}

@test "parse_args leaves interactive ralph mode prompt reachable" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local tmpdir plan_file
  tmpdir="$(mktemp -d)"
  plan_file="$tmpdir/PLAN.md"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    WORKSPACE="$3"
    export WORKSPACE
    unset RALPH_MODE
    export RALPH_MODE_PROMPT_ASSUME_TTY=1
    C_Y="" C_DIM="" C_RST=""
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=0
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_menu_select() { printf "%s" "hybrid"; }
    ralph_run_plan_parse_args --runtime cursor --plan "$plan"
    if [[ -z "${RALPH_MODE:-}" ]]; then
      prompt_ralph_mode
    fi
    printf "%s" "${RALPH_MODE:-unset}"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")" "$tmpdir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"hybrid"* ]]

  rm -rf "$tmpdir"
}

@test "run-plan --ralph-mode flag overrides RALPH_MODE env" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    WORKSPACE="$(pwd)"
    export WORKSPACE
    export RALPH_MODE=native
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan" --ralph-mode hybrid
    printf "%s" "${RALPH_MODE:-}"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "hybrid" ]

  rm -f "$plan_file"
}

@test "run-plan --ralph-mode accepts each explicit mode" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  local mode
  for mode in no native ralph hybrid; do
    run bash -c '
      set -euo pipefail
      WORKSPACE="$(pwd)"
      export WORKSPACE
      PREBUILT_AGENT=""
      PLAN_MODEL_CLI=""
      INTERACTIVE_SELECT_AGENT_FLAG=0
      NON_INTERACTIVE_FLAG=1
      SKIP_MCP_PREFLIGHT_FLAG=1
      CLI_RESUME_FLAG=0
      NO_CLI_RESUME_FLAG=0
      ALLOW_UNSAFE_RESUME_FLAG=0
      RESUME_SESSION_ID_OVERRIDE=""
      SESSION_STRATEGY_FLAG=""
      RUNTIME=""
      RALPH_PLAN_TODO_MAX_ITERATIONS=""
      CLAUDE_TOOLS_FROM_AGENT=""
      _RALPH_CLI_RESUME_ENV_WAS_SET=0
      plan="$1"
      ralph_root="$2"
      mode="$3"
      source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
      source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
      ralph_run_plan_parse_args --runtime cursor --plan "$plan" --ralph-mode "$mode"
      printf "%s" "${RALPH_MODE:-}"
    ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")" "$mode"

    [ "$status" -eq 0 ]
    [ "$output" = "$mode" ]
  done

  rm -f "$plan_file"
}

@test "run-plan --native-hooks fails with clear error pointing to --ralph-mode" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash "$RUN_PLAN_SH" --runtime cursor --plan "$plan_file" --native-hooks auto 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--native-hooks"* ]] && [[ "$output" == *"--ralph-mode"* ]]

  rm -f "$plan_file"
}

@test "RALPH_AGENT_TOOL_ACCESS env var fails with clear error pointing to RALPH_MODE" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    WORKSPACE="$(pwd)"
    export WORKSPACE
    export RALPH_AGENT_TOOL_ACCESS=ralph
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/error-handling.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -ne 0 ]
  [[ "$output" == *"RALPH_AGENT_TOOL_ACCESS"* ]] && [[ "$output" == *"RALPH_MODE"* ]]

  rm -f "$plan_file"
}

@test "RALPH_NATIVE_HOOKS env var fails with clear error pointing to RALPH_MODE" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    WORKSPACE="$(pwd)"
    export WORKSPACE
    export RALPH_NATIVE_HOOKS=auto
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/error-handling.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -ne 0 ]
  [[ "$output" == *"RALPH_NATIVE_HOOKS"* ]] && [[ "$output" == *"RALPH_MODE"* ]]

  rm -f "$plan_file"
}

@test "run-plan rejects removed --optimization-mode flag" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash "$RUN_PLAN_SH" --runtime cursor --plan "$plan_file" --optimization-mode bounded 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument"* ]] || [[ "$output" == *"unknown"* ]]

  rm -f "$plan_file"
}

@test "RALPH_OPTIMIZATION_MODE env var fails with clear error pointing to RALPH_MODE" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    WORKSPACE="$(pwd)"
    export WORKSPACE
    export RALPH_OPTIMIZATION_MODE=governed
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/error-handling.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -ne 0 ]
  [[ "$output" == *"RALPH_OPTIMIZATION_MODE"* ]] && [[ "$output" == *"RALPH_MODE"* ]]

  rm -f "$plan_file"
}

@test "RALPH_PLAN_TRANSCRIPT_EVICTION env var fails with clear error on invalid value" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    WORKSPACE="$(pwd)"
    export WORKSPACE
    export RALPH_PLAN_TRANSCRIPT_EVICTION=maybe
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/error-handling.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -ne 0 ]
  [[ "$output" == *"RALPH_PLAN_TRANSCRIPT_EVICTION"* ]] && [[ "$output" == *"off, safe, or aggressive"* ]]

  rm -f "$plan_file"
}

@test "workspace preferences load ralph_mode_default" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local tmpdir prefs_file
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/.ralph-workspace"
  prefs_file="$tmpdir/.ralph-workspace/preferences.json"

  printf '%s\n' '{"ralph_mode_default": "native"}' >"$prefs_file"

  run bash -c '
    unset RALPH_MODE
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    ralph_load_workspace_preferences "$2" "$3"
    printf "%s" "${RALPH_MODE:-}"
  ' _ "$(dirname "$RUN_PLAN_SH")" "$tmpdir" "$tmpdir/.ralph-workspace"

  [ "$status" -eq 0 ]
  [ "$output" = "native" ]

  rm -rf "$tmpdir"
}

@test "ralph_load_workspace_preferences does not override explicit RALPH_MODE" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local tmpdir prefs_file
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/.ralph-workspace"
  prefs_file="$tmpdir/.ralph-workspace/preferences.json"

  printf '{"ralph_mode_default": "native"}' > "$prefs_file"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    RALPH_MODE=ralph
    ralph_load_workspace_preferences "$2" "$3"
    printf "%s" "${RALPH_MODE:-}"
  ' _ "$(dirname "$RUN_PLAN_SH")" "$tmpdir" "$tmpdir/.ralph-workspace"

  [ "$status" -eq 0 ]
  [ "$output" = "ralph" ]

  rm -rf "$tmpdir"
}

@test "prompt_ralph_mode respects NON_INTERACTIVE_FLAG" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    NON_INTERACTIVE_FLAG=1
    C_Y="" C_DIM="" C_RST=""
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    prompt_ralph_mode
    [ "$?" -eq 0 ] && echo "skipped_interactive"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped_interactive"* ]]
}

@test "prompt_ralph_mode sets hybrid mode interactively" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    export RALPH_MODE_PROMPT_ASSUME_TTY=1
    unset RALPH_MODE
    C_Y="" C_DIM="" C_RST=""
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    ralph_menu_select() { printf "%s" "hybrid"; }
    prompt_ralph_mode
    printf "%s" "${RALPH_MODE:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"hybrid"* ]]
}

@test "prompt_ralph_mode defaults interactive selection to no" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    export RALPH_MODE_PROMPT_ASSUME_TTY=1
    unset RALPH_MODE
    C_Y="" C_DIM="" C_RST=""
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    ralph_menu_select() {
      [[ "$1" == "--prompt" ]]
      [[ "$2" == "Ralph mode" ]]
      [[ "$3" == "--default" ]]
      [[ "$4" == "1" ]]
      shift 5
      [[ "$1" == "no" ]]
      [[ "$2" == "native" ]]
      [[ "$3" == "ralph" ]]
      [[ "$4" == "hybrid" ]]
      printf "%s" "no"
    }
    prompt_ralph_mode
    printf "%s" "${RALPH_MODE:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no"* ]]
}

@test "prompt_ralph_mode sets ralph mode interactively" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    export RALPH_MODE_PROMPT_ASSUME_TTY=1
    unset RALPH_MODE
    C_Y="" C_DIM="" C_RST=""
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    ralph_menu_select() { printf "%s" "ralph"; }
    prompt_ralph_mode
    printf "%s" "${RALPH_MODE:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ralph"* ]]
}

@test "run-plan --session-strategy compact parses correctly" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    WORKSPACE="$(pwd)"
    export WORKSPACE
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME="cursor"
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/run-plan/run-plan-session.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan" --session-strategy compact
    printf "%s" "${RALPH_PLAN_SESSION_STRATEGY:-}"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "compact" ]

  rm -f "$plan_file"
}

@test "ralph_apply_shell_compact_defaults enables compaction for hybrid mode" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    RALPH_MODE="hybrid"
    unset RALPH_PROXY_SHELL_COMPACT
    ralph_apply_shell_compact_defaults
    printf "%s" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "ralph_apply_shell_compact_defaults enables compaction for ralph mode" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    RALPH_MODE="ralph"
    unset RALPH_PROXY_SHELL_COMPACT
    ralph_apply_shell_compact_defaults
    printf "%s" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "ralph_apply_shell_compact_defaults does not enable compaction for native mode" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    RALPH_MODE="native"
    unset RALPH_PROXY_SHELL_COMPACT
    ralph_apply_shell_compact_defaults
    printf "%s" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "unset" ]
}

@test "ralph_apply_shell_compact_defaults does not enable compaction for no mode" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    RALPH_MODE="no"
    unset RALPH_PROXY_SHELL_COMPACT
    ralph_apply_shell_compact_defaults
    printf "%s" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "unset" ]
}

@test "ralph_apply_shell_compact_defaults respects explicit RALPH_PROXY_SHELL_COMPACT=0 opt-out" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    RALPH_MODE="hybrid"
    RALPH_PROXY_SHELL_COMPACT="0"
    ralph_apply_shell_compact_defaults
    printf "%s" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "ralph_apply_shell_compact_defaults respects explicit RALPH_PROXY_SHELL_COMPACT=1 opt-in" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-runtime.sh"
    RALPH_MODE="no"
    RALPH_PROXY_SHELL_COMPACT="1"
    ralph_apply_shell_compact_defaults
    printf "%s" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "ralph_apply_mode_compaction_defaults enables RALPH_PROXY_SHELL_COMPACT for hybrid and ralph modes" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    unset RALPH_PROXY_SHELL_COMPACT RALPH_BASH_COMPACT
    ralph_apply_mode_compaction_defaults "hybrid"
    printf "hybrid_proxy=%s\n" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
    printf "hybrid_bash=%s\n" "${RALPH_BASH_COMPACT:-unset}"
    unset RALPH_PROXY_SHELL_COMPACT RALPH_BASH_COMPACT
    ralph_apply_mode_compaction_defaults "ralph"
    printf "ralph_proxy=%s\n" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
    printf "ralph_bash=%s\n" "${RALPH_BASH_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"hybrid_proxy=1"* ]]
  [[ "$output" == *"hybrid_bash=1"* ]]
  [[ "$output" == *"ralph_proxy=1"* ]]
  [[ "$output" == *"ralph_bash=unset"* ]]
}

@test "ralph_apply_mode_compaction_defaults leaves native exploration compaction opt-in" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    unset RALPH_NATIVE_RESULT_COMPACT
    ralph_apply_mode_compaction_defaults "native"
    printf "native_result=%s\n" "${RALPH_NATIVE_RESULT_COMPACT:-unset}"
    unset RALPH_NATIVE_RESULT_COMPACT
    ralph_apply_mode_compaction_defaults "hybrid"
    printf "hybrid_result=%s\n" "${RALPH_NATIVE_RESULT_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"native_result=unset"* ]]
  [[ "$output" == *"hybrid_result=unset"* ]]
}

@test "ralph_apply_mode_transcript_eviction_defaults enables safe eviction for ralph and hybrid modes" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    unset RALPH_PLAN_TRANSCRIPT_EVICTION RALPH_CONTINUATION_SUMMARY RALPH_CONTINUATION_SUMMARY_HIERARCHICAL RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES
    ralph_apply_mode_transcript_eviction_defaults "ralph"
    printf "ralph_eviction=%s\n" "${RALPH_PLAN_TRANSCRIPT_EVICTION:-unset}"
    printf "ralph_summary=%s\n" "${RALPH_CONTINUATION_SUMMARY:-unset}"
    printf "ralph_hier=%s\n" "${RALPH_CONTINUATION_SUMMARY_HIERARCHICAL:-unset}"
    printf "ralph_bytes=%s\n" "${RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES:-unset}"
    unset RALPH_PLAN_TRANSCRIPT_EVICTION RALPH_CONTINUATION_SUMMARY RALPH_CONTINUATION_SUMMARY_HIERARCHICAL RALPH_CONTINUATION_SUMMARY_MAX_RENDER_BYTES
    ralph_apply_mode_transcript_eviction_defaults "hybrid"
    printf "hybrid_eviction=%s\n" "${RALPH_PLAN_TRANSCRIPT_EVICTION:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ralph_eviction=safe"* ]]
  [[ "$output" == *"ralph_summary=1"* ]]
  [[ "$output" == *"ralph_hier=1"* ]]
  [[ "$output" == *"ralph_bytes=8192"* ]]
  [[ "$output" == *"hybrid_eviction=safe"* ]]
}

@test "ralph_apply_mode_transcript_eviction_defaults leaves no/native modes off by default" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    unset RALPH_PLAN_TRANSCRIPT_EVICTION
    ralph_apply_mode_transcript_eviction_defaults "no"
    printf "no_eviction=%s\n" "${RALPH_PLAN_TRANSCRIPT_EVICTION:-unset}"
    unset RALPH_PLAN_TRANSCRIPT_EVICTION
    ralph_apply_mode_transcript_eviction_defaults "native"
    printf "native_eviction=%s\n" "${RALPH_PLAN_TRANSCRIPT_EVICTION:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no_eviction=off"* ]]
  [[ "$output" == *"native_eviction=off"* ]]
}

@test "ralph_apply_mode_transcript_eviction_defaults respects explicit aggressive and off values" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    RALPH_PLAN_TRANSCRIPT_EVICTION="aggressive"
    unset RALPH_PLAN_CONTEXT_BUDGET RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT
    ralph_apply_mode_transcript_eviction_defaults "no"
    printf "aggressive=%s\n" "${RALPH_PLAN_TRANSCRIPT_EVICTION:-unset}"
    printf "budget=%s\n" "${RALPH_PLAN_CONTEXT_BUDGET:-unset}"
    printf "recent=%s\n" "${RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT:-unset}"
    RALPH_PLAN_TRANSCRIPT_EVICTION="off"
    unset RALPH_PLAN_CONTEXT_BUDGET RALPH_CONTINUATION_SUMMARY_RECENT_DETAIL_COUNT
    ralph_apply_mode_transcript_eviction_defaults "hybrid"
    printf "off=%s\n" "${RALPH_PLAN_TRANSCRIPT_EVICTION:-unset}"
    printf "off_budget=%s\n" "${RALPH_PLAN_CONTEXT_BUDGET:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"aggressive=aggressive"* ]]
  [[ "$output" == *"budget=lean"* ]]
  [[ "$output" == *"recent=3"* ]]
  [[ "$output" == *"off=off"* ]]
  [[ "$output" == *"off_budget=unset"* ]]
}

@test "ralph_apply_mode_compaction_defaults leaves compaction unset for native and no modes" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    unset RALPH_PROXY_SHELL_COMPACT RALPH_BASH_COMPACT
    ralph_apply_mode_compaction_defaults "native"
    printf "native_proxy=%s\n" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
    printf "native_bash=%s\n" "${RALPH_BASH_COMPACT:-unset}"
    unset RALPH_PROXY_SHELL_COMPACT RALPH_BASH_COMPACT
    ralph_apply_mode_compaction_defaults "no"
    printf "no_proxy=%s\n" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
    printf "no_bash=%s\n" "${RALPH_BASH_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"native_proxy=unset"* ]]
  [[ "$output" == *"native_bash=1"* ]]
  [[ "$output" == *"no_proxy=unset"* ]]
  [[ "$output" == *"no_bash=unset"* ]]
}

@test "ralph_apply_mode_compaction_defaults respects explicit RALPH_NATIVE_RESULT_COMPACT=0 opt-out" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    RALPH_NATIVE_RESULT_COMPACT="0"
    ralph_apply_mode_compaction_defaults "hybrid"
    printf "%s" "${RALPH_NATIVE_RESULT_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "ralph_apply_mode_compaction_defaults honors explicit RALPH_PROXY_SHELL_COMPACT=0 opt-out" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    RALPH_PROXY_SHELL_COMPACT="0"
    ralph_apply_mode_compaction_defaults "hybrid"
    printf "%s" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "ralph_apply_ralph_mode_to_knobs derives RALPH_PROXY_SHELL_COMPACT from hybrid mode" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    unset RALPH_PROXY_SHELL_COMPACT RALPH_BASH_COMPACT RALPH_PLAN_TRANSCRIPT_EVICTION
    ralph_apply_ralph_mode_to_knobs "hybrid"
    printf "%s\n" \
      "RALPH_PROXY_SHELL_COMPACT=${RALPH_PROXY_SHELL_COMPACT:-unset}" \
      "RALPH_BASH_COMPACT=${RALPH_BASH_COMPACT:-unset}" \
      "RALPH_PLAN_TRANSCRIPT_EVICTION=${RALPH_PLAN_TRANSCRIPT_EVICTION:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_PROXY_SHELL_COMPACT=1"* ]]
  [[ "$output" == *"RALPH_BASH_COMPACT=1"* ]]
  [[ "$output" == *"RALPH_PLAN_TRANSCRIPT_EVICTION=safe"* ]]
}

@test "ralph_run_plan_sync_mode_knobs derives RALPH_PROXY_SHELL_COMPACT from ralph mode" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-invoke-common.sh"
    RALPH_MODE="ralph"
    unset RALPH_PROXY_SHELL_COMPACT RALPH_BASH_COMPACT RALPH_PLAN_TRANSCRIPT_EVICTION
    ralph_run_plan_sync_mode_knobs
    printf "%s\n" \
      "RALPH_PROXY_SHELL_COMPACT=${RALPH_PROXY_SHELL_COMPACT:-unset}" \
      "RALPH_BASH_COMPACT=${RALPH_BASH_COMPACT:-unset}" \
      "RALPH_PLAN_TRANSCRIPT_EVICTION=${RALPH_PLAN_TRANSCRIPT_EVICTION:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_PROXY_SHELL_COMPACT=1"* ]]
  [[ "$output" == *"RALPH_BASH_COMPACT=unset"* ]]
  [[ "$output" == *"RALPH_PLAN_TRANSCRIPT_EVICTION=safe"* ]]
}

@test "ralph_run_plan_sync_mode_knobs respects explicit RALPH_PLAN_TRANSCRIPT_EVICTION override" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-invoke-common.sh"
    RALPH_MODE="hybrid"
    RALPH_PLAN_TRANSCRIPT_EVICTION="off"
    unset RALPH_CONTINUATION_SUMMARY RALPH_CONTINUATION_SUMMARY_HIERARCHICAL
    ralph_run_plan_sync_mode_knobs
    printf "%s\n" \
      "RALPH_PLAN_TRANSCRIPT_EVICTION=${RALPH_PLAN_TRANSCRIPT_EVICTION:-unset}" \
      "RALPH_CONTINUATION_SUMMARY=${RALPH_CONTINUATION_SUMMARY:-unset}" \
      "RALPH_CONTINUATION_SUMMARY_HIERARCHICAL=${RALPH_CONTINUATION_SUMMARY_HIERARCHICAL:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_PLAN_TRANSCRIPT_EVICTION=off"* ]]
  [[ "$output" == *"RALPH_CONTINUATION_SUMMARY=unset"* ]]
  [[ "$output" == *"RALPH_CONTINUATION_SUMMARY_HIERARCHICAL=unset"* ]]
}

@test "ralph_run_plan_sync_mode_knobs honors explicit RALPH_PROXY_SHELL_COMPACT=0 opt-out" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-invoke-common.sh"
    RALPH_MODE="hybrid"
    RALPH_PROXY_SHELL_COMPACT="0"
    ralph_run_plan_sync_mode_knobs
    printf "%s" "${RALPH_PROXY_SHELL_COMPACT:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "ralph_apply_ralph_mode_to_knobs maps no to native+off" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    ralph_apply_ralph_mode_to_knobs "no"
    printf "%s\n" \
      "RALPH_AGENT_TOOL_ACCESS=${RALPH_AGENT_TOOL_ACCESS:-unset}" \
      "RALPH_NATIVE_HOOKS=${RALPH_NATIVE_HOOKS:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_AGENT_TOOL_ACCESS=native"* ]]
  [[ "$output" == *"RALPH_NATIVE_HOOKS=off"* ]]
}

@test "ralph_apply_ralph_mode_to_knobs maps native to native+auto" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    ralph_apply_ralph_mode_to_knobs "native"
    printf "%s\n" \
      "RALPH_AGENT_TOOL_ACCESS=${RALPH_AGENT_TOOL_ACCESS:-unset}" \
      "RALPH_NATIVE_HOOKS=${RALPH_NATIVE_HOOKS:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_AGENT_TOOL_ACCESS=native"* ]]
  [[ "$output" == *"RALPH_NATIVE_HOOKS=auto"* ]]
}

@test "ralph_apply_ralph_mode_to_knobs maps ralph to ralph+off" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    ralph_apply_ralph_mode_to_knobs "ralph"
    printf "%s\n" \
      "RALPH_AGENT_TOOL_ACCESS=${RALPH_AGENT_TOOL_ACCESS:-unset}" \
      "RALPH_NATIVE_HOOKS=${RALPH_NATIVE_HOOKS:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_AGENT_TOOL_ACCESS=ralph"* ]]
  [[ "$output" == *"RALPH_NATIVE_HOOKS=off"* ]]
}

@test "ralph_apply_ralph_mode_to_knobs maps hybrid to ralph+auto" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  run bash -c '
    source "$1/bash-lib/run-plan/run-plan-args.sh"
    ralph_apply_ralph_mode_to_knobs "hybrid"
    printf "%s\n" \
      "RALPH_AGENT_TOOL_ACCESS=${RALPH_AGENT_TOOL_ACCESS:-unset}" \
      "RALPH_NATIVE_HOOKS=${RALPH_NATIVE_HOOKS:-unset}"
  ' _ "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_AGENT_TOOL_ACCESS=ralph"* ]]
  [[ "$output" == *"RALPH_NATIVE_HOOKS=auto"* ]]
}

@test "RALPH_STRICT_PROXY=1 is normalized correctly" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    export WORKSPACE="$(pwd)"
    export RALPH_STRICT_PROXY=1
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan"
    printf "%s" "${RALPH_STRICT_PROXY:-unset}"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  rm -f "$plan_file"
}

@test "RALPH_STRICT_PROXY=0 is normalized correctly" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    export WORKSPACE="$(pwd)"
    export RALPH_STRICT_PROXY=0
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan"
    printf "%s" "${RALPH_STRICT_PROXY:-unset}"
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  rm -f "$plan_file"
}

@test "RALPH_OPTIMIZATION_MODE env var fails with clear error pointing to RALPH_MODE (parse)" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local plan_file
  plan_file="$(mktemp)"
  printf '%s\n' "- [ ] pending task" >"$plan_file"

  run bash -c '
    set -euo pipefail
    export WORKSPACE="$(pwd)"
    export RALPH_OPTIMIZATION_MODE="governed"
    PREBUILT_AGENT=""
    PLAN_MODEL_CLI=""
    INTERACTIVE_SELECT_AGENT_FLAG=0
    NON_INTERACTIVE_FLAG=1
    SKIP_MCP_PREFLIGHT_FLAG=1
    CLI_RESUME_FLAG=0
    NO_CLI_RESUME_FLAG=0
    ALLOW_UNSAFE_RESUME_FLAG=0
    RESUME_SESSION_ID_OVERRIDE=""
    SESSION_STRATEGY_FLAG=""
    RUNTIME=""
    RALPH_PLAN_TODO_MAX_ITERATIONS=""
    CLAUDE_TOOLS_FROM_AGENT=""
    _RALPH_CLI_RESUME_ENV_WAS_SET=0
    plan="$1"
    ralph_root="$2"
    source "$ralph_root/bash-lib/error-handling.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-runtime.sh"
    source "$ralph_root/bash-lib/run-plan/run-plan-args.sh"
    ralph_run_plan_parse_args --runtime cursor --plan "$plan" 2>&1
  ' _ "$plan_file" "$(dirname "$RUN_PLAN_SH")"

  [ "$status" -ne 0 ]
  [[ "$output" == *"RALPH_OPTIMIZATION_MODE"* ]] && [[ "$output" == *"RALPH_MODE"* ]]

  rm -f "$plan_file"
}
