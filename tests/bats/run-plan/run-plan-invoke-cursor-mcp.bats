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
    export WORKSPACE="$5"
    export RALPH_PROJECT_ROOT="$5"
    export HOME="$6"
    export RALPH_RUNTIME_MCP_HOME="$6"
    ralph_runtime_config_mcp_resolve cursor "$5" "" "$5"
    export PROMPT=cursor-test-prompt
    export OUTPUT_LOG="$7/output.log"
    export EXIT_CODE_FILE="$7/exit-code"
    ralph_run_plan_invoke_cursor
  ' _ "$TEST_TMPDIR" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh" \
    "$WORKSPACE" "$ISOLATED_HOME" "$TEST_TMPDIR"
}

# Exercise the MCP overlay prepare/cleanup pair in a subshell (the overlay
# registers an EXIT-time cleanup, which must not run inside the bats process).
# Dumps the overlaid project config and both recorded decision values.
run_cursor_mcp_prepare_probe() {
  local resolve_path="$1" agent_entries="$2" mode="$3" overlay_dump="$4" decision_out="$5"
  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    source "$3"
    export WORKSPACE="$4"
    export RALPH_PROJECT_ROOT="$4"
    export HOME="$5"
    export RALPH_RUNTIME_MCP_HOME="$5"
    export RALPH_MODE="$8"
    if [[ -n "$6" ]]; then export RALPH_RUNTIME_MCP_RESOLVE_PATH="$6"; else unset RALPH_RUNTIME_MCP_RESOLVE_PATH; fi
    if [[ -n "$7" ]]; then export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON="$7"; else unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON; fi
    run_plan_invoke_cursor_mcp_config_prepare >/dev/null
    cp "$4/.cursor/mcp.json" "$9"
    printf "%s\n%s\n" "$CURSOR_PLAN_MCP_OVERLAY_DECISION" "${RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS:-}" >"${10}"
    run_plan_invoke_cursor_mcp_config_cleanup
  ' _ \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh" \
    "$WORKSPACE" "$ISOLATED_HOME" "$resolve_path" "$agent_entries" "$mode" \
    "$overlay_dump" "$decision_out"
}

@test "cursor ralph mode layers ralph onto the project overlay and leaves user-level ambient to native discovery" {
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
  # Ambient-MCP boundary rule: the project-level ambient server and unrelated
  # keys survive the merge, and the user-level ambient server is NOT reproduced
  # into the project file -- cursor-agent loads ~/.cursor/mcp.json natively at
  # the same time as the project file, so re-emitting it would only be a lossy
  # reconstructed copy.
  grep -q '"project-server"' "$mcp_capture"
  ! grep -q '"user-server"' "$mcp_capture"
  grep -q '"keep"[[:space:]]*:[[:space:]]*"keep-value"' "$mcp_capture"
}

@test "cursor hybrid mode leaves ambient user servers to native discovery and layers ralph proxy" {
  [ -x "$(command -v jq)" ] || skip "jq required"
  [ -f "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" ] || skip "runtime-config-mcp.sh missing"

  printf '%s\n' '{"mcpServers":{"shared":{"command":"shared-cmd"}}}' >"$ISOLATED_HOME/.cursor/mcp.json"

  local record="$TEST_TMPDIR/cursor-hybrid.args"
  local mcp_capture="$TEST_TMPDIR/cursor-hybrid.mcp"

  run_cursor_with_resolver "hybrid" "$record" "$mcp_capture"

  [ "$status" -eq 0 ]
  # The user-level ambient server stays visible through Cursor's own loading of
  # ~/.cursor/mcp.json; the overlay only layers Ralph.
  ! grep -q '"shared"' "$mcp_capture"
  grep -q '"ralph"' "$mcp_capture"
  grep -Fxq -- "--workspace" "$record"
  grep -Fxq -- "--approve-mcps" "$record"
}

@test "cursor ralph profile records the layered native decision in the overlay summary" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  printf '%s\n' '{"mcpServers":{"user-server":{"command":"user-cmd"}}}' >"$ISOLATED_HOME/.cursor/mcp.json"
  printf '%s\n' '{"mcpServers":{"project-server":{"command":"project-cmd"}}}' >"$WORKSPACE/.cursor/mcp.json"
  local original_bytes
  original_bytes="$(cat "$WORKSPACE/.cursor/mcp.json")"

  # A reconstructed effective catalog is available, but with no agent-declared
  # mcp_servers the Ralph profile must not use it.
  local resolve_path="$TEST_TMPDIR/resolve.json"
  jq -n '{"mcpServers":{"user-server":{"command":"user-cmd"},"project-server":{"command":"project-cmd"},"ralph":{"command":"true"}}}' >"$resolve_path"
  local overlay_dump="$TEST_TMPDIR/layered-overlay.json"

  run_cursor_mcp_prepare_probe \
    "$resolve_path" "" "ralph" "$overlay_dump" "$TEST_TMPDIR/layered-decision"

  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/layered-decision")" = "profile_ralph_layered_native_project_mcp_json
profile_ralph_layered_native_project_mcp_json" ]
  grep -q '"ralph"' "$overlay_dump"
  grep -q '"project-server"' "$overlay_dump"
  ! grep -q '"user-server"' "$overlay_dump"
  # Byte-exact restoration of the project config after cleanup.
  [ "$(cat "$WORKSPACE/.cursor/mcp.json")" = "$original_bytes" ]
}

