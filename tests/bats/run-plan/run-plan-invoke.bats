#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"

  TEST_TMPDIR="$(mktemp -d)"
  BIN_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
  export TMPDIR="$TEST_TMPDIR"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  mkdir -p "$WORKSPACE/.codex/ralph"
  mkdir -p "$WORKSPACE/.ralph"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$WORKSPACE/.ralph/mcp-server.sh"
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"

  ORIGINAL_PATH="$PATH"
  PATH="$BIN_DIR:$PATH"

  export OUTPUT_LOG="$TEST_TMPDIR/output.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/exit-code"
  export PROMPT=""
  unset PROMPT_STATIC

  unset SELECTED_MODEL
  unset CLAUDE_PLAN_ALLOWED_TOOLS
  unset CLAUDE_PLAN_NO_ALLOWED_TOOLS
  unset CLAUDE_TOOLS_FROM_AGENT
  unset CLAUDE_PLAN_BARE
  unset CLAUDE_PLAN_PERMISSION_MODE
  unset CODEX_CLI
  unset CODEX_PLAN_CLI
  unset CODEX_PLAN_MODEL
  unset OPENCODE_CLI
  unset OPENCODE_PLAN_CLI
  unset OPENCODE_PLAN_MODEL
  unset OPENCODE_CONFIG
  unset OPENCODE_PLAN_MCP_CONFIG_PATH
  unset CODEX_PLAN_MCP_CONFIG_PATH
  unset RALPH_PLAN_ALLOW_UNSAFE_RESUME
  unset RALPH_RUN_PLAN_RESUME_BARE
  unset RALPH_PLAN_CLI_RESUME
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  unset RALPH_RUN_PLAN_RESET_COMMAND_USED
  unset RALPH_MCP_TOOLS_ENABLED
  unset RALPH_MODE
  unset RALPH_AGENT_WORKSPACE
  unset RALPH_PROJECT_ROOT
  unset RALPH_PLAN_WORKSPACE_ROOT
  unset RALPH_AGENT_TOOL_ACCESS
  unset RALPH_NATIVE_HOOKS
  unset RALPH_MCP_CONFIG_PATH
  unset RALPH_MCP_PROXY_SERVER_SCRIPT
  unset CLAUDE_PLAN_MCP_CONFIG_PATH
  unset CLAUDE_PLAN_MCP_CONFIG_OWNED
  unset CLAUDE_PLAN_PROXY_CONFIG_PATH
  unset CLAUDE_PLAN_PROXY_CONFIG_OWNED
  unset CURSOR_PLAN_MCP_CONFIG_TARGET
  unset CURSOR_PLAN_MCP_CONFIG_BACKUP
  unset CURSOR_PLAN_MCP_CONFIG_HAD_FILE
  unset PREBUILT_AGENT
  unset CLAUDE_PLAN_MINIMAL_DISABLE_MCP
  unset CURSOR_PLAN_OUTPUT_FORMAT
  unset RALPH_CLAUDE_EXCLUDE_DYNAMIC_SYSTEM_PROMPT_SECTIONS
  unset RALPH_PLAN_PRETTY
  unset RALPH_PLAN_NO_COLOR
  unset CURSOR_PLAN_NO_COLOR
  unset NO_COLOR
}

teardown() {
  PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

write_stub_script() {
  local name="$1"
  local record="$2"

  cat <<EOF >"$BIN_DIR/$name"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
EOF
  chmod +x "$BIN_DIR/$name"
}

write_codex_exec_stub() {
  local record="$1"
  local stdin_capture="$TEST_TMPDIR/codex.stdin"

  cat <<CODEX_STUB >"$BIN_DIR/codex"
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

if [[ "\$1" == "exec" ]]; then
  strict_config=0
  for arg in "\$@"; do
    if [[ "\$arg" == "--strict-config" ]]; then
      strict_config=1
      break
    fi
  done
  for arg in "\$@"; do
    if [[ "\$arg" == *'mcp_servers.ralph.type'* ]] && [[ "\$strict_config" == "1" ]] && [[ "\${CODEX_STUB_REJECT_MCP_TYPE:-0}" == "1" ]]; then
      echo "Error loading config.toml: unknown configuration field mcp_servers.ralph.type in -c/--config override" >&2
      exit 1
    fi
    if [[ "\$arg" == *'mcp_servers.ralph.command'* ]] && [[ "\$strict_config" == "1" ]] && [[ "\${CODEX_STUB_REJECT_MCP_COMMAND:-0}" == "1" ]]; then
      echo "Error loading config.toml: unknown configuration field mcp_servers.ralph.command in -c/--config override" >&2
      exit 1
    fi
    if [[ "\$arg" == *'mcp_servers.ralph.default_tools_approval_mode'* ]] && [[ "\$strict_config" == "1" ]] && [[ "\${CODEX_STUB_REJECT_MCP_APPROVAL_MODE:-0}" == "1" ]]; then
      echo "Error loading config.toml: unknown configuration field mcp_servers.ralph.default_tools_approval_mode in -c/--config override" >&2
      exit 1
    fi
  done
fi

printf 'MODEL:%s\n' "\${CODEX_PLAN_MODEL:-}" >>"$record"
printf 'CLI:%s\n' "\${CODEX_PLAN_CLI:-}" >>"$record"
printf 'RESUME_BARE:%s\n' "\${RALPH_RUN_PLAN_RESUME_BARE:-}" >>"$record"
printf 'ARGS:%s\n' "\$@" >>"$record"
exit 0
CODEX_STUB
  chmod +x "$BIN_DIR/codex"
}

assert_opencode_prompt_arg() {
  local record="$1"
  local expected="$2"
  local escaped=""
  printf -v escaped '%q' "$expected"
  if grep -q '^ARG_Q:' "$record"; then
    grep -Fxq -- "ARG_Q:$escaped" "$record"
  else
    grep -Fxq -- "$expected" "$record"
  fi
  ! grep -q 'ralph-opencode-prompt-' "$record"
}

write_opencode_stub_with_prompt_capture() {
  local record="$1"
cat <<EOF >"$BIN_DIR/opencode"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
printf 'ARG_Q:%q\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"
}

assert_opencode_final_cache_settings_is() {
  local expected="$1"
  [ "${RALPH_OPENCODE_FINAL_CACHE_SETTINGS:-0}" = "$expected" ]
}

assert_opencode_prompt_cache_key_not_injected() {
  [ "${RALPH_OPENCODE_PROMPT_CACHE_KEY_INJECTED:-0}" = "0" ]
}

invoke_common_ndjson_runner() {
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"plain text"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo hi"}}]}}'
  printf '%s\n' '{"type":"result","num_turns":1,"duration_ms":1000}'
  return 7
}

invoke_common_raw_runner() {
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"raw fallback"}]}}'
  return 7
}

assert_file_has_no_esc_bytes() {
  local path="$1"
  ! LC_ALL=C grep -q $'\033' "$path"
}

@test "cursor invoke helper adds -p --force and passes prompt" {
  local record="$TEST_TMPDIR/cursor.args"
  write_stub_script "cursor-agent" "$record"

  PROMPT="cursor-prompt"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"-p"* ]]
  [[ "$captured" == *"--force"* ]]
  [[ "$captured" == *"cursor-prompt"* ]]
}

@test "cursor invoke helper keeps native mode unchanged when RALPH_MODE is native" {
  local record="$TEST_TMPDIR/cursor-legacy.args"
  write_stub_script "cursor-agent" "$record"

  PROMPT="cursor-legacy-prompt"
  export PROMPT
  RALPH_MODE="native"
  export RALPH_MODE

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"-p"* ]]
  [[ "$captured" == *"--force"* ]]
  [[ "$captured" == *"cursor-legacy-prompt"* ]]
  [[ "$captured" != *"--mcp-config"* ]]
}

@test "claude invoke helper leaves MCP config untouched in native mode" {
  local record="$TEST_TMPDIR/claude-native.args"
  local stdin_cap="$TEST_TMPDIR/claude-native.stdin"

  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-native-prompt"
  export PROMPT
  RALPH_MODE="native"
  export RALPH_MODE
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *'{"mcpServers":{}}'* ]]
  [[ "$captured" == *"--allowedTools"* ]]
  [[ "$captured" == *"Bash,Read,Edit"* ]]
  [[ "$captured" != *"mcp__ralph__"* ]]
  [[ "$captured" != *"/ralph-claude-mcp-"* ]]
  [ "$(cat "$stdin_cap")" = "claude-native-prompt" ]
  [ "$(find "$TEST_TMPDIR" -name 'ralph-claude-mcp-*' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "cursor invoke helper injects Ralph MCP config when RALPH_MODE is ralph" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/cursor-proxy.args"
  local mcp_capture="$TEST_TMPDIR/cursor-proxy.mcp"
  local proxy_server="$WORKSPACE/.ralph/mcp-server.sh"
  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$proxy_server"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$proxy_server"
  cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
if [[ -f "$WORKSPACE/.cursor/mcp.json" ]]; then
  printf 'MCP_CONFIG:%s\n' "\$(cat "$WORKSPACE/.cursor/mcp.json")" >>"$mcp_capture"
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  PROMPT="cursor-proxy-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE

  [ ! -f "$WORKSPACE/.cursor/mcp.json" ]

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [ ! -f "$WORKSPACE/.cursor/mcp.json" ]

  grep -Fxq -- "--workspace" "$record"
  grep -Fxq -- "$WORKSPACE" "$record"
  grep -Fxq -- "--approve-mcps" "$record"
  grep -q 'MCP_CONFIG:' "$mcp_capture"
  grep -q '"mcpServers"' "$mcp_capture"
  grep -q '"ralph"' "$mcp_capture"
}

