#!/usr/bin/env bash
set -euo pipefail

_killswitch_cli_dir="${BASH_SOURCE[0]%/*}"
[[ "$_killswitch_cli_dir" == "${BASH_SOURCE[0]}" ]] && _killswitch_cli_dir="."

RALPH_HOME="${RALPH_HOME:-${HOME:-}/.ralph}"

killswitch_cli_usage() {
  cat <<'USAGE'
Usage: ralph config killswitch [command] [options]

Manage killswitch.json for blocking dangerous commands, tools, and paths.
The first matching file wins: workspace, then global, then bundle default.

Commands:
  status              Show active source and config paths (default)
  init                Copy the bundle default to workspace and/or global
  edit                Open a config file in $EDITOR

Options:
  --workspace <path>  Project root (default: current directory)
  --global            Target the global config ($RALPH_HOME/killswitch.json)
  --force             Overwrite an existing file on init
  --both              Init both workspace and global configs (init only)

Examples:
  ralph config killswitch
  ralph config killswitch init
  ralph config killswitch init --global
  ralph config killswitch edit --global

See docs/SECURITY.md for the configuration reference.
USAGE
}

killswitch_cli_bundle_default() {
  printf '%s/bundle/.ralph/killswitch.json\n' "$RALPH_HOME"
}

killswitch_cli_workspace_root() {
  local workspace="${1:-}"
  if [[ -z "$workspace" ]]; then
    workspace="$PWD"
  fi
  if [[ ! -d "$workspace" ]]; then
    echo "Error: workspace is not a directory: $workspace" >&2
    return 1
  fi
  cd "$workspace" && pwd
}

killswitch_cli_workspace_config() {
  printf '%s/.ralph-workspace/killswitch.json\n' "$1"
}

killswitch_cli_global_config() {
  printf '%s/killswitch.json\n' "$RALPH_HOME"
}

killswitch_cli_resolve_active() {
  local workspace="$1"
  local ws_cfg global_cfg bundle_cfg
  ws_cfg="$(killswitch_cli_workspace_config "$workspace")"
  global_cfg="$(killswitch_cli_global_config)"
  bundle_cfg="$(killswitch_cli_bundle_default)"

  if [[ -f "$ws_cfg" ]]; then
    printf 'workspace\t%s\n' "$ws_cfg"
  elif [[ -f "$global_cfg" ]]; then
    printf 'global\t%s\n' "$global_cfg"
  elif [[ -f "$bundle_cfg" ]]; then
    printf 'bundle\t%s\n' "$bundle_cfg"
  else
    printf 'none\t\n'
  fi
}

killswitch_cli_read_summary() {
  local config_file="$1"
  if [[ ! -f "$config_file" ]]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf '  (install python3 to show enabled/dry_run summary)\n'
    return 0
  fi
  python3 - "$config_file" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path) as fh:
        cfg = json.load(fh)
except Exception as exc:
    print(f"  (could not parse config: {exc})")
    raise SystemExit(0)

print(f"  enabled: {str(cfg.get('enabled', True)).lower()}")
print(f"  dry_run: {str(cfg.get('dry_run', False)).lower()}")
print(f"  banned_tools: {len(cfg.get('banned_tools', []))}")
print(f"  banned_paths: {len(cfg.get('banned_paths', []))}")
print(f"  custom_rules: {len(cfg.get('custom_rules', []))}")
PY
}

killswitch_cli_status() {
  local workspace="$1"
  local active_source active_path
  local ws_cfg global_cfg bundle_cfg
  ws_cfg="$(killswitch_cli_workspace_config "$workspace")"
  global_cfg="$(killswitch_cli_global_config)"
  bundle_cfg="$(killswitch_cli_bundle_default)"

  IFS=$'\t' read -r active_source active_path <<< "$(killswitch_cli_resolve_active "$workspace")"

  echo "Killswitch configuration"
  echo
  if [[ "$active_source" == "none" ]]; then
    echo "Active source: (none found; killswitch config is not loaded)"
  else
    echo "Active source: $active_source"
    echo "  path: $active_path"
    killswitch_cli_read_summary "$active_path"
  fi
  echo
  echo "Config paths (first match wins):"
  if [[ -f "$ws_cfg" ]]; then
    echo "  workspace: $ws_cfg"
  else
    echo "  workspace: $ws_cfg  (not present; run: ralph config killswitch init)"
  fi
  if [[ -f "$global_cfg" ]]; then
    echo "  global:    $global_cfg"
  else
    echo "  global:    $global_cfg  (not present; run: ralph config killswitch init --global)"
  fi
  echo "  bundle:    $bundle_cfg"
  echo
  echo "Customize:"
  echo "  ralph config killswitch init              # per-project (gitignored under .ralph-workspace/)"
  echo "  ralph config killswitch init --global     # all projects (under \$RALPH_HOME)"
  echo "  ralph config killswitch edit              # edit workspace config"
  echo "  ralph config killswitch edit --global     # edit global config"
}

