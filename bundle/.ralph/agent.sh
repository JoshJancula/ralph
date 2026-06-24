#!/usr/bin/env bash
set -euo pipefail
#
# Agent CLI: ralph agent <subcommand> [args]
#
# Subcommands:
#   list [workspace] [runtime]  -- enumerate all agents across sources (with kind + model)
#   show <name> [workspace] [runtime] -- print normalized agent profile
#   new <name> [--ralph|--all] [workspace] -- scaffold a new agent
#
# The agent CLI is wired into the ralph shim via install.sh and is callable as:
#   ralph agent list
#   ralph agent show <name>
#   ralph agent new <name>

if [[ -n "${RALPH_AGENT_CLI_LOADED:-}" ]]; then
  return 0
fi
RALPH_AGENT_CLI_LOADED=1

_agent_cli_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load agent source helpers
# shellcheck source=/dev/null
source "$_agent_cli_dir/bash-lib/agent-source/resolve-source.sh"
# shellcheck source=/dev/null
source "$_agent_cli_dir/bash-lib/agent-source/frontmatter.sh"
# shellcheck source=/dev/null
source "$_agent_cli_dir/bash-lib/agent-source/adapters/adapter-classic-config.sh"
# shellcheck source=/dev/null
source "$_agent_cli_dir/bash-lib/agent-source/adapters/adapter-ralph-md.sh"
# shellcheck source=/dev/null
source "$_agent_cli_dir/bash-lib/agent-source/adapters/adapter-native-md.sh"
# shellcheck source=/dev/null
source "$_agent_cli_dir/bash-lib/runtime-normalize.sh"
# shellcheck source=/dev/null
source "$_agent_cli_dir/bash-lib/new-agent/new-agent.sh"
# shellcheck source=/dev/null
source "$_agent_cli_dir/bash-lib/new-agent/new-agent-writers.sh"
# shellcheck source=/dev/null
source "$_agent_cli_dir/bash-lib/new-agent/new-agent-helpers.sh"

agent_cli_usage() {
  cat <<'USAGE'
Usage: ralph agent <subcommand> [args]

Subcommands:
  list [workspace] [runtime]
    Enumerate all agents across all sources (ralph-workspace, ralph-install,
    native-md, classic-config). Shows kind, name, and resolved model for each.
    Surfaces shadowing (earlier sources override later ones).
    Workspace defaults to current directory.
    Runtime defaults to "claude".

  show <name> [workspace] [runtime]
    Print the normalized agent profile (as config.json shape).
    Workspace defaults to current directory.
    Runtime defaults to "claude".

  new <name> [--ralph|--all] [workspace]
    Create a new agent scaffold.
    --ralph (default): writes only the canonical .ralph/agents/<name>.md
            (or agents/agents/<name>.md if root layer exists).
            Does NOT run sync-runtime-assets.sh.
    --all: scaffold all runtime subdirs + calls sync-runtime-assets.sh
           (behavior of old .ralph/new-agent.sh).
    Workspace defaults to current directory.
USAGE
}

