#!/usr/bin/env bats
# Tests for the "Enable Jev?" prompt in run-plan-runtime.sh.
#
# The prompt must stay silent on every path except an attended TTY run that has
# a configured TypeSafe key and no explicit RALPH_JEV. No test makes a live API
# call: only jev_key_source (which never reads or prints the key) is exercised.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUNTIME_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-runtime.sh"
MENU_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/menu-select.sh"

setup() {
  JEVP_TMP="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/ralph-jev-prompt.XXXXXX")"
  export HOME="$JEVP_TMP/home"
  export RALPH_CONFIG_HOME="$JEVP_TMP/config"
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export RALPH_JEV_ENV_FILE=0
  mkdir -p "$HOME" "$RALPH_CONFIG_HOME"
  unset RALPH_JEV RALPH_JEV_MCP RALPH_JEV_ROUTING RALPH_JEV_COMPACT TYPESAFE_API_KEY
}

teardown() {
  rm -rf "$JEVP_TMP"
}

# Source the runtime lib and run <script> with the prompt's TTY gate bypassed.
# menu_choice seeds what ralph_menu_select returns.
jevp_run() {
  local menu_choice="$1" script="$2"
  run bash -c '
    source "'"$MENU_LIB"'" 2>/dev/null || true
    source "'"$RUNTIME_LIB"'"
    ralph_menu_select() { printf "%s\n" "'"$menu_choice"'"; }
    NON_INTERACTIVE_FLAG=0
    RALPH_JEV_PROMPT_ASSUME_TTY=1
    '"$script"'
  '
}

@test "no configured key means no prompt and no RALPH_JEV" {
  jevp_run "yes" '
    prompt_ralph_jev
    printf "RALPH_JEV=%s\n" "${RALPH_JEV:-unset}"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^RALPH_JEV=unset$'
  # Silence is the contract: nothing about Jev is advertised without a key.
  ! printf '%s\n' "$output" | grep -qi 'Enable Jev'
}

@test "configured key plus each enabling choice sets only its surfaces" {
  export TYPESAFE_API_KEY="typesafe-prompt-test-key"
  local pair choice expect
  for pair in "compaction|JEV=1 MCP=unset ROUTING=unset COMPACT=1" \
              "mcp|JEV=1 MCP=1 ROUTING=unset COMPACT=unset" \
              "both|JEV=1 MCP=1 ROUTING=unset COMPACT=1"; do
    choice="${pair%%|*}"; expect="${pair#*|}"
    jevp_run "$choice" '
      prompt_ralph_jev
      printf "JEV=%s MCP=%s ROUTING=%s COMPACT=%s\n" \
        "${RALPH_JEV:-unset}" "${RALPH_JEV_MCP:-unset}" \
        "${RALPH_JEV_ROUTING:-unset}" "${RALPH_JEV_COMPACT:-unset}"
    '
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qF "$expect"
  done
}

@test "configured key plus none sets RALPH_JEV=0" {
  export TYPESAFE_API_KEY="typesafe-prompt-test-key"
  jevp_run "none" '
    prompt_ralph_jev
    printf "RALPH_JEV=%s COMPACT=%s\n" "${RALPH_JEV:-unset}" "${RALPH_JEV_COMPACT:-unset}"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^RALPH_JEV=0 COMPACT=unset$'
}

@test "the prompt never prints the API key" {
  export TYPESAFE_API_KEY="typesafe-prompt-secret-should-not-appear"
  jevp_run "yes" 'prompt_ralph_jev'
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -qF 'typesafe-prompt-secret-should-not-appear'
  # The source name is shown; the value never is.
  printf '%s\n' "$output" | grep -q 'source: env'
}

@test "an explicit RALPH_JEV skips the prompt entirely" {
  export TYPESAFE_API_KEY="typesafe-prompt-test-key"
  export RALPH_JEV=0
  jevp_run "yes" '
    prompt_ralph_jev
    printf "RALPH_JEV=%s\n" "${RALPH_JEV:-unset}"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^RALPH_JEV=0$'
  ! printf '%s\n' "$output" | grep -qi 'Enable Jev'
}

@test "non-interactive runs never prompt" {
  export TYPESAFE_API_KEY="typesafe-prompt-test-key"
  run bash -c '
    source "'"$MENU_LIB"'" 2>/dev/null || true
    source "'"$RUNTIME_LIB"'"
    ralph_menu_select() { printf "yes\n"; }
    NON_INTERACTIVE_FLAG=1
    RALPH_JEV_PROMPT_ASSUME_TTY=0
    prompt_ralph_jev
    printf "RALPH_JEV=%s\n" "${RALPH_JEV:-unset}"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^RALPH_JEV=unset$'
  ! printf '%s\n' "$output" | grep -qi 'Enable Jev'
}

@test "jev_default preference is honored and an invalid value warns" {
  local ws="$JEVP_TMP/ws" root="$JEVP_TMP/ws/.ralph-workspace"
  mkdir -p "$root"
  printf '%s\n' '{"jev_default":"yes"}' >"$root/preferences.json"
  run bash -c '
    source "'"$RUNTIME_LIB"'"
    ralph_load_workspace_preferences "'"$ws"'" "'"$root"'"
    printf "JEV=%s MCP=%s COMPACT=%s\n" \
      "${RALPH_JEV:-unset}" "${RALPH_JEV_MCP:-unset}" "${RALPH_JEV_COMPACT:-unset}"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'JEV=1 MCP=1 COMPACT=1'

  printf '%s\n' '{"jev_default":"maybe"}' >"$root/preferences.json"
  run bash -c '
    source "'"$RUNTIME_LIB"'"
    ralph_load_workspace_preferences "'"$ws"'" "'"$root"'"
    printf "JEV=%s\n" "${RALPH_JEV:-unset}"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'JEV=unset'
  printf '%s\n' "$output" | grep -q "ignoring invalid jev_default='maybe'"
}

@test "jev_default no is honored without enabling any surface" {
  local ws="$JEVP_TMP/ws" root="$JEVP_TMP/ws/.ralph-workspace"
  mkdir -p "$root"
  printf '%s\n' '{"jev_default":"no"}' >"$root/preferences.json"
  run bash -c '
    source "'"$RUNTIME_LIB"'"
    ralph_load_workspace_preferences "'"$ws"'" "'"$root"'"
    printf "JEV=%s MCP=%s\n" "${RALPH_JEV:-unset}" "${RALPH_JEV_MCP:-unset}"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'JEV=0 MCP=unset'
}

@test "an explicit RALPH_JEV beats the jev_default preference" {
  local ws="$JEVP_TMP/ws" root="$JEVP_TMP/ws/.ralph-workspace"
  mkdir -p "$root"
  printf '%s\n' '{"jev_default":"yes"}' >"$root/preferences.json"
  run bash -c '
    source "'"$RUNTIME_LIB"'"
    RALPH_JEV=0
    ralph_load_workspace_preferences "'"$ws"'" "'"$root"'"
    printf "JEV=%s MCP=%s\n" "${RALPH_JEV:-unset}" "${RALPH_JEV_MCP:-unset}"
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'JEV=0 MCP=unset'
}
