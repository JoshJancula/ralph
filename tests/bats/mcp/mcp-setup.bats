#!/usr/bin/env bats
# Tests for bundle/.ralph/bash-lib/mcp/mcp-setup.sh

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SETUP_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
MCP_SERVER="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  if [[ -e "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

@test "ralph_mcp_proxy_server_script_path resolves from workspace for local invocation" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws
  ws="$TEST_TMPDIR/ws_server_path"
  mkdir -p "$ws/.ralph"
  printf '# stub\n' > "$ws/.ralph/mcp-server.sh"

  run bash -c 'source "$1" && RALPH_DIR="$2/.ralph" && ralph_mcp_proxy_server_script_path "$2"' _ "$SETUP_FILE" "$ws"
  [ "$status" -eq 0 ]
  [ "$output" = "$ws/.ralph/mcp-server.sh" ]
}

@test "ralph_mcp_proxy_server_script_path prefers canonical server even when fast wrapper exists" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws
  ws="$TEST_TMPDIR/ws_prefers_canonical"
  mkdir -p "$ws/.ralph"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ws/.ralph/mcp-server.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ws/.ralph/mcp-server-fast.sh"

  run bash -c 'source "$1" && RALPH_DIR="$2/.ralph" && ralph_mcp_proxy_server_script_path "$2"' _ "$SETUP_FILE" "$ws"
  [ "$status" -eq 0 ]
  [ "$output" = "$ws/.ralph/mcp-server.sh" ]
}

@test "ralph_mcp_proxy_server_script_path prefers active Ralph install for global invocation" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws global_ralph
  ws="$TEST_TMPDIR/ws_global"
  global_ralph="$TEST_TMPDIR/global_ralph"
  mkdir -p "$ws/.ralph" "$global_ralph"
  printf '# stale workspace copy\n' > "$ws/.ralph/mcp-server.sh"
  cp "$MCP_SERVER" "$global_ralph/mcp-server.sh"

  run bash -c 'source "$1" && RALPH_DIR="$2" && ralph_mcp_proxy_server_script_path "$3"' _ "$SETUP_FILE" "$global_ralph" "$ws"
  [ "$status" -eq 0 ]
  [ "$output" = "$global_ralph/mcp-server.sh" ]
}

@test "ralph_mcp_proxy_generate_config succeeds for supported runtimes" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws out
  ws="$TEST_TMPDIR/ws_gen"
  mkdir -p "$ws/.ralph"
  cp "$MCP_SERVER" "$ws/.ralph/mcp-server.sh"
  out="$ws/ephemeral.json"

  run bash -c 'source "$1" && RALPH_DIR="$3/.ralph" && ralph_mcp_proxy_generate_config claude "$2" "$3"' _ "$SETUP_FILE" "$out" "$ws"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q '"ralph"' "$out"
  grep -q "$ws/.ralph/mcp-server.sh" "$out"
}

@test "ralph_mcp_proxy_generate_config uses global install server when workspace copy is stale" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws out global_ralph
  ws="$TEST_TMPDIR/ws_gen_global"
  global_ralph="$TEST_TMPDIR/global_ralph_gen"
  mkdir -p "$ws/.ralph" "$global_ralph"
  printf '# stale workspace copy\n' > "$ws/.ralph/mcp-server.sh"
  cp "$MCP_SERVER" "$global_ralph/mcp-server.sh"
  out="$ws/ephemeral.json"

  run bash -c 'source "$1" && RALPH_DIR="$4" && ralph_mcp_proxy_generate_config claude "$2" "$3"' _ "$SETUP_FILE" "$out" "$ws" "$global_ralph"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q '"ralph"' "$out"
  grep -q "$global_ralph/mcp-server.sh" "$out"
}

@test "ralph_mcp_proxy_generate_config returns error for unsupported runtime" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws out
  ws="$TEST_TMPDIR/ws_unsup"
  out="$ws/ephemeral.json"

  run bash -c 'source "$1" && ralph_mcp_proxy_generate_config unsupported "$2" "$3"' _ "$SETUP_FILE" "$out" "$ws"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported runtime"* ]]
}

@test "ralph_mcp_proxy_generate_config returns actionable error when jq fails" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws out stub_dir
  ws="$TEST_TMPDIR/ws_bad_jq"
  out="$ws/ephemeral.json"
  mkdir -p "$ws/.ralph"
  cp "$MCP_SERVER" "$ws/.ralph/mcp-server.sh"

  stub_dir="$TEST_TMPDIR/stub_bin"
  mkdir -p "$stub_dir"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_dir/jq"
  chmod +x "$stub_dir/jq"

  run bash -c 'export PATH="$4:$PATH"; source "$1" && RALPH_DIR="$3/.ralph" && ralph_mcp_proxy_generate_config claude "$2" "$3"' _ "$SETUP_FILE" "$out" "$ws" "$stub_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to write ephemeral MCP config"* || "$output" == *"failed to build Ralph MCP server environment JSON"* ]]
}

