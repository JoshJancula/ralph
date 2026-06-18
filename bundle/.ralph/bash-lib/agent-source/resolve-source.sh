#!/usr/bin/env bash
#
# Resolve the source file for a named agent across probe locations.
#
# Public interface:
#   ralph_agent_resolve_source <name> <runtime> <workspace>
#     Prints "kind<TAB>path" for the first matching probe and exits 0.
#     Exits non-zero when nothing matches.
#
# Probe order (default RALPH_AGENT_SOURCE_ORDER):
#   ralph-workspace  .ralph-workspace/agents/<name>.md
#   ralph-install    .ralph/agents/<name>.md (then bundle fallback)
#   native-md        <RUNTIME_ROOT>/agents/<name>.md
#   classic-config   <RUNTIME_ROOT>/agents/<name>/config.json
#
# Override:
#   RALPH_AGENT_SOURCE -- explicit path that wins over all probes
#   --agent-source <path> -- CLI equivalent of RALPH_AGENT_SOURCE
#   RALPH_AGENT_SOURCE_ORDER -- comma-separated probe order override

if [[ -n "${RALPH_AGENT_SOURCE_RESOLVE_LOADED:-}" ]]; then
  return 0
fi
RALPH_AGENT_SOURCE_RESOLVE_LOADED=1

if ! declare -F ralph_resolve_runtime_root >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../runtime-resolve.sh"
fi

ralph_agent_resolve_source() {
  local name="${1:-}"
  local runtime="${2:-}"
  local workspace="${3:-}"

  if [[ -z "$name" ]]; then
    echo "Error: agent name is required" >&2
    return 2
  fi

  if [[ -z "$runtime" ]]; then
    echo "Error: runtime is required" >&2
    return 2
  fi

  if [[ -z "$workspace" ]]; then
    echo "Error: workspace is required" >&2
    return 2
  fi

  local explicit_source="${RALPH_AGENT_SOURCE:-}"
  if [[ -n "$explicit_source" ]]; then
    if [[ -r "$explicit_source" ]]; then
      printf 'explicit\t%s\n' "$explicit_source"
      return 0
    fi
    echo "Error: RALPH_AGENT_SOURCE=$explicit_source is not readable" >&2
    return 1
  fi

  local default_order="ralph-workspace,ralph-install,native-md,classic-config"
  local order="${RALPH_AGENT_SOURCE_ORDER:-$default_order}"

  local runtime_root
  runtime_root="$(ralph_resolve_runtime_root "$runtime" "$workspace" 2>/dev/null)" || runtime_root=""

  local probe kind path bundle_path

  local IFS=','
  for probe in $order; do
    kind=""
    path=""
    case "$probe" in
      ralph-workspace)
        kind="ralph-workspace"
        path="$workspace/.ralph-workspace/agents/$name.md"
        ;;
      ralph-install)
        kind="ralph-install"
        path="$workspace/.ralph/agents/$name.md"
        if [[ -r "$path" ]]; then
          printf '%s\t%s\n' "$kind" "$path"
          return 0
        fi
        bundle_path="${RALPH_HOME:-$HOME/.ralph}/bundle/.ralph/agents/$name.md"
        if [[ -r "$bundle_path" ]]; then
          printf '%s\t%s\n' "$kind" "$bundle_path"
          return 0
        fi
        continue
        ;;
      native-md)
        kind="native-md"
        if [[ -n "$runtime_root" ]]; then
          path="$runtime_root/agents/$name.md"
        else
          continue
        fi
        ;;
      classic-config)
        kind="classic-config"
        if [[ -n "$runtime_root" ]]; then
          path="$runtime_root/agents/$name/config.json"
        else
          continue
        fi
        ;;
      *)
        echo "Warning: unknown probe '$probe' in RALPH_AGENT_SOURCE_ORDER" >&2
        continue
        ;;
    esac

    if [[ -n "$path" && -r "$path" ]]; then
      printf '%s\t%s\n' "$kind" "$path"
      return 0
    fi
  done

  echo "Error: no agent source found for '$name' (runtime=$runtime)" >&2
  return 1
}