# List all agents across sources, deduplicating and annotating kind + model.
# Args: $1=workspace, $2=runtime (used for model resolution only)
# Output: one agent per line, tab-delimited: "name<TAB>kind<TAB>model"
agent_cli_list() {
  local workspace="${1:-.}"
  local runtime="${2:-claude}"

  if [[ ! -d "$workspace" ]]; then
    echo "Error: workspace directory not found: $workspace" >&2
    return 1
  fi

  local seen_agents
  declare -A seen_agents

  # First, enumerate ralph-workspace and ralph-install sources (runtime-agnostic)
  local sources=(
    "ralph-workspace:$workspace/.ralph-workspace/agents"
    "ralph-install:$workspace/.ralph/agents"
  )

  for source_spec in "${sources[@]}"; do
    local kind="${source_spec%%:*}"
    local dir="${source_spec#*:}"

    [[ -d "$dir" ]] || continue

    # .md files
    local md_file
    for md_file in "$dir"/*.md; do
      [[ -f "$md_file" ]] || continue
      local name
      name="$(basename "$md_file" .md)"

      if [[ -n "${seen_agents[$name]:-}" ]]; then
        continue
      fi

      local model version
      model="$(agent_source_fm_scalar "$md_file" "models.${runtime}" 2>/dev/null || true)"
      if [[ -z "$model" ]]; then
        model="$(agent_source_fm_scalar "$md_file" "model" 2>/dev/null || true)"
      fi
      version="$(agent_source_fm_scalar "$md_file" "version" 2>/dev/null || true)"
      printf '%s\t%s\t%s\t%s\n' "$name" "$kind" "${model:-}" "${version:-}"
      seen_agents[$name]=1
    done
  done

  # Then, enumerate native-md and classic-config across all runtimes
  local all_runtimes=(cursor claude codex opencode antigravity)
  for rt in "${all_runtimes[@]}"; do
    local runtime_root
    runtime_root="$(ralph_resolve_runtime_root "$rt" "$workspace" 2>/dev/null || true)"
    [[ -n "$runtime_root" ]] || continue

    # native-md: .md files
    local native_dir="$runtime_root/agents"
    if [[ -d "$native_dir" ]]; then
      local md_file
      for md_file in "$native_dir"/*.md; do
        [[ -f "$md_file" ]] || continue
        local name
        name="$(basename "$md_file" .md)"

        if [[ -n "${seen_agents[$name]:-}" ]]; then
          continue
        fi

        local model version
        model="$(agent_source_fm_scalar "$md_file" "model" 2>/dev/null || true)"
        version="$(agent_source_fm_scalar "$md_file" "version" 2>/dev/null || true)"
        printf '%s\t%s\t%s\t%s\n' "$name" "native-md" "${model:-}" "${version:-}"
        seen_agents[$name]=1
      done
    fi

    # classic-config: config.json in subdirs
    local config_base="$runtime_root/agents"
    if [[ -d "$config_base" ]]; then
      local config_file
      for config_file in "$config_base"/*/config.json; do
        [[ -f "$config_file" ]] || continue
        local name
        name="$(basename "$(dirname "$config_file")")"

        if [[ -n "${seen_agents[$name]:-}" ]]; then
          continue
        fi

        local model version
        model="$(agent_adapter_classic_config_read_model "$config_file" 2>/dev/null || true)"
        version="$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as handle:
        cfg = json.load(handle)
except Exception:
    sys.exit(0)
value = cfg.get('version')
if isinstance(value, str):
    print(value)
" "$config_file" 2>/dev/null || true)"
        printf '%s\t%s\t%s\t%s\n' "$name" "classic-config" "${model:-}" "${version:-}"
        seen_agents[$name]=1
      done
    fi
  done
}

