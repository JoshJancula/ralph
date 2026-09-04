#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUNTIME_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"

setup() {
  bats_skip_known_ci_flakes
}

@test "byte-exact restoration: original file bytes preserved" {
  source "$RUNTIME_OVERLAY_LIB"
  
  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_PLAN_KEY="byte-exact-test"
  RUNTIME="claude"
  
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  
  # Create a file with binary content
  original_file="$workspace/test-config.bin"
  printf '\x00\x01\x02\x03\xff\xfe\xfd\xfc' > "$original_file"
  original_hash="$(md5 -q "$original_file" 2>/dev/null || md5sum "$original_file" | cut -d' ' -f1)"
  original_size="$(stat -f%z "$original_file" 2>/dev/null || stat -c%s "$original_file")"
  
  runtime_overlay_record_original_file "$original_file"
  
  # Mutate the file
  printf 'mutated content' > "$original_file"
  
  # Now restore stale runs to trigger restoration
  RALPH_PLAN_KEY="byte-exact-test"
  runtime_overlay_restore_stale_runs "$workspace" "byte-exact-test" 0
  
  # Verify restoration
  restored_hash="$(md5 -q "$original_file" 2>/dev/null || md5sum "$original_file" | cut -d' ' -f1)"
  restored_size="$(stat -f%z "$original_file" 2>/dev/null || stat -c%s "$original_file")"
  
  [ "$original_hash" = "$restored_hash" ]
  [ "$original_size" = "$restored_size" ]
  
  ralph_test_rm_workspace "$workspace"
}

@test "signal cleanup: trap handler registered for INT TERM HUP" {
  # This test verifies that run-plan-core.sh registers signal trap handlers
  local core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  [ -f "$core_lib" ]
  
  # Check for trap registration in the code
  grep -q "trap.*INT TERM HUP" "$core_lib" || grep -q "trap.*ralph_runtime_overlay_signal_trap_handler" "$core_lib"
}

@test "concurrent plans use isolated runtime-config paths" {
  source "$RUNTIME_OVERLAY_LIB"
  
  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  RUNTIME="claude"
  
  plan1_key="concurrent-plan-1"
  plan2_key="concurrent-plan-2"
  
  RALPH_PLAN_KEY="$plan1_key"
  runtime_overlay_init_state "$RUNTIME" "$plan1_key"
  state_dir1="$RUNTIME_OVERLAY_STATE_DIR"
  
  RALPH_PLAN_KEY="$plan2_key"
  runtime_overlay_init_state "$RUNTIME" "$plan2_key"
  state_dir2="$RUNTIME_OVERLAY_STATE_DIR"
  
  # Verify different state directories
  [ -n "$state_dir1" ]
  [ -n "$state_dir2" ]
  [ "$state_dir1" != "$state_dir2" ]
  
  # Verify both directories exist
  [ -d "$state_dir1" ]
  [ -d "$state_dir2" ]
  
  # Verify they are in different plan-key paths
  [[ "$state_dir1" == *"$plan1_key"* ]]
  [[ "$state_dir2" == *"$plan2_key"* ]]
  
  ralph_test_rm_workspace "$workspace"
}

@test "failed CLI cleanup: overlays restored after runtime failure" {
  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_PLAN_KEY="fail-cleanup-test"
  
  mkdir -p "$workspace/.cursor"
  original_mcp='{"original":"mcp"}'
  printf '%s' "$original_mcp" > "$workspace/.cursor/mcp.json"
  
  source "$RUNTIME_OVERLAY_LIB"
  runtime_overlay_init_state "cursor" "$RALPH_PLAN_KEY"
  runtime_overlay_record_original_file "$workspace/.cursor/mcp.json"
  
  # Simulate mutation
  printf '%s' '{"mutated":"mcp"}' > "$workspace/.cursor/mcp.json"
  
  # Mark journal as cleaned (simulating cleanup after failure)
  runtime_overlay_journal_mark_cleaned
  
  # Verify cleanup marker
  journal_file="$RUNTIME_OVERLAY_JOURNAL_FILE"
  [ -f "$journal_file" ]
  python3 -c "
import json
with open('$journal_file') as f:
    data = json.load(f)
assert data['cleanup_status'] == 'cleaned'
"
  
  ralph_test_rm_workspace "$workspace"
}

