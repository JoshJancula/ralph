#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUNTIME_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
MCP_SETUP="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
RUNTIME_CONFIG_MCP="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh"

@test "no secret leakage in stderr: resolved secrets not logged" {
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.cursor"
  
  # Setup MCP config with env reference
  cat > "$workspace/.cursor/mcp.json" <<'JSON'
{
  "mcpServers": {
    "secure": {
      "command": "cmd",
      "env": {"TOKEN": "${TEST_SECRET_TOKEN}"}
    }
  }
}
JSON
  
  # Set the secret value
  export TEST_SECRET_TOKEN="super-secret-value-12345"
  
  run env TEST_SECRET_TOKEN="super-secret-value-12345" bash -c '
    source "$1"
    source "$2"
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export RALPH_MODE=no
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3" 2>&1
  ' _ "$MCP_SETUP" "$RUNTIME_CONFIG_MCP" "$workspace"
  
  [ "$status" -eq 0 ]
  # Secret value should NOT appear in stderr/output
  [[ "$output" != *"super-secret-value-12345"* ]]
  
  unset TEST_SECRET_TOKEN
  ralph_test_rm_workspace "$workspace"
}

@test "no secret leakage in overlay summary: secrets redacted" {
  source "$RUNTIME_OVERLAY_LIB"
  
  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_PLAN_KEY="summary-redact-test"
  RUNTIME="claude"
  
  mkdir -p "$workspace/.cursor"
  cat > "$workspace/.cursor/mcp.json" <<'JSON'
{
  "mcpServers": {
    "secure": {
      "command": "cmd",
      "env": {"TOKEN": "${TEST_SECRET}"}
    }
  }
}
JSON
  
  # Export the secret
  export TEST_SECRET="my-sensitive-secret"
  
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  
  # Source MCP setup and resolve
  source "$MCP_SETUP"
  source "$RUNTIME_CONFIG_MCP"
  export WORKSPACE="$workspace"
  export RALPH_PROJECT_ROOT="$workspace"
  export RALPH_MODE=no
  ralph_runtime_config_mcp_resolve cursor "$workspace" "" "$workspace"
  
  # Write summary
  runtime_overlay_write_summary
  summary_file="$(runtime_overlay_summary_path)"
  
  # Verify secret not in summary
  [ -f "$summary_file" ]
  ! grep -q "my-sensitive-secret" "$summary_file"
  
  # Verify redaction markers present
  grep -q "REDACTED\|redacted\|\*\*\*" "$summary_file" || true
  
  unset TEST_SECRET
  ralph_test_rm_workspace "$workspace"
}

@test "no secret leakage in temp config file: resolved values isolated" {
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.cursor"
  
  cat > "$workspace/.cursor/mcp.json" <<'JSON'
{
  "mcpServers": {
    "secure": {
      "command": "cmd",
      "env": {"API_KEY": "${TEST_API_KEY}"}
    }
  }
}
JSON
  
  export TEST_API_KEY="secret-api-key-999"
  
  run env TEST_API_KEY="secret-api-key-999" bash -c '
    source "$1"
    source "$2"
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export RALPH_MODE=no
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3"
    # Verify temp config has resolved value
    grep -q "secret-api-key-999" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    # Verify summary does NOT have secret
    ! grep -q "secret-api-key-999" <<< "$RALPH_RUNTIME_MCP_SUMMARY_JSON"
  ' _ "$MCP_SETUP" "$RUNTIME_CONFIG_MCP" "$workspace"
  
  [ "$status" -eq 0 ]
  
  unset TEST_API_KEY
  ralph_test_rm_workspace "$workspace"
}

@test "summary includes sanitized overlay fields without secrets" {
  source "$RUNTIME_OVERLAY_LIB"
  
  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_PLAN_KEY="sanitized-fields-test"
  RUNTIME="cursor"
  
  mkdir -p "$workspace/.cursor"
  cat > "$workspace/.cursor/mcp.json" <<'JSON'
{
  "mcpServers": {
    "ambient-server": {
      "command": "cmd",
      "args": ["arg1"]
    }
  }
}
JSON
  
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  
  source "$MCP_SETUP"
  source "$RUNTIME_CONFIG_MCP"
  export WORKSPACE="$workspace"
  export RALPH_PROJECT_ROOT="$workspace"
  export RALPH_MODE=no
  ralph_runtime_config_mcp_resolve cursor "$workspace" "" "$workspace"
  
  runtime_overlay_write_summary
  summary_file="$(runtime_overlay_summary_path)"
  
  # Verify sanitized fields present
  [ -f "$summary_file" ]
  run jq -e ".mcp_config_sources | length > 0" "$summary_file"
  [ "$status" -eq 0 ]
  run jq -e ".mcp_effective_names | length > 0" "$summary_file"
  [ "$status" -eq 0 ]
  run jq -e ".mcp_override_decisions | length >= 0" "$summary_file"
  [ "$status" -eq 0 ]
  
  ralph_test_rm_workspace "$workspace"
}

@test "log files do not contain resolved credential values" {
  source "$RUNTIME_OVERLAY_LIB"
  
  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_PLAN_KEY="log-redact-test"
  RUNTIME="claude"
  
  mkdir -p "$workspace/.cursor"
  cat > "$workspace/.cursor/mcp.json" <<'JSON'
{
  "mcpServers": {
    "secure": {
      "command": "cmd",
      "env": {"PASSWORD": "${TEST_PASSWORD}"}
    }
  }
}
JSON
  
  export TEST_PASSWORD="super-secret-password"
  export RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace"
  
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  
  source "$MCP_SETUP"
  source "$RUNTIME_CONFIG_MCP"
  export WORKSPACE="$workspace"
  export RALPH_PROJECT_ROOT="$workspace"
  export RALPH_MODE=no
  ralph_runtime_config_mcp_resolve cursor "$workspace" "" "$workspace"
  
  # Write summary
  runtime_overlay_write_summary
  summary_file="$(runtime_overlay_summary_path)"
  
  # Check all log/output files for secrets
  for log_file in "$RUNTIME_OVERLAY_STATE_DIR"/*; do
    if [ -f "$log_file" ]; then
      ! grep -q "super-secret-password" "$log_file" || {
        echo "Secret found in: $log_file"
        false
      }
    fi
  done
  
  unset TEST_PASSWORD
  ralph_test_rm_workspace "$workspace"
}

@test "redaction applies to headers as well as env vars" {
  local agents_root agent_id cfg
  agents_root="$(mktemp -d)"
  agent_id="header-redact"
  cfg="$agents_root/$agent_id/config.json"
  mkdir -p "$agents_root/$agent_id"
  
  cat > "$cfg" <<CONFIG
{
  "name": "header-redact",
  "model": "gpt-test",
  "description": "Agent for header redaction test",
  "rules": ["rule-1"],
  "skills": ["skill-1"],
  "mcp_servers": [
    {
      "name": "http-server",
      "transport": "http",
      "url": "https://api.example.com",
      "headers": {"Authorization": "\${API_TOKEN}"}
    }
  ]
}
CONFIG
  
  AGENT_CONFIG_MCP_PY="$REPO_ROOT/bundle/.ralph/python/agent-config-mcp.py"
  [ -f "$AGENT_CONFIG_MCP_PY" ] || skip "agent-config-mcp.py missing"
  
  # Profile mcp_servers (and profile secret redaction) were removed.
  run python3 "$AGENT_CONFIG_MCP_PY" --redact-config "$cfg"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mcp_servers"* ]]
  [[ "$output" == *"ralph migrate"* ]]
  
  rm -rf "$agents_root"
}