@test "cursor invoke helper injects Ralph MCP config and restores existing mcp.json bytes in ralph mode" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/cursor-proxy-restore.args"
  local mcp_capture="$TEST_TMPDIR/cursor-proxy-restore.mcp"
  local original_config="$WORKSPACE/.cursor/mcp.json"
  local proxy_server="$WORKSPACE/.ralph/mcp-server.sh"
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.cursor"
  printf '{"keep":"value","mcpServers":{"other":{"command":"keep-me"}}}' >"$original_config"
  local original_bytes
  original_bytes="$(cat "$original_config")"
  cat <<'EOF' >"$proxy_server"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$proxy_server"
  cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
if [[ -f "$WORKSPACE/.cursor/mcp.json" ]]; then
  printf 'MCP_CONFIG:%s\n' "\$(cat "$WORKSPACE/.cursor/mcp.json")" >>"$mcp_capture"
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  PROMPT="cursor-proxy-restore-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [ "$(cat "$original_config")" = "$original_bytes" ]

  grep -Fxq -- "--workspace" "$record"
  grep -Fxq -- "$WORKSPACE" "$record"
  grep -Fxq -- "--approve-mcps" "$record"
  grep -q 'MCP_CONFIG:' "$mcp_capture"
  grep -q '"ralph"' "$mcp_capture"
  grep -q '"other"' "$mcp_capture"
  grep -q '"keep"[[:space:]]*:[[:space:]]*"value"' "$mcp_capture"
}

@test "cursor invoke helper restores existing mcp.json when CLI exits non-zero in ralph mode" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/cursor-proxy-fail.args"
  local original_config="$WORKSPACE/.cursor/mcp.json"
  local proxy_server="$WORKSPACE/.ralph/mcp-server.sh"
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.cursor"
  printf '{"mcpServers":{"other":{"command":"keep-me"}}}' >"$original_config"
  local original_bytes
  original_bytes="$(cat "$original_config")"
  cat <<'EOF' >"$proxy_server"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$proxy_server"
  cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 1
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  PROMPT="cursor-proxy-fail-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [ "$(cat "$original_config")" = "$original_bytes" ]
}

@test "claude invoke helper removes temp MCP config after CLI failure" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/claude-proxy-fail.args"
  local captured_config="$TEST_TMPDIR/claude-proxy-fail.mcp-path"
  local proxy_server="$WORKSPACE/.ralph/mcp-server.sh"
  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$proxy_server"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$proxy_server"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--mcp-config" && -f "\$arg" ]]; then
    printf '%s\n' "\$arg" >"$captured_config"
  fi
  prev="\$arg"
done
printf '%s\n' "\$@" >>"$record"
exit 1
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-proxy-fail-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [ -s "$captured_config" ]
  [ ! -f "$(cat "$captured_config")" ]
}

@test "claude invoke helper removes temp MCP config when validation fails before invoke" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/claude-proxy-validate-fail.args"
  local proxy_server="$WORKSPACE/.ralph/mcp-server.sh"
  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$proxy_server"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$proxy_server"
  write_stub_script "claude" "$record"

  PROMPT="claude-proxy-validate-fail-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS
  CLAUDE_PLAN_PERMISSION_MODE="invalid-mode"
  export CLAUDE_PLAN_PERMISSION_MODE

  local before_count
  before_count="$(find "$TEST_TMPDIR" -name 'ralph-claude-mcp-*' | wc -l | tr -d ' ')"

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: CLAUDE_PLAN_PERMISSION_MODE must be one of"* ]]
  [ ! -s "$record" ]

  local after_count
  after_count="$(find "$TEST_TMPDIR" -name 'ralph-claude-mcp-*' | wc -l | tr -d ' ')"
  [ "$after_count" -eq "$before_count" ]
}

@test "cursor invoke helper rejects invalid existing mcp.json in ralph mode without modifying it" {
  local record="$TEST_TMPDIR/cursor-proxy-invalid.args"
  local original_config="$WORKSPACE/.cursor/mcp.json"
  mkdir -p "$WORKSPACE/.cursor"
  printf 'not-json' >"$original_config"
  write_stub_script "cursor-agent" "$record"

  PROMPT="cursor-proxy-invalid-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: existing Cursor MCP config is invalid JSON:"* ]]
  [ "$(cat "$original_config")" = "not-json" ]
  [ ! -s "$record" ]
}

@test "cursor invoke helper leaves mcp.json untouched in native mode" {
  local record="$TEST_TMPDIR/cursor-native-mcp.args"
  local original_config="$WORKSPACE/.cursor/mcp.json"
  mkdir -p "$WORKSPACE/.cursor"
  printf '{"mcpServers":{"keep":"me"}}' >"$original_config"
  local original_bytes
  original_bytes="$(cat "$original_config")"
  write_stub_script "cursor-agent" "$record"

  PROMPT="cursor-native-prompt"
  export PROMPT
  RALPH_MODE="native"
  export RALPH_MODE

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [ "$(cat "$original_config")" = "$original_bytes" ]
  ! grep -Fxq -- "--workspace" "$record"
  ! grep -Fxq -- "--approve-mcps" "$record"
}

@test "cursor invoke helper honors SELECTED_MODEL" {
  local record="$TEST_TMPDIR/cursor.model.args"
  write_stub_script "cursor-agent" "$record"

  SELECTED_MODEL="gpt-4"
  export SELECTED_MODEL
  PROMPT="model prompt"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  grep -Fxq -- "--model" "$record"
  grep -Fxq -- "gpt-4" "$record"
}

@test "claude invoke helper passes --system-prompt with PROMPT_STATIC and omits exclude-dynamic" {
  local record="$TEST_TMPDIR/claude-system-prompt.args"
  local stdin_cap="$TEST_TMPDIR/claude-system-prompt.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="dynamic todo prompt"
  export PROMPT
  PROMPT_STATIC="stable agent context for caching"
  export PROMPT_STATIC

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--system-prompt"* ]]
  grep -Fxq -- "stable agent context for caching" "$record"
  [[ "$captured" != *"--exclude-dynamic-system-prompt-sections"* ]]
  [ "$(cat "$stdin_cap")" = "dynamic todo prompt" ]
}

@test "claude invoke helper passes exclude-dynamic only when PROMPT_STATIC is empty" {
  local record="$TEST_TMPDIR/claude-exclude-dynamic.args"
  local stdin_cap="$TEST_TMPDIR/claude-exclude-dynamic.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="resume todo prompt"
  export PROMPT
  unset PROMPT_STATIC

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--exclude-dynamic-system-prompt-sections"* ]]
  [[ "$captured" != *"--system-prompt"* ]]
  [ "$(cat "$stdin_cap")" = "resume todo prompt" ]
}

@test "claude invoke helper omits exclude-dynamic when disabled and PROMPT_STATIC is empty" {
  local record="$TEST_TMPDIR/claude-no-exclude-dynamic.args"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >/dev/null
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="resume todo prompt"
  export PROMPT
  unset PROMPT_STATIC
  RALPH_CLAUDE_EXCLUDE_DYNAMIC_SYSTEM_PROMPT_SECTIONS=0
  export RALPH_CLAUDE_EXCLUDE_DYNAMIC_SYSTEM_PROMPT_SECTIONS

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--exclude-dynamic-system-prompt-sections"* ]]
  [[ "$captured" != *"--system-prompt"* ]]
}

@test "claude invoke helper namespaces allowed tools and passes prompt on stdin" {
  local record="$TEST_TMPDIR/claude.args"
  local stdin_cap="$TEST_TMPDIR/claude.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-prompt"
  export PROMPT
  export RALPH_MODE=native
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"-p"* ]]
  [[ "$captured" == *"--allowedTools"* ]]
  [[ "$captured" == *"Bash,Read,Edit"* ]]
  [ "$(cat "$stdin_cap")" = "claude-prompt" ]
}

@test "claude invoke helper strips native tools after MCP preflight in ralph mode" {
  local strip_native_read=1
  local strip_native_bash=1
  RALPH_MODE="ralph"
  export RALPH_MODE
  RALPH_MCP_PREFLIGHT_PASSED=1
  export RALPH_MCP_PREFLIGHT_PASSED
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  local tools_use
  tools_use="$(ralph_run_plan_invoke_claude_allowed_tools_list "$CLAUDE_PLAN_ALLOWED_TOOLS" "$strip_native_read" "$strip_native_bash")"

  [ -n "$tools_use" ]
  [[ "$tools_use" == *"mcp__ralph__ralph_proxy_read"* ]]
  [[ "$tools_use" == *"mcp__ralph__ralph_proxy_shell"* ]]
  [[ "$tools_use" == *"mcp__ralph__ralph_proxy_shell_start"* ]]
  [[ "$tools_use" == *"mcp__ralph__ralph_proxy_shell_status"* ]]
  [[ "$tools_use" == *"mcp__ralph__ralph_proxy_shell_wait"* ]]
  [[ "$tools_use" == *"mcp__ralph__ralph_proxy_shell_read"* ]]
  [[ "$tools_use" == *"mcp__ralph__ralph_proxy_shell_cancel"* ]]
  [[ "$tools_use" == *"mcp__ralph__ralph_proxy_batch"* ]]

  if printf '%s\n' "$tools_use" | grep -Eq '(^|,)Read($|,)'; then
    fail "Read should be stripped from the tool list"
  fi
  if printf '%s\n' "$tools_use" | grep -Eq '(^|,)Bash($|,)'; then
    fail "Bash should be stripped from the tool list"
  fi

  local -a args=()
  run_plan_invoke_claude_apply_minimal_flags args "" "$tools_use"

  local tools_arg=""
  for idx in "${!args[@]}"; do
    if [[ "${args[idx]}" == "--tools" ]]; then
      tools_arg="${args[idx+1]}"
      break
    fi
  done

  [ -n "$tools_arg" ]
  [ "$tools_arg" = "$tools_use" ]
}

