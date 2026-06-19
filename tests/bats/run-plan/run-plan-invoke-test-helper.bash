#!/usr/bin/env bash

run_plan_invoke_test_setup_common() {
  TEST_TMPDIR="$(mktemp -d)"
  BIN_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"

  export TMPDIR="$TEST_TMPDIR"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  export OUTPUT_LOG="$TEST_TMPDIR/output.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/exit-code"
  export SESSION_ID_FILE="$TEST_TMPDIR/session-id.txt"
  export PROMPT=""

  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.codex/ralph"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$WORKSPACE/.ralph/mcp-server.sh"
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"
  : >"$OUTPUT_LOG"
  : >"$EXIT_CODE_FILE"

  ORIGINAL_PATH="$PATH"
  PATH="$BIN_DIR:$PATH"
  export PATH

  unset PROMPT_STATIC
  unset SELECTED_MODEL
  unset CLAUDE_PLAN_CLI CLAUDE_PLAN_ALLOWED_TOOLS CLAUDE_PLAN_NO_ALLOWED_TOOLS CLAUDE_TOOLS_FROM_AGENT
  unset CLAUDE_PLAN_BARE CLAUDE_PLAN_MINIMAL CLAUDE_PLAN_MINIMAL_DISABLE_MCP CLAUDE_PLAN_PERMISSION_MODE
  unset CODEX_CLI CODEX_PLAN_CLI CODEX_PLAN_MODEL CODEX_PLAN_EXTRA_ADD_DIRS CODEX_PLAN_MCP_CONFIG_PATH
  unset OPENCODE_CLI OPENCODE_PLAN_CLI OPENCODE_PLAN_MODEL OPENCODE_CONFIG OPENCODE_PLAN_MCP_CONFIG_PATH
  unset RALPH_MODE RALPH_AGENT_WORKSPACE RALPH_PROJECT_ROOT RALPH_PLAN_WORKSPACE_ROOT
  unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_MCP_CONFIG_PATH RALPH_MCP_PROXY_SERVER_SCRIPT
  unset RALPH_PLAN_ALLOW_UNSAFE_RESUME RALPH_RUN_PLAN_RESUME_BARE RALPH_RUN_PLAN_RESUME_SESSION_ID
  unset RALPH_RUN_PLAN_RESET_COMMAND_USED RALPH_MCP_TOOLS_ENABLED RALPH_PLAN_PRETTY RALPH_PLAN_NO_COLOR
  unset CURSOR_PLAN_NO_COLOR CURSOR_PLAN_OUTPUT_FORMAT NO_COLOR RALPH_CLAUDE_EXCLUDE_DYNAMIC_SYSTEM_PROMPT_SECTIONS
}

run_plan_invoke_test_teardown_common() {
  PATH="$ORIGINAL_PATH"
  export PATH
  rm -rf "$TEST_TMPDIR"
}

run_plan_invoke_test_write_stub() {
  local name="$1"
  local record="$2"
  local stdin_capture="${3:-}"

  cat <<EOF >"$BIN_DIR/$name"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
EOF
  if [[ -n "$stdin_capture" ]]; then
    cat <<EOF >>"$BIN_DIR/$name"
cat >"$stdin_capture"
EOF
  fi
  printf '\nexit 0\n' >>"$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
}

run_plan_invoke_test_write_codex_stub() {
  local record="$1"

  cat <<EOF >"$BIN_DIR/codex"
#!/usr/bin/env bash
if [[ "\$1" == "mcp" && "\${2:-}" == "--help" ]]; then
  cat <<'MCP_HELP'
Manage external MCP servers for Codex

Usage: codex mcp [OPTIONS] <COMMAND>

Commands:
  list
  get
  add
  remove
  login
  logout
  help
MCP_HELP
  exit 0
fi

if [[ "\$1" == "exec" && "\${2:-}" == "--help" ]]; then
  cat <<'EXEC_HELP'
Run Codex non-interactively

Options:
  -c, --config <key=value>
      Override a configuration value that would otherwise be loaded from ~/.codex/config.toml.
      --strict-config
EXEC_HELP
  exit 0
fi

printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/codex"
}

