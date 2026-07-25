#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

adapter_dir="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/adapters"
runtime_normalize="$REPO_ROOT/.ralph/bash-lib/runtime-normalize.sh"
runtime_resolve="$REPO_ROOT/.ralph/bash-lib/runtime-resolve.sh"
frontmatter_lib="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/frontmatter.sh"

setup() {
  _tmp="$(mktemp -d)"
  export WORKSPACE="$_tmp"
}

teardown() {
  rm -rf "$_tmp"
  unset WORKSPACE
}

_load_libs() {
  source "$runtime_normalize"
  source "$runtime_resolve"
  source "$frontmatter_lib"
  source "$adapter_dir/adapter-native-md.sh"
}

_create_native_agent() {
  local name="$1"
  local runtime="${2:-claude}"
  local model="${3:-claude-3-5-sonnet-20241022}"
  local tools="${4:-}"

  local runtime_root
  if [[ "$runtime" == "claude" ]]; then
    runtime_root="$WORKSPACE/.claude"
  elif [[ "$runtime" == "cursor" ]]; then
    runtime_root="$WORKSPACE/.cursor"
  elif [[ "$runtime" == "codex" ]]; then
    runtime_root="$WORKSPACE/.codex"
  elif [[ "$runtime" == "opencode" ]]; then
    runtime_root="$WORKSPACE/.opencode"
  fi

  mkdir -p "$runtime_root/agents"

  local tools_yaml=""
  if [[ -n "$tools" ]]; then
    tools_yaml="tools:"
    while IFS=',' read -r tool; do
      tool="$(printf '%s\n' "$tool" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [[ -n "$tool" ]] && tools_yaml="$tools_yaml"$'\n'"  - $tool"
    done <<< "$(printf '%s\n' "$tools" | sed 's/, /\n/g')"
  fi

  cat > "$runtime_root/agents/$name.md" <<MDEOF
---
name: $name
description: Test native agent for adapter
model: $model
${tools_yaml}
---

# Native Agent: $name

This is a test native runtime agent for adapter testing.
MDEOF
}

@test "native-md adapter: resolve finds native .claude agent" {
  _load_libs
  _create_native_agent "test-agent" "claude"
  run agent_adapter_native_md_resolve "test-agent" "claude" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == "native-md	$WORKSPACE/.claude/agents/test-agent.md" ]]
}

@test "native-md adapter: resolve finds native .cursor agent" {
  _load_libs
  _create_native_agent "cursor-agent" "cursor" "cursor-model"
  run agent_adapter_native_md_resolve "cursor-agent" "cursor" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" == "native-md	$WORKSPACE/.cursor/agents/cursor-agent.md" ]]
}

@test "native-md adapter: resolve returns error for missing agent" {
  _load_libs
  run agent_adapter_native_md_resolve "nonexistent" "claude" "$WORKSPACE"
  [ "$status" -eq 1 ]
}

@test "native-md adapter: resolve requires all arguments" {
  _load_libs
  run agent_adapter_native_md_resolve "" "claude" "$WORKSPACE"
  [ "$status" -eq 2 ]
}

@test "native-md adapter: to_native_passthrough sets name" {
  _load_libs
  _create_native_agent "my-agent" "claude"
  run agent_adapter_native_md_to_native_passthrough "my-agent" "claude" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ native_passthrough_name ]]
  [[ "$output" =~ "my-agent" ]]
}

@test "native-md adapter: to_native_passthrough resolves model" {
  _load_libs
  _create_native_agent "model-agent" "claude" "claude-3-7-test-model"
  run agent_adapter_native_md_to_native_passthrough "model-agent" "claude" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ native_passthrough_model ]]
  [[ "$output" =~ "claude-3-7-test-model" ]]
}

@test "native-md adapter: to_native_passthrough maps empty model" {
  _load_libs
  _create_native_agent "empty-model" "cursor" ""
  run agent_adapter_native_md_to_native_passthrough "empty-model" "cursor" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ native_passthrough_model ]]
}

