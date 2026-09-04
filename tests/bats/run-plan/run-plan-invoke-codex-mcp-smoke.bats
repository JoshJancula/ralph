#!/usr/bin/env bats
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TMPDIR="$TEST_TMPDIR"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export OUTPUT_LOG="$TEST_TMPDIR/output.log"
  export EXIT_CODE_FILE="$TEST_TMPDIR/exit-code"
  export SESSION_ID_FILE="$TEST_TMPDIR/session-id"
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.codex/ralph"
  : >"$OUTPUT_LOG"
  : >"$EXIT_CODE_FILE"

  BIN_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
  ORIGINAL_PATH="$PATH"
  PATH="$BIN_DIR:$PATH"

  export CODEX_STUB_RECORD="$TEST_TMPDIR/codex.record"
  export MCP_SERVER_RECORD="$TEST_TMPDIR/mcp-server.record"

  # Plan-runner resolver state must not override the workspace-local MCP stub.
  unset RALPH_RUNTIME_MCP_RESOLVE_PATH RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON

  cat <<'EOF' >"$WORKSPACE/.ralph/mcp-server.sh"
#!/usr/bin/env bash
printf 'SERVER_WORKSPACE:%s\n' "${RALPH_MCP_WORKSPACE:-}" >>"$MCP_SERVER_RECORD"
printf 'SERVER_ARGS:%s\n' "$*" >>"$MCP_SERVER_RECORD"
exit 0
EOF
  chmod +x "$WORKSPACE/.ralph/mcp-server.sh"
  export RALPH_MCP_PROXY_SERVER_SCRIPT="$WORKSPACE/.ralph/mcp-server.sh"

  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh"
}

