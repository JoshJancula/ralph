#!/usr/bin/env bash
set -euo pipefail
#
# MCP server configuration for Cursor, Claude, and Codex.
#
# Public interface:
#   install_configure_mcp -- prompt and configure MCP servers for installed runtimes.

install_mcp_source_setup_libs() {
  if [[ -n "${RALPH_INSTALL_MCP_SETUP_LOADED:-}" ]]; then
    return 0
  fi
  RALPH_INSTALL_MCP_SETUP_LOADED=1
  # RALPH_BASH_LIB is set by install.sh before this file is sourced.
  source "$RALPH_BASH_LIB/setup/setup-helpers.sh"
  source "$RALPH_BASH_LIB/setup/setup-mcp.sh"
}

install_mcp_configure_runtime() {
  local runtime="$1"
  local runtime_dir="$2"
  local project_root="$3"
  local target=""
  local saved_setup_dry_run="${SETUP_DRY_RUN:-}"

  install_mcp_source_setup_libs

  case "$runtime" in
    cursor)
      target="$runtime_dir/mcp.json"
      ;;
    claude)
      target="$project_root/.mcp.json"
      ;;
    codex)
      target="$runtime_dir/config.toml"
      ;;
    *)
      install_log_warn "Warning: MCP setup is not implemented for runtime $runtime; skipping."
      return 0
      ;;
  esac

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    SETUP_DRY_RUN=1
    export SETUP_DRY_RUN
  fi

  if setup_mcp_for_runtime "$runtime" "$runtime_dir" "$project_root"; then
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      install_log_dry "[dry-run]" "would configure MCP for $runtime at $target"
    else
      install_log_ok "Configured MCP" "$target"
    fi
  else
    install_log_warn "Warning: MCP setup for $runtime failed; skipping."
  fi

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    if [[ -n "$saved_setup_dry_run" ]]; then
      SETUP_DRY_RUN="$saved_setup_dry_run"
      export SETUP_DRY_RUN
    else
      unset SETUP_DRY_RUN
    fi
  fi

  return 0
}

install_configure_mcp() {
  if [[ "${SILENT:-0}" -eq 1 ]]; then
    return 0
  fi

  local answer
  printf '%b\n' "${C_C}${C_BOLD}MCP${C_RST} ${C_DIM}Optional: wire the Ralph MCP server into your editor configs.${C_RST}"
  printf '%b' "${C_Y}${C_BOLD}Configure MCP now?${C_RST} ${C_DIM}[y/N]${C_RST} "
  if ! read -r -t 0 answer < /dev/tty; then
    printf '\n'
    read -r answer < /dev/tty
  else
    read -r answer < /dev/tty
  fi

  case "$answer" in
    y|Y)
      [[ "${INSTALL_CURSOR:-0}" -eq 1 ]] && install_mcp_configure_runtime cursor "$TARGET/.cursor" "$TARGET"
      [[ "${INSTALL_CLAUDE:-0}" -eq 1 ]] && install_mcp_configure_runtime claude "$TARGET/.claude" "$TARGET"
      [[ "${INSTALL_CODEX:-0}" -eq 1 ]] && install_mcp_configure_runtime codex "$TARGET/.codex" "$TARGET"
      ;;
    *)
      return 0
      ;;
  esac
}

_mcp_configure_cursor() {
  install_mcp_configure_runtime cursor "$TARGET/.cursor" "$TARGET"
}

_mcp_configure_claude() {
  install_mcp_configure_runtime claude "$TARGET/.claude" "$TARGET"
}

_mcp_configure_codex() {
  install_mcp_configure_runtime codex "$TARGET/.codex" "$TARGET"
}