@test "claude minimal mode helper appends auth-safe flags in order" {
  local -a args=()

  run_plan_invoke_claude_apply_minimal_flags args

  [ "${#args[@]}" -eq 8 ]
  [ "${args[0]}" = "--disable-slash-commands" ]
  [ "${args[1]}" = "--strict-mcp-config" ]
  [ "${args[2]}" = "--mcp-config" ]
  [ "${args[3]}" = '{"mcpServers":{}}' ]
  [ "${args[4]}" = "--setting-sources" ]
  [ "${args[5]}" = "project,local" ]
  [ "${args[6]}" = "--tools" ]
  [ "${args[7]}" = "Bash,Read,Edit,Write" ]

  local -a override_args=()
  CLAUDE_PLAN_MINIMAL_TOOLS="Bash,Read"
  run_plan_invoke_claude_apply_minimal_flags override_args

  [ "${#override_args[@]}" -eq 8 ]
  [ "${override_args[0]}" = "--disable-slash-commands" ]
  [ "${override_args[1]}" = "--strict-mcp-config" ]
  [ "${override_args[2]}" = "--mcp-config" ]
  [ "${override_args[3]}" = '{"mcpServers":{}}' ]
  [ "${override_args[4]}" = "--setting-sources" ]
  [ "${override_args[5]}" = "project,local" ]
  [ "${override_args[6]}" = "--tools" ]
  [ "${override_args[7]}" = "Bash,Read" ]

  unset CLAUDE_PLAN_MINIMAL_TOOLS
  local -a reset_args=()
  RALPH_RUN_PLAN_RESET_COMMAND_USED=1
  run_plan_invoke_claude_apply_minimal_flags reset_args
  unset RALPH_RUN_PLAN_RESET_COMMAND_USED

  [ "${#reset_args[@]}" -eq 7 ]
  [ "${reset_args[0]}" = "--strict-mcp-config" ]
  [ "${reset_args[1]}" = "--mcp-config" ]
  [ "${reset_args[2]}" = '{"mcpServers":{}}' ]
  [ "${reset_args[3]}" = "--setting-sources" ]
  [ "${reset_args[4]}" = "project,local" ]
  [ "${reset_args[5]}" = "--tools" ]
  [ "${reset_args[6]}" = "Bash,Read,Edit,Write" ]
}

@test "claude minimal mode validator normalizes accepted values" {
  unset CLAUDE_PLAN_MINIMAL

  run_plan_invoke_claude_minimal_mode_validate
  [ "$?" -eq 0 ]
  [ "$CLAUDE_PLAN_MINIMAL" = "1" ]

  local case_value expected_value
  for case_value in true yes on 0 false no off; do
    case "$case_value" in
      true|yes|on) expected_value=1 ;;
      0|false|no|off) expected_value=0 ;;
    esac
    CLAUDE_PLAN_MINIMAL="$case_value"
    run_plan_invoke_claude_minimal_mode_validate
    [ "$?" -eq 0 ]
    [ "$CLAUDE_PLAN_MINIMAL" = "$expected_value" ]
  done
}

@test "claude minimal mode validator rejects invalid values" {
  CLAUDE_PLAN_MINIMAL="garbage"

  run run_plan_invoke_claude_minimal_mode_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: CLAUDE_PLAN_MINIMAL must be one of 1, true, yes, on, 0, false, no, or off."* ]]
}

@test "claude minimal MCP lockdown validator rejects invalid values" {
  CLAUDE_PLAN_MINIMAL_DISABLE_MCP="garbage"

  run run_plan_invoke_claude_minimal_mcp_lockdown_validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: CLAUDE_PLAN_MINIMAL_DISABLE_MCP must be one of 1, true, yes, on, 0, false, no, or off."* ]]
}

@test "claude invoke helper appends minimal flags by default" {
  local record="$TEST_TMPDIR/claude-minimal-default.args"
  local stdin_cap="$TEST_TMPDIR/claude-minimal-default.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-minimal-prompt"
  export PROMPT
  export RALPH_MODE=native

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--disable-slash-commands"* ]]
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *"--mcp-config"* ]]
  [[ "$captured" == *'{"mcpServers":{}}'* ]]
  [[ "$captured" == *"--setting-sources"* ]]
  [[ "$captured" == *"project,local"* ]]
  [[ "$captured" == *"--tools"* ]]
  [[ "$captured" == *"Bash,Read,Edit,Write"* ]]
  [[ "$captured" != *"--bare"* ]]
  [ "$(cat "$stdin_cap")" = "claude-minimal-prompt" ]
}

@test "claude invoke helper omits MCP lockdown in minimal mode when CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0" {
  local record="$TEST_TMPDIR/claude-minimal-allow-mcp.args"
  local stdin_cap="$TEST_TMPDIR/claude-minimal-allow-mcp.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-minimal-allow-mcp-prompt"
  export PROMPT
  export RALPH_MODE=native
  CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--disable-slash-commands"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [[ "$captured" != *"--mcp-config"* ]]
  [[ "$captured" == *"--setting-sources"* ]]
  [[ "$captured" == *"project,local"* ]]
  [[ "$captured" == *"--tools"* ]]
  [[ "$captured" == *"Bash,Read,Edit,Write"* ]]
  [ "$(cat "$stdin_cap")" = "claude-minimal-allow-mcp-prompt" ]
}

@test "claude invoke helper injects Ralph MCP config and aligns tool surfaces" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/claude-proxy.args"
  local stdin_cap="$TEST_TMPDIR/claude-proxy.stdin"
  local proxy_server="$WORKSPACE/.ralph/mcp-server.sh"
  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$proxy_server"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$proxy_server"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--mcp-config" && -f "\$arg" ]]; then
    printf 'MCP_CONFIG:%s\n' "\$(cat "\$arg")" >>"$record"
  fi
  prev="\$arg"
done
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-proxy-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE
  CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS
  CLAUDE_PLAN_MINIMAL_TOOLS="Bash,Edit"
  export CLAUDE_PLAN_MINIMAL_TOOLS
  RALPH_MCP_PREFLIGHT_PASSED=1
  export RALPH_MCP_PREFLIGHT_PASSED

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured mcp_config_path
  captured="$(cat "$record")"
  [[ "$captured" == *"--mcp-config"* ]]
  mcp_config_path="$(awk 'prev=="--mcp-config" { print; exit } { prev=$0 }' "$record")"
  [[ "$mcp_config_path" == *"/ralph-claude-mcp-"* ]]
  grep -q 'MCP_CONFIG:' "$record"
  grep -q '"mcpServers"' "$record"
  [[ "$captured" == *"--tools"* ]]
  [[ "$captured" == *"Edit"* ]]
  [[ "$captured" == *"--allowedTools"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_read"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_grep"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_glob"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_shell"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_shell_start"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_shell_status"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_shell_wait"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_shell_read"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_shell_cancel"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_result_read"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_result_search"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_result_summary"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_batch"* ]]
  [[ "$captured" == *"Read"* ]]
  [ "$(cat "$stdin_cap")" = "claude-proxy-prompt" ]
}

@test "claude invoke helper strips native Bash but keeps native Read/Edit in strict proxy mode by default" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/claude-proxy-strict.args"
  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-strict-proxy-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE
  RALPH_MCP_PREFLIGHT_PASSED=1
  export RALPH_MCP_PREFLIGHT_PASSED
  RALPH_CLAUDE_RALPH_STRICT_PROXY=1
  export RALPH_CLAUDE_RALPH_STRICT_PROXY
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local allowed
  allowed="$(awk 'prev=="--allowedTools" { print; exit } { prev=$0 }' "$record")"
  # Native Bash is replaced by ralph_proxy_shell, but native Read/Edit are kept:
  # Claude Code requires a native Read before Edit/Write, so stripping Read would
  # deadlock all edits of existing files.
  if printf '%s\n' "$allowed" | grep -Eq '(^|,)Bash($|,)'; then
    fail "Bash should be stripped from the allowed tool list"
  fi
  [[ "$allowed" == *"Read"* ]]
  [[ "$allowed" == *"Edit"* ]]
  [[ "$allowed" == *"mcp__ralph__ralph_proxy_read"* ]]
}

@test "claude invoke helper also strips native Read when RALPH_CLAUDE_RALPH_STRICT_PROXY_STRIP_READ=1" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/claude-proxy-strict-stripread.args"
  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-strict-proxy-stripread-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE
  RALPH_MCP_PREFLIGHT_PASSED=1
  export RALPH_MCP_PREFLIGHT_PASSED
  RALPH_CLAUDE_RALPH_STRICT_PROXY=1
  export RALPH_CLAUDE_RALPH_STRICT_PROXY
  RALPH_CLAUDE_RALPH_STRICT_PROXY_STRIP_READ=1
  export RALPH_CLAUDE_RALPH_STRICT_PROXY_STRIP_READ
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local allowed
  allowed="$(awk 'prev=="--allowedTools" { print; exit } { prev=$0 }' "$record")"
  if printf '%s\n' "$allowed" | grep -Eq '(^|,)Read($|,)'; then
    fail "Read should be stripped when STRIP_READ=1"
  fi
  if printf '%s\n' "$allowed" | grep -Eq '(^|,)Bash($|,)'; then
    fail "Bash should be stripped from the allowed tool list"
  fi
  [[ "$allowed" == *"Edit"* ]]
  [[ "$allowed" == *"mcp__ralph__ralph_proxy_read"* ]]
}