@test "native-md adapter: to_native_passthrough maps tools to allowed_tools csv" {
  _load_libs
  local tools_list="read_files, execute_bash, write_files"
  _create_native_agent "tools-agent" "claude" "test-model" "$tools_list"
  run agent_adapter_native_md_to_native_passthrough "tools-agent" "claude" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ native_passthrough_allowed_tools ]]
  [[ "$output" =~ "read_files" ]]
  [[ "$output" =~ "execute_bash" ]]
  [[ "$output" =~ "write_files" ]]
  # Verify comma-separated format
  [[ "$output" =~ "read_files, execute_bash, write_files" ]]
}

@test "native-md adapter: to_native_passthrough maps single tool to allowed_tools" {
  _load_libs
  _create_native_agent "single-tool" "claude" "model" "read_files"
  run agent_adapter_native_md_to_native_passthrough "single-tool" "claude" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ native_passthrough_allowed_tools ]]
  [[ "$output" =~ "read_files" ]]
}

@test "native-md adapter: to_native_passthrough handles empty tools" {
  _load_libs
  _create_native_agent "no-tools" "claude" "model" ""
  run agent_adapter_native_md_to_native_passthrough "no-tools" "claude" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ native_passthrough_allowed_tools ]]
}

@test "native-md adapter: to_native_passthrough includes description" {
  _load_libs
  _create_native_agent "with-desc" "claude" "model"
  run agent_adapter_native_md_to_native_passthrough "with-desc" "claude" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ native_passthrough_description ]]
  [[ "$output" =~ "Test native agent for adapter" ]]
}

@test "native-md adapter: to_native_passthrough captures markdown body as instruction_body" {
  _load_libs
  _create_native_agent "body-agent" "claude" "model"
  run agent_adapter_native_md_to_native_passthrough "body-agent" "claude" "$WORKSPACE"
  [ "$status" -eq 0 ]
  [[ "$output" =~ native_passthrough_instruction_body ]]
  [[ "$output" =~ "This is a test native runtime agent" ]]
}

@test "native-md adapter: to_native_passthrough requires all arguments" {
  _load_libs
  run agent_adapter_native_md_to_native_passthrough "" "claude" "$WORKSPACE"
  [ "$status" -eq 2 ]
}

@test "native-md adapter: to_config_json carries mcp_servers from frontmatter" {
  _load_libs
  mkdir -p "$WORKSPACE/.claude/agents"
  cat >"$WORKSPACE/.claude/agents/mcp-native.md" <<'EOF'
---
name: mcp-native
description: Native agent with MCP
model: claude-test
mcp_servers:
  - ambient-server
  - name: portable-stdio
    transport: stdio
    command: node
    args:
      - /path/to/server.js
---
Native body
EOF

  local result cache_dir
  cache_dir="$WORKSPACE/cache"
  mkdir -p "$cache_dir"
  result="$(agent_adapter_native_md_to_config_json mcp-native claude "$WORKSPACE" "$cache_dir")"
  [[ -f "$result" ]]
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
m = c.get('mcp_servers', [])
assert len(m) == 2, m
assert m[0] == {'name': 'ambient-server', 'reference': True}
assert m[1]['name'] == 'portable-stdio'
assert m[1]['transport'] == 'stdio'
" "$result"
}

@test "native-md adapter: to_config_json omits mcp_servers when absent" {
  _load_libs
  _create_native_agent "no-mcp-native" "claude"
  local result cache_dir
  cache_dir="$WORKSPACE/cache"
  mkdir -p "$cache_dir"
  result="$(agent_adapter_native_md_to_config_json no-mcp-native claude "$WORKSPACE" "$cache_dir")"
  [[ -f "$result" ]]
  ! python3 -c "import json,sys; print('mcp_servers' in json.load(open(sys.argv[1])))" "$result" | grep -q True
}

@test "native-md adapter: to_native_passthrough returns error for missing file" {
  _load_libs
  run agent_adapter_native_md_to_native_passthrough "missing-agent" "claude" "$WORKSPACE"
  [ "$status" -eq 1 ]
}
