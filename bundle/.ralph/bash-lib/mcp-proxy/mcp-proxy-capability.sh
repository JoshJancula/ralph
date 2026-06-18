#!/usr/bin/env bash
# Runtime capability matrix for MCP proxy mode (tool replacement and related features).

if [[ -n "${RALPH_MCP_PROXY_CAPABILITY_LOADED:-}" ]]; then
  return
fi
RALPH_MCP_PROXY_CAPABILITY_LOADED=1

# Returns 0 when the runtime may expose Ralph-owned proxy tools (ralph_proxy_*) to the model.
ralph_mcp_proxy_runtime_supports_tool_replacement() {
  local runtime="${1:-${RALPH_MCP_PROXY_RUNTIME:-}}"
  case "$runtime" in
    claude|opencode)
      return 0
      ;;
    cursor|codex)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}