teardown() {
  PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

write_codex_mcp_stub_script() {
  cat <<'EOF' >"$BIN_DIR/codex"
#!/usr/bin/env bash
if [[ "$1" == "mcp" && "$2" == "--help" ]]; then
  printf '%s\n' "Usage: codex mcp" "  add    Add MCP server" "  remove Remove MCP server"
  exit 0
fi

if [[ "$1" == "exec" && "$2" == "--help" ]]; then
  printf '%s\n' "Usage: codex exec [OPTIONS] [PROMPT]" "Options:" "  --config VALUE" "  --strict-config"
  exit 0
fi

  if [[ "$1" == "exec" ]]; then
    strict_config=0
    mcp_command=""
    mcp_workspace=""
    prev=""

  for arg in "$@"; do
    if [[ "$arg" == "--strict-config" ]]; then
      strict_config=1
      printf 'STRICT_CONFIG:1\n' >>"$CODEX_STUB_RECORD"
    fi

    if [[ "$prev" == "--config" ]]; then
      printf 'CONFIG:%s\n' "$arg" >>"$CODEX_STUB_RECORD"
      case "$arg" in
        mcp_servers.ralph.command=*)
          mcp_command="$(sed -n 's/^mcp_servers\.ralph\.command="\([^"]*\)"$/\1/p' <<<"$arg")"
          ;;
        mcp_servers.ralph.args=*)
          mcp_script="$(sed -n 's/^mcp_servers\.ralph\.args=\["\([^"]*\)".*$/\1/p' <<<"$arg")"
          ;;
        mcp_servers.ralph.env.RALPH_MCP_WORKSPACE=*)
          mcp_workspace="$(sed -n 's/^mcp_servers\.ralph\.env\.RALPH_MCP_WORKSPACE="\([^"]*\)"$/\1/p' <<<"$arg")"
          ;;
      esac
    fi
    if [[ "$prev" == "--add-dir" ]]; then
      printf 'ADD_DIR:%s\n' "$arg" >>"$CODEX_STUB_RECORD"
    fi
    prev="$arg"
  done

  if [[ "$strict_config" != "1" ]]; then
    echo "missing --strict-config in Codex MCP smoke stub" >&2
    exit 1
  fi

  if [[ -z "$mcp_command" || -z "${mcp_script:-}" || -z "$mcp_workspace" ]]; then
    echo "missing Ralph MCP config overrides in Codex smoke stub" >&2
    exit 1
  fi

  RALPH_MCP_WORKSPACE="$mcp_workspace" MCP_SERVER_RECORD="$MCP_SERVER_RECORD" \
    "$mcp_command" "$mcp_script"
  printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
  exit 0
fi

exit 0
EOF
  chmod +x "$BIN_DIR/codex"
}

# Argv-capturing Codex stub for session/resume matrix tests (no MCP strict-config requirements).
write_codex_session_argv_stub() {
  local record="${1:-$CODEX_STUB_RECORD}"
  : >"$record"
  cat <<EOF >"$BIN_DIR/codex"
#!/usr/bin/env bash
if [[ "\$1" == "mcp" && "\${2:-}" == "--help" ]]; then
  printf '%s\n' "Usage: codex mcp" "  add" "  remove"
  exit 0
fi
if [[ "\$1" == "exec" && "\${2:-}" == "--help" ]]; then
  printf '%s\n' "Usage: codex exec" "Options:" "  --config VALUE" "  --strict-config"
  exit 0
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/codex"
}

@test "Codex Ralph MCP smoke stub exercises the final strict-config exec path" {
  command -v jq >/dev/null || skip "jq required"

  write_codex_mcp_stub_script
  printf '%s\n' '[mcp_servers.ambient]' 'command = "printf"' >"$WORKSPACE/.codex/config.toml"
  ambient_before="$(shasum -a 256 "$WORKSPACE/.codex/config.toml" | awk '{print $1}')"
  export CODEX_PLAN_CLI="$BIN_DIR/codex"
  export RALPH_MODE="ralph"
  export PROMPT="codex smoke prompt"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$CODEX_STUB_RECORD" ]
  [ -s "$MCP_SERVER_RECORD" ]

  local stub_output server_output
  stub_output="$(cat "$CODEX_STUB_RECORD")"
  server_output="$(cat "$MCP_SERVER_RECORD")"

  [[ "$stub_output" == *"STRICT_CONFIG:1"* ]]
  [[ "$stub_output" == *"CONFIG:mcp_servers.ralph.enabled=true"* ]]
  [[ "$server_output" == *"SERVER_WORKSPACE:$WORKSPACE"* ]]
  [ "$(shasum -a 256 "$WORKSPACE/.codex/config.toml" | awk '{print $1}')" = "$ambient_before" ]
}

@test "Codex ralph profile without agent overrides layers ralph-only config and leaves ambient config.toml to native loading" {
  command -v jq >/dev/null || skip "jq required"

  write_codex_mcp_stub_script
  printf '%s\n' '[mcp_servers.ambient]' 'command = "printf"' >"$WORKSPACE/.codex/config.toml"

  # Simulate the runtime-config resolver having produced a merged
  # ambient+ralph catalog. With no agent-declared mcp_servers, the adapter
  # must NOT prefer this reconstructed catalog: Codex's own native loading of
  # config.toml is what is left to surface the ambient server, so only
  # Ralph's own server should ever appear as a --config override.
  local resolve_path="$TEST_TMPDIR/resolve.json"
  jq -n '{"mcp_servers":{"ambient":{"command":"printf","args":["ambient-arg"]}}}' >"$resolve_path"
  export RALPH_RUNTIME_MCP_RESOLVE_PATH="$resolve_path"
  unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON

  export CODEX_PLAN_CLI="$BIN_DIR/codex"
  export RALPH_MODE="ralph"
  export PROMPT="codex ambient-survives prompt"
  export RALPH_PLAN_KEY="codex-ambient-survives"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$CODEX_STUB_RECORD" ]

  local stub_output
  stub_output="$(cat "$CODEX_STUB_RECORD")"
  [[ "$stub_output" == *"CONFIG:mcp_servers.ralph.enabled=true"* ]]
  [[ "$stub_output" != *"mcp_servers.ambient"* ]]
}

@test "Codex ralph profile with agent overrides records the reconstructed-catalog limitation instead of silently dropping it" {
  command -v jq >/dev/null || skip "jq required"

  write_codex_mcp_stub_script
  printf '%s\n' '[mcp_servers.ambient]' 'command = "printf"' >"$WORKSPACE/.codex/config.toml"

  # An agent-declared mcp_servers override is the one case Codex has no
  # invocation-local mechanism to express short of a --config override, so
  # the adapter retains the reconstructed-catalog fallback here and must
  # record that choice via RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS
  # rather than silently reproducing every ambient server.
  local resolve_path="$TEST_TMPDIR/resolve-agent.json"
  jq -n '{"mcp_servers":{"ambient":{"command":"printf","args":["ambient-arg"]},"tools":{"command":"printf","args":["tools-arg"]},"ralph":{"command":"true","args":["dummy"],"env":{"RALPH_MCP_WORKSPACE":"'"$WORKSPACE"'"}}}}' >"$resolve_path"
  export RALPH_RUNTIME_MCP_RESOLVE_PATH="$resolve_path"
  export RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON='[{"name":"tools"}]'

  export CODEX_PLAN_CLI="$BIN_DIR/codex"
  export RALPH_MODE="ralph"
  export PROMPT="codex agent-override prompt"
  export RALPH_PLAN_KEY="codex-agent-override"

  ralph_run_plan_invoke_codex
  [ -s "$CODEX_STUB_RECORD" ]

  local stub_output
  stub_output="$(cat "$CODEX_STUB_RECORD")"
  [[ "$stub_output" == *"CONFIG:mcp_servers.tools.command="* ]]
  [[ "$stub_output" == *"CONFIG:mcp_servers.ambient.command="* ]]
  [ "$RUNTIME_OVERLAY_SUMMARY_MCP_OVERRIDE_DECISIONS" = "profile_ralph_agent_overrides_reconstructed_catalog" ]
}

@test "Codex raw profile with no agent overrides never touches MCP config, preserving existing isolation" {
  command -v jq >/dev/null || skip "jq required"

  write_codex_mcp_stub_script
  printf '%s\n' '[mcp_servers.ambient]' 'command = "printf"' >"$WORKSPACE/.codex/config.toml"
  local ambient_before
  ambient_before="$(shasum -a 256 "$WORKSPACE/.codex/config.toml" | awk '{print $1}')"

  unset RALPH_RUNTIME_MCP_RESOLVE_PATH RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON
  export CODEX_PLAN_CLI="$BIN_DIR/codex"
  export RALPH_MODE="no"
  unset RALPH_AGENT_TOOL_ACCESS
  export PROMPT="codex raw isolation prompt"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]

  # No overlay was required at all, so the stub must never see any
  # --config/--strict-config MCP override, and the ambient config.toml is
  # left completely untouched.
  local stub_output=""
  [ -f "$CODEX_STUB_RECORD" ] && stub_output="$(cat "$CODEX_STUB_RECORD")"
  [[ "$stub_output" != *"CONFIG:"* ]]
  [[ "$stub_output" != *"STRICT_CONFIG:"* ]]
  [ "$(shasum -a 256 "$WORKSPACE/.codex/config.toml" | awk '{print $1}')" = "$ambient_before" ]
}

@test "Codex invoke helper appends session-local extra add-dirs" {
  command -v jq >/dev/null || skip "jq required"

  write_codex_mcp_stub_script
  export CODEX_PLAN_CLI="$BIN_DIR/codex"
  export RALPH_MODE="ralph"
  export PROMPT="codex add-dir prompt"
  export CODEX_PLAN_EXTRA_ADD_DIRS="/tmp"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$CODEX_STUB_RECORD" ]

  local stub_output
  stub_output="$(cat "$CODEX_STUB_RECORD")"
  [[ "$stub_output" == *"ADD_DIR:/tmp"* ]]
}

@test "codex session continuation tier probe selects hook matching evaluate when hooks proven" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-tier-probe.sh"

  _run_plan_invoke_codex_hooks_config_supported() { return 0; }

  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=auto
  export RUNTIME=codex
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  mkdir -p "$WORKSPACE/.codex"

  local probe expected
  probe="$(ralph_bg_tier_probe_evaluate codex)"
  expected="$(jq -r '.tier' <<<"$probe")"
  [ "$expected" = "hook" ]
  [[ "$(jq -r '.reason' <<<"$probe")" == *"codex-stop-hook"* ]]

  ralph_bg_tier_probe_apply codex >/dev/null
  [ "${RALPH_BG_TIER_SELECTED:-}" = "$expected" ]
  [[ "${RALPH_BG_TIER_REASON:-}" == *"codex-stop-hook"* ]]
}

@test "codex tier1 continuation holds session and emits no resume argv" {
  write_codex_session_argv_stub "$CODEX_STUB_RECORD"
  export CODEX_PLAN_CLI="$BIN_DIR/codex"
  export SESSION_ID_FILE="$TEST_TMPDIR/session-id.codex.txt"
  printf '%s\n' "held-codex-session" >"$SESSION_ID_FILE"
  export RALPH_BG_TIER_SELECTED=hook
  export RALPH_USAGE_SESSION_CONTINUITY=held
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  unset RALPH_MODE
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export PROMPT="codex-tier1-held"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$CODEX_STUB_RECORD" ]
  ! grep -Fxq -- "resume" "$CODEX_STUB_RECORD"
  ! grep -Fxq -- "held-codex-session" "$CODEX_STUB_RECORD"
}

@test "codex tier2 continuation resumes exact session id while fresh todo-start omits resume" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
  ralph_run_plan_log() { :; }

  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  mkdir -p "$RALPH_SESSION_DIR"
  export RUNTIME=codex
  export RALPH_PROCESS_RUN_ID=run-codex-tier2
  export RALPH_CURRENT_TODO_ORDINAL=1
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.codex.txt"
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  export RALPH_BG_TIER_SELECTED=invocation
  unset RALPH_MODE
  export CODEX_PLAN_CLI="$BIN_DIR/codex"

  export RALPH_CURRENT_TODO_LINE=17
  export RALPH_CURRENT_TODO_ID=codex-tier2-start-todo
  export RALPH_CURRENT_TODO_HASH=hash-codex-tier2-start
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]

  write_codex_session_argv_stub "$CODEX_STUB_RECORD"
  export PROMPT="codex-tier2-start"
  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "resume" "$CODEX_STUB_RECORD"

  export RALPH_CURRENT_TODO_LINE=18
  export RALPH_CURRENT_TODO_ID=codex-tier2-cont-todo
  export RALPH_CURRENT_TODO_HASH=hash-codex-tier2-cont
  ralph_session_todo_create "exact-codex-session" "exact" >/dev/null
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  export RALPH_PLAN_CLI_RESUME=0
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" = "exact-codex-session" ]

  : >"$CODEX_STUB_RECORD"
  export PROMPT="codex-tier2-continue"
  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  grep -Fxq -- "resume" "$CODEX_STUB_RECORD"
  grep -Fxq -- "exact-codex-session" "$CODEX_STUB_RECORD"

  export RALPH_CURRENT_TODO_ID=codex-tier2-rework
  export RALPH_CURRENT_TODO_HASH=hash-codex-tier2-rework
  export RALPH_CURRENT_TODO_LINE=19
  export RALPH_PLAN_CLI_RESUME=0
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
}