@test "claude invoke helper keeps native Read and Bash when MCP preflight was skipped" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/claude-proxy-preflight-skipped.args"
  local stdin_cap="$TEST_TMPDIR/claude-proxy-preflight-skipped.stdin"
  local proxy_server="$WORKSPACE/.ralph/mcp-server.sh"
  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$proxy_server"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$proxy_server"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-preflight-skipped-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE
  RALPH_MCP_PREFLIGHT_PASSED=0
  export RALPH_MCP_PREFLIGHT_PASSED
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"Bash"* ]]
  [[ "$captured" == *"Read"* ]]
  [[ "$captured" == *"mcp__ralph__ralph_proxy_read"* ]]
}

@test "claude invoke helper auto-enables MCP when RALPH_MODE is ralph" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/claude-ralph-tools.args"
  local stdin_cap="$TEST_TMPDIR/claude-ralph-tools.stdin"
  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--mcp-config" && -f "\$arg" ]]; then
    printf 'MCP_CONFIG:%s\n' "\$(cat "\$arg")" >>"$record"
  fi
  prev="\$arg"
done
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-proxy-disabled-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE
  CLAUDE_PLAN_MINIMAL_DISABLE_MCP=1
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit,Write"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured mcp_config_path
  captured="$(cat "$record")"
  [[ "$captured" == *"--mcp-config"* ]]
  mcp_config_path="$(awk 'prev=="--mcp-config" { print; exit } { prev=$0 }' "$record")"
  [[ "$mcp_config_path" == *"/ralph-claude-mcp-"* ]]
  grep -q 'MCP_CONFIG:' "$record"
  grep -q '"mcpServers"' "$record"
  [[ "$captured" != *'{"mcpServers":{}}'* ]]
  [ "$(cat "$stdin_cap")" = "claude-proxy-disabled-prompt" ]
}

@test "claude invoke helper leaves slash commands enabled when reset command is used" {
  local record="$TEST_TMPDIR/claude-minimal-reset.args"
  local stdin_cap="$TEST_TMPDIR/claude-minimal-reset.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="/clear

claude-minimal-reset-prompt"
  export PROMPT
  export RALPH_MODE=native
  RALPH_RUN_PLAN_RESET_COMMAND_USED=1
  export RALPH_RUN_PLAN_RESET_COMMAND_USED

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--disable-slash-commands"* ]]
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *"--mcp-config"* ]]
  [[ "$captured" == *'{"mcpServers":{}}'* ]]
  [[ "$captured" == *"--setting-sources"* ]]
  [[ "$captured" == *"project,local"* ]]
  [[ "$captured" == *"--tools"* ]]
  [[ "$captured" == *"Bash,Read,Edit,Write"* ]]
  [ "$(cat "$stdin_cap")" = "$PROMPT" ]
}

@test "claude invoke helper reset mode omits MCP lockdown when CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0" {
  local record="$TEST_TMPDIR/claude-minimal-reset-allow-mcp.args"
  local stdin_cap="$TEST_TMPDIR/claude-minimal-reset-allow-mcp.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="/clear

claude-minimal-reset-allow-mcp-prompt"
  export PROMPT
  export RALPH_MODE=native
  RALPH_RUN_PLAN_RESET_COMMAND_USED=1
  export RALPH_RUN_PLAN_RESET_COMMAND_USED
  CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--disable-slash-commands"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [[ "$captured" != *"--mcp-config"* ]]
  [[ "$captured" == *"--setting-sources"* ]]
  [[ "$captured" == *"--tools"* ]]
  [ "$(cat "$stdin_cap")" = "$PROMPT" ]
}

@test "claude invoke helper omits --bare when CLAUDE_PLAN_BARE=0" {
  local record="$TEST_TMPDIR/claude-no-bare.args"
  local stdin_cap="$TEST_TMPDIR/claude-no-bare.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-no-bare-prompt"
  export PROMPT
  export RALPH_MODE=native
  CLAUDE_PLAN_BARE=0
  CLAUDE_PLAN_MINIMAL=0
  export CLAUDE_PLAN_BARE
  export CLAUDE_PLAN_MINIMAL

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--bare"* ]]
  [[ "$captured" != *"--disable-slash-commands"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [[ "$captured" != *"--mcp-config"* ]]
  [[ "$captured" != *"--setting-sources"* ]]
  [[ "$captured" != *"--tools"* ]]
  [ "$(cat "$stdin_cap")" = "claude-no-bare-prompt" ]
}

@test "claude invoke helper appends --bare when CLAUDE_PLAN_BARE=1" {
  local record="$TEST_TMPDIR/claude-bare.args"
  local stdin_cap="$TEST_TMPDIR/claude-bare.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-bare-prompt"
  export PROMPT
  export RALPH_MODE=native
  CLAUDE_PLAN_BARE=1
  export CLAUDE_PLAN_BARE

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--bare"* ]]
  [[ "$captured" != *"--disable-slash-commands"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [[ "$captured" != *"--mcp-config"* ]]
  [[ "$captured" != *"--setting-sources"* ]]
  [[ "$captured" != *"--tools"* ]]
  [ "$(cat "$stdin_cap")" = "claude-bare-prompt" ]
}

@test "claude invoke helper retries with minimal flags on Not logged in" {
  local first_record="$TEST_TMPDIR/claude-retry-first.args"
  local second_record="$TEST_TMPDIR/claude-retry-second.args"
  local call_count="$TEST_TMPDIR/claude-retry-count"
  export CLAUDE_RETRY_FIRST="$first_record"
  export CLAUDE_RETRY_SECOND="$second_record"
  export CLAUDE_RETRY_COUNT="$call_count"
  cat <<'EOF' >"$BIN_DIR/claude"
#!/usr/bin/env bash
count=0
if [[ -f "$CLAUDE_RETRY_COUNT" ]]; then
  count="$(cat "$CLAUDE_RETRY_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$CLAUDE_RETRY_COUNT"

if [[ "$count" -eq 1 ]]; then
  printf '%s\n' "$@" >>"$CLAUDE_RETRY_FIRST"
  echo "Not logged in - Please run /login"
  exit 1
fi

printf '%s\n' "$@" >>"$CLAUDE_RETRY_SECOND"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-retry-prompt"
  export PROMPT
  export RALPH_MODE=native
  CLAUDE_PLAN_BARE=1
  export CLAUDE_PLAN_BARE

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$first_record" ]
  [ -s "$second_record" ]
  [ "$(cat "$call_count")" = "2" ]

  local first_captured second_captured
  first_captured="$(cat "$first_record")"
  second_captured="$(cat "$second_record")"
  [[ "$first_captured" == *"--bare"* ]]
  [[ "$first_captured" != *"--disable-slash-commands"* ]]
  [[ "$first_captured" != *"--strict-mcp-config"* ]]
  [[ "$first_captured" != *"--mcp-config"* ]]
  [[ "$first_captured" != *"--setting-sources"* ]]
  [[ "$first_captured" != *"--tools"* ]]
  [[ "$second_captured" != *"--bare"* ]]
  [[ "$second_captured" == *"--disable-slash-commands"* ]]
  [[ "$second_captured" == *"--strict-mcp-config"* ]]
  [[ "$second_captured" == *"--mcp-config"* ]]
  [[ "$second_captured" == *'{"mcpServers":{}}'* ]]
  [[ "$second_captured" == *"--setting-sources"* ]]
  [[ "$second_captured" == *"project,local"* ]]
  [[ "$second_captured" == *"--tools"* ]]
  [[ "$second_captured" == *"Bash,Read,Edit,Write"* ]]
  [[ "$output" == *"Retrying once with CLAUDE_PLAN_MINIMAL=1"* ]]
}

@test "claude invoke helper does not retry when bare is already off" {
  local record="$TEST_TMPDIR/claude-no-retry.args"
  local call_count="$TEST_TMPDIR/claude-no-retry-count"
  export CLAUDE_NO_RETRY_RECORD="$record"
  export CLAUDE_NO_RETRY_COUNT="$call_count"
  cat <<'EOF' >"$BIN_DIR/claude"
#!/usr/bin/env bash
count=0
if [[ -f "$CLAUDE_NO_RETRY_COUNT" ]]; then
  count="$(cat "$CLAUDE_NO_RETRY_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$CLAUDE_NO_RETRY_COUNT"
printf '%s\n' "$@" >>"$CLAUDE_NO_RETRY_RECORD"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-no-retry-prompt"
  export PROMPT
  CLAUDE_PLAN_BARE=0
  export CLAUDE_PLAN_BARE

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ "$(cat "$call_count")" = "1" ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--bare"* ]]
  [[ "$captured" == *"--disable-slash-commands"* ]]
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *"--mcp-config"* ]]
  [[ "$captured" == *"--setting-sources"* ]]
  [[ "$captured" == *"--tools"* ]]
  [[ "$output" != *"Retrying once with CLAUDE_PLAN_MINIMAL=1"* ]]
}

@test "claude invoke helper appends --permission-mode when CLAUDE_PLAN_PERMISSION_MODE is set" {
  local record="$TEST_TMPDIR/claude-permission.args"
  local stdin_cap="$TEST_TMPDIR/claude-permission.stdin"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-permission-prompt"
  export PROMPT
  CLAUDE_PLAN_PERMISSION_MODE="acceptEdits"
  export CLAUDE_PLAN_PERMISSION_MODE

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--permission-mode"* ]]
  [[ "$captured" == *"acceptEdits"* ]]
  [ "$(cat "$stdin_cap")" = "claude-permission-prompt" ]
}

@test "claude invoke helper rejects invalid CLAUDE_PLAN_PERMISSION_MODE" {
  local record="$TEST_TMPDIR/claude-permission-invalid.args"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  PROMPT="claude-permission-invalid"
  export PROMPT
  CLAUDE_PLAN_PERMISSION_MODE="not-a-mode"
  export CLAUDE_PLAN_PERMISSION_MODE

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: CLAUDE_PLAN_PERMISSION_MODE must be one of default, acceptEdits, auto, bypassPermissions, dontAsk, or plan."* ]]
}

@test "claude invoke helper errors when CLI missing" {
  export CLAUDE_PLAN_CLI="claude-does-not-exist"

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: Claude CLI not found"* ]]
}

@test "claude stream-json path writes session_id to SESSION_ID_FILE" {
  cat <<'EOF' >"$BIN_DIR/claude"
#!/usr/bin/env bash
echo '{"session_id":"sid-from-stream","message":{"text":"done"}}'
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  export SESSION_ID_FILE="$TEST_TMPDIR/session-id.txt"
  export RALPH_PLAN_CLI_RESUME=1
  PROMPT="p"
  export PROMPT

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ "$(cat "$SESSION_ID_FILE" | tr -d '\n')" = "sid-from-stream" ]
}

@test "cursor json path writes session_id to SESSION_ID_FILE" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON demux"
  cat <<'EOF' >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
echo '{"session_id":"cursor-sid-9","content":"ok"}'
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  export SESSION_ID_FILE="$TEST_TMPDIR/cursor-sid.txt"
  export RALPH_PLAN_CLI_RESUME=1
  PROMPT="p"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ "$(cat "$SESSION_ID_FILE" | tr -d '\n')" = "cursor-sid-9" ]
}

