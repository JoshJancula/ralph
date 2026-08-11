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