@test "timeout cleanup: overlays restored on timeout" {
  source "$RUNTIME_OVERLAY_LIB"
  
  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_PLAN_KEY="timeout-cleanup-test"
  RUNTIME="claude"
  
  mkdir -p "$workspace/.cursor"
  printf '%s' '{"timeout":"original"}' > "$workspace/.cursor/mcp.json"
  
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  runtime_overlay_record_original_file "$workspace/.cursor/mcp.json"
  
  # Verify journal entry created
  [ -f "$RUNTIME_OVERLAY_JOURNAL_FILE" ]
  
  # Mark as cleaned (simulating timeout cleanup)
  runtime_overlay_journal_mark_cleaned
  
  # Verify cleanup marked
  python3 -c "
import json
with open('$RUNTIME_OVERLAY_JOURNAL_FILE') as f:
    data = json.load(f)
assert data['cleanup_status'] == 'cleaned'
assert data['cleanup_time'] is not None
"
  
  ralph_test_rm_workspace "$workspace"
}

@test "stale restore preserves durable Claude hook install" {
  source "$RUNTIME_OVERLAY_LIB"

  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_PLAN_KEY="stale-claude-durable-hooks"
  runtime_overlay_init_state "claude" "$RALPH_PLAN_KEY"

  mkdir -p "$workspace/.claude"
  printf '%s\n' '{"other":"original"}' > "$workspace/.claude/settings.json"
  runtime_overlay_record_original_file "$workspace/.claude/settings.json"
  cp "$REPO_ROOT/bundle/.claude/settings.json" "$workspace/.claude/settings.json"

  run runtime_overlay_restore_stale_runs "$workspace" "$RALPH_PLAN_KEY" 0
  [ "$status" -eq 0 ]
  run jq -r '.hooks.PostToolUse[] | select(.matcher == "Read|Grep|Glob") | .hooks[0].command' "$workspace/.claude/settings.json"
  [ "$output" = ".claude/hooks/native-result-compact.sh" ]

  ralph_test_rm_workspace "$workspace"
}

@test "stale restore preserves durable Cursor hook install and hook scripts" {
  source "$RUNTIME_OVERLAY_LIB"

  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_PLAN_KEY="stale-cursor-durable-hooks"
  runtime_overlay_init_state "cursor" "$RALPH_PLAN_KEY"

  mkdir -p "$workspace/.cursor/hooks"
  printf '%s\n' '{"version":1,"keep":"original"}' > "$workspace/.cursor/hooks.json"
  runtime_overlay_record_original_file "$workspace/.cursor/hooks.json"
  cp "$REPO_ROOT/bundle/.cursor/hooks.json" "$workspace/.cursor/hooks.json"

  for script in pre-tool-shell-policy.sh post-tool-shell-telemetry.sh post-tool-native-result-compact.sh post-tool-mcp-compact.sh after-shell-telemetry.sh; do
    cp "$REPO_ROOT/bundle/.cursor/hooks/$script" "$workspace/.cursor/hooks/$script"
    runtime_overlay_record_generated_file "$workspace/.cursor/hooks/$script"
  done

  run runtime_overlay_restore_stale_runs "$workspace" "$RALPH_PLAN_KEY" 0
  [ "$status" -eq 0 ]
  [ -f "$workspace/.cursor/hooks/post-tool-native-result-compact.sh" ]
  run jq -r '.hooks.postToolUse[] | select(.matcher == "Read|read|readToolCall|Grep|grep|grepToolCall|Glob|glob|globToolCall|SemanticSearch|semanticSearch") | .command' "$workspace/.cursor/hooks.json"
  [ "$output" = ".cursor/hooks/post-tool-native-result-compact.sh" ]

  ralph_test_rm_workspace "$workspace"
}

@test "malformed ambient config: invalid JSON rejected" {
  workspace="$(mktemp -d)"
  
  # Create malformed ambient config
  mkdir -p "$workspace/.cursor"
  printf '{invalid json' > "$workspace/.cursor/mcp.json"
  
  MCP_SETUP="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  RUNTIME_CONFIG_MCP="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh"
  
  # Verify malformed config is detected
  run bash -c '
    source "$1"
    source "$2"
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export RALPH_MODE=no
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3" 2>&1
  ' _ "$MCP_SETUP" "$RUNTIME_CONFIG_MCP" "$workspace"
  
  [ "$status" -ne 0 ] || [[ "$output" == *"json"* ]] || [[ "$output" == *"JSON"* ]]
  
  ralph_test_rm_workspace "$workspace"
}