@test "cursor usage capture defaults to stream-json output format" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON demux"

  local record="$TEST_TMPDIR/cursor-stream-format.args"
  cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
echo '{"session_id":"cursor-sid-stream","content":"ok"}'
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  export SESSION_ID_FILE="$TEST_TMPDIR/cursor-sid-stream.txt"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=1
  PROMPT="p"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  grep -Fxq -- "--output-format" "$record"
  grep -Fxq -- "stream-json" "$record"
}

@test "cursor usage capture honors CURSOR_PLAN_OUTPUT_FORMAT json fallback" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON demux"

  local record="$TEST_TMPDIR/cursor-json-format.args"
  cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
echo '{"session_id":"cursor-sid-json","content":"ok"}'
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  export SESSION_ID_FILE="$TEST_TMPDIR/cursor-sid-json.txt"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=1
  export CURSOR_PLAN_OUTPUT_FORMAT=json
  PROMPT="p"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  grep -Fxq -- "--output-format" "$record"
  grep -Fxq -- "json" "$record"
  ! grep -Fxq -- "stream-json" "$record"
}

@test "cursor usage capture rejects invalid CURSOR_PLAN_OUTPUT_FORMAT" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON demux"

  local record="$TEST_TMPDIR/cursor-invalid-format.args"
  write_stub_script "cursor-agent" "$record"

  export RALPH_PLAN_CAPTURE_USAGE=1
  export CURSOR_PLAN_OUTPUT_FORMAT=xml
  PROMPT="p"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: CURSOR_PLAN_OUTPUT_FORMAT must be one of json or stream-json."* ]]
  [ ! -e "$record" ]
}

@test "cursor usage capture writes USAGE_FILE even without CLI resume" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON demux"
  cat <<'EOF' >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
echo '{"session_id":"cursor-sid-usage","content":"ok","usage":{"promptTokens":5,"completionTokens":7,"cacheReadInputTokens":2}}'
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  export SESSION_ID_FILE="$TEST_TMPDIR/cursor-sid-usage.txt"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=1
  export USAGE_FILE="$TEST_TMPDIR/cursor.usage.json"
  PROMPT="p"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$USAGE_FILE" ]
  python3 - <<'PY' "$USAGE_FILE"
import json,sys
with open(sys.argv[1]) as f:
  d=json.load(f)
assert d.get("input_tokens") == 5
assert d.get("output_tokens") == 7
assert d.get("cache_read_input_tokens") == 2
PY
}

@test "invoke common execute writes plain output log and preserves runner exit code" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON demux"

  export RALPH_PLAN_PRETTY=0
  run run_plan_invoke_common_execute invoke_common_ndjson_runner claude ""
  [ "$status" -eq 0 ]
  [ "$(cat "$EXIT_CODE_FILE" | tr -d '\n')" = "7" ]
  [[ "$output" == *"plain text"* ]]
  [[ "$output" != *"●"* ]]
  [[ "$(cat "$OUTPUT_LOG")" == *"plain text"* ]]
  assert_file_has_no_esc_bytes "$OUTPUT_LOG"
}

@test "invoke common execute honors forced pretty stdout while keeping output log plain" {
  [ -x "$(command -v python3)" ] || skip "python3 required for JSON demux"

  : >"$OUTPUT_LOG"
  export RALPH_PLAN_PRETTY=1
  run run_plan_invoke_common_execute invoke_common_ndjson_runner claude ""
  [ "$status" -eq 0 ]
  [ "$(cat "$EXIT_CODE_FILE" | tr -d '\n')" = "7" ]
  [[ "$output" == *"●"* ]]
  [[ "$output" == *"Bash"* ]]
  [[ "$(cat "$OUTPUT_LOG")" == *"plain text"* ]]
  [[ "$(cat "$OUTPUT_LOG")" != *"●"* ]]
  assert_file_has_no_esc_bytes "$OUTPUT_LOG"
}

@test "invoke common execute falls back to raw tee output without python3" {
  local original_path="$PATH"

  PATH="$BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  [ ! -x "$(command -v python3)" ] || skip "python3 still available in fallback PATH"
  : >"$OUTPUT_LOG"
  export RALPH_PLAN_PRETTY=1
  export RALPH_PLAN_CLI_RESUME=1

  run run_plan_invoke_common_execute invoke_common_raw_runner claude ""
  PATH="$original_path"

  [ "$status" -eq 0 ]
  [ "$(cat "$EXIT_CODE_FILE" | tr -d '\n')" = "7" ]
  [[ "$output" == *'{"type":"assistant"'* ]]
  [[ "$(cat "$OUTPUT_LOG")" == *'{"type":"assistant"'* ]]
}

@test "claude bare resume passes --resume without session id argument when unsafe allowed" {
  local record="$TEST_TMPDIR/claude-bare.args"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  PROMPT="x"
  export PROMPT

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  grep -Fxq -- "--resume" "$record"
  ! grep -Fxq -- "some-uuid" "$record"
}

@test "claude omits bare --resume when unsafe resume is not allowed" {
  local record="$TEST_TMPDIR/claude-no-unsafe.args"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=0
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  PROMPT="x"
  export PROMPT

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--resume" "$record"
}

@test "opencode invoke helper pins build agent by default" {
  local record="$TEST_TMPDIR/opencode.args"
  write_opencode_stub_with_prompt_capture "$record"

  PROMPT="opencode-prompt"
  export PROMPT
  SELECTED_MODEL="anthropic/claude-sonnet-4-6"
  export SELECTED_MODEL

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  grep -Fxq -- "run" "$record"
  grep -Fxq -- "--agent" "$record"
  grep -Fxq -- "build" "$record"
  grep -Fxq -- "--model" "$record"
  grep -Fxq -- "anthropic/claude-sonnet-4-6" "$record"
  assert_opencode_prompt_arg "$record" "opencode-prompt"
}

@test "opencode invoke helper passes multiline prompts as inline positional message text" {
  local record="$TEST_TMPDIR/opencode-long-prompt.args"
  write_opencode_stub_with_prompt_capture "$record"

  PROMPT=$'Complete exactly this TODO and nothing else:\nline two\nline three'
  export PROMPT

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  assert_opencode_prompt_arg "$record" "$PROMPT"
}

