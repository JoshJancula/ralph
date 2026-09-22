#!/usr/bin/env bash
set -euo pipefail

_workspaces_cli_dir="${BASH_SOURCE[0]%/*}"
[[ "$_workspaces_cli_dir" == "${BASH_SOURCE[0]}" ]] && _workspaces_cli_dir="."
_workspaces_registry_py="$_workspaces_cli_dir/../python/workspace-registry.py"
# shellcheck source=help-render.sh
source "$_workspaces_cli_dir/help-render.sh"

workspaces_usage() {
  cat <<'USAGE' | ralph_help_render
Usage: ralph workspaces <command> [args]      (alias: ralph ws)

Two different things are called "workspace" here:
  - the registry: a global list of projects Ralph has run in
    (~/.config/ralph/workspaces.json), used by the dashboard
  - .ralph-workspace/: the per-project directory holding logs, runs, and state

Manage a project's .ralph-workspace/ (path defaults to the current directory):
  status [path]         Show disk usage and stuck runs
  doctor [path] [--fix] Find (and with --fix repair) stuck runs and stale overlays
  clean  [path]         Preview reclaiming disk space; add --yes to delete,
                        --older-than DAYS / --keep N to tune, --all to wipe it

Manage the global registry:
  list                  Print the registry as a table
  add <path>            Add a project to the registry manually
  prune [--dry-run]     Remove registry entries whose directory no longer exists
                        or that were not used in the last 60 days. Does NOT
                        delete any project files; use `clean` for that.

Typical cleanup:
  ralph ws status
  ralph ws doctor --fix
  ralph ws clean --yes

Environment:
  RALPH_WORKSPACES_FILE           Override the registry file path
  RALPH_WORKSPACE_PRUNE_DAYS=60   Registry prune age cutoff
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

case "$cmd" in
  status|doctor|clean)
    # shellcheck source=workspaces-data.sh
    source "$_workspaces_cli_dir/workspaces-data.sh"
    "ws_data_$cmd" "$@"
    exit $?
    ;;
esac

workspaces_require_python
registry_file="$(workspaces_registry_file)"

case "$cmd" in
  list)
    [[ $# -eq 0 ]] || { echo "Error: list does not accept arguments." >&2; exit 2; }
    exec python3 "$_workspaces_registry_py" list "$registry_file"
    ;;
  prune)
    dry_run=0
    if [[ "${1:-}" == "--dry-run" ]]; then dry_run=1; shift; fi
    [[ $# -eq 0 ]] || { echo "Error: prune accepts only --dry-run." >&2; exit 2; }
    days="${RALPH_WORKSPACE_PRUNE_DAYS:-60}"
    if [[ ! "$days" =~ ^[0-9]+$ ]]; then
      echo "Error: RALPH_WORKSPACE_PRUNE_DAYS must be a non-negative integer." >&2
      exit 2
    fi
    if [[ "$dry_run" -eq 1 ]]; then
      exec python3 "$_workspaces_registry_py" prune "$registry_file" "$days" --dry-run
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
