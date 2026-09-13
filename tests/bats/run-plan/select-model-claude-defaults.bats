#!/usr/bin/env bats

# Claude's built-in model menu. Claude Code resolves the aliases haiku, sonnet,
# opus, and fable to the latest model in each family, so they are the useful
# defaults to offer. Before this, ralph_select_model_list_discovered returned
# only the saved model store for claude, which is empty on a fresh machine --
# leaving the workflow start model prompt with nothing but "Use claude default"
# and "Enter a model ID".

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  SMC_TMP="$(mktemp -d)"
  export RALPH_CONFIG_HOME="$SMC_TMP/config"
  mkdir -p "$RALPH_CONFIG_HOME"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-claude.sh"
}

teardown() { rm -rf "$SMC_TMP"; }

write_saved_models() {
  printf '%s\n' "$1" >"$RALPH_CONFIG_HOME/models.json"
}

@test "claude defaults offer haiku sonnet opus and fable" {
  [ "${_CLAUDE_DEFAULT_MODELS[0]}" = "haiku" ]
  [ "${_CLAUDE_DEFAULT_MODELS[1]}" = "sonnet" ]
  [ "${_CLAUDE_DEFAULT_MODELS[2]}" = "opus" ]
  [ "${_CLAUDE_DEFAULT_MODELS[3]}" = "fable" ]
  [ "${#_CLAUDE_DEFAULT_MODELS[@]}" -eq 4 ]
}

@test "discovery lists the claude defaults when nothing is saved" {
  run ralph_select_model_list_discovered claude
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "haiku" ]
  [ "${lines[1]}" = "sonnet" ]
  [ "${lines[2]}" = "opus" ]
  [ "${lines[3]}" = "fable" ]
}

@test "discovery puts saved claude models first and never duplicates a default" {
  # Dated saved ids plus a saved alias: aliases append once, saved stay first.
  write_saved_models '{"claude":["claude-sonnet-4-6","claude-haiku-4-5","opus"]}'
  run ralph_select_model_list_discovered claude
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "claude-sonnet-4-6" ]
  [ "${lines[1]}" = "claude-haiku-4-5" ]
  [ "${lines[2]}" = "opus" ]
  [ "${lines[3]}" = "haiku" ]
  [ "${lines[4]}" = "sonnet" ]
  [ "${lines[5]}" = "fable" ]
  [ "$(printf '%s\n' "$output" | grep -c '^opus$')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^haiku$')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^sonnet$')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^fable$')" -eq 1 ]
  [ "${#lines[@]}" -eq 6 ]
}

@test "codex discovery still returns only the saved store" {
  run ralph_select_model_list_discovered codex
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  write_saved_models '{"codex":["gpt-5"]}'
  run ralph_select_model_list_discovered codex
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-5" ]
}

@test "direct interactive picker defaults-only preselects sonnet" {
  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    choices_file="$3"
    default_file="$4"
    ralph_menu_select() {
      local default_idx=1
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --default)
            default_idx="$2"
            shift 2
            ;;
          --prompt)
            shift 2
            ;;
          --)
            shift
            break
            ;;
          *)
            shift
            ;;
        esac
      done
      printf "%s" "$default_idx" >"$default_file"
      printf "%s" "$*" >"$choices_file"
      printf "%s" "sonnet"
    }
    _claude_select_model_interactive 2>/dev/null
  ' _ "$RALPH_CONFIG_HOME" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-claude.sh" \
    "$SMC_TMP/menu-choices" \
    "$SMC_TMP/menu-default"

  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]
  [ "$(cat "$SMC_TMP/menu-default")" = "2" ]
  [ "$(cat "$SMC_TMP/menu-choices")" = "haiku sonnet opus fable Enter custom model id" ]
}

@test "direct interactive picker merges saved models with claude defaults once each" {
  # Saved dated ids plus a saved alias: defaults must still appear exactly once,
  # saved entries first, custom placeholder last.
  write_saved_models '{"claude":["claude-sonnet-4-6","claude-haiku-4-5","opus"]}'

  run bash -c '
    set -euo pipefail
    export RALPH_CONFIG_HOME="$1"
    # shellcheck source=/dev/null
    source "$2"
    choices_file="$3"
    default_file="$4"
    ralph_menu_select() {
      local default_idx=1
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --default)
            default_idx="$2"
            shift 2
            ;;
          --prompt)
            shift 2
            ;;
          --)
            shift
            break
            ;;
          *)
            shift
            ;;
        esac
      done
      printf "%s" "$default_idx" >"$default_file"
      printf "%s" "$*" >"$choices_file"
      printf "%s" "haiku"
    }
    _claude_select_model_interactive 2>/dev/null
  ' _ "$RALPH_CONFIG_HOME" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/select-model/select-model-claude.sh" \
    "$SMC_TMP/menu-choices" \
    "$SMC_TMP/menu-default"

  [ "$status" -eq 0 ]
  [ "$output" = "haiku" ]
  # Saved models keep preselect index 1; defaults-only path uses index 2 (sonnet).
  [ "$(cat "$SMC_TMP/menu-default")" = "1" ]
  [ "$(cat "$SMC_TMP/menu-choices")" = "claude-sonnet-4-6 claude-haiku-4-5 opus haiku sonnet fable Enter custom model id" ]
  [ "$(tr ' ' '\n' <"$SMC_TMP/menu-choices" | grep -c '^haiku$')" -eq 1 ]
  [ "$(tr ' ' '\n' <"$SMC_TMP/menu-choices" | grep -c '^sonnet$')" -eq 1 ]
  [ "$(tr ' ' '\n' <"$SMC_TMP/menu-choices" | grep -c '^opus$')" -eq 1 ]
  [ "$(tr ' ' '\n' <"$SMC_TMP/menu-choices" | grep -c '^fable$')" -eq 1 ]
  [ "$(tr ' ' '\n' <"$SMC_TMP/menu-choices" | grep -c '^claude-sonnet-4-6$')" -eq 1 ]
  [ "$(tr ' ' '\n' <"$SMC_TMP/menu-choices" | grep -c '^claude-haiku-4-5$')" -eq 1 ]
}