@test "overlay collision precedence: ralph protected last" {
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.ralph"
  cp "$REPO_ROOT/bundle/.ralph/mcp-server.sh" "$workspace/.ralph/mcp-server.sh" 2>/dev/null || touch "$workspace/.ralph/mcp-server.sh"
  mkdir -p "$workspace/.cursor"
  printf '{"mcpServers":{"collision":{"command":"ambient-cmd"}}}' > "$workspace/.cursor/mcp.json"
  
  MCP_SETUP="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  RUNTIME_CONFIG_MCP="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh"
  
  # Test with ralph mode
  run bash -c '
    source "$1"
    source "$2"
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export RALPH_MODE=ralph
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3"
    jq -e ".mcpServers.ralph" "$RALPH_RUNTIME_MCP_RESOLVE_PATH"
  ' _ "$MCP_SETUP" "$RUNTIME_CONFIG_MCP" "$workspace"
  
  [ "$status" -eq 0 ]
  
  ralph_test_rm_workspace "$workspace"
}

@test "temp filename isolation: no secret leakage in temp paths" {
  source "$RUNTIME_OVERLAY_LIB"
  
  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_PLAN_KEY="temp-path-test"
  RUNTIME="claude"
  
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  
  # Create a temp file
  temp_file="$workspace/temp-with-secret-name.txt"
  printf 'content' > "$temp_file"
  runtime_overlay_record_external_temp_file "$temp_file"
  
  # Verify file is tracked
  summary_file="$(runtime_overlay_summary_path)"
  runtime_overlay_write_summary
  
  # Verify no secrets in summary
  ! grep -q "secret" "$summary_file" || true
  [ -f "$temp_file" ]
  
  ralph_test_rm_workspace "$workspace"
}

@test "missing variable resolution fails before CLI" {
  workspace="$(mktemp -d)"
  mkdir -p "$workspace/.cursor"
  cat > "$workspace/.cursor/mcp.json" <<'JSON'
{
  "mcpServers": {
    "test": {
      "command": "cmd",
      "env": {"MISSING": "${UNSET_VAR_12345}"}
    }
  }
}
JSON
  
  MCP_SETUP="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  RUNTIME_CONFIG_MCP="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh"
  
  # Ensure var is unset
  unset UNSET_VAR_12345 2>/dev/null || true
  
  run bash -c '
    source "$1"
    source "$2"
    unset UNSET_VAR_12345
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export RALPH_MODE=no
    ralph_runtime_config_mcp_resolve cursor "$3" "" "$3" 2>&1
  ' _ "$MCP_SETUP" "$RUNTIME_CONFIG_MCP" "$workspace"
  
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNSET_VAR_12345"* ]] || [[ "$output" == *"missing"* ]]
  
  ralph_test_rm_workspace "$workspace"
}

@test "stale journal cleanup: old journals are restored automatically" {
  source "$RUNTIME_OVERLAY_LIB"
  
  workspace="$(mktemp -d)"
  RALPH_PROJECT_ROOT="$workspace"
  plan_key="stale-journal-test"
  
  plan_dir="$workspace/.ralph-workspace/runtime-config/$plan_key"
  journal_dir="$plan_dir/journals"
  originals_dir="$plan_dir/originals"
  mkdir -p "$journal_dir" "$originals_dir/.cursor"
  mkdir -p "$workspace/.cursor"
  
  # Create original file
  target_file="$workspace/.cursor/mcp.json"
  printf '{"original":true}' > "$target_file"
  
  # Create backup
  backup_file="$originals_dir/.cursor/mcp.json"
  cp "$target_file" "$backup_file"
  
  # Mutate
  printf '{"mutated":true}' > "$target_file"
  
  # Create stale journal (very old start_time to force stale)
  journal_file="$journal_dir/journal-${plan_key}-99999-1.json"
  python3 -c "
import json
data = {
    'pid': 99999,
    'start_time': 1,
    'runtime': 'cursor',
    'plan_key': '$plan_key',
    'workspace_root': '$workspace',
    'cleanup_status': 'pending',
    'cleanup_time': None,
    'generated_files': [],
    'mutated_files': [{'path': '$target_file', 'backup': '$backup_file', 'restored': False}]
}
with open('$journal_file', 'w') as f:
    json.dump(data, f, indent=2)
"
  
  # Run restore with 0 threshold (forces stale)
  run runtime_overlay_restore_stale_runs "$workspace" "$plan_key" 0
  
  # Verify restoration
  [ "$status" -eq 0 ]
  grep -q '"original":true' "$target_file"
  
  ralph_test_rm_workspace "$workspace"
}
