#!/usr/bin/env bats
# Tests for --jev on `ralph workflow start`: parse into WORKFLOW_CLI_START_JEV
# and export via ralph_jev_apply_cli_choice. Unit-level: no engine dispatch.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CLI="$REPO_ROOT/bundle/.ralph/workflow-cli.sh"

setup() {
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export RALPH_JEV_ENV_FILE=0
  unset RALPH_JEV RALPH_JEV_MCP RALPH_JEV_ROUTING RALPH_JEV_COMPACT
}

# Source every function in workflow-cli.sh (everything before the final
# dispatch case), parse start argv, apply, and print the resulting env.
jevw_parse_apply() {
  local line
  line="$(grep -nF 'case "${1:-}" in' "$CLI" | tail -1 | cut -d: -f1)"
  run bash -c '
    cli="$1"; line="$2"; shift 2
    dir="$(dirname "$cli")"
    # The script derives script_dir from BASH_SOURCE; pin it for the sourced copy.
    source <(head -n $((line - 1)) "$cli" | sed "s|^script_dir=.*|script_dir=\"$dir\"|")
    workflow_cli_parse_start wf-id "$@"
    workflow_cli_apply_start_jev
    printf "start=%s J=%s R=%s M=%s C=%s\n" "$WORKFLOW_CLI_START_JEV" "${RALPH_JEV:-}" "${RALPH_JEV_ROUTING:-}" "${RALPH_JEV_MCP:-}" "${RALPH_JEV_COMPACT:-}"
  ' _ "$CLI" "$line" "$@"
}

@test "start: no --jev leaves env untouched" {
  jevw_parse_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"start= J= R= M= C=" ]]
}

@test "start: bare --jev means all" {
  jevw_parse_apply --jev
  [ "$status" -eq 0 ]
  [[ "$output" == *"start=all J=1 R=1 M=1 C=1" ]]
}

@test "start: --jev routing" {
  jevw_parse_apply --jev routing
  [ "$status" -eq 0 ]
  [[ "$output" == *"start=routing J=1 R=1 M= C=" ]]
}

@test "start: --jev tooling" {
  jevw_parse_apply --jev tooling
  [ "$status" -eq 0 ]
  [[ "$output" == *"start=tooling J=1 R= M=1 C=1" ]]
}

@test "start: --jev all" {
  jevw_parse_apply --jev all
  [ "$status" -eq 0 ]
  [[ "$output" == *"start=all J=1 R=1 M=1 C=1" ]]
}

@test "start: --jev=routing" {
  jevw_parse_apply --jev=routing
  [ "$status" -eq 0 ]
  [[ "$output" == *"start=routing J=1 R=1 M= C=" ]]
}

@test "start: bare --jev before another flag keeps that flag" {
  jevw_parse_apply --jev --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"start=all J=1"* ]]
}

@test "start: --jev foo exits 2" {
  jevw_parse_apply --jev foo
  [ "$status" -eq 2 ]
  [[ "$output" == *"--jev value must be one of"* ]]
}

@test "start: --jev=foo exits 2" {
  jevw_parse_apply --jev=foo
  [ "$status" -eq 2 ]
}

@test "start: duplicate --jev exits 2" {
  jevw_parse_apply --jev routing --jev tooling
  [ "$status" -eq 2 ]
}

@test "start: cmd_start applies jev before roots init and engine dispatch" {
  body="$(sed -n '/^workflow_cli_cmd_start() {/,/^}/p' "$CLI")"
  apply_line="$(printf '%s\n' "$body" | grep -n 'workflow_cli_apply_start_jev' | head -1 | cut -d: -f1)"
  roots_line="$(printf '%s\n' "$body" | grep -n 'workflow_cli_init_roots' | head -1 | cut -d: -f1)"
  [ -n "$apply_line" ]
  [ -n "$roots_line" ]
  [ "$apply_line" -lt "$roots_line" ]
}

@test "start --help documents --jev" {
  run bash "$CLI" start --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--jev"* ]]
}
