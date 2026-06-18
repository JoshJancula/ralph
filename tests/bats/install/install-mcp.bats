#!/usr/bin/env bats
# Installer MCP configuration shares durable setup helpers with ralph setup --mcp.
#
# Covers:
# - install_mcp_configure_runtime matches setup_mcp_for_runtime for Cursor, Claude, Codex
# - Existing MCP servers are preserved equivalently on merge
# - Installer dry-run does not write MCP config files

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

INSTALL_MCP_SH="$REPO_ROOT/bundle/.ralph/bash-lib/install/install-mcp.sh"
INSTALL_COLORS_SH="$REPO_ROOT/bundle/.ralph/bash-lib/install/install-colors.sh"
SETUP_HELPERS_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-helpers.sh"
SETUP_MCP_SH="$REPO_ROOT/bundle/.ralph/bash-lib/setup/setup-mcp.sh"
SETUP_RUNTIME_SH="$REPO_ROOT/bundle/.ralph/setup-runtime.sh"

setup() {
  TEST_TEMP_DIR="$(mktemp -d)"
  export TEST_TEMP_DIR
  export BUNDLE_ROOT="$REPO_ROOT/bundle"
}

teardown() {
  if [[ -d "${TEST_TEMP_DIR:-}" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

install_mcp_prepare_project() {
  local project_dir="$1"
  mkdir -p "$project_dir/.ralph"
  cp "$REPO_ROOT/bundle/.ralph/mcp-server.sh" "$project_dir/.ralph/mcp-server.sh"
  chmod +x "$project_dir/.ralph/mcp-server.sh"
}

install_mcp_run_setup_runtime() {
  local runtime="$1"
  local project_dir="$2"
  bash "$SETUP_RUNTIME_SH" \
    --runtime "$runtime" \
    --runtime-dir "$project_dir/.$runtime" \
    --mcp
}

install_mcp_run_install_configure() {
  local runtime="$1"
  local project_dir="$2"
  local fn=""
  case "$runtime" in
    cursor) fn="_mcp_configure_cursor" ;;
    claude) fn="_mcp_configure_claude" ;;
    codex) fn="_mcp_configure_codex" ;;
    *)
      printf 'unsupported runtime: %s\n' "$runtime" >&2
      return 1
      ;;
  esac

  bash -c "
    set -euo pipefail
    source \"$INSTALL_COLORS_SH\"
    install_colors_init
    RALPH_BASH_LIB=\"$REPO_ROOT/bundle/.ralph/bash-lib\"
    TARGET=\"$project_dir\"
    DRY_RUN=0
    INSTALL_CURSOR=1
    INSTALL_CLAUDE=1
    INSTALL_CODEX=1
    source \"$INSTALL_MCP_SH\"
    $fn
  "
}

install_mcp_normalize_json_config() {
  local file="$1"
  local project_dir="$2"
  jq -S --arg root "$project_dir" '
    walk(
      if type == "string" then
        gsub($root; "{{PROJECT_ROOT}}")
      else .
      end
    )
  ' "$file"
}

install_mcp_compare_json_configs() {
  local left="$1"
  local left_root="$2"
  local right="$3"
  local right_root="$4"
  diff -u \
    <(install_mcp_normalize_json_config "$left" "$left_root") \
    <(install_mcp_normalize_json_config "$right" "$right_root")
}

install_mcp_normalize_codex_config() {
  local file="$1"
  local project_dir="$2"
  python3 - "$file" "$project_dir" <<'PY'
import sys
import tomllib

path, root = sys.argv[1:3]
with open(path, "rb") as fh:
    data = tomllib.load(fh)

def normalize(value):
    if isinstance(value, str):
        return value.replace(root, "{{PROJECT_ROOT}}")
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        return {key: normalize(item) for key, item in value.items()}
    return value

import json
print(json.dumps(normalize(data), indent=2, sort_keys=True))
PY
}

install_mcp_compare_codex_configs() {
  local left="$1"
  local left_root="$2"
  local right="$3"
  local right_root="$4"
  diff -u \
    <(install_mcp_normalize_codex_config "$left" "$left_root") \
    <(install_mcp_normalize_codex_config "$right" "$right_root")
}

@test "install MCP configure for cursor matches ralph setup --mcp" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$INSTALL_MCP_SH" ] || skip "install-mcp.sh missing"
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local cli_dir="$TEST_TEMP_DIR/cli-cursor"
  local install_dir="$TEST_TEMP_DIR/install-cursor"
  install_mcp_prepare_project "$cli_dir"
  install_mcp_prepare_project "$install_dir"
  mkdir -p "$cli_dir/.cursor" "$install_dir/.cursor"

  install_mcp_run_setup_runtime cursor "$cli_dir"
  install_mcp_run_install_configure cursor "$install_dir"

  install_mcp_compare_json_configs \
    "$cli_dir/.cursor/mcp.json" "$cli_dir" \
    "$install_dir/.cursor/mcp.json" "$install_dir"
}

