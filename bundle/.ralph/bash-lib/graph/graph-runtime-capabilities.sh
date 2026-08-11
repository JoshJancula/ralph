#!/usr/bin/env bash
# Fail-closed runtime capabilities used by graph admission. A runtime may use
# more than one same-runtime slot only when every Ralph-owned configuration
# overlay is invocation-local (or the runtime project root is independently
# isolated). Snapshot/worktree agent workspaces do not satisfy that proof.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is meant to be sourced, not executed." >&2
  exit 1
fi

if [[ -n "${GRAPH_RUNTIME_CAPABILITIES_LOADED:-}" ]]; then
  return 0
fi
GRAPH_RUNTIME_CAPABILITIES_LOADED=1

graph_runtime_same_runtime_parallel_safe() {
  case "${1:-}" in
    # These adapters pass Ralph-owned MCP/config additions through a unique
    # temporary file or per-invocation CLI overrides. Ambient user/project
    # configuration is read, never rewritten.
    claude|codex|opencode|antigravity) return 0 ;;
    # Cursor currently installs and restores <project>/.cursor/mcp.json.
    # Node agent-workspace isolation does not isolate that project-root file.
    cursor|*) return 1 ;;
  esac
}

graph_runtime_same_runtime_parallel_safe_json() {
  if graph_runtime_same_runtime_parallel_safe "$1"; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

graph_runtime_overlay_isolation() {
  case "${1:-}" in
    claude) printf 'temporary-cli-config\n' ;;
    codex) printf 'temporary-cli-overrides\n' ;;
    opencode) printf 'temporary-env-config\n' ;;
    antigravity) printf 'temporary-env-config\n' ;;
    cursor) printf 'project-root-overlay-journal\n' ;;
    *) printf 'unproven\n' ;;
  esac
}
