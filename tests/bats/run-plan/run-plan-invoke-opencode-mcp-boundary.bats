#!/usr/bin/env bats
# shellcheck shell=bash
#
# Ambient-MCP boundary rule for the OpenCode adapter. OPENCODE_CONFIG is one
# layer of OpenCode's precedence chain, so Ralph copies the merged ambient
# layers into the per-run temp config and merges only its own keys on top.
# These tests assert that ambient native settings and ambient MCP servers
# survive under a Ralph profile, that the reconstructed effective catalog is
# used only for the proven limitation (selected-agent mcp_servers overrides)
# and recorded in RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS, and that raw
# behavior is unchanged.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  TEST_TMPDIR="$(mktemp -d)"
  ISOLATED_HOME="$TEST_TMPDIR/home"
  XDG_DIR="$ISOLATED_HOME/.config"
  export TMPDIR="$TEST_TMPDIR"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  mkdir -p "$XDG_DIR/opencode" "$WORKSPACE/.ralph"
  cp "$REPO_ROOT/bundle/.ralph/mcp-server.sh" "$WORKSPACE/.ralph/mcp-server.sh"
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"
  export RALPH_DIR="$REPO_ROOT/bundle/.ralph"
  export SCRIPT_DIR="$RALPH_DIR"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# Run config prepare in a subshell (it registers EXIT-time cleanup, which must
# not run inside the bats process). Dumps the effective OPENCODE_CONFIG document
# and both recorded decision values.
run_opencode_config_prepare_probe() {
  local mode="$1" resolve_path="$2" agent_entries="$3" config_dump="$4" decision_out="$5"
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    source "$3"
    source "$4"
    export WORKSPACE="$5"
    export RALPH_PROJECT_ROOT="$5"
    export HOME="$6"
    export XDG_CONFIG_HOME="$6/.config"
    export RALPH_RUNTIME_MCP_HOME="$6"
    export RALPH_MODE="$7"
    unset OPENCODE_CONFIG OPENCODE_DIRECTORY_CONFIG OPENCODE_REMOTE_CONFIG
    unset SELECTED_MODEL PLAN_PATH
    export RALPH_OPENCODE_SET_CACHE_KEY=0
    if [[ -n "$8" ]]; then export RALPH_RUNTIME_MCP_RESOLVE_PATH="$8"; else unset RALPH_RUNTIME_MCP_RESOLVE_PATH; fi
    if [[ -n "$9" ]]; then export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON="$9"; else unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON; fi
    run_plan_invoke_opencode_config_prepare >/dev/null
    if [[ -n "${OPENCODE_PLAN_MCP_CONFIG_PATH:-}" ]]; then
      cp "$OPENCODE_PLAN_MCP_CONFIG_PATH" "${10}"
    else
      printf "NO_CONFIG\n" >"${10}"
    fi
    printf "%s\n%s\n" "${OPENCODE_PLAN_MCP_OVERLAY_DECISION:-}" "${RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS:-}" >"${11}"
  ' _ \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh" \
    "$WORKSPACE" "$ISOLATED_HOME" "$mode" "$resolve_path" "$agent_entries" \
    "$config_dump" "$decision_out"
}

write_ambient_configs() {
  # Global layer: an ambient MCP server plus an unrelated native setting.
  printf '%s\n' '{"theme":"opencode-dark","mcp":{"user-server":{"type":"local","command":["user-cmd"],"enabled":true}}}' \
    >"$XDG_DIR/opencode/opencode.json"
  # Project layer: JSONC with comments, another ambient server and settings.
  cat >"$WORKSPACE/opencode.jsonc" <<'JSONC'
{
  // project level ambient configuration
  "autoshare": false,
  "instructions": ["docs/PROJECT.md"],
  "mcp": {
    "project-server": { "type": "local", "command": ["project-cmd"], "enabled": true }
  }
}
JSONC
}