@test "install MCP configure for claude matches ralph setup --mcp" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$INSTALL_MCP_SH" ] || skip "install-mcp.sh missing"
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local cli_dir="$TEST_TEMP_DIR/cli-claude"
  local install_dir="$TEST_TEMP_DIR/install-claude"
  install_mcp_prepare_project "$cli_dir"
  install_mcp_prepare_project "$install_dir"
  mkdir -p "$cli_dir/.claude" "$install_dir/.claude"

  install_mcp_run_setup_runtime claude "$cli_dir"
  install_mcp_run_install_configure claude "$install_dir"

  install_mcp_compare_json_configs \
    "$cli_dir/.mcp.json" "$cli_dir" \
    "$install_dir/.mcp.json" "$install_dir"
}

@test "install MCP configure for codex matches ralph setup --mcp" {
  command -v python3 >/dev/null || skip "python3 required"
  python3 -c 'import tomllib' 2>/dev/null || skip "Python 3.11+ required"
  [ -f "$INSTALL_MCP_SH" ] || skip "install-mcp.sh missing"
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local cli_dir="$TEST_TEMP_DIR/cli-codex"
  local install_dir="$TEST_TEMP_DIR/install-codex"
  install_mcp_prepare_project "$cli_dir"
  install_mcp_prepare_project "$install_dir"
  mkdir -p "$cli_dir/.codex" "$install_dir/.codex"

  install_mcp_run_setup_runtime codex "$cli_dir"
  install_mcp_run_install_configure codex "$install_dir"

  install_mcp_compare_codex_configs \
    "$cli_dir/.codex/config.toml" "$cli_dir" \
    "$install_dir/.codex/config.toml" "$install_dir"
}

@test "install MCP configure preserves existing cursor servers like ralph setup --mcp" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$INSTALL_MCP_SH" ] || skip "install-mcp.sh missing"
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local cli_dir="$TEST_TEMP_DIR/cli-cursor-merge"
  local install_dir="$TEST_TEMP_DIR/install-cursor-merge"
  install_mcp_prepare_project "$cli_dir"
  install_mcp_prepare_project "$install_dir"
  mkdir -p "$cli_dir/.cursor" "$install_dir/.cursor"
  printf '%s\n' '{"keep":"value","mcpServers":{"other":{"command":"keep-me"}}}' \
    >"$cli_dir/.cursor/mcp.json"
  cp "$cli_dir/.cursor/mcp.json" "$install_dir/.cursor/mcp.json"

  install_mcp_run_setup_runtime cursor "$cli_dir"
  install_mcp_run_install_configure cursor "$install_dir"

  install_mcp_compare_json_configs \
    "$cli_dir/.cursor/mcp.json" "$cli_dir" \
    "$install_dir/.cursor/mcp.json" "$install_dir"
}

@test "install MCP configure preserves existing claude servers like ralph setup --mcp" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$INSTALL_MCP_SH" ] || skip "install-mcp.sh missing"
  [ -f "$SETUP_RUNTIME_SH" ] || skip "setup-runtime.sh missing"

  local cli_dir="$TEST_TEMP_DIR/cli-claude-merge"
  local install_dir="$TEST_TEMP_DIR/install-claude-merge"
  install_mcp_prepare_project "$cli_dir"
  install_mcp_prepare_project "$install_dir"
  mkdir -p "$cli_dir/.claude" "$install_dir/.claude"
  printf '%s\n' '{"mcpServers":{"playwright":{"command":"npx","args":["playwright"]}}}' \
    >"$cli_dir/.mcp.json"
  cp "$cli_dir/.mcp.json" "$install_dir/.mcp.json"

  install_mcp_run_setup_runtime claude "$cli_dir"
  install_mcp_run_install_configure claude "$install_dir"

  install_mcp_compare_json_configs \
    "$cli_dir/.mcp.json" "$cli_dir" \
    "$install_dir/.mcp.json" "$install_dir"
}

@test "install MCP configure dry-run does not write cursor mcp.json" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$INSTALL_MCP_SH" ] || skip "install-mcp.sh missing"

  local project_dir="$TEST_TEMP_DIR/install-cursor-dry"
  install_mcp_prepare_project "$project_dir"
  mkdir -p "$project_dir/.cursor"

  run bash -c "
    set -euo pipefail
    source \"$INSTALL_COLORS_SH\"
    install_colors_init
    RALPH_BASH_LIB=\"$REPO_ROOT/bundle/.ralph/bash-lib\"
    TARGET=\"$project_dir\"
    DRY_RUN=1
    source \"$INSTALL_MCP_SH\"
    _mcp_configure_cursor
  "
  [ "$status" -eq 0 ]
  [ ! -f "$project_dir/.cursor/mcp.json" ]
}
