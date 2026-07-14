#!/usr/bin/env bash
#
# Setup a runtime directory with durable Ralph compaction hooks and MCP configuration.
#
# Usage:
#   ralph setup --runtime <claude|cursor|codex|opencode|antigravity|agy> [--runtime-dir <path>] [--hooks] [--mcp] [--all] [--dry-run] [--yes]
#
# Options:
#   --runtime <name>      Runtime to configure (claude, cursor, codex, opencode, antigravity; agy aliases antigravity)
#   --runtime-dir <path>  Path to the runtime directory (default: $PWD/.$runtime, $PWD/.agents for antigravity)
#                         Use ~/.claude, ~/.cursor, ~/.codex, ~/.opencode, or ~/.agents for user-home installs.
#   --hooks               Install durable Ralph compaction/native hooks for normal runtime sessions
#   --mcp                 Install MCP configuration for the runtime
#   --all                 Install both hooks and MCP (equivalent to --hooks --mcp)
#   --dry-run             Show what would be done without making changes
#   --yes                 Skip confirmation prompts, including runtime-dir basename mismatch
#   --help                Show this help message
#
# Constraints:
#   - At least one of --hooks, --mcp, or --all must be specified.
#   - Default --runtime-dir is "$PWD/.$runtime" (antigravity uses "$PWD/.agents").
#   - Runtime-dir basename must match the selected runtime unless --yes is provided.

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

# Valid runtimes
VALID_RUNTIMES=(claude cursor codex opencode antigravity)

# Globals set by argument parsing
SETUP_RUNTIME=""
SETUP_RUNTIME_DIR=""
SETUP_ACTION_HOOKS=""
SETUP_ACTION_MCP=""
SETUP_DRY_RUN=""
SETUP_YES=""
SETUP_PROJECT_ROOT=""

print_help() {
  cat << 'EOF'
Usage: ralph setup --runtime <claude|cursor|codex|opencode|antigravity|agy> [--runtime-dir <path>] [--hooks] [--mcp] [--all] [--dry-run] [--yes]

Configure a runtime directory with durable Ralph compaction hooks and MCP tools.

Options:
  --runtime <name>      Runtime to configure (claude, cursor, codex, opencode, antigravity; agy aliases antigravity)
  --runtime-dir <path>  Path to the runtime directory (default: $PWD/.$runtime, $PWD/.agents for antigravity)
                        Use ~/.claude, ~/.cursor, ~/.codex, ~/.opencode, or ~/.agents for user-home installs.
  --hooks               Install durable Ralph compaction/native hooks for normal runtime sessions
  --mcp                 Install MCP configuration for the runtime
  --all                 Install both hooks and MCP (equivalent to --hooks --mcp)
  --dry-run             Show what would be done without making changes
  --yes                 Skip confirmation prompts, including runtime-dir basename mismatch
  --help                Show this help message

Constraints:
  - At least one of --hooks, --mcp, or --all must be specified.
  - Default --runtime-dir is "$PWD/.$runtime" (antigravity uses "$PWD/.agents").
  - Runtime-dir basename must match the selected runtime config dir unless --yes is provided.

Examples:
  ralph setup --runtime claude --runtime-dir ~/.claude --hooks
  ralph setup --runtime cursor --runtime-dir /path/to/project/.cursor --hooks
  ralph setup --runtime codex --runtime-dir ~/.codex --hooks
  ralph setup --runtime claude --hooks --mcp
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
  SETUP_DRY_RUN=""
  SETUP_YES=""

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
        SETUP_ACTION_HOOKS="1"
        shift
        ;;
      --mcp)
        SETUP_ACTION_MCP="1"
        shift
        ;;
      --all)
        SETUP_ACTION_HOOKS="1"
        SETUP_ACTION_MCP="1"
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

  # Validate runtime-dir basename matches runtime (unless --yes)
  validate_runtime_dir_basename "$SETUP_RUNTIME" "$SETUP_RUNTIME_DIR" "$SETUP_YES"

  # Validate at least one action is specified
  if [[ -z "$SETUP_ACTION_HOOKS" && -z "$SETUP_ACTION_MCP" ]]; then
    ralph_die "Error: At least one of --hooks, --mcp, or --all is required"
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
  printf 'Setting up %s runtime\n' "$SETUP_RUNTIME"
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
