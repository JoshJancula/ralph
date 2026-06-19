#!/usr/bin/env bats
# shellcheck shell=bash
#
# Focused Cursor invocation + runtime-overlay tests covering the effective
# MCP catalog merge (ambient user/project + selected-agent overrides + Ralph's
# protected server), precedence, fail-closed behavior for invalid JSON and
# missing references, --workspace/--trust/--approve-mcps gating, and cleanup.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh"

  TEST_TMPDIR="$(mktemp -d)"
  BIN_DIR="$TEST_TMPDIR/bin"
  ISOLATED_HOME="$TEST_TMPDIR/home"
  mkdir -p "$BIN_DIR" "$ISOLATED_HOME" "$ISOLATED_HOME/.cursor"
  export TMPDIR="$TEST_TMPDIR"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  export HOME="$ISOLATED_HOME"
  export RALPH_RUNTIME_MCP_HOME="$ISOLATED_HOME"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export SCRIPT_DIR="$RALPH_DIR"
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.cursor"
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
  unset CURSOR_PLAN_MCP_CONFIG_TARGET
  unset CURSOR_PLAN_MCP_CONFIG_BACKUP
  unset CURSOR_PLAN_MCP_CONFIG_HAD_FILE
  unset CURSOR_PLAN_NATIVE_HOOKS_ACTIVE
  unset RALPH_MODE
  unset RALPH_AGENT_TOOL_ACCESS
  unset RALPH_AGENT_WORKSPACE
  unset RALPH_PLAN_WORKSPACE_ROOT
  unset RALPH_PLAN_KEY
  unset RALPH_ARTIFACT_NS
  unset RALPH_MCP_PREFLIGHT_PASSED
  unset PREBUILT_AGENT
  unset SELECTED_MODEL
  unset CURSOR_PLAN_OUTPUT_FORMAT
}

teardown() {
  PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

write_cursor_stub() {
  local record="$1"
  local mcp_capture="${2:-}"
  if [[ -n "$mcp_capture" ]]; then
    cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
if [[ -f "$WORKSPACE/.cursor/mcp.json" ]]; then
  printf 'MCP_CONFIG:%s\n' "\$(cat "$WORKSPACE/.cursor/mcp.json")" >>"$mcp_capture"
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  else
    cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  fi
  chmod +x "$BIN_DIR/cursor-agent"
}

write_cursor_fail_stub() {
  local record="$1"
  cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 1
EOF
  chmod +x "$BIN_DIR/cursor-agent"
}

# Invoke Cursor through the full ralph_run_plan_invoke_cursor path with the
# runtime-config resolver already run, so the effective catalog is applied to
# the per-run project .cursor/mcp.json overlay.
run_cursor_with_resolver() {
  local mode="$1"
  local record="$2"
  local mcp_capture="${3:-}"
  write_cursor_stub "$record" "$mcp_capture"
  RALPH_MODE="$mode" export RALPH_MODE
  run bash -c '
    set -euo pipefail
    export PATH="$1/bin:$PATH"
    source "$2"
    source "$3"
    source "$4"
    export RALPH_MODE='"'"'$5'"'"'
    export WORKSPACE="$6"
    export RALPH_PROJECT_ROOT="$6"
    export HOME="$7"
    export RALPH_RUNTIME_MCP_HOME="$7"
    ralph_runtime_config_mcp_resolve cursor "$6" "" "$6"
    export PROMPT=cursor-test-prompt
    export OUTPUT_LOG="$8/output.log"
    export EXIT_CODE_FILE="$8/exit-code"
    ralph_run_plan_invoke_cursor
  ' _ "$TEST_TMPDIR" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh" \
    "$mode" "$WORKSPACE" "$ISOLATED_HOME" "$TEST_TMPDIR"
}

@test "cursor ralph mode merges ambient user/project servers and ralph into project overlay" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  printf '%s\n' '{"mcpServers":{"user-server":{"command":"user-cmd"}}}' >"$ISOLATED_HOME/.cursor/mcp.json"
  printf '%s\n' '{"keep":"keep-value","mcpServers":{"project-server":{"command":"project-cmd"}}}' >"$WORKSPACE/.cursor/mcp.json"
  local original_bytes
  original_bytes="$(cat "$WORKSPACE/.cursor/mcp.json")"

  local record="$TEST_TMPDIR/cursor-ralph.args"
  local mcp_capture="$TEST_TMPDIR/cursor-ralph.mcp"

  run_cursor_with_resolver "ralph" "$record" "$mcp_capture"

  [ "$status" -eq 0 ]
  [ -s "$record" ]
  # Restore byte-exact original project mcp.json on cleanup.
  [ "$(cat "$WORKSPACE/.cursor/mcp.json")" = "$original_bytes" ]

  grep -Fxq -- "--workspace" "$record"
  grep -Fxq -- "$WORKSPACE" "$record"
  grep -Fxq -- "--approve-mcps" "$record"
  grep -q 'MCP_CONFIG:' "$mcp_capture"
  grep -q '"ralph"' "$mcp_capture"
  grep -q '"user-server"' "$mcp_capture"
  grep -q '"project-server"' "$mcp_capture"
  grep -q '"keep"[[:space:]]*:[[:space:]]*"keep-value"' "$mcp_capture"
}

