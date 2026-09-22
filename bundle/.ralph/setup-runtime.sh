#!/usr/bin/env bash
#
# Setup a runtime directory with durable Ralph compaction hooks and MCP configuration.
#
# Usage:
#   ralph setup --runtime <claude|cursor|codex|opencode|antigravity|agy> [--runtime-dir <path>] [--hooks] [--mcp] [--all] [--remove] [--dry-run] [--yes]
#
# Options:
#   --runtime <name>      Runtime to configure (claude, cursor, codex, opencode, antigravity; agy aliases antigravity)
#   --runtime-dir <path>  Path to the runtime directory (default: $PWD/.$runtime, $PWD/.agents for antigravity)
#                         Use ~/.claude, ~/.cursor, ~/.codex, ~/.opencode, or ~/.agents for user-home installs.
#   --hooks               Install durable Ralph compaction/native hooks for normal runtime sessions
#   --mcp                 Install MCP configuration for the runtime
#   --all                 Install both hooks and MCP (equivalent to --hooks --mcp)
#   --remove              Remove selected Ralph setup entries instead of installing them
#   --dry-run             Show what would be done without making changes
#   --yes                 Skip confirmation prompts, including runtime-dir basename mismatch
#   --help                Show this help message
#
# Constraints:
#   - At least one of --hooks, --mcp, or --all must be specified.
#   - --remove requires exactly one of --hooks, --mcp, or --all.
#   - Default --runtime-dir is "$PWD/.$runtime" (antigravity uses "$PWD/.agents").
#   - Runtime-dir basename must match the selected runtime unless --yes is provided.
#   - Setup never creates or validates Ralph native agent definitions. Native
#     runtime agent directories (and agents.md) are left untouched; rules,
#     skills, hooks, plugins, and MCP setup continue as before.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source error handling library
# shellcheck source=bash-lib/error-handling.sh
source "$SCRIPT_DIR/bash-lib/error-handling.sh"

# Source runtime normalization helpers
# shellcheck source=bash-lib/runtime-normalize.sh
source "$SCRIPT_DIR/bash-lib/runtime-normalize.sh"

# Source setup helpers library
# shellcheck source=bash-lib/setup/setup-helpers.sh
source "$SCRIPT_DIR/bash-lib/setup/setup-helpers.sh"

# Source durable hook setup library
# shellcheck source=bash-lib/setup/setup-hooks.sh
source "$SCRIPT_DIR/bash-lib/setup/setup-hooks.sh"

# Source durable MCP setup library
# shellcheck source=bash-lib/setup/setup-mcp.sh
source "$SCRIPT_DIR/bash-lib/setup/setup-mcp.sh"

# Source shared setup mutation journal
# shellcheck source=bash-lib/setup/setup-journal.sh
source "$SCRIPT_DIR/bash-lib/setup/setup-journal.sh"

# Source runtime removal adapters
# shellcheck source=bash-lib/setup/setup-remove.sh
source "$SCRIPT_DIR/bash-lib/setup/setup-remove.sh"

# Valid runtimes
VALID_RUNTIMES=(claude cursor codex opencode antigravity)

# Globals set by argument parsing
SETUP_RUNTIME=""
SETUP_RUNTIME_DIR=""
SETUP_ACTION_HOOKS=""
SETUP_ACTION_MCP=""
SETUP_FLAG_HOOKS=""
SETUP_FLAG_MCP=""
SETUP_FLAG_ALL=""
SETUP_REMOVE=""
SETUP_DRY_RUN=""
SETUP_YES=""
SETUP_PROJECT_ROOT=""
SETUP_STATE_ROOT=""
# shellcheck source=bash-lib/help-render.sh
source "$SCRIPT_DIR/bash-lib/help-render.sh"