# Print the normalized agent profile for a given name.
# Args: $1=name, $2=workspace, $3=runtime
# Output: normalized config.json
agent_cli_show() {
  local name="${1:-}"
  local workspace="${2:-.}"
  local runtime="${3:-claude}"

  if [[ -z "$name" ]]; then
    echo "Error: agent name is required" >&2
    return 1
  fi

  if [[ ! -d "$workspace" ]]; then
    echo "Error: workspace directory not found: $workspace" >&2
    return 1
  fi

  local resolved_kind resolved_path
  local resolve_rc=0
  local resolve_out
  resolve_out="$(ralph_agent_resolve_source "$name" "$runtime" "$workspace")" || resolve_rc=$?

  if [[ $resolve_rc -ne 0 ]]; then
    echo "Error: agent '$name' not found in any source" >&2
    return 1
  fi

  resolved_kind="${resolve_out%%	*}"
  resolved_path="${resolve_out#*	}"

  # Create a temp cache dir for the config.json
  local cache_dir
  cache_dir="$(mktemp -d)"
  trap 'rm -rf "$cache_dir"' EXIT

  case "$resolved_kind" in
    classic-config)
      if [[ -f "$resolved_path" ]]; then
        cat "$resolved_path"
      else
        echo "Error: classic-config path not found: $resolved_path" >&2
        return 1
      fi
      ;;

    ralph-md|ralph-install|ralph-workspace)
      local layer="bundle"
      if [[ "$resolved_kind" == "ralph-install" || "$resolved_kind" == "ralph-workspace" ]]; then
        if [[ "$resolved_path" == "$workspace/.ralph/"* || "$resolved_path" == "$workspace/.ralph-workspace/"* ]]; then
          layer="root"
        fi
      fi

      local config_path
      config_path="$(agent_adapter_ralph_md_to_config_json "$name" "$runtime" "$workspace" "$cache_dir" "$layer" "" 2>/dev/null)" || {
        echo "Error: failed to generate config for '$name'" >&2
        return 1
      }

      if [[ -f "$config_path" ]]; then
        cat "$config_path"
      else
        echo "Error: config generation produced no output" >&2
        return 1
      fi
      ;;

    native-md)
      local config_path
      config_path="$(agent_adapter_native_md_to_config_json "$name" "$runtime" "$workspace" "$cache_dir" 2>/dev/null)" || {
        echo "Error: failed to generate config for native-md agent '$name'" >&2
        return 1
      }

      if [[ -f "$config_path" ]]; then
        cat "$config_path"
      else
        echo "Error: config generation produced no output" >&2
        return 1
      fi
      ;;

    *)
      echo "Error: unknown agent kind: $resolved_kind" >&2
      return 1
      ;;
  esac
}

# Create a new agent scaffold.
# Args: $1=name, $2=--ralph|--all|empty (defaults to --ralph), $3=workspace
# Behavior:
#   --ralph (default): write only canonical .ralph/agents/<name>.md (or agents/agents/<name>.md)
#                      do NOT run sync-runtime-assets.sh
#   --all:             scaffold all runtimes + run sync
agent_cli_new() {
  local name="${1:-}"
  local flag="${2:---ralph}"
  local workspace="${3:-.}"

  if [[ -z "$name" ]]; then
    echo "Error: agent name is required" >&2
    return 1
  fi

  if ! new_agent_is_valid_id "$name"; then
    echo "Error: agent name must be lowercase with hyphens only" >&2
    return 1
  fi

  if [[ ! -d "$workspace" ]]; then
    echo "Error: workspace directory not found: $workspace" >&2
    return 1
  fi

  # Normalize flag
  case "${flag}" in
    --ralph)
      # Default: canonical-only
      _agent_cli_new_ralph_only "$name" "$workspace"
      ;;
    --all)
      # Full scaffold with sync
      _agent_cli_new_all_runtimes "$name" "$workspace"
      ;;
    *)
      echo "Error: unknown flag: $flag (use --ralph or --all)" >&2
      return 1
      ;;
  esac
}

