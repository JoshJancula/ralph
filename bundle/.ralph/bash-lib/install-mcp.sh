#!/usr/bin/env bash
set -euo pipefail
#
# MCP server configuration for Cursor, Claude, and Codex.
#
# Public interface:
#   install_configure_mcp -- prompt and configure MCP servers for installed runtimes.

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
      [[ "${INSTALL_CURSOR:-0}" -eq 1 ]] && _mcp_configure_cursor
      [[ "${INSTALL_CLAUDE:-0}" -eq 1 ]] && _mcp_configure_claude
      [[ "${INSTALL_CODEX:-0}" -eq 1 ]] && _mcp_configure_codex
      ;;
    *)
      return 0
      ;;
  esac
}

_mcp_configure_cursor() {
  local source_file="$BUNDLE/.cursor/mcp.example.json"
  local target_file="$TARGET/.cursor/mcp.json"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    install_log_dry "[dry-run]" "would write/merge $target_file"
    return 0
  fi

  # Read and substitute the example file
  local content
  content=$(sed "s|/path/to/workspace|$TARGET|g" "$source_file")

  # If target does not exist, write directly
  if [[ ! -f "$target_file" ]]; then
    mkdir -p "$(dirname "$target_file")"
    printf '%s\n' "$content" > "$target_file"
    install_log_ok "Wrote Cursor MCP example" "$target_file"
    return 0
  fi

  # Target exists - check if jq is available
  if ! command -v jq &> /dev/null; then
    install_log_warn "Warning: $target_file exists and jq is not installed; skipping MCP merge."
    return 0
  fi

  # Merge using jq
  # Extract the new mcpServers array from the source
  local new_servers
  new_servers=$(printf '%s\n' "$content" | jq '.mcpServers')

  # Merge: append new servers to existing ones, deduplicating by name
  jq --argjson new_servers "$new_servers" '
    .mcpServers += $new_servers |
    .mcpServers |= unique_by(.name)
  ' "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
  install_log_ok "Merged Cursor MCP config" "$target_file"
}

_mcp_configure_claude() {
  local source_file="$BUNDLE/.claude/mcp.example.json"
  local target_file="$TARGET/.claude/mcp.json"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    install_log_dry "[dry-run]" "would write/merge $target_file"
    return 0
  fi

  # Read and substitute the example file
  local content
  content=$(sed "s|/path/to/workspace|$TARGET|g" "$source_file")

  # If target does not exist, write directly
  if [[ ! -f "$target_file" ]]; then
    mkdir -p "$(dirname "$target_file")"
    printf '%s\n' "$content" > "$target_file"
    install_log_ok "Wrote Claude MCP example" "$target_file"
    return 0
  fi

  # Target exists - check if jq is available
  if ! command -v jq &> /dev/null; then
    install_log_warn "Warning: $target_file exists and jq is not installed; skipping MCP merge."
    return 0
  fi

  # Merge using jq
  # Extract the new mcpServers object from the source
  local new_config
  new_config=$(printf '%s\n' "$content" | jq '.')

  # Merge: preserve existing keys and add the ralph entry
  jq --argjson new_config "$new_config" '. * $new_config' "$target_file" > "$target_file.tmp" && mv "$target_file.tmp" "$target_file"
  install_log_ok "Merged Claude MCP config" "$target_file"
}

_mcp_configure_codex() {
  local source_file="$BUNDLE/.codex/mcp.example.toml"
  local target_file="$TARGET/.codex/config.toml"

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    install_log_dry "[dry-run]" "would write/append $target_file"
    return 0
  fi

  # Read and substitute the example file
  local content
  content=$(sed "s|/path/to/workspace|$TARGET|g" "$source_file")

  # If target exists, check if ralph is already configured
  if [[ -f "$target_file" ]]; then
    if grep -q '\[mcp_servers\.ralph\]' "$target_file"; then
      install_log_skip "Skip Codex MCP (already configured):" "$target_file"
      return 0
    fi
    # Append to existing file
    printf '\n%s\n' "$content" >> "$target_file"
    install_log_ok "Appended Codex MCP block" "$target_file"
    return 0
  fi

  # Target does not exist, create it
  mkdir -p "$(dirname "$target_file")"
  printf '%s\n' "$content" > "$target_file"
  install_log_ok "Wrote Codex MCP example" "$target_file"
}