@test "cursor hybrid mode keeps ambient servers and ralph proxy" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  printf '%s\n' '{"mcpServers":{"shared":{"command":"shared-cmd"}}}' >"$ISOLATED_HOME/.cursor/mcp.json"

  local record="$TEST_TMPDIR/cursor-hybrid.args"
  local mcp_capture="$TEST_TMPDIR/cursor-hybrid.mcp"

  run_cursor_with_resolver "hybrid" "$record" "$mcp_capture"

  [ "$status" -eq 0 ]
  grep -q '"shared"' "$mcp_capture"
  grep -q '"ralph"' "$mcp_capture"
  grep -Fxq -- "--workspace" "$record"
  grep -Fxq -- "--approve-mcps" "$record"
}

@test "cursor agent portable MCP overrides ambient server collision" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  printf '%s\n' '{"mcpServers":{"tools":{"command":"ambient-cmd"}}}' >"$WORKSPACE/.cursor/mcp.json"

  local record="$TEST_TMPDIR/cursor-collision.args"
  local mcp_capture="$TEST_TMPDIR/cursor-collision.mcp"
  write_cursor_stub "$record" "$mcp_capture"

  run bash -c '
    set -euo pipefail
    export PATH="$1/bin:$PATH"
    source "$2"
    source "$3"
    source "$4"
    export RALPH_MODE=no
    export WORKSPACE="$5"
    export RALPH_PROJECT_ROOT="$5"
    export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='"'"'[{"name":"tools","transport":"stdio","command":"agent-cmd"}]'"'"'
    ralph_runtime_config_mcp_resolve cursor "$5" "test-agent" "$5"
    export PROMPT=cursor-collision-prompt
    export OUTPUT_LOG="$6/output.log"
    export EXIT_CODE_FILE="$6/exit-code"
    ralph_run_plan_invoke_cursor
  ' _ "$TEST_TMPDIR" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh" \
    "$WORKSPACE" "$TEST_TMPDIR"

  [ "$status" -eq 0 ]
  grep -q 'agent-cmd' "$mcp_capture"
  ! grep -q 'ambient-cmd' "$mcp_capture"
  grep -Fxq -- "--workspace" "$record"
  grep -Fxq -- "--approve-mcps" "$record"
}

@test "cursor agent string reference resolves ambient server by name" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  printf '%s\n' '{"mcpServers":{"ambient-tool":{"command":"ambient-tool-cmd"}}}' >"$ISOLATED_HOME/.cursor/mcp.json"

  local record="$TEST_TMPDIR/cursor-ref.args"
  local mcp_capture="$TEST_TMPDIR/cursor-ref.mcp"
  write_cursor_stub "$record" "$mcp_capture"

  run bash -c '
    set -euo pipefail
    export PATH="$1/bin:$PATH"
    source "$2"
    source "$3"
    source "$4"
    export RALPH_MODE=no
    export WORKSPACE="$5"
    export RALPH_PROJECT_ROOT="$5"
    export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='"'"'["ambient-tool"]'"'"'
    ralph_runtime_config_mcp_resolve cursor "$5" "test-agent" "$5"
    export PROMPT=cursor-ref-prompt
    export OUTPUT_LOG="$6/output.log"
    export EXIT_CODE_FILE="$6/exit-code"
    ralph_run_plan_invoke_cursor
  ' _ "$TEST_TMPDIR" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh" \
    "$WORKSPACE" "$TEST_TMPDIR"

  [ "$status" -eq 0 ]
  grep -q 'ambient-tool-cmd' "$mcp_capture"
}

@test "cursor missing ambient MCP reference fails before CLI invoke" {
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=no
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='"'"'["missing-server"]'"'"'
    ralph_runtime_config_mcp_resolve cursor "$3" "test-agent" "$3"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" \
    "$WORKSPACE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"missing ambient MCP server"* ]]
  [[ "$output" == *"missing-server"* ]]
  [[ "$output" == *"Searched MCP config sources"* ]]
}

@test "cursor invalid existing project mcp.json fails closed without modifying it" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/cursor-invalid.args"
  local original_config="$WORKSPACE/.cursor/mcp.json"
  mkdir -p "$WORKSPACE/.cursor"
  printf 'not-json' >"$original_config"
  write_cursor_stub "$record"

  PROMPT="cursor-invalid-prompt"
  export PROMPT
  RALPH_MODE="ralph"
  export RALPH_MODE

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 1 ]
  [[ "$output" == *"Error: existing Cursor MCP config is invalid JSON:"* ]]
  [ "$(cat "$original_config")" = "not-json" ]
  [ ! -s "$record" ]
}

