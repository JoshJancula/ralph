#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  TEST_TMPDIR="$(mktemp -d)"
  BIN_DIR="$TEST_TMPDIR/bin"
  ISOLATED_HOME="$TEST_TMPDIR/home"
  mkdir -p "$BIN_DIR" "$ISOLATED_HOME"
  export TMPDIR="$TEST_TMPDIR"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  export HOME="$ISOLATED_HOME"
  export RALPH_RUNTIME_MCP_HOME="$ISOLATED_HOME"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export SCRIPT_DIR="$RALPH_DIR"
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.claude"
  cp "$REPO_ROOT/bundle/.ralph/mcp-server.sh" "$WORKSPACE/.ralph/mcp-server.sh"
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"

  ORIGINAL_PATH="$PATH"
  PATH="$BIN_DIR:$PATH"

  export OUTPUT_LOG="$TEST_TMPDIR/output.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/exit-code"
  export PROMPT=""
  unset PROMPT_STATIC
  unset RALPH_RUNTIME_MCP_RESOLVE_PATH
  unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
  unset RALPH_RUNTIME_MCP_SUMMARY_JSON
  unset CLAUDE_PLAN_MCP_CONFIG_PATH
  unset CLAUDE_PLAN_MCP_CONFIG_OWNED
  unset CLAUDE_PLAN_ALLOWED_TOOLS
  unset CLAUDE_PLAN_MINIMAL_DISABLE_MCP
  unset CLAUDE_PLAN_BARE
  unset CLAUDE_PLAN_MINIMAL
  unset RALPH_MODE
  unset RALPH_AGENT_TOOL_ACCESS
  unset RALPH_MCP_PREFLIGHT_PASSED
  unset PREBUILT_AGENT
}

teardown() {
  PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

write_claude_stub() {
  local record="$1"
  local stdin_cap="${2:-}"
  if [[ -n "$stdin_cap" ]]; then
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
  else
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
EOF
  fi
  chmod +x "$BIN_DIR/claude"
}

@test "claude minimal mode preserves user, project, and local setting sources" {
  local -a args=()

  run_plan_invoke_claude_apply_minimal_flags args

  [ "${args[4]}" = "--setting-sources" ]
  [ "${args[5]}" = "user,project,local" ]
}

@test "claude no mode uses merged ambient MCP config instead of empty lockdown" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-no-ambient.args"
  write_claude_stub "$record"

  printf '%s\n' '{"mcpServers":{"ambient":{"command":"ambient-cmd"}}}' >"$WORKSPACE/.mcp.json"

  run bash -c '
    set -euo pipefail
    export PATH="$5/bin:$PATH"
    source "$1"
    source "$2"
    source "$6"
    export RALPH_MODE=no
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve claude "$3" "" "$3"
    export PROMPT=claude-no-ambient-prompt
    export OUTPUT_LOG="$4/output.log"
    export EXIT_CODE_FILE="$4/exit-code"
    ralph_run_plan_invoke_claude
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" "$WORKSPACE" "$TEST_TMPDIR" "$TEST_TMPDIR" "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  [ "$status" -eq 0 ]
  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *"--mcp-config"* ]]
  [[ "$captured" == *"user,project,local"* ]]
  grep -q 'MCP_CONFIG:' "$record"
  grep -q '"ambient"' "$record"
  grep -q 'ambient-cmd' "$record"
  [[ "$captured" != *'{"mcpServers":{}}'* ]]
}

@test "claude ralph mode merges ambient and ralph MCP servers" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-ralph.args"
  write_claude_stub "$record"

  printf '%s\n' '{"mcpServers":{"ambient":{"command":"ambient-cmd"}}}' >"$WORKSPACE/.mcp.json"

  PROMPT="claude-ralph-prompt"
  export PROMPT
  export RALPH_MODE=ralph
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS
  RALPH_MCP_PREFLIGHT_PASSED=1
  export RALPH_MCP_PREFLIGHT_PASSED

  run bash -c '
    set -euo pipefail
    export PATH="$5/bin:$PATH"
    source "$1"
    source "$2"
    source "$6"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve claude "$3" "" "$3"
    export PROMPT=claude-ralph-prompt
    export OUTPUT_LOG="$4/output.log"
    export EXIT_CODE_FILE="$4/exit-code"
    export CLAUDE_PLAN_ALLOWED_TOOLS=Bash,Read,Edit
    export RALPH_MCP_PREFLIGHT_PASSED=1
    ralph_run_plan_invoke_claude
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" "$WORKSPACE" "$TEST_TMPDIR" "$TEST_TMPDIR" "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  [ "$status" -eq 0 ]
  grep -q '"ralph"' "$record"
  grep -q '"ambient"' "$record"
  [[ "$(cat "$record")" == *"mcp__ralph__ralph_proxy_read"* ]]
}