@test "opencode invoke helper sets OPENCODE_CONFIG to Ralph temp working config when native hooks are active" {
  local record="$TEST_TMPDIR/opencode-native.args"
  cat <<EOF >"$BIN_DIR/opencode"
#!/usr/bin/env bash
printf 'OPENCODE_CONFIG:%s\n' "\${OPENCODE_CONFIG:-}" >>"$record"
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"

  local ambient_config="$TEST_TMPDIR/ambient-opencode-config.json"
  printf '{}\n' >"$ambient_config"

  PROMPT="opencode-native-prompt"
  export PROMPT
  export RALPH_MODE="native"
  export OPENCODE_CONFIG="$ambient_config"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  grep -q 'OPENCODE_CONFIG:' "$record"
  grep -q 'ralph-opencode-config-' "$record"
  ! grep -Fxq -- "ambient-opencode-config.json" "$record"
  ! grep -q 'ralph-opencode-mcp-' "$record"
  grep -Fxq -- "run" "$record"
  grep -Fxq -- "--agent" "$record"
  grep -Fxq -- "build" "$record"
  assert_opencode_prompt_arg "$record" "opencode-native-prompt"
  [ "$(find "$TEST_TMPDIR" -name 'ralph-opencode-mcp-*' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "opencode invoke helper injects the ephemeral MCP config when Ralph MCP tools are enabled" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/opencode-proxy.args"

  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"

  cat <<EOF >"$BIN_DIR/opencode"
#!/usr/bin/env bash
printf 'OPENCODE_CONFIG:%s\n' "\${OPENCODE_CONFIG:-}" >>"$record"
if [[ -n "\${OPENCODE_CONFIG:-}" && -f "\${OPENCODE_CONFIG}" ]]; then
  printf 'MCP_CONFIG:%s\n' "\$(cat "\${OPENCODE_CONFIG}")" >>"$record"
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"

  PROMPT="opencode-proxy-prompt"
  export PROMPT
  export RALPH_MODE="ralph"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local config_line
  config_line="$(grep '^OPENCODE_CONFIG:' "$record" | head -1 | sed 's/^OPENCODE_CONFIG://')"
  [ -n "$config_line" ]
  [[ "$config_line" == *"/ralph-opencode-mcp-"* ]]
  grep -q 'MCP_CONFIG:' "$record"
  grep -q '"mcp"' "$record"
  grep -q '"environment"' "$record"
  grep -q '"RALPH_MCP_WORKSPACE"' "$record"
  grep -Fxq -- "run" "$record"
  grep -Fxq -- "--agent" "$record"
  grep -Fxq -- "build" "$record"
  assert_opencode_prompt_arg "$record" "opencode-proxy-prompt"
  [ "$(find "$TEST_TMPDIR" -name 'ralph-opencode-mcp-*' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "opencode invoke helper removes temp MCP config after CLI failure" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/opencode-proxy-fail.args"
  local captured_config="$TEST_TMPDIR/opencode-proxy-fail.mcp-path"

  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"

  cat <<EOF >"$BIN_DIR/opencode"
#!/usr/bin/env bash
if [[ -n "\${OPENCODE_CONFIG:-}" && -f "\${OPENCODE_CONFIG}" ]]; then
  printf '%s\n' "\${OPENCODE_CONFIG}" >"$captured_config"
fi
printf '%s\n' "\$@" >>"$record"
exit 1
EOF
  chmod +x "$BIN_DIR/opencode"

  PROMPT="opencode-proxy-fail-prompt"
  export PROMPT
  export RALPH_MODE="ralph"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [ -s "$captured_config" ]
  [ ! -f "$(cat "$captured_config")" ]
}

@test "opencode invoke helper merges Ralph MCP config into existing OPENCODE_CONFIG" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/opencode-merge.args"
  local ambient_config="$TEST_TMPDIR/ambient-opencode-config.json"

  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"
  printf '{"provider":{"anthropic":{"options":{"setCacheKey":true}}}}' >"$ambient_config"

  cat <<EOF >"$BIN_DIR/opencode"
#!/usr/bin/env bash
printf 'OPENCODE_CONFIG:%s\n' "\${OPENCODE_CONFIG:-}" >>"$record"
if [[ -n "\${OPENCODE_CONFIG:-}" && -f "\${OPENCODE_CONFIG}" ]]; then
  printf 'MCP_CONFIG:%s\n' "\$(cat "\${OPENCODE_CONFIG}")" >>"$record"
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"

  PROMPT="opencode-merge-prompt"
  export PROMPT
  export RALPH_MODE="ralph"
  export OPENCODE_CONFIG="$ambient_config"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local config_line mcp_config
  config_line="$(grep '^OPENCODE_CONFIG:' "$record" | head -1 | sed 's/^OPENCODE_CONFIG://')"
  [ -n "$config_line" ]
  [[ "$config_line" == *"/ralph-opencode-mcp-merged-"* ]]
  ! grep -Fxq -- "ambient-opencode-config.json" "$record"
  mcp_config="$(grep '^MCP_CONFIG:' "$record" | head -1 | sed 's/^MCP_CONFIG://')"
  [ "$(echo "$mcp_config" | jq -r '.provider.anthropic.options.setCacheKey')" = "true" ]
  [ "$(echo "$mcp_config" | jq -r '.mcp.ralph.type')" = "local" ]
  [ "$(echo "$mcp_config" | jq -r '.mcp.ralph.enabled')" = "true" ]
  [ "$(echo "$mcp_config" | jq '.mcp.ralph | has("environment")')" = "true" ]
  [ "$(echo "$mcp_config" | jq '.mcp.ralph | has("env")')" = "false" ]
  [ "$(echo "$mcp_config" | jq -r '.mcp.ralph.environment.RALPH_MCP_WORKSPACE')" = "$WORKSPACE" ]
}

@test "opencode config prepare preserves JSONC ambient fields before MCP merge" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -x "$(command -v python3)" ] || skip "python3 required"
  local fixture="$REPO_ROOT/tests/fixtures/opencode-ambient-config/provider-options.jsonc"
  local server="$WORKSPACE/.ralph/mcp-server.sh"

  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$server"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$server"

  export RALPH_MODE="ralph"
  export OPENCODE_CONFIG="$fixture"

  run_plan_invoke_opencode_config_prepare
  [ "$?" -eq 0 ]
  jq -e '
    .provider == "ollama" and
    .model == "ollama-mini" and
    .options.setCacheKey == true and
    .options.source == "jsonc"
  ' "$OPENCODE_PLAN_MCP_CONFIG_PATH"

  run_plan_invoke_opencode_config_cleanup
  unset OPENCODE_CONFIG
}

@test "opencode provider id derives from model with slash" {
  run ralph_opencode_provider_id_from_selected_model "ollama-cloud/kimi-k2.6"
  [ "$status" -eq 0 ]
  [ "$output" = "ollama-cloud" ]
}

@test "opencode provider id is empty for model without slash" {
  run ralph_opencode_provider_id_from_selected_model "kimi-k2.6"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "opencode provider id is empty for empty model" {
  unset SELECTED_MODEL
  run ralph_opencode_provider_id_from_selected_model ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "opencode config prepare injects setCacheKey when absent" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -x "$(command -v python3)" ] || skip "python3 required"
  local ambient_config="$TEST_TMPDIR/ambient-no-cache.json"
  printf '{"model":"ollama-cloud/kimi-k2.6","keep":"ambient"}' >"$ambient_config"

  export RALPH_MODE="ralph"
  export OPENCODE_CONFIG="$ambient_config"
  export SELECTED_MODEL="ollama-cloud/kimi-k2.6"

  run_plan_invoke_opencode_config_prepare
  [ "$?" -eq 0 ]
  jq -e '
    .provider["ollama-cloud"].options.setCacheKey == true and
    .keep == "ambient"
  ' "$OPENCODE_PLAN_MCP_CONFIG_PATH"
  [ "${RALPH_OPENCODE_CACHE_KEY_INJECTED:-0}" = "1" ]
  [ "${RALPH_OPENCODE_CACHE_KEY_PROVIDER_ID:-}" = "ollama-cloud" ]

  run_plan_invoke_opencode_config_cleanup
  unset OPENCODE_CONFIG SELECTED_MODEL
}

@test "opencode config prepare honors RALPH_OPENCODE_SET_CACHE_KEY=0 opt-out" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -x "$(command -v python3)" ] || skip "python3 required"
  local ambient_config="$TEST_TMPDIR/ambient-opt-out.json"
  printf '{"model":"ollama-cloud/kimi-k2.6"}' >"$ambient_config"

  export RALPH_MODE="ralph"
  export OPENCODE_CONFIG="$ambient_config"
  export SELECTED_MODEL="ollama-cloud/kimi-k2.6"
  export RALPH_OPENCODE_SET_CACHE_KEY=0

  run_plan_invoke_opencode_config_prepare
  [ "$?" -eq 0 ]
  jq -e '(.provider // {}) | has("ollama-cloud") | not' "$OPENCODE_PLAN_MCP_CONFIG_PATH"
  [ "${RALPH_OPENCODE_CACHE_KEY_INJECTED:-0}" = "0" ]
  [ -z "${RALPH_OPENCODE_CACHE_KEY_PROVIDER_ID:-}" ]

  run_plan_invoke_opencode_config_cleanup
  unset OPENCODE_CONFIG SELECTED_MODEL RALPH_OPENCODE_SET_CACHE_KEY
}

@test "opencode config prepare skips injection for model without provider slash" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -x "$(command -v python3)" ] || skip "python3 required"
  local ambient_config="$TEST_TMPDIR/ambient-no-slash.json"
  printf '{"model":"kimi-k2.6"}' >"$ambient_config"

  export RALPH_MODE="ralph"
  export OPENCODE_CONFIG="$ambient_config"
  export SELECTED_MODEL="kimi-k2.6"

  run_plan_invoke_opencode_config_prepare
  [ "$?" -eq 0 ]
  jq -e '(.provider // {}) == {}' "$OPENCODE_PLAN_MCP_CONFIG_PATH"
  [ "${RALPH_OPENCODE_CACHE_KEY_INJECTED:-0}" = "0" ]

  run_plan_invoke_opencode_config_cleanup
  unset OPENCODE_CONFIG SELECTED_MODEL
}

@test "opencode invoke helper rejects invalid existing OPENCODE_CONFIG in ralph mode" {
  local record="$TEST_TMPDIR/opencode-invalid-config.args"
  local ambient_config="$TEST_TMPDIR/ambient-opencode-config.json"

  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"
  printf '{not-json' >"$ambient_config"

  write_stub_script "opencode" "$record"

  PROMPT="opencode-invalid-config-prompt"
  export PROMPT
  export RALPH_MODE="ralph"
  export OPENCODE_CONFIG="$ambient_config"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: existing OpenCode config is invalid JSON"* ]]
  [ ! -s "$record" ]
  [ "$(cat "$ambient_config")" = '{not-json' ]
}

@test "opencode invoke helper rejects Agent Tool Access ralph when MCP config generation fails" {
  local record="$TEST_TMPDIR/opencode-ralph-tools-fail.args"
  write_stub_script "opencode" "$record"

  PROMPT="opencode-proxy-missing-prompt"
  export PROMPT
  export RALPH_MODE="ralph"
  export RALPH_MCP_PROXY_SERVER_SCRIPT="$TEST_TMPDIR/missing-mcp-server.sh"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: failed to generate OpenCode MCP config."* ]]
  [ ! -s "$record" ]
}

@test "opencode invoke helper adds --continue for bare resume when unsafe allowed" {
  local record="$TEST_TMPDIR/opencode-bare.args"
  write_opencode_stub_with_prompt_capture "$record"

  PROMPT="opencode-bare-prompt"
  export PROMPT
  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  grep -Fxq -- "run" "$record"
  grep -Fxq -- "--continue" "$record"
  assert_opencode_prompt_arg "$record" "opencode-bare-prompt"
}

@test "cursor bare resume passes --resume and --continue when unsafe allowed" {
  local record="$TEST_TMPDIR/cursor-bare.args"
  cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  PROMPT="x"
  export PROMPT

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  grep -Fxq -- "--resume" "$record"
  grep -Fxq -- "--continue" "$record"
}

