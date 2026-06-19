#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"

adapter_dir="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/adapters"
frontmatter_lib="$REPO_ROOT/bundle/.ralph/bash-lib/agent-source/frontmatter.sh"
runtime_normalize="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-normalize.sh"

setup() {
  bats_skip_known_ci_flakes
  _tmp="$(mktemp -d)"
  _cache="$_tmp/cache"
  mkdir -p "$_cache"
}

teardown() {
  rm -rf "$_tmp"
}

_source_sync_lib() {
  # shellcheck disable=SC1090
  eval "$(sed '/^sync_assets_main "\$@"/d' "$REPO_ROOT/scripts/sync-runtime-assets.sh")"
}

_load_adapter_libs() {
  source "$runtime_normalize"
  source "$frontmatter_lib"
  source "$adapter_dir/adapter-ralph-md.sh"
}

_write_mcp_canonical() {
  local dest="$1"
  cat >"$dest" <<'EOF'
---
description: Sync MCP test agent
models:
  claude: claude-test
rules:
  - no-emoji
skills:
  - repo-context
mcp_servers:
  - ambient-server
  - name: portable-http
    transport: http
    url: https://example.com/mcp
    headers:
      Authorization: "${MCP_TOKEN}"
---
Body
EOF
}

@test "sync-runtime-assets --check passes with current generated fixtures" {
  run bash "$REPO_ROOT/scripts/sync-runtime-assets.sh" --check
  [ "$status" -eq 0 ]
}

@test "sync-runtime-assets render carries mcp_servers from canonical frontmatter" {
  _source_sync_lib
  _load_adapter_libs

  mkdir -p "$_tmp/bundle/.ralph/agents"
  local canonical="$_tmp/bundle/.ralph/agents/mcp-sync.md"
  _write_mcp_canonical "$canonical"

  local sync_file adapter_out
  sync_file="$_cache/sync.json"
  sync_assets_render_agent_config_json bundle claude mcp-sync "$canonical" "bundle/.ralph/agents/mcp-sync.md" >"$sync_file"
  adapter_out="$(agent_adapter_ralph_md_to_config_json mcp-sync claude "$_tmp" "$_cache" bundle)"

  [[ -f "$sync_file" ]] || { echo "sync render produced no file" >&2; return 1; }
  [[ -f "$adapter_out" ]] || { echo "adapter produced no file" >&2; return 1; }

  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    sync_cfg = json.load(f)
with open(sys.argv[2]) as f:
    adapter_cfg = json.load(f)
sync_m = sync_cfg.get('mcp_servers', [])
adapter_m = adapter_cfg.get('mcp_servers', [])
assert sync_m == adapter_m, (sync_m, adapter_m)
assert len(sync_m) == 2, sync_m
assert sync_m[0] == {'name': 'ambient-server', 'reference': True}
assert sync_m[1]['name'] == 'portable-http'
assert sync_m[1]['transport'] == 'http'
" "$sync_file" "$adapter_out"
}

@test "sync-runtime-assets render omits mcp_servers when frontmatter absent" {
  _source_sync_lib

  local canonical="$_tmp/no-mcp.md"
  cat >"$canonical" <<'EOF'
---
description: No MCP
models:
  claude: claude-test
rules:
  - no-emoji
skills:
  - repo-context
---
Body
EOF

  local sync_file="$_cache/no-mcp.json"
  sync_assets_render_agent_config_json bundle claude no-mcp "$canonical" "bundle/.ralph/agents/no-mcp.md" >"$sync_file"
  ! python3 -c "import json,sys; print('mcp_servers' in json.load(open(sys.argv[1])))" "$sync_file" | grep -q True
}