@test "claude hybrid mode keeps ambient servers and ralph proxy tools" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-hybrid.args"
  write_claude_stub "$record"

  printf '%s\n' '{"mcpServers":{"shared":{"command":"shared-cmd"}}}' >"$ISOLATED_HOME/.claude.json"

  PROMPT="claude-hybrid-prompt"
  export PROMPT
  export RALPH_MODE=hybrid
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run bash -c '
    set -euo pipefail
    export PATH="$6/bin:$PATH"
    source "$1"
    source "$2"
    source "$7"
    export RALPH_MODE=hybrid
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export HOME="$4"
    export RALPH_RUNTIME_MCP_HOME="$4"
    ralph_runtime_config_mcp_resolve claude "$3" "" "$3"
    export PROMPT=claude-hybrid-prompt
    export OUTPUT_LOG="$5/output.log"
    export EXIT_CODE_FILE="$5/exit-code"
    export CLAUDE_PLAN_ALLOWED_TOOLS=Bash,Read,Edit
    ralph_run_plan_invoke_claude
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" "$WORKSPACE" "$ISOLATED_HOME" "$TEST_TMPDIR" "$TEST_TMPDIR" "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  [ "$status" -eq 0 ]
  grep -q '"shared"' "$record"
  grep -q '"ralph"' "$record"
  [[ "$(cat "$record")" == *"mcp__ralph__ralph_proxy_batch"* ]]
}

@test "claude agent portable MCP overrides ambient server collision" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-collision.args"
  write_claude_stub "$record"

  printf '%s\n' '{"mcpServers":{"tools":{"command":"ambient-cmd"}}}' >"$WORKSPACE/.mcp.json"
  export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='[{"name":"tools","transport":"stdio","command":"agent-cmd"}]'

  run bash -c '
    set -euo pipefail
    export PATH="$5/bin:$PATH"
    source "$1"
    source "$2"
    source "$6"
    export RALPH_MODE=no
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='"'"'[{"name":"tools","transport":"stdio","command":"agent-cmd"}]'"'"'
    ralph_runtime_config_mcp_resolve claude "$3" "test-agent" "$3"
    export PROMPT=claude-collision-prompt
    export OUTPUT_LOG="$4/output.log"
    export EXIT_CODE_FILE="$4/exit-code"
    ralph_run_plan_invoke_claude
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" "$WORKSPACE" "$TEST_TMPDIR" "$TEST_TMPDIR" "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  [ "$status" -eq 0 ]
  grep -q 'agent-cmd' "$record"
  ! grep -q 'ambient-cmd' "$record"
}

@test "claude missing ambient MCP reference fails before invoke" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=no
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='"'"'["missing-server"]'"'"'
    ralph_runtime_config_mcp_resolve claude "$3" "test-agent" "$3"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" "$WORKSPACE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"missing ambient MCP server"* ]]
  [[ "$output" == *"missing-server"* ]]
}

@test "claude invoke cleans up owned temp MCP config but not runtime resolve artifact" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-cleanup.args"
  write_claude_stub "$record"

  PROMPT="claude-cleanup-prompt"
  export PROMPT
  export RALPH_MODE=ralph
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run bash -c '
    set -euo pipefail
    export PATH="$5/bin:$PATH"
    source "$1"
    source "$2"
    source "$6"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve claude "$3" "" "$3"
    resolve_path="$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    export PROMPT=claude-cleanup-prompt
    export OUTPUT_LOG="$4/output.log"
    export EXIT_CODE_FILE="$4/exit-code"
    export CLAUDE_PLAN_ALLOWED_TOOLS=Bash,Read,Edit
    ralph_run_plan_invoke_claude
    test -f "$resolve_path"
    [ "$(find "$4" -name "ralph-claude-mcp-*" | wc -l | tr -d " ")" -eq 0 ]
    ralph_runtime_config_mcp_cleanup
    test ! -f "$resolve_path"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" "$WORKSPACE" "$TEST_TMPDIR" "$TEST_TMPDIR" "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  [ "$status" -eq 0 ]
}

@test "claude bare mode omits setting sources and MCP overlay flags" {
  local record="$TEST_TMPDIR/claude-bare.args"
  local stdin_cap="$TEST_TMPDIR/claude-bare.stdin"
  write_claude_stub "$record" "$stdin_cap"

  PROMPT="claude-bare-prompt"
  export PROMPT
  CLAUDE_PLAN_BARE=1
  export CLAUDE_PLAN_BARE
  export RALPH_MODE=native

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--bare"* ]]
  [[ "$captured" != *"--setting-sources"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
}
