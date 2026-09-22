#!/usr/bin/env bats
# shellcheck shell=bash
# Antigravity MCP overlay after profile MCP layer removal:
# ambient native discovery, then Ralph protected server when mode enables it.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

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

  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.agents"
  cp "$REPO_ROOT/bundle/.ralph/mcp-server.sh" "$WORKSPACE/.ralph/mcp-server.sh"

  printf '%s\n' '{"mcpServers":{"ambient1":{"command":"ambient-cmd"}}}' >"$WORKSPACE/.agents/mcp_config.json"

  export OUTPUT_LOG="$TEST_TMPDIR/output.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/exit-code"
  export PROMPT="antigravity-mcp-prompt"

  export ANTIGRAVITY_PLAN_SKIP_PERMISSIONS=1

  PATH="$BIN_DIR:$PATH"
  export PATH

  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-antigravity.sh"

  export OVERLAY_DECISION_FILE="$TEST_TMPDIR/overlay-decision"
  runtime_overlay_set_mcp_override_decisions() {
    printf '%s\n' "${1:-}" >"$OVERLAY_DECISION_FILE"
  }
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

write_agy_stub() {
  local record="$1"
  cat >"$BIN_DIR/agy" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "\${ANTIGRAVITY_CONFIG:-}" ]]; then
  printf 'ANTIGRAVITY_CONFIG:%s\n' "\$ANTIGRAVITY_CONFIG" >>"$record"
  if [[ -f "\$ANTIGRAVITY_CONFIG" ]]; then
    printf 'CONFIG_EXISTS:1\n' >>"$record"
    cp "\$ANTIGRAVITY_CONFIG" "$record.config"
  else
    printf 'CONFIG_EXISTS:0\n' >>"$record"
  fi
fi

printf 'DECISION:%s\n' "\${ANTIGRAVITY_PLAN_MCP_OVERLAY_DECISION:-}" >>"$record"

printf 'ARGS:%s\n' "\$*" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/agy"
}

@test "antigravity native-only run does not create ANTIGRAVITY_CONFIG" {
  write_agy_stub "$TEST_TMPDIR/record1"

  unset RALPH_MODE
  unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
  unset PREBUILT_AGENT
  unset RALPH_RUNTIME_MCP_RESOLVE_PATH

  export ANTIGRAVITY_PLAN_CLI=agy
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  run grep -q "ANTIGRAVITY_CONFIG:" "$TEST_TMPDIR/record1"
  [ "$status" -ne 0 ]
}

@test "antigravity ralph mode reconstructs ambient + protected ralph and cleans up" {
  command -v jq >/dev/null 2>&1 || skip "jq required"

  write_agy_stub "$TEST_TMPDIR/record2"
  ambient_before="$(shasum -a 256 "$WORKSPACE/.agents/mcp_config.json" | awk '{print $1}')"

  export RALPH_MODE=ralph
  unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
  unset PREBUILT_AGENT

  export ANTIGRAVITY_PLAN_CLI=agy
  export RALPH_PLAN_CLI_RESUME=0
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]

  config_path="$(awk -F: '/^ANTIGRAVITY_CONFIG:/{print $2; exit}' "$TEST_TMPDIR/record2")"
  [ -n "$config_path" ]
  grep -Fxq "CONFIG_EXISTS:1" "$TEST_TMPDIR/record2"
  [ ! -f "$config_path" ]
  [ "$(shasum -a 256 "$WORKSPACE/.agents/mcp_config.json" | awk '{print $1}')" = "$ambient_before" ]

  [ -f "$TEST_TMPDIR/record2.config" ]
  run jq -r '.mcpServers | keys | join(",")' "$TEST_TMPDIR/record2.config"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ambient1"* ]]
  [[ "$output" == *"ralph"* ]]
  grep -Fxq "DECISION:profile_ralph_reconstructed_catalog" "$TEST_TMPDIR/record2"
}

@test "antigravity rejects removed profile MCP agent entries" {
  write_agy_stub "$TEST_TMPDIR/record3"

  export RALPH_MODE=ralph
  export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='[
    {"name":"ambient1","transport":"stdio","command":"bash","args":["-lc","echo agent"],"env":{}}
  ]'
  export PREBUILT_AGENT=""

  export ANTIGRAVITY_PLAN_CLI=agy
  run ralph_run_plan_invoke_antigravity
  [ "$status" -ne 0 ]
  [[ "$output" == *"profile MCP layer is removed"* ]]
}

@test "antigravity overlay cleans up after profile-layer rejection" {
  write_agy_stub "$TEST_TMPDIR/record4"

  export RALPH_MODE=ralph
  export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='["missing-ambient"]'
  unset ANTIGRAVITY_CONFIG
  export ANTIGRAVITY_PLAN_CLI=agy
  run bash -c 'ralph_run_plan_invoke_antigravity || true; [[ -z "${ANTIGRAVITY_CONFIG:-}" ]]'
  [ "$status" -eq 0 ]
}

@test "antigravity ralph mode keeps ambient file byte-exact on disk" {
  write_agy_stub "$TEST_TMPDIR/record5"
  ambient_before="$(shasum -a 256 "$WORKSPACE/.agents/mcp_config.json" | awk '{print $1}')"

  export RALPH_MODE=ralph
  unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
  unset PREBUILT_AGENT

  export ANTIGRAVITY_PLAN_CLI=agy
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  [ "$(shasum -a 256 "$WORKSPACE/.agents/mcp_config.json" | awk '{print $1}')" = "$ambient_before" ]
}