print_help() {
  cat << 'EOF' | ralph_help_render
Usage: ralph setup --runtime <claude|cursor|codex|opencode|antigravity|agy> [--runtime-dir <path>] [--hooks] [--mcp] [--all] [--remove] [--dry-run] [--yes]

Configure a runtime directory with durable Ralph compaction hooks and MCP tools.
Does not create or validate Ralph native agent definitions; native agent dirs stay untouched.

Options:
  --runtime <name>      Runtime to configure (claude, cursor, codex, opencode, antigravity; agy aliases antigravity)
  --runtime-dir <path>  Path to the runtime directory (default: $PWD/.$runtime, $PWD/.agents for antigravity)
                        Use ~/.claude, ~/.cursor, ~/.codex, ~/.opencode, or ~/.agents for user-home installs.
  --hooks               Install durable Ralph compaction/native hooks for normal runtime sessions
  --mcp                 Install MCP configuration for the runtime
  --all                 Install both hooks and MCP (equivalent to --hooks --mcp)
  --remove              Remove the selected Ralph setup entries instead of installing them
  --dry-run             Show what would be done without making changes
  --yes                 Skip confirmation prompts, including runtime-dir basename mismatch
  --help                Show this help message

Constraints:
  - At least one of --hooks, --mcp, or --all must be specified.
  - --remove requires exactly one of --hooks, --mcp, or --all.
  - Default --runtime-dir is "$PWD/.$runtime" (antigravity uses "$PWD/.agents").
  - Runtime-dir basename must match the selected runtime config dir unless --yes is provided.
  - Non-dry-run --remove requires --yes when stdin is not a terminal.
  - Native runtime agent directories and agents.md are never created or validated.

Examples:
  ralph setup --runtime claude --runtime-dir ~/.claude --hooks
  ralph setup --runtime cursor --runtime-dir /path/to/project/.cursor --hooks
  ralph setup --runtime codex --runtime-dir ~/.codex --hooks
  ralph setup --runtime claude --hooks --mcp
  ralph setup --runtime claude --remove --all --yes
EOF
}

validate_runtime() {
  local runtime="$1"
  runtime="$(ralph_normalize_runtime_name "$runtime")"
  for valid in "${VALID_RUNTIMES[@]}"; do
    if [[ "$runtime" == "$valid" ]]; then
      return 0
    fi
  done
  ralph_die "Error: Invalid runtime '$runtime'. Must be one of: ${VALID_RUNTIMES[*]}"
}

validate_runtime_dir_basename() {
  local runtime="$1"
  local runtime_dir="$2"
  local yes_flag="$3"

  local basename
  basename="$(basename "$runtime_dir")"

  # Expected basename is the runtime config dir (e.g., .claude, .cursor, .agents for antigravity)
  local expected_basename
  expected_basename="$(ralph_runtime_config_dirname "$runtime")"

  if [[ "$basename" != "$expected_basename" ]]; then
    if [[ -z "$yes_flag" ]]; then
      ralph_die "Error: Runtime directory basename '$basename' does not match runtime '$runtime' (expected '$expected_basename'). Use --yes to override."
    fi
  fi
}

resolve_project_root() {
  local runtime_dir="$1"
  # Project root is the parent directory of runtime-dir
  printf '%s' "$(dirname "$runtime_dir")"
}

