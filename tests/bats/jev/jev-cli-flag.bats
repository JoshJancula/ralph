#!/usr/bin/env bats
# Tests for the --jev CLI flag: parse in run-plan-args.sh, apply via
# ralph_jev_apply_cli_choice in run-plan-runtime.sh. No network or agent calls.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

ARGS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-args.sh"
RUNTIME_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-runtime.sh"
RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"

setup() {
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export RALPH_JEV_ENV_FILE=0
  JEVF_WS="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/ralph-jev-cli.XXXXXX")"
  : >"$JEVF_WS/p.plan.md"
  unset RALPH_JEV RALPH_JEV_MCP RALPH_JEV_ROUTING RALPH_JEV_COMPACT RALPH_JEV_CLI_CHOICE
  unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_OPTIMIZATION_MODE RALPH_MCP_TOOLS_ENABLED RALPH_TOOL_ACCESS_FLAG_SET RALPH_PLAN_TRANSCRIPT_EVICTION
}

teardown() {
  rm -rf "$JEVF_WS"
}

# Parse "$@" then apply the choice; print the resulting env on one line.
jevf_parse_apply() {
  run bash -c '
    source "'"$RALPH_DIR"'/bash-lib/error-handling.sh"
    source "'"$ARGS_LIB"'"
    source "'"$RUNTIME_LIB"'"
    ralph_run_plan_parse_args --runtime claude --workspace "'"$JEVF_WS"'" --plan p.plan.md "$@" || exit $?
    [[ -n "${RALPH_JEV_CLI_CHOICE:-}" ]] && { ralph_jev_apply_cli_choice "$RALPH_JEV_CLI_CHOICE" || exit 2; }
    printf "choice=%s J=%s R=%s M=%s C=%s\n" "${RALPH_JEV_CLI_CHOICE:-}" "${RALPH_JEV:-}" "${RALPH_JEV_ROUTING:-}" "${RALPH_JEV_MCP:-}" "${RALPH_JEV_COMPACT:-}"
  ' _ "$@"
}

@test "bare --jev means all" {
  jevf_parse_apply --jev
  [ "$status" -eq 0 ]
  [[ "$output" == *"choice=all J=1 R=1 M=1 C=1" ]]
}

@test "--jev routing sets only routing" {
  jevf_parse_apply --jev routing
  [ "$status" -eq 0 ]
  [[ "$output" == *"choice=routing J=1 R=1 M= C=" ]]
}

@test "--jev tooling sets mcp and compact" {
  jevf_parse_apply --jev tooling
  [ "$status" -eq 0 ]
  [[ "$output" == *"choice=tooling J=1 R= M=1 C=1" ]]
}

@test "--jev all sets every surface" {
  jevf_parse_apply --jev all
  [ "$status" -eq 0 ]
  [[ "$output" == *"choice=all J=1 R=1 M=1 C=1" ]]
}

@test "--jev=routing equals form" {
  jevf_parse_apply --jev=routing
  [ "$status" -eq 0 ]
  [[ "$output" == *"choice=routing J=1 R=1 M= C=" ]]
}

@test "bare --jev before another flag keeps that flag" {
  jevf_parse_apply --jev --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"choice=all J=1"* ]]
}

@test "--jev foo exits 2" {
  jevf_parse_apply --jev foo
  [ "$status" -eq 2 ]
  [[ "$output" == *"--jev value must be one of"* ]]
}

@test "--jev=foo exits 2" {
  jevf_parse_apply --jev=foo
  [ "$status" -eq 2 ]
}

@test "run-plan --help documents --jev" {
  run bash "$RUN_PLAN_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--jev"* ]]
}
