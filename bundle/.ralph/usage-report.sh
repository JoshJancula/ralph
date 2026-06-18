#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
  cat <<'EOU'
Usage: usage-report.sh [OPTIONS]

Options:
  --workspace <path>                   Workspace root (default: the current directory; use --full to search $HOME).
  --logs-dir <path>                    Directory containing usage logs (may be specified multiple times).
                                        Default: <workspace>/.ralph-workspace/logs when the current
                                        directory is or directly contains a .ralph-workspace;
                                        all registered workspace logs when --full or outside any workspace.
  --format text|json                   Output format: text or json (default: text).
  --full                               Search all registered workspaces instead of the current workspace.
  -h, --help                           Show this message.
EOU
}

workspace=""
logs_dirs=()
seen_logs_dirs=$'\n'
format="text"
full=0

add_logs_dir() {
  local logs_dir="$1"
  if [[ -z "$logs_dir" || ! -d "$logs_dir" ]]; then
    return
  fi
  case "$seen_logs_dirs" in
    *$'\n'"$logs_dir"$'\n'*)
      return
      ;;
  esac
  seen_logs_dirs+="$logs_dir"$'\n'
  logs_dirs+=("$logs_dir")
}

# Detect a workspace at the current directory level only: PWD itself is a
# .ralph-workspace directory, or PWD has a .ralph-workspace child. This keeps
# `ralph usage` scoped like `.claude` / `.ralph-workspace` discovery.
find_local_logs_dir() {
  local dir="${1:-$PWD}"
  [[ -d "$dir" ]] || return 1
  dir="$(cd "$dir" && pwd)"
  local base
  base="$(basename "$dir")"
  if [[ "$base" == ".ralph-workspace" ]]; then
    printf '%s\n' "$dir/logs"
    return 0
  fi
  if [[ -d "$dir/.ralph-workspace" ]]; then
    printf '%s\n' "$dir/.ralph-workspace/logs"
    return 0
  fi
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --workspace)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --workspace requires a workspace path." >&2
        exit 1
      fi
      workspace="$2"
      shift 2
      ;;
    --logs-dir)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --logs-dir requires a directory path." >&2
        exit 1
      fi
      logs_dirs+=("$2")
      shift 2
      ;;
    --format)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --format requires text or json." >&2
        exit 1
      fi
      case "$2" in
        text|json)
          format="$2"
          ;;
        *)
          echo "Error: --format must be text or json." >&2
          exit 1
          ;;
      esac
      shift 2
      ;;
    --full)
      full=1
      shift
      ;;
    *)
      echo "Error: unknown argument $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$workspace" ]]; then
  if [[ "$full" -eq 1 ]]; then
    workspace="$HOME"
  else
    workspace="$PWD"
  fi
fi

workspace="$(cd "$workspace" && pwd)"

_registry_py="$SCRIPT_DIR/python/workspace-registry.py"

_registry_paths() {
  local registry_file
  if [[ -n "${RALPH_WORKSPACES_FILE:-}" ]]; then
    registry_file="$RALPH_WORKSPACES_FILE"
  else
    local config_home="${XDG_CONFIG_HOME:-}"
    if [[ -z "$config_home" && -n "${HOME:-}" ]]; then
      config_home="$HOME/.config"
    fi
    registry_file="$config_home/ralph/workspaces.json"
  fi
  if [[ -f "$registry_file" ]] && command -v python3 >/dev/null 2>&1; then
    python3 "$_registry_py" paths "$registry_file" 2>/dev/null
  fi
}

collect_registry_logs_dirs() {
  while IFS= read -r ws_path; do
    [[ -z "$ws_path" ]] && continue
    add_logs_dir "${ws_path}/.ralph-workspace/logs"
  done < <(_registry_paths)
}

collect_home_logs_dirs() {
  local home_dir="${HOME:-}"
  [[ -z "$home_dir" ]] && return
  while IFS= read -r ws_dir; do
    add_logs_dir "${ws_dir}/logs"
  done < <(find "$home_dir" -maxdepth 5 \
    \( -path '*/.git' -o -path '*/node_modules' \) -prune -o \
    -type d -name '.ralph-workspace' -print 2>/dev/null | sort)
}

# Build logs_dirs if none were explicitly provided.
if [[ ${#logs_dirs[@]} -eq 0 ]]; then
  _local_logs_dir=""
  if [[ "$full" -eq 0 ]]; then
    _local_logs_dir="$(find_local_logs_dir "$workspace" 2>/dev/null)" || true
  fi
  if [[ -n "$_local_logs_dir" ]]; then
    add_logs_dir "$_local_logs_dir"
  else
    collect_registry_logs_dirs
    collect_home_logs_dirs
    if [[ ${#logs_dirs[@]} -eq 0 ]]; then
      add_logs_dir "${workspace}/.ralph-workspace/logs"
    fi
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found on PATH" >&2
  exit 1
fi

logs_args=()
for d in "${logs_dirs[@]}"; do
  logs_args+=(--logs-dir "$d")
done

RALPH_USAGE_REPORT_SHOW_TOOLS=1 exec python3 "$SCRIPT_DIR/python/ralph-usage-summary-text.py" all "${logs_args[@]}" --workspace "$workspace" --format "$format"