@test "opencode ralph profile layers ralph while preserving ambient settings and servers" {
  command -v jq >/dev/null || skip "jq required"

  write_ambient_configs
  local dump="$TEST_TMPDIR/ralph-config.json"
  local decision="$TEST_TMPDIR/ralph-decision"

  run_opencode_config_prepare_probe "ralph" "" "" "$dump" "$decision"

  [ "$status" -eq 0 ]
  [ "$(cat "$decision")" = "profile_ralph_layered_native_opencode_config
profile_ralph_layered_native_opencode_config" ]

  # Ralph's own server is layered on.
  [ "$(jq -r '.mcp.ralph | type' "$dump")" = "object" ]
  # Ambient MCP servers from BOTH the global and the JSONC project layer survive.
  [ "$(jq -r '.mcp["user-server"].command[0]' "$dump")" = "user-cmd" ]
  [ "$(jq -r '.mcp["project-server"].command[0]' "$dump")" = "project-cmd" ]
  # Ambient native settings survive; the config is not an MCP-only document.
  [ "$(jq -r '.theme' "$dump")" = "opencode-dark" ]
  [ "$(jq -r '.autoshare' "$dump")" = "false" ]
  [ "$(jq -r '.instructions[0]' "$dump")" = "docs/PROJECT.md" ]
}

@test "opencode ralph profile ignores the reconstructed catalog when no agent overrides exist" {
  command -v jq >/dev/null || skip "jq required"

  write_ambient_configs
  # A reconstructed effective catalog is available, but with no agent-declared
  # mcp_servers the Ralph profile must not use it: it would overwrite the
  # ambient entries with a lossy snapshot.
  local resolve_path="$TEST_TMPDIR/resolve.json"
  jq -n '{"mcp":{"user-server":{"type":"local","command":["stale-cmd"]},"ralph":{"type":"local","command":["true"]}}}' \
    >"$resolve_path"
  local dump="$TEST_TMPDIR/layered-config.json"
  local decision="$TEST_TMPDIR/layered-decision"

  run_opencode_config_prepare_probe "ralph" "$resolve_path" "" "$dump" "$decision"

  [ "$status" -eq 0 ]
  [ "$(cat "$decision")" = "profile_ralph_layered_native_opencode_config
profile_ralph_layered_native_opencode_config" ]
  [ "$(jq -r '.mcp["user-server"].command[0]' "$dump")" = "user-cmd" ]
  [ "$(jq -r '.mcp["project-server"].command[0]' "$dump")" = "project-cmd" ]
  [ "$(jq -r '.mcp.ralph | type' "$dump")" = "object" ]
}

@test "opencode ralph profile with agent overrides records the reconstructed-catalog limitation" {
  command -v jq >/dev/null || skip "jq required"

  write_ambient_configs
  # An agent-declared mcp_servers override must win over an ambient entry of the
  # same name, and OpenCode has no invocation-local mechanism for that, so the
  # safest current merge (the reconstructed effective catalog) is retained and
  # the limitation is recorded rather than left silent.
  local resolve_path="$TEST_TMPDIR/resolve-agent.json"
  jq -n '{"mcp":{"user-server":{"type":"local","command":["agent-cmd"]},"ralph":{"type":"local","command":["true"]}}}' \
    >"$resolve_path"
  local dump="$TEST_TMPDIR/agent-config.json"
  local decision="$TEST_TMPDIR/agent-decision"

  run_opencode_config_prepare_probe "ralph" "$resolve_path" '[{"name":"user-server"}]' "$dump" "$decision"

  [ "$status" -eq 0 ]
  [ "$(cat "$decision")" = "profile_ralph_agent_overrides_reconstructed_catalog
profile_ralph_agent_overrides_reconstructed_catalog" ]
  [ "$(jq -r '.mcp["user-server"].command[0]' "$dump")" = "agent-cmd" ]
  # Ambient native settings still survive; only the MCP catalog is authoritative.
  [ "$(jq -r '.theme' "$dump")" = "opencode-dark" ]
  [ "$(jq -r '.instructions[0]' "$dump")" = "docs/PROJECT.md" ]
}

@test "opencode raw profile leaves ambient MCP discovery untouched" {
  command -v jq >/dev/null || skip "jq required"

  write_ambient_configs
  local resolve_path="$TEST_TMPDIR/resolve-raw.json"
  jq -n '{"mcp":{"ralph":{"type":"local","command":["true"]}}}' >"$resolve_path"
  local dump="$TEST_TMPDIR/raw-config.json"
  local decision="$TEST_TMPDIR/raw-decision"

  run_opencode_config_prepare_probe "no" "$resolve_path" "" "$dump" "$decision"

  [ "$status" -eq 0 ]
  # No temp OPENCODE_CONFIG is produced at all: raw runs are unchanged.
  [ "$(cat "$dump")" = "NO_CONFIG" ]
  [ "$(cat "$decision")" = "profile_raw_native_mcp_discovery_unchanged
profile_raw_native_mcp_discovery_unchanged" ]
}

@test "opencode session continuation tier probe selects invocation matching evaluate" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-tier-probe.sh"

  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=auto
  unset RALPH_BG_OPENCODE_SESSION_IDLE_PROVEN
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  mkdir -p "$WORKSPACE/.opencode/plugins"

  local probe expected
  probe="$(ralph_bg_tier_probe_evaluate opencode)"
  expected="$(jq -r '.tier' <<<"$probe")"
  [ "$expected" = "invocation" ]
  [[ "$(jq -r '.reason' <<<"$probe")" == *"opencode-session-idle"* ]]

  ralph_bg_tier_probe_apply opencode >/dev/null
  [ "${RALPH_BG_TIER_SELECTED:-}" = "$expected" ]
  [[ "${RALPH_BG_TIER_REASON:-}" == *"opencode-session-idle"* ]]
}

@test "opencode tier1 continuation holds session and emits no resume argv" {
  local bin_dir="$TEST_TMPDIR/bin"
  local record="$TEST_TMPDIR/opencode-tier1-held.args"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$bin_dir/opencode"
  PATH="$bin_dir:$PATH"
  export PATH

  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"

  export HOME="$ISOLATED_HOME"
  export XDG_CONFIG_HOME="$ISOLATED_HOME/.config"
  export RALPH_RUNTIME_MCP_HOME="$ISOLATED_HOME"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export OPENCODE_PLAN_CLI="$bin_dir/opencode"
  export OUTPUT_LOG="$TEST_TMPDIR/opencode-tier1.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/opencode-tier1.exit"
  export SESSION_ID_FILE="$TEST_TMPDIR/session-id.opencode.txt"
  printf '%s\n' "held-opencode-session" >"$SESSION_ID_FILE"
  : >"$OUTPUT_LOG"
  : >"$EXIT_CODE_FILE"
  export RALPH_BG_TIER_SELECTED=hook
  export RALPH_USAGE_SESSION_CONTINUITY=held
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  export RALPH_MODE=native
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export PROMPT="opencode-tier1-held"

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  ! grep -Fxq -- "--session" "$record"
  ! grep -Fxq -- "--continue" "$record"
  ! grep -Fxq -- "held-opencode-session" "$record"
}

@test "opencode tier2 continuation resumes exact session id while fresh todo-start omits resume" {
  command -v jq >/dev/null 2>&1 || skip "jq required"

  local bin_dir="$TEST_TMPDIR/bin"
  mkdir -p "$bin_dir"
  PATH="$bin_dir:$PATH"
  export PATH

  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
  ralph_run_plan_log() { :; }

  export HOME="$ISOLATED_HOME"
  export XDG_CONFIG_HOME="$ISOLATED_HOME/.config"
  export RALPH_RUNTIME_MCP_HOME="$ISOLATED_HOME"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export OPENCODE_PLAN_CLI="$bin_dir/opencode"
  export OUTPUT_LOG="$TEST_TMPDIR/opencode-tier2.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/opencode-tier2.exit"
  : >"$OUTPUT_LOG"
  : >"$EXIT_CODE_FILE"

  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  mkdir -p "$RALPH_SESSION_DIR"
  export RUNTIME=opencode
  export RALPH_PROCESS_RUN_ID=run-opencode-tier2
  export RALPH_CURRENT_TODO_ORDINAL=1
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.opencode.txt"
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  export RALPH_BG_TIER_SELECTED=invocation
  export RALPH_MODE=native

  export RALPH_CURRENT_TODO_LINE=17
  export RALPH_CURRENT_TODO_ID=opencode-tier2-start-todo
  export RALPH_CURRENT_TODO_HASH=hash-opencode-tier2-start
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]

  local start_record="$TEST_TMPDIR/opencode-tier2-start.args"
  cat >"$bin_dir/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$start_record"
exit 0
EOF
  chmod +x "$bin_dir/opencode"
  export PROMPT="opencode-tier2-start"
  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--session" "$start_record"

  export RALPH_CURRENT_TODO_LINE=18
  export RALPH_CURRENT_TODO_ID=opencode-tier2-cont-todo
  export RALPH_CURRENT_TODO_HASH=hash-opencode-tier2-cont
  ralph_session_todo_create "exact-opencode-session" "exact" >/dev/null
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" = "exact-opencode-session" ]

  local cont_record="$TEST_TMPDIR/opencode-tier2-cont.args"
  cat >"$bin_dir/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$cont_record"
exit 0
EOF
  chmod +x "$bin_dir/opencode"
  export PROMPT="opencode-tier2-continue"
  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  grep -Fxq -- "--session" "$cont_record"
  grep -Fxq -- "exact-opencode-session" "$cont_record"

  export RALPH_CURRENT_TODO_ID=opencode-tier2-rework
  export RALPH_CURRENT_TODO_HASH=hash-opencode-tier2-rework
  export RALPH_CURRENT_TODO_LINE=19
  export RALPH_PLAN_CLI_RESUME=0
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
}