# Write the canonical .md only (no sync).
# Uses the canonical markdown template.
_agent_cli_new_ralph_only() {
  local name="$1"
  local workspace="$2"

  local canonical_dir
  if [[ -d "$workspace/agents/agents" ]]; then
    canonical_dir="$workspace/agents/agents"
  else
    canonical_dir="$workspace/.ralph/agents"
  fi

  mkdir -p "$canonical_dir"

  local canonical_file="$canonical_dir/$name.md"

  if [[ -f "$canonical_file" ]]; then
    echo "Error: agent already exists at $canonical_file" >&2
    return 1
  fi

  # Generate canonical markdown with basic frontmatter
  cat >"$canonical_file" <<EOF
---
description: "Agent description for $name"
models:
  claude: ""
  cursor: ""
  codex: ""
  opencode: ""
  antigravity: ""
rules:
  - no-emoji
  - efficient-tool-usage
skills:
  - repo-context
output_artifacts:
  - ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$name.md|required"
mcp_servers: []
---

## Role
You are the $name agent.

## Constraints
- Plain ASCII only; no emoji.
- Read-only: use Read, Grep, Glob, and read-only tools; no builds or tests unless the plan explicitly requests them.

## Deliverable
\`.ralph-workspace/artifacts/{{ARTIFACT_NS}}/$name.md\` -- the requested output.
EOF

  echo "Created: $canonical_file"
}

# Write canonical + all runtime scaffolds, then run sync.
_agent_cli_new_all_runtimes() {
  local name="$1"
  local workspace="$2"

  local canonical_dir
  if [[ -d "$workspace/agents/agents" ]]; then
    canonical_dir="$workspace/agents/agents"
  else
    canonical_dir="$workspace/.ralph/agents"
  fi

  mkdir -p "$canonical_dir"

  local canonical_file="$canonical_dir/$name.md"

  if [[ -f "$canonical_file" ]]; then
    echo "Error: agent already exists at $canonical_file" >&2
    return 1
  fi

  # Generate canonical markdown
  cat >"$canonical_file" <<EOF
---
description: "Agent description for $name"
models:
  claude: ""
  cursor: ""
  codex: ""
  opencode: ""
  antigravity: ""
rules:
  - no-emoji
  - efficient-tool-usage
skills:
  - repo-context
output_artifacts:
  - ".ralph-workspace/artifacts/{{ARTIFACT_NS}}/$name.md|required"
mcp_servers: []
---

## Role
You are the $name agent.

## Constraints
- Plain ASCII only; no emoji.
- Read-only: use Read, Grep, Glob, and read-only tools; no builds or tests unless the plan explicitly requests them.

## Deliverable
\`.ralph-workspace/artifacts/{{ARTIFACT_NS}}/$name.md\` -- the requested output.
EOF

  echo "Created: $canonical_file"

  # Create per-runtime scaffolds
  local runtimes=(cursor claude codex opencode antigravity)
  for runtime in "${runtimes[@]}"; do
    local runtime_dir
    runtime_dir="$(ralph_runtime_config_dirname "$runtime")"
    local base_dir="$workspace/$runtime_dir/agents"

    mkdir -p "$base_dir/$name"

    # Write agent markdown
    local rule_ext
    [[ "$runtime" == "cursor" ]] && rule_ext=".mdc" || rule_ext=".md"

    local template="${workspace}/$runtime_dir/agents/${name}${rule_ext}"
    write_agent_scaffold "$runtime" "$name" "Agent description for $name" "" "$base_dir" "$rule_ext"

    echo "Created: $base_dir/$name/ (config.json + ${name}${rule_ext})"
  done

  # Run sync if available
  local sync_script="$workspace/.ralph/scripts/sync-runtime-assets.sh"
  if [[ -f "$sync_script" ]]; then
    echo "Running sync-runtime-assets.sh..."
    bash "$sync_script" || {
      echo "Warning: sync-runtime-assets.sh failed, but agents are scaffolded" >&2
    }
  fi
}

# Entry point: parse subcommand and dispatch
agent_cli_main() {
  local subcommand="${1:-}"

  case "${subcommand}" in
    list)
      agent_cli_list "${2:-.}" "${3:-claude}"
      ;;
    show)
      agent_cli_show "${2:-}" "${3:-.}" "${4:-claude}"
      ;;
    new)
      agent_cli_new "${2:-}" "${3:---ralph}" "${4:-.}"
      ;;
    --help|-h|help)
      agent_cli_usage
      exit 0
      ;;
    *)
      if [[ -n "$subcommand" ]]; then
        echo "Error: unknown subcommand: $subcommand" >&2
      fi
      agent_cli_usage >&2
      exit 1
      ;;
  esac
}

# Allow both sourcing and direct execution
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  agent_cli_main "$@"
fi