@test "cursor invalid ambient user mcp.json fails closed at resolver before invoke" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  printf 'not-json' >"$ISOLATED_HOME/.cursor/mcp.json"

  run bash -c '
    source "$1"
    source "$2"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export HOME="$4"
    export RALPH_RUNTIME_MCP_HOME="$4"
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" \
    "$WORKSPACE" "$ISOLATED_HOME"

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid JSON"* ]] || [[ "$output" == *"MCP overlay preflight failed"* ]]
}

@test "cursor native mode omits workspace/trust/approve-mcps and leaves mcp.json untouched" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/cursor-native.args"
  local original_config="$WORKSPACE/.cursor/mcp.json"
  printf '{"mcpServers":{"keep":"me"}}' >"$original_config"
  local original_bytes
  original_bytes="$(cat "$original_config")"
  write_cursor_stub "$record"

  PROMPT="cursor-native-prompt"
  export PROMPT
  RALPH_MODE="native"
  export RALPH_MODE

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [ "$(cat "$original_config")" = "$original_bytes" ]
  ! grep -Fxq -- "--workspace" "$record"
  ! grep -Fxq -- "--trust" "$record"
  ! grep -Fxq -- "--approve-mcps" "$record"
}

@test "cursor overlay is created when no project mcp.json exists and removed on cleanup" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  [ ! -f "$WORKSPACE/.cursor/mcp.json" ]

  local record="$TEST_TMPDIR/cursor-create.args"
  local mcp_capture="$TEST_TMPDIR/cursor-create.mcp"

  run_cursor_with_resolver "ralph" "$record" "$mcp_capture"

  [ "$status" -eq 0 ]
  [ ! -f "$WORKSPACE/.cursor/mcp.json" ]
  grep -q 'MCP_CONFIG:' "$mcp_capture"
  grep -q '"ralph"' "$mcp_capture"
}

@test "cursor overlay restores original mcp.json when CLI exits non-zero" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  local original_config="$WORKSPACE/.cursor/mcp.json"
  printf '{"mcpServers":{"other":{"command":"keep-me"}}}' >"$original_config"
  local original_bytes
  original_bytes="$(cat "$original_config")"

  write_cursor_fail_stub "$TEST_TMPDIR/cursor-fail.args"

  run bash -c '
    set -euo pipefail
    export PATH="$1/bin:$PATH"
    source "$2"
    source "$3"
    source "$4"
    export RALPH_MODE=ralph
    export WORKSPACE="$5"
    export RALPH_PROJECT_ROOT="$5"
    export HOME="$6"
    export RALPH_RUNTIME_MCP_HOME="$6"
    ralph_runtime_config_mcp_resolve cursor "$5" "" "$5"
    export PROMPT=cursor-fail-prompt
    export OUTPUT_LOG="$7/output.log"
    export EXIT_CODE_FILE="$7/exit-code"
    ralph_run_plan_invoke_cursor
  ' _ "$TEST_TMPDIR" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh" \
    "$WORKSPACE" "$ISOLATED_HOME" "$TEST_TMPDIR"

  [ "$status" -eq 0 ]
  [ "$(cat "$original_config")" = "$original_bytes" ]
}

@test "cursor agent-only overlay applies without ralph mode and adds approve-mcps" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  local record="$TEST_TMPDIR/cursor-agent-only.args"
  local mcp_capture="$TEST_TMPDIR/cursor-agent-only.mcp"
  write_cursor_stub "$record" "$mcp_capture"

  run bash -c '
    set -euo pipefail
    export PATH="$1/bin:$PATH"
    source "$2"
    source "$3"
    source "$4"
    export RALPH_MODE=no
    export WORKSPACE="$5"
    export RALPH_PROJECT_ROOT="$5"
    export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='"'"'[{"name":"agent-srv","transport":"stdio","command":"agent-only-cmd"}]'"'"'
    ralph_runtime_config_mcp_resolve cursor "$5" "test-agent" "$5"
    export PROMPT=cursor-agent-only-prompt
    export OUTPUT_LOG="$6/output.log"
    export EXIT_CODE_FILE="$6/exit-code"
    ralph_run_plan_invoke_cursor
  ' _ "$TEST_TMPDIR" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh" \
    "$WORKSPACE" "$TEST_TMPDIR"

  [ "$status" -eq 0 ]
  grep -q 'agent-only-cmd' "$mcp_capture"
  # Ralph must not be added when ralph mode is off and only agent entries exist.
  ! grep -q '"ralph"' "$mcp_capture"
  grep -Fxq -- "--workspace" "$record"
  grep -Fxq -- "--approve-mcps" "$record"
}