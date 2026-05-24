#!/usr/bin/env bash
set -euo pipefail

_migrate_script_dir="${BASH_SOURCE[0]%/*}"
[[ "$_migrate_script_dir" == "${BASH_SOURCE[0]}" ]] && _migrate_script_dir="."

source "$_migrate_script_dir/bash-lib/ui-prompt.sh"

migrate_usage() {
  cat <<'USAGE'
Usage: migrate-to-global.sh [OPTIONS] <project-path> [<project-path> ...]

Migrate project-local Ralph installs to global mode by registering projects
in the workspace registry and optionally removing local Ralph files.

Options:
  --dry-run             Show what would be done without making changes
  --yes                 Skip confirmation prompts and remove files
  -h, --help            Show this help message

Environment:
  RALPH_WORKSPACES_FILE     Override the registry file path
  HOME                      Used to resolve config directory if XDG_CONFIG_HOME is unset

Each project will be:
  1. Validated to exist and contain a .ralph/ directory or .<runtime>/ directories
  2. Registered in the workspace registry
  3. Optionally have local .ralph/ and .<runtime>/ directories removed
     (with confirmation unless --yes is passed or --dry-run is used)

USAGE
}

migrate_registry_file() {
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

migrate_add_to_registry() {
  local registry_file="$1"
  local project_path="$2"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 not available; skipping registry update for $project_path" >&2
    return 1
  fi

  local py_helper="$_migrate_script_dir/bash-lib/workspace-registry.py"
  if [[ ! -f "$py_helper" ]]; then
    echo "Warning: workspace registry helper not found; skipping registry update for $project_path" >&2
    return 1
  fi

  python3 "$py_helper" add "$registry_file" "$project_path" 2>/dev/null || true
}

migrate_project() {
  local project_path="$1"
  local dry_run="$2"
  local auto_yes="$3"
  local registry_file="$4"

  local project_abs
  project_abs="$(cd "$project_path" 2>/dev/null && pwd)" || {
    echo "Error: project path does not exist: $project_path"
    return 1
  }

  if [[ ! -d "$project_abs" ]]; then
    echo "Error: not a directory: $project_abs"
    return 1
  fi

  local has_ralph=0
  local has_runtime=0
  if [[ -d "$project_abs/.ralph" ]]; then
    has_ralph=1
  fi

  for runtime in cursor claude codex opencode; do
    if [[ -d "$project_abs/.$runtime" ]]; then
      has_runtime=1
      break
    fi
  done

  if [[ "$has_ralph" -eq 0 && "$has_runtime" -eq 0 ]]; then
    echo "Warning: $project_abs has no .ralph/ or .<runtime>/ directories; skipping"
    return 1
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    echo "Would register: $project_abs"
    if [[ "$has_ralph" -eq 1 ]]; then
      echo "  Would remove: .ralph/"
    fi
    if [[ "$has_runtime" -eq 1 ]]; then
      for runtime in cursor claude codex opencode; do
        if [[ -d "$project_abs/.$runtime" ]]; then
          echo "  Would remove: .$runtime/"
        fi
      done
    fi
    return 0
  fi

  echo "Processing: $project_abs"

  migrate_add_to_registry "$registry_file" "$project_abs"
  echo "  Registered in workspace registry"

  local dirs_to_remove=()
  if [[ "$has_ralph" -eq 1 ]]; then
    dirs_to_remove+=(".ralph")
  fi
  for runtime in cursor claude codex opencode; do
    if [[ -d "$project_abs/.$runtime" ]]; then
      dirs_to_remove+=(".$runtime")
    fi
  done

  if [[ ${#dirs_to_remove[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ "$auto_yes" -eq 0 ]]; then
    echo ""
    local prompt_msg="Remove local Ralph directories from $(basename "$project_abs")?"
    local response
    response="$(ralph_prompt_yesno "$prompt_msg" "n")"
    if [[ "$response" != "y" ]]; then
      echo "  Skipped directory removal"
      return 0
    fi
  fi

  for dir in "${dirs_to_remove[@]}"; do
    rm -rf "$project_abs/$dir"
    echo "  Removed: $dir/"
  done
}

main() {
  local dry_run=0
  local auto_yes=0
  local projects=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        migrate_usage
        return 0
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --yes)
        auto_yes=1
        shift
        ;;
      -*)
        echo "Error: unknown option: $1" >&2
        migrate_usage >&2
        return 2
        ;;
      *)
        projects+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#projects[@]} -eq 0 ]]; then
    echo "Error: at least one project path is required" >&2
    migrate_usage >&2
    return 2
  fi

  local registry_file
  registry_file="$(migrate_registry_file)" || return 1

  echo "Ralph Global Install Migration"
  if [[ "$dry_run" -eq 1 ]]; then
    echo "Mode: DRY RUN (no changes will be made)"
  fi
  echo ""

  local success=0
  local failed=0
  for project in "${projects[@]}"; do
    if migrate_project "$project" "$dry_run" "$auto_yes" "$registry_file"; then
      ((success++))
    else
      ((failed++))
    fi
    echo ""
  done

  echo "Summary:"
  echo "  Processed: $((success + failed))"
  echo "  Successful: $success"
  if [[ "$failed" -gt 0 ]]; then
    echo "  Failed: $failed"
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    echo ""
    echo "Dry-run complete. Run without --dry-run to apply changes."
  fi

  return 0
}

main "$@"
