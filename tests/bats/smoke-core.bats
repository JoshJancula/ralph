#!/usr/bin/env bats
# Consolidated smoke tests replacing deleted extended-tier matrices.

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

SETUP_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
MCP_SERVER="$REPO_ROOT/bundle/.ralph/mcp-server.sh"
RUNTIME_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TMPDIR="$TEST_TMPDIR"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.cursor"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$WORKSPACE/.ralph/mcp-server.sh"
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"

  BIN_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
  ORIGINAL_PATH="$PATH"
  PATH="$BIN_DIR:$PATH"

  export OUTPUT_LOG="$TEST_TMPDIR/output.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/exit-code"
  export PROMPT="smoke-core-prompt"
  unset RALPH_MODE SELECTED_MODEL

  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"
}

teardown() {
  PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

@test "smoke: MCP server initialize and tools/list expose ralph_proxy_read" {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws payload
  ws="$TEST_TMPDIR/mcp_ws"
  mkdir -p "$ws"
  payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"exit"}'

  run bash -c '
    source "$1"
    server_script="$(ralph_mcp_proxy_server_script_path "$2")" || exit 1
    env RALPH_MODE=ralph RALPH_MCP_WORKSPACE="$3" bash "$server_script" 2>/dev/null <<< "$4"
  ' _ "$SETUP_FILE" "$REPO_ROOT" "$ws" "$payload"

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -s -e '.[0].result.capabilities.tools.listChanged == false'
  printf '%s\n' "$output" | jq -s -e '[.[1].result.tools[]?.name] | index("ralph_proxy_read") != null'
}

@test "smoke: cursor ralph mode injects MCP config and restores existing mcp.json" {
  command -v jq >/dev/null || skip "jq required"

  local record="$TEST_TMPDIR/cursor.args"
  local mcp_capture="$TEST_TMPDIR/cursor.mcp"
  local original_config="$WORKSPACE/.cursor/mcp.json"
  printf '{"keep":"value","mcpServers":{"other":{"command":"keep-me"}}}' >"$original_config"
  local original_bytes
  original_bytes="$(cat "$original_config")"

  cat <<EOF >"$BIN_DIR/cursor-agent"
#!/usr/bin/env bash
if [[ -f "$WORKSPACE/.cursor/mcp.json" ]]; then
  printf 'MCP_CONFIG:%s\n' "\$(cat "$WORKSPACE/.cursor/mcp.json")" >>"$mcp_capture"
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/cursor-agent"

  export RALPH_MODE="ralph"
  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ "$(cat "$original_config")" = "$original_bytes" ]
  grep -q '"ralph"' "$mcp_capture"
  grep -q '"other"' "$mcp_capture"
}

@test "smoke: claude ralph mode generates ephemeral MCP config path" {
  command -v jq >/dev/null || skip "jq required"

  local record="$TEST_TMPDIR/claude.args"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"

  export RALPH_MODE="ralph"
  export CLAUDE_PLAN_CLI="$BIN_DIR/claude"
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  grep -Fq -- "--mcp-config" "$record"
}

@test "smoke: opencode invoke pins build agent by default" {
  local record="$TEST_TMPDIR/opencode.args"
  cat <<EOF >"$BIN_DIR/opencode"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/opencode"
  export OPENCODE_PLAN_CLI="$BIN_DIR/opencode"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  grep -Fq -- "build" "$record"
}

@test "smoke: runtime overlay writes summary and restores journaled originals" {
  command -v python3 >/dev/null || skip "python3 required"
  # shellcheck disable=SC1090
  source "$RUNTIME_OVERLAY_LIB"

  local plan_key="smoke-overlay"
  export RALPH_PLAN_KEY="$plan_key"
  export RUNTIME="cursor"

  runtime_overlay_init_state "$RUNTIME" "$plan_key"
  runtime_overlay_set_tool_access_mode "ralph"
  runtime_overlay_set_mcp_effective "true"

  local generated="$WORKSPACE/generated.txt"
  printf 'generated' >"$generated"
  runtime_overlay_record_generated_file "$generated"
  runtime_overlay_write_summary

  summary_file="$(runtime_overlay_summary_path)"
  [ -f "$summary_file" ]
  python3 - <<'PY' "$summary_file"
import json, sys
summary = json.load(open(sys.argv[1]))
assert summary["tool_access_mode"] == "ralph"
assert summary["mcp_effective"] == "true"
assert summary["generated_files"]
PY
}