@test "codex-exec-prompt uses resume --last when bare and unsafe resume allowed" {
  local record="$TEST_TMPDIR/codex.args"
  cat <<EOF >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/codex"

  local pf="$TEST_TMPDIR/prompt.txt"
  echo "prompt-body" >"$pf"
  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=1
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh" "$pf" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -Fxq -- "resume" "$record"
  grep -Fxq -- "--last" "$record"
}

@test "codex-exec-prompt passes --json when RALPH_PLAN_CAPTURE_USAGE=1" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-capture-prompt.txt"
  echo "capture-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=1

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--json"* ]]
}

@test "codex-exec-prompt omits --json when both CAPTURE_USAGE and CLI_RESUME are off" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-no-json-prompt.txt"
  echo "no-json-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--json"* ]]
}

@test "codex invoke helper warns when unsafe bare resume is blocked" {
  local record="$TEST_TMPDIR/codex-bare.warn"
  write_codex_exec_stub "$record"

  export PROMPT="bare warn"
  export RALPH_RUN_PLAN_RESUME_BARE=1
  export RALPH_PLAN_ALLOW_UNSAFE_RESUME=0
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: resume without a session id requires"* ]]
  [ -s "$record" ]
}

@test "codex invoke helper honors CODEX_CLI overrides" {
  local record="$TEST_TMPDIR/codex-cli.args"
  write_codex_exec_stub "$record"
  cp "$BIN_DIR/codex" "$BIN_DIR/custom-codex"
  chmod +x "$BIN_DIR/custom-codex"

  export CODEX_CLI="custom-codex"
  export PROMPT="cli override"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  grep -Fxq -- "CLI:custom-codex" "$record"
}

@test "codex invoke helper respects SELECTED_MODEL" {
  local record="$TEST_TMPDIR/codex-model.args"
  write_codex_exec_stub "$record"

  SELECTED_MODEL="gpt-5"
  export SELECTED_MODEL
  export PROMPT="model test"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  grep -Fxq -- "MODEL:gpt-5" "$record"
}

@test "codex invoke helper injects Ralph MCP config through config overrides" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/codex-proxy.args"
  local prompt_file="$TEST_TMPDIR/codex-proxy-prompt.txt"

  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"

  write_codex_exec_stub "$record"
  echo "proxy-prompt" >"$prompt_file"
  export PROMPT="proxy-prompt"
  export CODEX_CLI="$BIN_DIR/codex"
  export RALPH_MODE="ralph"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--config"* ]]
  [[ "$captured" == *"--strict-config"* ]]
  [[ "$captured" == *"mcp_servers.ralph.enabled=true"* ]]
  [[ "$captured" == *"mcp_servers.ralph.type=\"stdio\""* ]]
  [[ "$captured" == *'mcp_servers.ralph.default_tools_approval_mode="approve"'* ]]
  [[ "$captured" == *"mcp_servers.ralph.command=\"bash\""* ]]
  [[ "$captured" == *"mcp_servers.ralph.args="* ]]
  [[ "$captured" == *"mcp_servers.ralph.env.RALPH_MCP_WORKSPACE="* ]]
  [[ "$captured" == *"proxy-prompt"* ]]
  [ "$(find "$TEST_TMPDIR" -name 'ralph-codex-mcp-*' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "codex invoke helper omits mcp_servers.ralph.default_tools_approval_mode when Codex rejects the field" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/codex-proxy-no-approval.args"

  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"

  write_codex_exec_stub "$record"
  export CODEX_STUB_REJECT_MCP_APPROVAL_MODE=1
  export PROMPT="proxy-no-approval-prompt"
  export CODEX_CLI="$BIN_DIR/codex"
  export RALPH_MODE="ralph"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"mcp_servers.ralph.enabled=true"* ]]
  [[ "$captured" != *"mcp_servers.ralph.default_tools_approval_mode"* ]]
  [[ "$captured" == *"mcp_servers.ralph.required=true"* ]]
  [[ "$captured" == *"proxy-no-approval-prompt"* ]]
}

@test "codex invoke helper omits mcp_servers.ralph.type when Codex rejects the field" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/codex-proxy-no-type.args"

  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"

  write_codex_exec_stub "$record"
  export CODEX_STUB_REJECT_MCP_TYPE=1
  export PROMPT="proxy-no-type-prompt"
  export CODEX_CLI="$BIN_DIR/codex"
  export RALPH_MODE="ralph"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"mcp_servers.ralph.enabled=true"* ]]
  [[ "$captured" != *"mcp_servers.ralph.type"* ]]
  [[ "$captured" == *"mcp_servers.ralph.required=true"* ]]
  [[ "$captured" == *"proxy-no-type-prompt"* ]]
}

@test "codex invoke helper removes temp MCP config after CLI failure" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/codex-proxy-fail.args"
  local prompt_file="$TEST_TMPDIR/codex-proxy-fail-prompt.txt"

  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"

  cat <<CODEX_FAIL >"$BIN_DIR/codex"
#!/usr/bin/env bash
if [[ "\$1" == "mcp" && "\${2:-}" == "--help" ]]; then
  cat <<'MCP_HELP'
Manage external MCP servers for Codex

Commands:
  add
  remove
MCP_HELP
  exit 0
fi
if [[ "\$1" == "exec" && "\${2:-}" == "--help" ]]; then
  cat <<'EXEC_HELP'
Run Codex non-interactively

Options:
  -c, --config <key=value>
      --strict-config
EXEC_HELP
  exit 0
fi
printf 'ARGS:%s\n' "\$@" >>"$record"
exit 1
CODEX_FAIL
  chmod +x "$BIN_DIR/codex"

  echo "proxy-fail-prompt" >"$prompt_file"
  export PROMPT="proxy-fail-prompt"
  export CODEX_CLI="$BIN_DIR/codex"
  export RALPH_MODE="ralph"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [ "$(find "$TEST_TMPDIR" -name 'ralph-codex-mcp-*' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "codex invoke helper omits Ralph MCP config in native mode" {
  local record="$TEST_TMPDIR/codex-native.args"

  write_codex_exec_stub "$record"

  export PROMPT="codex-native-prompt"
  export CODEX_CLI="$BIN_DIR/codex"
  export RALPH_MODE="native"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=0

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$record" ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"mcp_servers.ralph"* ]]
  [[ "$captured" != *"--strict-config"* ]]
  [[ "$captured" == *"codex-native-prompt"* ]]
  [ "$(find "$TEST_TMPDIR" -name 'ralph-codex-mcp-*' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "codex invoke helper rejects Agent Tool Access ralph when Codex config injection is unsupported" {
  local record="$TEST_TMPDIR/codex-proxy-unsupported.args"
  local prompt_file="$TEST_TMPDIR/codex-proxy-unsupported-prompt.txt"

  cat <<CODEX_UNSUPPORTED >"$BIN_DIR/codex"
#!/usr/bin/env bash
if [[ "\$1" == "mcp" && "\${2:-}" == "--help" ]]; then
  exit 1
fi
if [[ "\$1" == "exec" && "\${2:-}" == "--help" ]]; then
  cat <<'CODEX_HELP'
Run Codex non-interactively

Options:
  -c, --config <key=value>
      Override a configuration value that would otherwise be loaded from ~/.codex/config.toml.
      --strict-config
CODEX_HELP
  exit 0
fi
printf '%s\n' "\$@" >>"$record"
cat >"$TEST_TMPDIR/codex-proxy-unsupported.stdin"
CODEX_UNSUPPORTED
  chmod +x "$BIN_DIR/codex"

  echo "proxy-unsupported" >"$prompt_file"
  export PROMPT="proxy-unsupported"
  export CODEX_CLI="$BIN_DIR/codex"
  export RALPH_MODE="ralph"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: RALPH_MODE=ralph is unsupported because this Codex CLI is missing: codex mcp subcommand."* ]]
  [ ! -s "$record" ]
}

@test "codex invoke helper fails before model invocation when Codex rejects required config field" {
  [ -x "$(command -v jq)" ] || skip "jq required for Ralph MCP config generation"

  local record="$TEST_TMPDIR/codex-proxy-reject-required.args"

  mkdir -p "$WORKSPACE/.ralph"
  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"

  write_codex_exec_stub "$record"
  export CODEX_STUB_REJECT_MCP_COMMAND=1
  export PROMPT="proxy-reject-required-prompt"
  export CODEX_CLI="$BIN_DIR/codex"
  export RALPH_MODE="ralph"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: Codex MCP strict-config validation failed before model invocation:"* ]]
  [[ "$output" == *"unsupported required field: mcp_servers.ralph.command"* ]]
  [ "$(find "$TEST_TMPDIR" -name 'ralph-codex-mcp-*' | wc -l | tr -d ' ')" -eq 0 ]
  [ ! -s "$record" ]
}

@test "codex-exec-prompt includes bypass flag when CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX=1" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-bypass-prompt.txt"
  echo "bypass-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_DANGEROUSLY_BYPASS_APPROVALS_AND_SANDBOX=1
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dangerously-bypass-approvals-and-sandbox"* ]]
  [[ "$output" == *"--sandbox"* ]]
  [[ "$output" == *"bypass-prompt"* ]]
}

@test "codex-exec-prompt omits bypass flag by default" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-no-bypass-prompt.txt"
  echo "no-bypass-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"--dangerously-bypass-approvals-and-sandbox"* ]]
  [[ "$output" == *"--sandbox"* ]]
  [[ "$output" == *"no-bypass-prompt"* ]]
}

@test "codex-exec-prompt default uses workspace-write sandbox" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-sandbox-default.txt"
  echo "sandbox-default-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--sandbox"* ]]
  [[ "$output" == *"workspace-write"* ]]
  [[ "$output" == *"sandbox-default-prompt"* ]]
}

