#!/usr/bin/env bash
set -euo pipefail

_workspaces_cli_dir="${BASH_SOURCE[0]%/*}"
[[ "$_workspaces_cli_dir" == "${BASH_SOURCE[0]}" ]] && _workspaces_cli_dir="."
_workspaces_registry_py="$_workspaces_cli_dir/../python/workspace-registry.py"
# shellcheck source=help-render.sh
source "$_workspaces_cli_dir/help-render.sh"

workspaces_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph workspaces <command> [args]

Commands:
  list          Print the workspace registry as a table
  prune         Drop missing or stale workspaces
  add <path>    Add a workspace path manually

Environment:
  RALPH_WORKSPACES_FILE           Override the registry file path
  RALPH_WORKSPACE_PRUNE_DAYS=60   Age cutoff for prune
USAGE
}

workspaces_registry_file() {
  if [[ -n "${RALPH_WORKSPACES_FILE:-}" ]]; then
    printf '%s\n' "$RALPH_WORKSPACES_FILE"
    return 0
  fi

  local config_home="${XDG_CONFIG_HOME:-}"
  if [[ -z "$config_home" && -n "${HOME:-}" ]]; then
    config_home="$HOME/.config"
  fi
  if [[ -z "$config_home" ]]; then
    echo "Error: HOME or XDG_CONFIG_HOME must be set to locate the Ralph workspace registry." >&2
    return 1
  fi
  printf '%s\n' "$config_home/ralph/workspaces.json"
}

workspaces_require_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for ralph workspaces." >&2
    return 1
  fi
  if [[ ! -f "$_workspaces_registry_py" ]]; then
    echo "Error: workspace registry helper missing: $_workspaces_registry_py" >&2
    return 1
  fi
}

cmd="${1:-list}"
case "$cmd" in
  -h|--help|help)
    workspaces_usage
    exit 0
    ;;
esac
shift || true

workspaces_require_python
registry_file="$(workspaces_registry_file)"

case "$cmd" in
  list)
    [[ $# -eq 0 ]] || { echo "Error: list does not accept arguments." >&2; exit 2; }
    exec python3 "$_workspaces_registry_py" list "$registry_file"
    ;;
  prune)
    [[ $# -eq 0 ]] || { echo "Error: prune does not accept arguments." >&2; exit 2; }
    days="${RALPH_WORKSPACE_PRUNE_DAYS:-60}"
    if [[ ! "$days" =~ ^[0-9]+$ ]]; then
      echo "Error: RALPH_WORKSPACE_PRUNE_DAYS must be a non-negative integer." >&2
      exit 2
    fi
    exec python3 "$_workspaces_registry_py" prune "$registry_file" "$days"
    ;;
  add)
    [[ $# -eq 1 ]] || { echo "Error: add requires exactly one workspace path." >&2; exit 2; }
    exec python3 "$_workspaces_registry_py" add "$registry_file" "$1"
    ;;
  *)
    echo "Error: unknown workspaces command: $cmd" >&2
    workspaces_usage >&2
    exit 2
    ;;
esac