@test "ralph_mcp_proxy_generate_config returns error when output dir is not writable" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws out
  ws="$TEST_TMPDIR/ws_nowrite"
  mkdir -p "$ws/.ralph"
  cp "$MCP_SERVER" "$ws/.ralph/mcp-server.sh"
  out="/nonexistent/path/ephemeral.json"

  run bash -c 'source "$1" && RALPH_DIR="$3/.ralph" && ralph_mcp_proxy_generate_config claude "$2" "$3"' _ "$SETUP_FILE" "$out" "$ws"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config directory"* ]]
}

@test "ralph_mcp_proxy_preflight succeeds against real Ralph MCP server" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"
  command -v jq > /dev/null || skip "jq required"

  run bash -c 'source "$1" && RALPH_MODE=ralph ralph_mcp_proxy_preflight "$2" "$3"' _ "$SETUP_FILE" "$MCP_SERVER" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "ralph_mcp_proxy_preflight fails when tools/list returns a null nextCursor" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"
  command -v jq > /dev/null || skip "jq required"

  # Claude Code drops every tool from a server whose tools/list carries a
  # present-but-null nextCursor; the preflight must reject that shape.
  local wrap="$TEST_TMPDIR/wrap-nextcursor.sh"
  cat > "$wrap" <<EOF
#!/usr/bin/env bash
bash "$MCP_SERVER" "\$@" | jq -c --unbuffered 'if (.result and (.result|type=="object") and (.result|has("tools"))) then .result.nextCursor=null else . end'
EOF
  chmod +x "$wrap"

  run bash -c 'source "$1" && RALPH_MODE=ralph ralph_mcp_proxy_preflight "$2" "$3"' _ "$SETUP_FILE" "$wrap" "$REPO_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"null nextCursor"* ]]
}

@test "ralph_mcp_proxy_preflight fails when a required proxy tool is absent" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"
  command -v jq > /dev/null || skip "jq required"

  local wrap="$TEST_TMPDIR/wrap-missing.sh"
  cat > "$wrap" <<EOF
#!/usr/bin/env bash
bash "$MCP_SERVER" "\$@" | jq -c --unbuffered 'if (.result and (.result|type=="object") and (.result|has("tools"))) then .result.tools |= map(select(.name != "ralph_proxy_shell")) else . end'
EOF
  chmod +x "$wrap"

  run bash -c 'source "$1" && RALPH_MODE=ralph ralph_mcp_proxy_preflight "$2" "$3"' _ "$SETUP_FILE" "$wrap" "$REPO_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required tools for RALPH_MODE="* ]]
  [[ "$output" == *"ralph_proxy_shell"* ]]
}

@test "ralph_mcp_proxy_preflight fails immediately when RALPH_MODE=no" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  run bash -c 'source "$1" && RALPH_MODE=no ralph_mcp_proxy_preflight "$2" "$3"' _ "$SETUP_FILE" "$MCP_SERVER" "$REPO_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RALPH_MODE=no"* ]]
}

@test "ralph_mcp_proxy_preflight succeeds in native mode with result tools only" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"
  command -v jq > /dev/null || skip "jq required"

  run bash -c 'source "$1" && RALPH_MODE=native ralph_mcp_proxy_preflight "$2" "$3"' _ "$SETUP_FILE" "$MCP_SERVER" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "ralph_mcp_proxy_preflight fails in native mode when proxy read tools are exposed" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"
  command -v jq > /dev/null || skip "jq required"

  local wrap="$TEST_TMPDIR/wrap-native-leak.sh"
  cat > "$wrap" <<EOF
#!/usr/bin/env bash
env RALPH_MODE=native bash "$MCP_SERVER" "\$@" | jq -c --unbuffered 'if (.result and (.result|type=="object") and (.result|has("tools"))) then .result.tools += [{"name":"ralph_proxy_read","description":"leak","inputSchema":{"type":"object","properties":{},"required":[]}}] else . end'
EOF
  chmod +x "$wrap"

  run bash -c 'source "$1" && RALPH_MODE=native ralph_mcp_proxy_preflight "$2" "$3"' _ "$SETUP_FILE" "$wrap" "$REPO_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"native mode"* ]]
  [[ "$output" == *"ralph_proxy_read"* ]]
}

@test "resolved default MCP server handles initialize then tool call then tools list" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"
  command -v jq > /dev/null || skip "jq required"

  local ws payload
  ws="$TEST_TMPDIR/ws_mcp_flow"
  mkdir -p "$ws"
  printf '%s\n' '- [ ] todo one' > "$ws/PLAN.md"

  payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ralph_plan_status","arguments":{"workspace":".","plan_path":"PLAN.md"}}}
{"jsonrpc":"2.0","id":3,"method":"tools/list"}
{"jsonrpc":"2.0","id":4,"method":"exit"}'

  run bash -c '
    source "$1"
    server_script="$(ralph_mcp_proxy_server_script_path "$2")" || exit 1
    env RALPH_MODE=ralph RALPH_MCP_WORKSPACE="$4" bash "$server_script" 2>/dev/null <<< "$3"
  ' _ "$SETUP_FILE" "$REPO_ROOT" "$payload" "$ws"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -s -e '.[0].result.capabilities.tools.listChanged == false'
  printf '%s\n' "$output" | jq -s -e '.[1].result.structuredContent.total >= 1'
  printf '%s\n' "$output" | jq -s -e '[.[2].result.tools[]?.name] | index("ralph_proxy_read") != null'
  printf '%s\n' "$output" | jq -s -e '.[3].result.status == "exiting"'
}