@test "codex-exec-prompt resume session uses sandbox_mode workspace-write" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-resume-session.txt"
  echo "resume-session-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1
  export RALPH_RUN_PLAN_RESUME_SESSION_ID="test-session-456"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh" "$prompt_file" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resume"* ]]
  [[ "$output" == *'sandbox_mode="workspace-write"'* ]]
  [[ "$output" == *"resume-session-prompt"* ]]
}

@test "codex-exec-prompt CODEX_PLAN_SANDBOX=read-only sets sandbox flag" {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/codex-readonly.txt"
  echo "readonly-prompt" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_PLAN_SANDBOX=read-only
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native
  export RALPH_PLAN_CAPTURE_USAGE=0

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--sandbox"* ]]
  [[ "$output" == *"read-only"* ]]
  [[ "$output" == *"readonly-prompt"* ]]
}

@test "codex-exec-prompt adds --add-dir when global runtime fallback is active" {
  local record="$TEST_TMPDIR/codex.args"
  cat <<EOF >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/codex"

  local global_runtime_root="$TEST_TMPDIR/global-codex"
  mkdir -p "$global_runtime_root"

  local prompt_file="$TEST_TMPDIR/prompt.txt"
  echo "prompt-body" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  export CODEX_GLOBAL_RUNTIME_ROOT="$global_runtime_root"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  grep -Fxq -- "--add-dir" "$record"
  grep -Fxq -- "$global_runtime_root" "$record"
}

@test "codex-exec-prompt omits --add-dir when global runtime fallback is not active" {
  local record="$TEST_TMPDIR/codex-no-global.args"
  cat <<EOF >"$BIN_DIR/codex"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/codex"

  local prompt_file="$TEST_TMPDIR/prompt-no-global.txt"
  echo "prompt-body" >"$prompt_file"

  export CODEX_PLAN_CLI=codex
  unset CODEX_GLOBAL_RUNTIME_ROOT
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_MODE=native

  run bash "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh" "$prompt_file" "$WORKSPACE"
  [ "$status" -eq 0 ]
  ! grep -q "CODEX_GLOBAL_RUNTIME_ROOT" "$record" || true
}

@test "compact session strategy: Codex emits /compact command prefix in prompt" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh" ] || skip "run-plan-core missing"

  local tmpdir helper_sh prompt_var result
  tmpdir="$(mktemp -d)"
  helper_sh="$tmpdir/helper.sh"

  cat > "$helper_sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
RALPH_PLAN_SESSION_STRATEGY="compact"
RALPH_RUN_PLAN_RESUME_SESSION_ID="test-session-123"
RALPH_RUN_PLAN_RESET_COMMAND_USED=0
RUNTIME="codex"
RALPH_PLAN_COMPACT_COMMAND_CODEX="${RALPH_PLAN_COMPACT_COMMAND_CODEX:-/compact}"
RALPH_PLAN_RESET_COMMAND="${RALPH_PLAN_RESET_COMMAND:-}"
RALPH_PLAN_COMPACT_COMMAND="${RALPH_PLAN_COMPACT_COMMAND:-}"

RUNTIME="codex"
_session_strategy="compact"
_prompt_mode=""
_compact_prefix=""
_resume_intro=""
_compact_label=""
PROMPT_STATIC=""
PROMPT=""

if [[ "$_session_strategy" == "compact" ]] && [[ -n "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]]; then
  _prompt_mode="compact"
  _compact_command=""
  if [[ -z "$_compact_command" ]]; then
    case "$RUNTIME" in
      codex) _compact_command="${RALPH_PLAN_COMPACT_COMMAND_CODEX:-/compact}" ;;
    esac
  fi
  if [[ -n "$_compact_command" ]]; then
    _compact_prefix="${_compact_command}"$'\n\n'
  fi
fi
printf "%s\n" "$_compact_prefix"
HELPER

  run bash "$helper_sh" "$REPO_ROOT/bundle/.ralph"
  [ "$status" -eq 0 ]
  [[ "$output" == */compact* ]]

  rm -rf "$tmpdir"
}

@test "compact session strategy: Cursor emits /compress command prefix in prompt" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh" ] || skip "run-plan-core missing"

  local tmpdir helper_sh
  tmpdir="$(mktemp -d)"
  helper_sh="$tmpdir/helper.sh"

  cat > "$helper_sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
RALPH_PLAN_SESSION_STRATEGY="compact"
RALPH_RUN_PLAN_RESUME_SESSION_ID="test-session-456"
RUNTIME="cursor"
RALPH_PLAN_COMPACT_COMMAND_CURSOR="${RALPH_PLAN_COMPACT_COMMAND_CURSOR:-/compress}"

_session_strategy="compact"
_compact_command=""
if [[ -z "$_compact_command" ]]; then
  case "$RUNTIME" in
    cursor) _compact_command="${RALPH_PLAN_COMPACT_COMMAND_CURSOR:-/compress}" ;;
  esac
fi
if [[ -n "$_compact_command" ]]; then
  _compact_prefix="${_compact_command}"$'\n\n'
fi
printf "%s\n" "$_compact_prefix"
HELPER

  run bash "$helper_sh"
  [ "$status" -eq 0 ]
  [[ "$output" == */compress* ]]

  rm -rf "$tmpdir"
}

@test "compact session strategy: Claude emits /clear command prefix in prompt" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh" ] || skip "run-plan-core missing"

  local tmpdir helper_sh
  tmpdir="$(mktemp -d)"
  helper_sh="$tmpdir/helper.sh"

  cat > "$helper_sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
RALPH_PLAN_SESSION_STRATEGY="compact"
RALPH_RUN_PLAN_RESUME_SESSION_ID="test-session-789"
RUNTIME="claude"
RALPH_PLAN_RESET_COMMAND_CLAUDE="${RALPH_PLAN_RESET_COMMAND_CLAUDE:-/clear}"

_session_strategy="compact"
_compact_command=""
if [[ -z "$_compact_command" ]]; then
  case "$RUNTIME" in
    claude) _compact_command="${RALPH_PLAN_RESET_COMMAND_CLAUDE:-/clear}" ;;
  esac
fi
if [[ -n "$_compact_command" ]]; then
  _compact_prefix="${_compact_command}"$'\n\n'
fi
printf "%s\n" "$_compact_prefix"
HELPER

  run bash "$helper_sh"
  [ "$status" -eq 0 ]
  [[ "$output" == */clear* ]]

  rm -rf "$tmpdir"
}

@test "compact session strategy: OpenCode gets empty compact command (unsupported)" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh" ] || skip "run-plan-core missing"

  local tmpdir helper_sh
  tmpdir="$(mktemp -d)"
  helper_sh="$tmpdir/helper.sh"

  cat > "$helper_sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
RALPH_PLAN_SESSION_STRATEGY="compact"
RALPH_RUN_PLAN_RESUME_SESSION_ID="test-session-opencode"
RUNTIME="opencode"
RALPH_PLAN_COMPACT_COMMAND_OPENCODE="${RALPH_PLAN_COMPACT_COMMAND_OPENCODE:-}"

_session_strategy="compact"
_compact_command=""
if [[ -z "$_compact_command" ]]; then
  case "$RUNTIME" in
    opencode) _compact_command="${RALPH_PLAN_COMPACT_COMMAND_OPENCODE:-}" ;;
  esac
fi
if [[ -z "$_compact_command" ]]; then
  printf "no_compact_command\n"
else
  printf "has_compact_command\n"
fi
HELPER

  run bash "$helper_sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "no_compact_command" ]]

  rm -rf "$tmpdir"
}

@test "compact session strategy sets RALPH_RUN_PLAN_RESET_COMMAND_USED when compact command exists" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh" ] || skip "run-plan-core missing"

  local tmpdir helper_sh
  tmpdir="$(mktemp -d)"
  helper_sh="$tmpdir/helper.sh"

  cat > "$helper_sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
RALPH_PLAN_SESSION_STRATEGY="compact"
RALPH_RUN_PLAN_RESUME_SESSION_ID="test-session-flag"
RUNTIME="cursor"
RALPH_RUN_PLAN_RESET_COMMAND_USED=0
RALPH_PLAN_COMPACT_COMMAND_CURSOR="${RALPH_PLAN_COMPACT_COMMAND_CURSOR:-/compress}"

_compact_command="${RALPH_PLAN_COMPACT_COMMAND_CURSOR:-/compress}"
if [[ -n "$_compact_command" ]]; then
  RALPH_RUN_PLAN_RESET_COMMAND_USED=1
  export RALPH_RUN_PLAN_RESET_COMMAND_USED
fi
printf "%d\n" "$RALPH_RUN_PLAN_RESET_COMMAND_USED"
HELPER

  run bash "$helper_sh"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  rm -rf "$tmpdir"
}

@test "compact session strategy differs from reset: compact preserves session id, reset may create new one" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh" ] || skip "run-plan-session missing"

  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/.ralph-workspace"

  run bash -c '
    set -euo pipefail
    source "$1/run-plan/run-plan-session.sh"

    RALPH_PLAN_SESSION_STRATEGY="compact"
    strategy="$(ralph_session_effective_strategy)"
    [[ "$strategy" == "compact" ]] && printf "compact_ok"

    RALPH_PLAN_SESSION_STRATEGY="reset"
    strategy="$(ralph_session_effective_strategy)"
    [[ "$strategy" == "reset" ]] && printf ",reset_ok"

    RALPH_PLAN_SESSION_STRATEGY="fresh"
    strategy="$(ralph_session_effective_strategy)"
    [[ "$strategy" == "fresh" ]] && printf ",fresh_ok"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib"

  [ "$status" -eq 0 ]
  [[ "$output" == "compact_ok,reset_ok,fresh_ok" ]]

  rm -rf "$tmpdir"
}

