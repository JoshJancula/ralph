#!/usr/bin/env bash
#
# Normalize the runtime-specific plan environment so the unified runner can read a single
# set of internal variables. Each runtime inherits a defined env chain for all supported
# knobs (verbose, color, log paths, gutter/iteration, progress interval, caffeinate, etc.):
# - cursor: `CURSOR_PLAN_*` values win for every option.
# - claude: `CLAUDE_PLAN_*` takes precedence, falling back to `CURSOR_PLAN_*`.
# - codex: `CODEX_PLAN_*` beats `CLAUDE_PLAN_*`, which in turn beats `CURSOR_PLAN_*`.
# - opencode: `OPENCODE_PLAN_*` beats `CODEX_PLAN_*`, `CLAUDE_PLAN_*`, and `CURSOR_PLAN_*`.
#
# The helper below sets verbose, color, log, gutter/iteration, progress, and caffeinate
# flags according to the documented chains above.
#
# Public interface:
#   ralph_run_plan_load_env_for_runtime <runtime> -- normalizes env into shared CURSOR_PLAN_*-style variables
#     used by run-plan-core (verbose, colors, logs, iterations, human prompt toggles).
#   ralph_run_plan_record_workspace_registry <workspace> <runtime> <plan-key> -- best-effort update of the
#     user-level workspace registry used by global Ralph installs.

ralph_run_plan_workspace_registry_file() {
  if [[ -n "${RALPH_WORKSPACES_FILE:-}" ]]; then
    printf '%s\n' "$RALPH_WORKSPACES_FILE"
    return 0
  fi

  local config_home="${XDG_CONFIG_HOME:-}"
  if [[ -z "$config_home" && -n "${HOME:-}" ]]; then
    config_home="$HOME/.config"
  fi
  if [[ -z "$config_home" ]]; then
    echo "Warning: HOME or XDG_CONFIG_HOME must be set to update Ralph workspace registry." >&2
    return 1
  fi
  printf '%s\n' "$config_home/ralph/workspaces.json"
}

ralph_run_plan_record_workspace_registry() {
  local workspace="${1:-${WORKSPACE:-}}"
  local runtime="${2:-${RUNTIME:-}}"
  local plan_key="${3:-${RALPH_PLAN_KEY:-}}"
  local registry_file lib_dir helper source_path

  if [[ -z "$workspace" || -z "$runtime" || -z "$plan_key" ]]; then
    echo "Warning: skipping Ralph workspace registry write; workspace, runtime, or plan key is missing." >&2
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 not found; skipping Ralph workspace registry write." >&2
    return 0
  fi

  if ! registry_file="$(ralph_run_plan_workspace_registry_file)"; then
    return 0
  fi

  source_path="${BASH_SOURCE[0]}"
  lib_dir="${source_path%/*}"
  [[ "$lib_dir" == "$source_path" ]] && lib_dir="."
  helper="$lib_dir/workspace-registry.py"
  if [[ ! -f "$helper" ]]; then
    echo "Warning: Ralph workspace registry helper missing: $helper" >&2
    return 0
  fi

  if ! python3 "$helper" "$registry_file" "$workspace" "$plan_key" "$runtime"; then
    echo "Warning: failed to update Ralph workspace registry: $registry_file" >&2
    return 0
  fi
}