killswitch_cli_copy_template() {
  local dest="$1"
  local force="$2"
  local template
  template="$(killswitch_cli_bundle_default)"

  if [[ ! -f "$template" ]]; then
    echo "Error: bundle default not found: $template" >&2
    echo "Is RALPH_HOME set correctly? Current: $RALPH_HOME" >&2
    return 1
  fi

  if [[ -f "$dest" && "$force" -ne 1 ]]; then
    echo "Error: config already exists: $dest" >&2
    echo "Use --force to overwrite, or ralph config killswitch edit to change it." >&2
    return 1
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$template" "$dest"
  echo "Created $dest"
}

killswitch_cli_init() {
  local workspace="$1"
  local init_workspace=0
  local init_global=0
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace)
        [[ -n "${2:-}" ]] || { echo "Error: --workspace requires a path." >&2; return 2; }
        workspace="$(killswitch_cli_workspace_root "$2")" || return 1
        shift 2
        ;;
      --global)
        init_global=1
        shift
        ;;
      --both)
        init_workspace=1
        init_global=1
        shift
        ;;
      --force)
        force=1
        shift
        ;;
      *)
        echo "Error: unknown init option: $1" >&2
        return 2
        ;;
    esac
  done

  if [[ "$init_workspace" -eq 0 && "$init_global" -eq 0 ]]; then
    init_workspace=1
  fi

  local created=0
  if [[ "$init_workspace" -eq 1 ]]; then
    killswitch_cli_copy_template "$(killswitch_cli_workspace_config "$workspace")" "$force"
    created=1
  fi
  if [[ "$init_global" -eq 1 ]]; then
    killswitch_cli_copy_template "$(killswitch_cli_global_config)" "$force"
    created=1
  fi

  if [[ "$created" -eq 1 ]]; then
    echo
    echo "Next: edit the file(s) above, then run 'ralph config killswitch' to verify the active source."
  fi
}

killswitch_cli_edit() {
  local workspace="$1"
  local target_global=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspace)
        [[ -n "${2:-}" ]] || { echo "Error: --workspace requires a path." >&2; return 2; }
        workspace="$(killswitch_cli_workspace_root "$2")" || return 1
        shift 2
        ;;
      --global)
        target_global=1
        shift
        ;;
      *)
        echo "Error: unknown edit option: $1" >&2
        return 2
        ;;
    esac
  done

  local config_file
  if [[ "$target_global" -eq 1 ]]; then
    config_file="$(killswitch_cli_global_config)"
  else
    config_file="$(killswitch_cli_workspace_config "$workspace")"
  fi

  if [[ ! -f "$config_file" ]]; then
    echo "Error: config not found: $config_file" >&2
    if [[ "$target_global" -eq 1 ]]; then
      echo "Run: ralph config killswitch init --global" >&2
    else
      echo "Run: ralph config killswitch init" >&2
    fi
    return 1
  fi

  local editor="${EDITOR:-${VISUAL:-vi}}"
  echo "Opening $config_file with $editor"
  exec "$editor" "$config_file"
}

cmd="${1:-status}"
if [[ "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  killswitch_cli_usage
  exit 0
fi
shift || true

workspace="$PWD"
force_global=0
init_both=0
init_force=0
passthrough=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      [[ -n "${2:-}" ]] || { echo "Error: --workspace requires a path." >&2; exit 2; }
      workspace="$(killswitch_cli_workspace_root "$2")" || exit 1
      shift 2
      ;;
    --global)
      force_global=1
      shift
      ;;
    --both)
      init_both=1
      shift
      ;;
    --force)
      init_force=1
      shift
      ;;
    *)
      passthrough+=("$1")
      shift
      ;;
  esac
done

case "$cmd" in
  status)
    [[ ${#passthrough[@]} -eq 0 ]] || { echo "Error: status does not accept extra arguments." >&2; exit 2; }
    killswitch_cli_status "$workspace"
    ;;
  init)
    init_args=(--workspace "$workspace")
    [[ "$force_global" -eq 1 ]] && init_args+=(--global)
    [[ "$init_both" -eq 1 ]] && init_args+=(--both)
    [[ "$init_force" -eq 1 ]] && init_args+=(--force)
    init_args+=("${passthrough[@]}")
    killswitch_cli_init "${init_args[@]}"
    ;;
  edit)
    edit_args=(--workspace "$workspace")
    [[ "$force_global" -eq 1 ]] && edit_args+=(--global)
    edit_args+=("${passthrough[@]}")
    killswitch_cli_edit "${edit_args[@]}"
    ;;
  *)
    echo "Error: unknown ralph config killswitch command: $cmd" >&2
    killswitch_cli_usage >&2
    exit 2
    ;;
esac
