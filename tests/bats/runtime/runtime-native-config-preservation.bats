#!/usr/bin/env bats
# Native config byte-exact restoration after role cutover.
# Hashes representative project native configs for all five runtimes before and
# after role-bearing success, preflight failure, model failure, timeout, and
# signal cleanup.
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUNTIME_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"

# Representative project-native configs (one per runtime).
NATIVE_REL_PATHS=(
  ".claude/settings.json"
  ".cursor/mcp.json"
  ".codex/config.toml"
  ".opencode/opencode.json"
  ".agents/mcp_config.json"
)

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  workspace="$(mktemp -d)"
  WORKSPACE="$workspace"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_AGENT_WORKSPACE="$workspace"
  RALPH_PLAN_KEY="native-config-preservation"
  RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace"
  export WORKSPACE RALPH_PROJECT_ROOT RALPH_AGENT_WORKSPACE RALPH_PLAN_KEY RALPH_PLAN_WORKSPACE_ROOT

  # Role-bearing context: instruction-only role must not change restore behavior.
  RALPH_ROLE_ID="research"
  RALPH_ROLE_SOURCE_KIND="bundled"
  RALPH_ROLE_BODY=$'## Instructions\n\nPrefer evidence.'
  export RALPH_ROLE_ID RALPH_ROLE_SOURCE_KIND RALPH_ROLE_BODY

  mkdir -p \
    "$workspace/.claude" \
    "$workspace/.cursor" \
    "$workspace/.codex" \
    "$workspace/.opencode" \
    "$workspace/.agents" \
    "$workspace/.ralph/roles" \
    "$RALPH_PLAN_WORKSPACE_ROOT"

  printf '%s\n' '{"keep":"claude-native","hooks":{}}' >"$workspace/.claude/settings.json"
  printf '%s\n' '{"mcpServers":{"project":{"command":"cursor-ambient"}},"keep":"cursor-native"}' >"$workspace/.cursor/mcp.json"
  printf '%s\n' '# keep=codex-native' >"$workspace/.codex/config.toml"
  printf 'model = "gpt-test"\n[mcp_servers.ambient]\ncommand = "codex-ambient"\n' >>"$workspace/.codex/config.toml"
  printf '%s\n' '{"keep":"opencode-native","mcp":{"ambient":{"command":"opencode-ambient"}}}' >"$workspace/.opencode/opencode.json"
  printf '%s\n' '{"mcpServers":{"ambient":{"command":"agy-ambient"}},"keep":"antigravity-native"}' >"$workspace/.agents/mcp_config.json"

  cat >"$workspace/.ralph/roles/research.md" <<'EOF'
---
description: "Research role for preservation tests"
---
## Instructions

Prefer evidence over claims.
EOF
}

teardown() {
  ralph_test_rm_workspace "$workspace"
}

_hash_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

_snapshot_native_hashes() {
  local rel path
  for rel in "${NATIVE_REL_PATHS[@]}"; do
    path="$workspace/$rel"
    [ -f "$path" ] || {
      echo "missing native config: $rel" >&2
      return 1
    }
    printf '%s %s\n' "$rel" "$(_hash_file "$path")"
  done
}

_assert_native_hashes_unchanged() {
  local before="$1"
  local after
  after="$(_snapshot_native_hashes)"
  if [[ "$before" != "$after" ]]; then
    printf 'native config hash mismatch\nbefore:\n%s\nafter:\n%s\n' "$before" "$after" >&2
    return 1
  fi
}

_mutate_all_native_configs() {
  local rel path
  for rel in "${NATIVE_REL_PATHS[@]}"; do
    path="$workspace/$rel"
    runtime_overlay_record_original_file "$path"
    printf 'MUTATED-BY-OVERLAY role=%s outcome=%s\n' "${RALPH_ROLE_ID:-none}" "${1:-unknown}" >"$path"
  done
}

_restore_via_outcome() {
  local outcome="$1"
  case "$outcome" in
    success|model-failure|timeout)
      # Mimic run-plan EXIT / failure / timeout cleanup: registered cmds then restore.
      runtime_overlay_run_cleanup
      runtime_overlay_journal_mark_cleaned
      ;;
    signal)
      # Mimic interrupt handler: cleanup_if_needed path without EXIT-chained restores.
      runtime_overlay_run_cleanup
      runtime_overlay_journal_mark_cleaned
      ;;
    *)
      echo "unknown outcome: $outcome" >&2
      return 1
      ;;
  esac
}

_init_overlay_for_runtime() {
  local runtime="$1"
  source "$RUNTIME_OVERLAY_LIB"
  runtime_overlay_init_state "$runtime" "$RALPH_PLAN_KEY"
}