parse_args() {
  SETUP_RUNTIME=""
  SETUP_RUNTIME_DIR=""
  SETUP_ACTION_HOOKS=""
  SETUP_ACTION_MCP=""
  SETUP_FLAG_HOOKS=""
  SETUP_FLAG_MCP=""
  SETUP_FLAG_ALL=""
  SETUP_REMOVE=""
  SETUP_DRY_RUN=""
  SETUP_YES=""
  SETUP_STATE_ROOT=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runtime)
        if [[ -z "${2:-}" || "${2:-}" =~ ^- ]]; then
          ralph_die "Error: --runtime requires an argument"
        fi
        SETUP_RUNTIME="$(ralph_normalize_runtime_name "$2")"
        shift 2
        ;;
      --runtime-dir)
        if [[ -z "${2:-}" || "${2:-}" =~ ^- ]]; then
          ralph_die "Error: --runtime-dir requires an argument"
        fi
        SETUP_RUNTIME_DIR="$2"
        shift 2
        ;;
      --hooks)
        SETUP_FLAG_HOOKS="1"
        SETUP_ACTION_HOOKS="1"
        shift
        ;;
      --mcp)
        SETUP_FLAG_MCP="1"
        SETUP_ACTION_MCP="1"
        shift
        ;;
      --all)
        SETUP_FLAG_ALL="1"
        SETUP_ACTION_HOOKS="1"
        SETUP_ACTION_MCP="1"
        shift
        ;;
      --remove)
        SETUP_REMOVE="1"
        shift
        ;;
      --dry-run)
        SETUP_DRY_RUN="1"
        shift
        ;;
      --yes)
        SETUP_YES="1"
        shift
        ;;
      --help)
        print_help
        exit 0
        ;;
      *)
        ralph_die "Error: Unknown argument '$1'"
        ;;
    esac
  done

  # Validate runtime is required
  if [[ -z "$SETUP_RUNTIME" ]]; then
    ralph_die "Error: --runtime is required"
  fi

  # Validate runtime value
  validate_runtime "$SETUP_RUNTIME"

  # Set default runtime-dir if not provided
  if [[ -z "$SETUP_RUNTIME_DIR" ]]; then
    SETUP_RUNTIME_DIR="$PWD/$(ralph_runtime_config_dirname "$SETUP_RUNTIME")"
  fi

  # Resolve absolute path for runtime-dir
  # Use pwd to resolve relative paths
  if [[ ! "$SETUP_RUNTIME_DIR" =~ ^/ ]]; then
    SETUP_RUNTIME_DIR="$(cd "$(dirname "$SETUP_RUNTIME_DIR")" && pwd)/$(basename "$SETUP_RUNTIME_DIR")"
  fi

  # Resolve project root
  SETUP_PROJECT_ROOT="$(resolve_project_root "$SETUP_RUNTIME_DIR")"
  SETUP_STATE_ROOT="${RALPH_PLAN_WORKSPACE_ROOT:-$SETUP_PROJECT_ROOT/.ralph-workspace}"

  # Validate runtime-dir basename matches runtime (unless --yes)
  validate_runtime_dir_basename "$SETUP_RUNTIME" "$SETUP_RUNTIME_DIR" "$SETUP_YES"

  if [[ -n "$SETUP_REMOVE" ]]; then
    local remove_action_count=0
    [[ -n "$SETUP_FLAG_HOOKS" ]] && remove_action_count=$((remove_action_count + 1))
    [[ -n "$SETUP_FLAG_MCP" ]] && remove_action_count=$((remove_action_count + 1))
    [[ -n "$SETUP_FLAG_ALL" ]] && remove_action_count=$((remove_action_count + 1))
    if [[ "$remove_action_count" -ne 1 ]]; then
      ralph_die "Error: --remove requires exactly one of --hooks, --mcp, or --all"
    fi
  elif [[ -z "$SETUP_ACTION_HOOKS" && -z "$SETUP_ACTION_MCP" ]]; then
    ralph_die "Error: At least one of --hooks, --mcp, or --all is required"
  fi
}