@test "cursor ralph profile with agent overrides records the reconstructed-catalog limitation" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  printf '%s\n' '{"mcpServers":{"project-server":{"command":"project-cmd"}}}' >"$WORKSPACE/.cursor/mcp.json"
  local original_bytes
  original_bytes="$(cat "$WORKSPACE/.cursor/mcp.json")"

  # An agent-declared mcp_servers override must win over an ambient entry of the
  # same name, and Cursor has no invocation-local mechanism for that, so the
  # safest current merge (the reconstructed effective catalog) is retained and
  # the limitation is recorded rather than left silent.
  local resolve_path="$TEST_TMPDIR/resolve-agent.json"
  jq -n '{"mcpServers":{"tools":{"command":"agent-cmd"},"user-server":{"command":"user-cmd"},"ralph":{"command":"true"}}}' >"$resolve_path"
  local overlay_dump="$TEST_TMPDIR/agent-overlay.json"

  run_cursor_mcp_prepare_probe \
    "$resolve_path" '[{"name":"tools"}]' "ralph" "$overlay_dump" "$TEST_TMPDIR/agent-decision"

  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/agent-decision")" = "profile_ralph_agent_overrides_reconstructed_catalog
profile_ralph_agent_overrides_reconstructed_catalog" ]
  grep -q 'agent-cmd' "$overlay_dump"
  grep -q '"user-server"' "$overlay_dump"
  # Byte-exact restoration of the project config after cleanup.
  [ "$(cat "$WORKSPACE/.cursor/mcp.json")" = "$original_bytes" ]
}

# Profile-declared MCP entries were removed: MCP composition is native
# ambient configuration plus Ralph's protected server. See
# tests/bats/runtime-config/runtime-config-mcp.bats for the replacement
# coverage, including the rejection of the removed agent-entries env.

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

@test "cursor session continuation tier probe selects hook matching evaluate" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-tier-probe.sh"

  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=auto
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  mkdir -p "$WORKSPACE/.cursor"

  local probe expected
  probe="$(ralph_bg_tier_probe_evaluate cursor)"
  expected="$(jq -r '.tier' <<<"$probe")"
  [ "$expected" = "hook" ]
  [[ "$(jq -r '.reason' <<<"$probe")" == *"cursor-stop-hook"* ]]

  # Call apply in-process (not under run/$(...)) so exports persist.
  ralph_bg_tier_probe_apply cursor >/dev/null
  [ "${RALPH_BG_TIER_SELECTED:-}" = "$expected" ]
  [[ "${RALPH_BG_TIER_REASON:-}" == *"cursor-stop-hook"* ]]
}

@test "cursor tier1 continuation holds session and emits no resume argv" {
  local record="$TEST_TMPDIR/cursor-tier1-held.args"
  write_cursor_stub "$record"
  export SESSION_ID_FILE="$TEST_TMPDIR/session-id.cursor.txt"
  printf '%s\n' "held-cursor-session" >"$SESSION_ID_FILE"
  export RALPH_BG_TIER_SELECTED=hook
  export RALPH_USAGE_SESSION_CONTINUITY=held
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  unset RALPH_MODE
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export PROMPT="cursor-tier1-held"

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  ! grep -Fxq -- "--resume" "$record"
  ! grep -Fxq -- "held-cursor-session" "$record"
}

@test "cursor tier2 continuation resumes exact session id while fresh todo-start omits resume" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
  ralph_run_plan_log() { :; }

  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  mkdir -p "$RALPH_SESSION_DIR"
  export RUNTIME=cursor
  export RALPH_PROCESS_RUN_ID=run-cursor-tier2
  export RALPH_CURRENT_TODO_ORDINAL=1
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.cursor.txt"
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  export RALPH_BG_TIER_SELECTED=invocation
  unset RALPH_MODE

  export RALPH_CURRENT_TODO_LINE=17
  export RALPH_CURRENT_TODO_ID=cursor-tier2-start-todo
  export RALPH_CURRENT_TODO_HASH=hash-cursor-tier2-start
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]

  local start_record="$TEST_TMPDIR/cursor-tier2-start.args"
  write_cursor_stub "$start_record"
  export PROMPT="cursor-tier2-start"
  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--resume" "$start_record"

  export RALPH_CURRENT_TODO_LINE=18
  export RALPH_CURRENT_TODO_ID=cursor-tier2-cont-todo
  export RALPH_CURRENT_TODO_HASH=hash-cursor-tier2-cont
  ralph_session_todo_create "exact-cursor-session" "exact" >/dev/null
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" = "exact-cursor-session" ]

  local cont_record="$TEST_TMPDIR/cursor-tier2-cont.args"
  write_cursor_stub "$cont_record"
  export PROMPT="cursor-tier2-continue"
  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  grep -Fxq -- "--resume" "$cont_record"
  grep -Fxq -- "exact-cursor-session" "$cont_record"

  # Cross-TODO / deliberate rework under fresh strategy starts without resume.
  export RALPH_CURRENT_TODO_ID=cursor-tier2-rework
  export RALPH_CURRENT_TODO_HASH=hash-cursor-tier2-rework
  export RALPH_CURRENT_TODO_LINE=19
  export RALPH_PLAN_CLI_RESUME=0
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
}