ralph_run_plan_load_env_for_runtime() {
  local runtime="${1:-${RUNTIME:-}}"
  if [[ -z "$runtime" ]]; then
    echo "RUNTIME must be set before calling ralph_run_plan_load_env_for_runtime." >&2
    return 1
  fi

  local verbose no_color max_iter gutter interval plan_log plan_output_log
  local no_caffeinate caffeinated
  local disable_prompt no_open

  case "$runtime" in
    cursor)
      verbose="${CURSOR_PLAN_VERBOSE:-0}"
      no_color="${CURSOR_PLAN_NO_COLOR:-0}"
      max_iter="${CURSOR_PLAN_MAX_ITER:-9999}"
      gutter="${CURSOR_PLAN_GUTTER_ITER:-10}"
      interval="${CURSOR_PLAN_PROGRESS_INTERVAL:-30}"
      plan_log="${CURSOR_PLAN_LOG:-}"
      plan_output_log="${CURSOR_PLAN_OUTPUT_LOG:-}"
      no_caffeinate="${CURSOR_PLAN_NO_CAFFEINATE:-0}"
      caffeinated="${CURSOR_PLAN_CAFFEINATED:-0}"
      disable_prompt="${CURSOR_PLAN_DISABLE_HUMAN_PROMPT:-0}"
      no_open="${CURSOR_PLAN_NO_OPEN:-0}"
      ;;
    claude)
      verbose="${CLAUDE_PLAN_VERBOSE:-${CURSOR_PLAN_VERBOSE:-0}}"
      no_color="${CLAUDE_PLAN_NO_COLOR:-${CURSOR_PLAN_NO_COLOR:-0}}"
      max_iter="${CLAUDE_PLAN_MAX_ITER:-${CURSOR_PLAN_MAX_ITER:-9999}}"
      gutter="${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-10}}"
      interval="${CLAUDE_PLAN_PROGRESS_INTERVAL:-${CURSOR_PLAN_PROGRESS_INTERVAL:-30}}"
      plan_log="${CLAUDE_PLAN_LOG:-${CURSOR_PLAN_LOG:-}}"
      plan_output_log="${CLAUDE_PLAN_OUTPUT_LOG:-${CURSOR_PLAN_OUTPUT_LOG:-}}"
      no_caffeinate="${CLAUDE_PLAN_NO_CAFFEINATE:-${CURSOR_PLAN_NO_CAFFEINATE:-0}}"
      caffeinated="${CLAUDE_PLAN_CAFFEINATED:-${CURSOR_PLAN_CAFFEINATED:-0}}"
      disable_prompt="${CLAUDE_PLAN_DISABLE_HUMAN_PROMPT:-${CURSOR_PLAN_DISABLE_HUMAN_PROMPT:-0}}"
      no_open="${CLAUDE_PLAN_NO_OPEN:-${CURSOR_PLAN_NO_OPEN:-0}}"
      ;;
    codex)
      verbose="${CODEX_PLAN_VERBOSE:-${CLAUDE_PLAN_VERBOSE:-${CURSOR_PLAN_VERBOSE:-0}}}"
      no_color="${CODEX_PLAN_NO_COLOR:-${CLAUDE_PLAN_NO_COLOR:-${CURSOR_PLAN_NO_COLOR:-0}}}"
      max_iter="${CODEX_PLAN_MAX_ITER:-${CLAUDE_PLAN_MAX_ITER:-${CURSOR_PLAN_MAX_ITER:-9999}}}"
      gutter="${CODEX_PLAN_GUTTER_ITER:-${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-10}}}"
      interval="${CODEX_PLAN_PROGRESS_INTERVAL:-${CLAUDE_PLAN_PROGRESS_INTERVAL:-${CURSOR_PLAN_PROGRESS_INTERVAL:-30}}}"
      plan_log="${CODEX_PLAN_LOG:-${CLAUDE_PLAN_LOG:-${CURSOR_PLAN_LOG:-}}}"
      plan_output_log="${CODEX_PLAN_OUTPUT_LOG:-${CLAUDE_PLAN_OUTPUT_LOG:-${CURSOR_PLAN_OUTPUT_LOG:-}}}"
      no_caffeinate="${CODEX_PLAN_NO_CAFFEINATE:-${CLAUDE_PLAN_NO_CAFFEINATE:-${CURSOR_PLAN_NO_CAFFEINATE:-0}}}"
      caffeinated="${CODEX_PLAN_CAFFEINATED:-${CLAUDE_PLAN_CAFFEINATED:-${CURSOR_PLAN_CAFFEINATED:-0}}}"
      disable_prompt="${CODEX_PLAN_DISABLE_HUMAN_PROMPT:-${CLAUDE_PLAN_DISABLE_HUMAN_PROMPT:-${CURSOR_PLAN_DISABLE_HUMAN_PROMPT:-0}}}"
      no_open="${CODEX_PLAN_NO_OPEN:-${CLAUDE_PLAN_NO_OPEN:-${CURSOR_PLAN_NO_OPEN:-0}}}"
      ;;
    opencode)
      verbose="${OPENCODE_PLAN_VERBOSE:-${CODEX_PLAN_VERBOSE:-${CLAUDE_PLAN_VERBOSE:-${CURSOR_PLAN_VERBOSE:-0}}}}"
      no_color="${OPENCODE_PLAN_NO_COLOR:-${CODEX_PLAN_NO_COLOR:-${CLAUDE_PLAN_NO_COLOR:-${CURSOR_PLAN_NO_COLOR:-0}}}}"
      max_iter="${OPENCODE_PLAN_MAX_ITER:-${CODEX_PLAN_MAX_ITER:-${CLAUDE_PLAN_MAX_ITER:-${CURSOR_PLAN_MAX_ITER:-9999}}}}"
      gutter="${OPENCODE_PLAN_GUTTER_ITER:-${CODEX_PLAN_GUTTER_ITER:-${CLAUDE_PLAN_GUTTER_ITER:-${CURSOR_PLAN_GUTTER_ITER:-10}}}}"
      interval="${OPENCODE_PLAN_PROGRESS_INTERVAL:-${CODEX_PLAN_PROGRESS_INTERVAL:-${CLAUDE_PLAN_PROGRESS_INTERVAL:-${CURSOR_PLAN_PROGRESS_INTERVAL:-30}}}}"
      plan_log="${OPENCODE_PLAN_LOG:-${CODEX_PLAN_LOG:-${CLAUDE_PLAN_LOG:-${CURSOR_PLAN_LOG:-}}}}"
      plan_output_log="${OPENCODE_PLAN_OUTPUT_LOG:-${CODEX_PLAN_OUTPUT_LOG:-${CLAUDE_PLAN_OUTPUT_LOG:-${CURSOR_PLAN_OUTPUT_LOG:-}}}}"
      no_caffeinate="${OPENCODE_PLAN_NO_CAFFEINATE:-${CODEX_PLAN_NO_CAFFEINATE:-${CLAUDE_PLAN_NO_CAFFEINATE:-${CURSOR_PLAN_NO_CAFFEINATE:-0}}}}"
      caffeinated="${OPENCODE_PLAN_CAFFEINATED:-${CODEX_PLAN_CAFFEINATED:-${CLAUDE_PLAN_CAFFEINATED:-${CURSOR_PLAN_CAFFEINATED:-0}}}}"
      disable_prompt="${OPENCODE_PLAN_DISABLE_HUMAN_PROMPT:-${CODEX_PLAN_DISABLE_HUMAN_PROMPT:-${CLAUDE_PLAN_DISABLE_HUMAN_PROMPT:-${CURSOR_PLAN_DISABLE_HUMAN_PROMPT:-0}}}}"
      no_open="${OPENCODE_PLAN_NO_OPEN:-${CODEX_PLAN_NO_OPEN:-${CLAUDE_PLAN_NO_OPEN:-${CURSOR_PLAN_NO_OPEN:-0}}}}"
      ;;
    *)
      echo "Unsupported runtime: $runtime" >&2
      return 1
      ;;
  esac

  RALPH_PLAN_VERBOSE="$verbose"
  RALPH_PLAN_NO_COLOR="$no_color"
  RALPH_PLAN_MAX_ITERATIONS="$max_iter"
  RALPH_PLAN_GUTTER_ITERATIONS="$gutter"
  RALPH_PLAN_PROGRESS_INTERVAL="$interval"
  RALPH_PLAN_NO_CAFFEINATE="$no_caffeinate"
  RALPH_PLAN_CAFFEINATED="$caffeinated"
  # Keep the human prompt toggles aligned with the runtime-specific env chain yet allow Cursor-compatible names.
  RALPH_PLAN_DISABLE_HUMAN_PROMPT="${disable_prompt:-0}"
  RALPH_PLAN_NO_OPEN="${no_open:-0}"
  : "$RALPH_PLAN_VERBOSE" "$RALPH_PLAN_NO_COLOR" "$RALPH_PLAN_MAX_ITERATIONS" "$RALPH_PLAN_GUTTER_ITERATIONS" \
    "$RALPH_PLAN_PROGRESS_INTERVAL" "$RALPH_PLAN_NO_CAFFEINATE" "$RALPH_PLAN_CAFFEINATED" \
    "$RALPH_PLAN_DISABLE_HUMAN_PROMPT" "$RALPH_PLAN_NO_OPEN"
  _PLAN_LOG="$plan_log"
  _PLAN_OUTPUT_LOG="$plan_output_log"
}