setup_remove_confirm() {
  local answer=""
  if [[ -n "$SETUP_DRY_RUN" || -n "$SETUP_YES" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    ralph_die "Error: --remove requires --yes when stdin is not a terminal"
  fi
  printf 'Remove Ralph setup (%s) from %s? [y/N]: ' \
    "${SETUP_FLAG_ALL:+all}${SETUP_FLAG_HOOKS:+hooks}${SETUP_FLAG_MCP:+mcp}" \
    "$SETUP_RUNTIME_DIR"
  IFS= read -r answer || ralph_die "Error: confirmation aborted"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) ralph_die "Error: removal cancelled" ;;
  esac
}

setup_remove_print_mutation_set() {
  if [[ -n "$SETUP_ACTION_HOOKS" ]]; then
    setup_action_status "remove hooks" "$SETUP_RUNTIME_DIR"
  fi
  if [[ -n "$SETUP_ACTION_MCP" ]]; then
    setup_action_status "remove mcp" "$SETUP_RUNTIME_DIR"
  fi
}

# Dispatch --remove after parse_args has accepted a valid combination.
# Dry-run still runs adapter discovery; the journal engine stays inactive.
setup_remove_dispatch() {
  setup_remove_confirm
  setup_remove_print_mutation_set

  if [[ -n "$SETUP_DRY_RUN" ]]; then
    printf '  Journal: none (dry-run does not create a setup journal)\n'
  else
    local op_id="remove-${SETUP_RUNTIME}-$$"
    setup_journal_begin "$SETUP_STATE_ROOT" "$op_id"
  fi
  if declare -F setup_remove_hooks >/dev/null 2>&1 && [[ -n "$SETUP_ACTION_HOOKS" ]]; then
    if ! setup_remove_hooks "$SETUP_RUNTIME" "$SETUP_RUNTIME_DIR"; then
      setup_journal_recover
      setup_journal_clear_traps
      return 1
    fi
  fi
  if declare -F setup_remove_mcp >/dev/null 2>&1 && [[ -n "$SETUP_ACTION_MCP" ]]; then
    if ! setup_remove_mcp "$SETUP_RUNTIME" "$SETUP_RUNTIME_DIR" "$SETUP_PROJECT_ROOT"; then
      setup_journal_recover
      setup_journal_clear_traps
      return 1
    fi
  fi
  if [[ -z "$SETUP_DRY_RUN" ]]; then
    setup_journal_commit
  fi
}

log_action() {
  local action="$1"
  local target="$2"

  # Use the shared helper for consistent dry-run output
  setup_action_status "$action" "$target"
}

main() {
  parse_args "$@"

  # Print summary
  if [[ -n "$SETUP_REMOVE" ]]; then
    printf 'Removing Ralph setup from %s runtime\n' "$SETUP_RUNTIME"
  else
    printf 'Setting up %s runtime\n' "$SETUP_RUNTIME"
  fi
  printf '  Runtime directory: %s\n' "$SETUP_RUNTIME_DIR"
  printf '  Project root: %s\n' "$SETUP_PROJECT_ROOT"
  printf '  Actions: '
  local actions=()
  [[ -n "$SETUP_ACTION_HOOKS" ]] && actions+=("hooks")
  [[ -n "$SETUP_ACTION_MCP" ]] && actions+=("mcp")
  printf '%s\n' "${actions[*]}"

  if [[ -n "$SETUP_DRY_RUN" ]]; then
    printf '  Mode: dry-run (no changes will be made)\n'
  fi

  if [[ -n "$SETUP_REMOVE" ]]; then
    if ! setup_remove_dispatch; then
      ralph_die "Error: failed to remove Ralph setup for $SETUP_RUNTIME"
    fi
    return 0
  fi

  if [[ -n "$SETUP_ACTION_HOOKS" ]]; then
    if ! setup_hooks_for_runtime "$SETUP_RUNTIME" "$SETUP_RUNTIME_DIR"; then
      ralph_die "Error: failed to install hooks for $SETUP_RUNTIME"
    fi
  fi

  if [[ -n "$SETUP_ACTION_MCP" ]]; then
    if ! setup_mcp_for_runtime "$SETUP_RUNTIME" "$SETUP_RUNTIME_DIR" "$SETUP_PROJECT_ROOT"; then
      ralph_die "Error: failed to install MCP for $SETUP_RUNTIME"
    fi
  fi
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