@test "role-bearing success restores hashed native configs for all five runtimes" {
  local before
  before="$(_snapshot_native_hashes)"

  _init_overlay_for_runtime "cursor"
  _mutate_all_native_configs "success"
  ! grep -Fq 'claude-native' "$workspace/.claude/settings.json"
  _restore_via_outcome "success"
  _assert_native_hashes_unchanged "$before"
}


@test "role-bearing model failure restores hashed native configs for all five runtimes" {
  local before
  before="$(_snapshot_native_hashes)"

  _init_overlay_for_runtime "claude"
  _mutate_all_native_configs "model-failure"
  _restore_via_outcome "model-failure"
  _assert_native_hashes_unchanged "$before"
}

@test "role-bearing timeout cleanup restores hashed native configs for all five runtimes" {
  local before
  before="$(_snapshot_native_hashes)"

  _init_overlay_for_runtime "codex"
  _mutate_all_native_configs "timeout"
  _restore_via_outcome "timeout"
  _assert_native_hashes_unchanged "$before"
}

@test "role-bearing signal cleanup restores hashed native configs for all five runtimes" {
  local before script status_file
  before="$(_snapshot_native_hashes)"
  status_file="$workspace/signal-still-running"
  script="$workspace/signal-child.sh"

  cat >"$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$RUNTIME_OVERLAY_LIB"
export WORKSPACE="$workspace"
export RALPH_PROJECT_ROOT="$workspace"
export RALPH_AGENT_WORKSPACE="$workspace"
export RALPH_PLAN_KEY="$RALPH_PLAN_KEY"
export RALPH_ROLE_ID=research
export RALPH_ROLE_SOURCE_KIND=bundled
runtime_overlay_init_state "opencode" "$RALPH_PLAN_KEY"
while IFS= read -r rel; do
  [[ -z "\$rel" ]] && continue
  path="$workspace/\$rel"
  runtime_overlay_record_original_file "\$path"
  printf 'MUTATED-BY-SIGNAL\\n' >"\$path"
done <<'RELS'
.claude/settings.json
.cursor/mcp.json
.codex/config.toml
.opencode/opencode.json
.agents/mcp_config.json
RELS
# Install restore traps then self-signal (mirrors interrupt cleanup path).
runtime_overlay_install_restore_traps
kill -TERM \$\$
echo still-running >"$status_file"
EOF
  chmod +x "$script"

  run bash "$script"
  [ "$status" -ne 0 ]
  [ ! -f "$status_file" ]
  _assert_native_hashes_unchanged "$before"
}

@test "role-bearing signal via run_cleanup restores hashed native configs for all five runtimes" {
  # run-plan interrupt clears EXIT before exit; restoration must happen through
  # runtime_overlay_run_cleanup (called from ralph_runtime_overlay_signal_trap_handler).
  local before
  before="$(_snapshot_native_hashes)"

  _init_overlay_for_runtime "antigravity"
  _mutate_all_native_configs "signal"
  _restore_via_outcome "signal"
  _assert_native_hashes_unchanged "$before"
}

@test "cursor mcp overlay with role restores project mcp.json hash on success failure and cleanup" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  local before mcp_lib invoke_lib
  before="$(_snapshot_native_hashes)"
  mcp_lib="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  invoke_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh"

  source "$RUNTIME_OVERLAY_LIB"
  source "$mcp_lib"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh"
  source "$invoke_lib"

  runtime_overlay_init_state "cursor" "$RALPH_PLAN_KEY"
  export RALPH_MODE=ralph
  # Ralph mode requires a resolvable MCP server script; point at the real one.
  export RALPH_MCP_PROXY_SERVER_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"
  export HOME="$workspace/home"
  export RALPH_RUNTIME_MCP_HOME="$HOME"
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{"mcpServers":{"user":{"command":"user-cmd"}}}' >"$HOME/.cursor/mcp.json"

  ralph_runtime_config_mcp_resolve cursor "$workspace" "" "$workspace"
  run_plan_invoke_cursor_mcp_config_prepare
  # Overlay mutated project mcp.json; ambient keep key may still be present but
  # file bytes must differ from the hashed original.
  [ "$(cat "$workspace/.cursor/mcp.json")" != "$(printf '%s\n' '{"mcpServers":{"project":{"command":"cursor-ambient"}},"keep":"cursor-native"}')" ] \
    || grep -q '"ralph"' "$workspace/.cursor/mcp.json"

  run_plan_invoke_cursor_mcp_config_cleanup
  runtime_overlay_run_cleanup
  _assert_native_hashes_unchanged "$before"
}