@test "ralph_mcp_proxy_preflight fails when server script is missing" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local fake_server
  fake_server="$TEST_TMPDIR/fake_server.sh"

  run bash -c 'source "$1" && ralph_mcp_proxy_preflight "$2" "$3"' _ "$SETUP_FILE" "$fake_server" "$REPO_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"server script not found"* ]]
}

@test "ralph_mcp_proxy_preflight fails when server exits nonzero" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local fake_server
  fake_server="$TEST_TMPDIR/fake_server_err.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_server"
  chmod +x "$fake_server"

  run bash -c 'source "$1" && RALPH_MODE=ralph ralph_mcp_proxy_preflight "$2" "$3"' _ "$SETUP_FILE" "$fake_server" "$REPO_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exited with code"* ]]
}

@test "ralph_mcp_proxy_cleanup_config removes the ephemeral file" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local file
  file="$TEST_TMPDIR/ephemeral.json"
  printf '{}' > "$file"
  [ -f "$file" ]

  run bash -c 'source "$1" && ralph_mcp_proxy_cleanup_config "$2"' _ "$SETUP_FILE" "$file"
  [ "$status" -eq 0 ]
  [ ! -f "$file" ]
}

@test "ralph_mcp_server_script_path alias works" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws
  ws="$TEST_TMPDIR/ws_alias"
  mkdir -p "$ws/.ralph"
  printf '# stub\n' > "$ws/.ralph/mcp-server.sh"

  run bash -c 'source "$1" && RALPH_DIR="$2/.ralph" && ralph_mcp_server_script_path "$2"' _ "$SETUP_FILE" "$ws"
  [ "$status" -eq 0 ]
  [ "$output" = "$ws/.ralph/mcp-server.sh" ]
}

@test "ralph_mcp_generate_config alias works for opencode runtime" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws out
  ws="$TEST_TMPDIR/ws_opencode"
  mkdir -p "$ws/.ralph"
  cp "$MCP_SERVER" "$ws/.ralph/mcp-server.sh"
  out="$ws/ephemeral.json"

  run bash -c 'source "$1" && RALPH_DIR="$3/.ralph" && ralph_mcp_generate_config opencode "$2" "$3"' _ "$SETUP_FILE" "$out" "$ws"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q '"opencode"\|"ralph"' "$out" || grep -q '"mcp"' "$out"
}

@test "ralph_mcp_proxy_generate_config includes plan-scoped env vars when set" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws out
  ws="$TEST_TMPDIR/ws_plan_env"
  mkdir -p "$ws/.ralph"
  cp "$MCP_SERVER" "$ws/.ralph/mcp-server.sh"
  out="$ws/ephemeral.json"

  run bash -c 'export RALPH_PLAN_KEY=PLAN26 RALPH_ARTIFACT_NS=PLAN26 RALPH_MCP_ALLOWLIST=/tmp/ws; source "$1" && RALPH_DIR="$3/.ralph" && ralph_mcp_proxy_generate_config claude "$2" "$3"' _ "$SETUP_FILE" "$out" "$ws"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q '"RALPH_PLAN_KEY": "PLAN26"' "$out"
  grep -q '"RALPH_ARTIFACT_NS": "PLAN26"' "$out"
  grep -q '"RALPH_MCP_ALLOWLIST": "/tmp/ws"' "$out"
}

@test "ralph_mcp_proxy_generate_config includes proxy shell compaction env when enabled" {
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  local ws out
  ws="$TEST_TMPDIR/ws_proxy_compact"
  mkdir -p "$ws/.ralph"
  cp "$MCP_SERVER" "$ws/.ralph/mcp-server.sh"
  out="$ws/ephemeral.json"

  run bash -c 'export RALPH_PROXY_SHELL_COMPACT=1 RALPH_PROXY_SHELL_COMPACT_LOG=/tmp/proxy.log; source "$1" && RALPH_DIR="$3/.ralph" && ralph_mcp_proxy_generate_config cursor "$2" "$3"' _ "$SETUP_FILE" "$out" "$ws"
  [ "$status" -eq 0 ]
  [ -f "$out" ]
  grep -q '"RALPH_PROXY_SHELL_COMPACT": "1"' "$out"
  grep -q '"RALPH_PROXY_SHELL_COMPACT_LOG": "/tmp/proxy.log"' "$out"
}