@test "Codex with ambient MCP catalog and Ralph mode off injects no ralph MCP server" {
  command -v jq >/dev/null || skip "jq required"

  # Regression: the mere presence of a resolver catalog (i.e. the operator has
  # ambient Codex MCP servers configured) used to force an MCP overlay, which
  # fell through to the Ralph-only generator and always emitted an
  # mcp_servers.ralph entry. That server refuses to start under RALPH_MODE=no,
  # so Codex died at session creation with "required MCP servers failed to
  # initialize" before the agent ran a single turn. With Ralph mode off and no
  # agent overrides, Codex must be invoked with no ralph MCP config at all.
  write_codex_session_argv_stub "$CODEX_STUB_RECORD"
  printf '%s\n' '[mcp_servers.ambient]' 'command = "printf"' >"$WORKSPACE/.codex/config.toml"

  local resolve_path="$TEST_TMPDIR/resolve.json"
  jq -n '{"mcp_servers":{"ambient":{"command":"printf","args":["ambient-arg"]}}}' >"$resolve_path"
  export RALPH_RUNTIME_MCP_RESOLVE_PATH="$resolve_path"
  unset RALPH_RUNTIME_MCP_AGENT_ENTRIES_JSON

  export CODEX_PLAN_CLI="$BIN_DIR/codex"
  export RALPH_MODE="no"
  unset RALPH_AGENT_TOOL_ACCESS
  export PROMPT="codex ralph-mode-off prompt"
  export RALPH_PLAN_KEY="codex-ralph-mode-off"

  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  [ -s "$CODEX_STUB_RECORD" ]

  local stub_output
  stub_output="$(cat "$CODEX_STUB_RECORD")"
  [[ "$stub_output" != *"mcp_servers.ralph"* ]]
  [[ "$stub_output" != *"mcp_servers.ambient"* ]]
  [ ! -s "$MCP_SERVER_RECORD" ]
}