@test "antigravity raw mode keeps native config and ignores no profile layer" {
  write_agy_stub "$TEST_TMPDIR/record6"
  ambient_before="$(shasum -a 256 "$WORKSPACE/.agents/mcp_config.json" | awk '{print $1}')"

  export RALPH_MODE=no
  unset RALPH_AGENT_TOOL_ACCESS
  unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
  unset PREBUILT_AGENT

  export ANTIGRAVITY_PLAN_CLI=agy
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]

  run grep -q "ANTIGRAVITY_CONFIG:" "$TEST_TMPDIR/record6"
  [ "$status" -ne 0 ]
  grep -Fxq "DECISION:profile_raw_native_mcp_config_unchanged" "$TEST_TMPDIR/record6"
  [ "$(cat "$OVERLAY_DECISION_FILE")" = "profile_raw_native_mcp_config_unchanged" ]
  [ "$(shasum -a 256 "$WORKSPACE/.agents/mcp_config.json" | awk '{print $1}')" = "$ambient_before" ]
}

@test "antigravity session continuation tier probe selects hook for .agents layout" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-tier-probe.sh"

  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=auto
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  mkdir -p "$WORKSPACE/.agents"

  local probe expected
  probe="$(ralph_bg_tier_probe_evaluate antigravity)"
  expected="$(jq -r '.tier' <<<"$probe")"
  [ "$expected" = "hook" ]
  [[ "$(jq -r '.reason' <<<"$probe")" == *"antigravity-stop-hook"* ]]

  ralph_bg_tier_probe_apply antigravity >/dev/null
  [ "${RALPH_BG_TIER_SELECTED:-}" = "$expected" ]
  [[ "${RALPH_BG_TIER_REASON:-}" == *"antigravity-stop-hook"* ]]
}

@test "antigravity tier1 continuation holds session and emits no conversation resume argv" {
  local record="$TEST_TMPDIR/agy-tier1-held.args"
  write_agy_stub "$record"
  export SESSION_ID_FILE="$TEST_TMPDIR/session-id.antigravity.txt"
  printf '%s\n' "held-agy-conversation" >"$SESSION_ID_FILE"
  export RALPH_BG_TIER_SELECTED=hook
  export RALPH_USAGE_SESSION_CONTINUITY=held
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  export RALPH_MODE=no
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export ANTIGRAVITY_PLAN_CLI=agy
  export PROMPT="antigravity-tier1-held"

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -q -- "--print" "$record"
  ! grep -q -- "--conversation" "$record"
  ! grep -q -- "held-agy-conversation" "$record"
}

@test "antigravity tier2 continuation resumes minted conversation id with --print and cache capture" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
  ralph_run_plan_log() { :; }

  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  mkdir -p "$RALPH_SESSION_DIR" "$WORKSPACE/.agents"
  export RUNTIME=antigravity
  export RALPH_PROCESS_RUN_ID=run-agy-tier2
  export RALPH_CURRENT_TODO_ORDINAL=1
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.antigravity.txt"
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  export RALPH_BG_TIER_SELECTED=invocation
  export RALPH_MODE=no
  export ANTIGRAVITY_PLAN_CLI=agy
  export RALPH_GEMINI_HOME="$TEST_TMPDIR/gemini"
  mkdir -p "$RALPH_GEMINI_HOME/antigravity-cli/cache"

  # Fresh todo-start omits --conversation; --print remains.
  export RALPH_CURRENT_TODO_LINE=17
  export RALPH_CURRENT_TODO_ID=agy-tier2-start-todo
  export RALPH_CURRENT_TODO_HASH=hash-agy-tier2-start
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]

  local start_record="$TEST_TMPDIR/agy-tier2-start.args"
  write_agy_stub "$start_record"
  printf '{"%s": "minted-agy-conversation"}\n' "$WORKSPACE" \
    >"$RALPH_GEMINI_HOME/antigravity-cli/cache/last_conversations.json"
  export PROMPT="antigravity-tier2-start"
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -q -- "--print" "$start_record"
  ! grep -q -- "--conversation" "$start_record"
  [ -f "$SESSION_ID_FILE" ]
  grep -Fxq -- "minted-agy-conversation" "$SESSION_ID_FILE"

  export RALPH_CURRENT_TODO_LINE=18
  export RALPH_CURRENT_TODO_ID=agy-tier2-cont-todo
  export RALPH_CURRENT_TODO_HASH=hash-agy-tier2-cont
  ralph_session_todo_create "minted-agy-conversation" "exact" >/dev/null
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" = "minted-agy-conversation" ]

  local cont_record="$TEST_TMPDIR/agy-tier2-cont.args"
  write_agy_stub "$cont_record"
  export PROMPT="antigravity-tier2-continue"
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -q -- "--print" "$cont_record"
  grep -q -- "--conversation" "$cont_record"
  grep -q -- "minted-agy-conversation" "$cont_record"

  export RALPH_CURRENT_TODO_ID=agy-tier2-rework
  export RALPH_CURRENT_TODO_HASH=hash-agy-tier2-rework
  export RALPH_CURRENT_TODO_LINE=19
  export RALPH_PLAN_CLI_RESUME=0
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
}

