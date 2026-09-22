#!/usr/bin/env bats
# Tests for bundle/.ralph/jev-mcp-server.sh (standalone Jev MCP server).
#
# Uses the multi-message slurp idiom from tests/bats/mcp/mcp-setup.bats:
# pipe initialize / tools/call / tools/list / exit into the server in one
# payload, then assert with jq -s -e over the collected JSON-RPC responses.
#
# Isolation: per-test RALPH_JEV_STATE_DIR under mktemp. Fixture transport never
# reaches the network. TYPESAFE_API_KEY is a disposable test token only.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

SETUP_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
JEV_SERVER="$REPO_ROOT/bundle/.ralph/jev-mcp-server.sh"
MCP_SERVER="$REPO_ROOT/bundle/.ralph/mcp-server.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/jev"
REGISTRY="$REPO_ROOT/bundle/.ralph/jev/questions.registry.json"

JEV_MCP_TEST_KEY="jev-mcp-bats-secret-key-NEVER-EMIT"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

jev_mcp_base_env() {
  # Common env for a Jev MCP server process. Caller may append overrides.
  printf '%s' '
    export RALPH_DIR="'"$REPO_ROOT"'/bundle/.ralph"
    export RALPH_JEV_REGISTRY="'"$REGISTRY"'"
    export RALPH_JEV_STATE_DIR="'"$JEV_MCP_STATE"'"
    export JEV_FIXTURE_DIR="'"$FIXTURE_DIR"'"
    export RALPH_WAIT_SCALE=0
    unset RALPH_MCP_WORKSPACE
  '
}

setup() {
  command -v jq >/dev/null || skip "jq required"
  [ -f "$JEV_SERVER" ] || skip "jev-mcp-server.sh missing"
  [ -f "$SETUP_FILE" ] || skip "mcp-setup.sh missing"

  TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/ralph-jev-mcp.XXXXXX")"
  JEV_MCP_STATE="$TEST_TMPDIR/jev-state"
  mkdir -p "$JEV_MCP_STATE"
  export TEST_TMPDIR JEV_MCP_STATE
}

teardown() {
  if [[ -n "${TEST_TMPDIR:-}" && -e "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

# ---------------------------------------------------------------------------
# 1. tools/list has no nextCursor
# ---------------------------------------------------------------------------

@test "jev tools/list result has no nextCursor key" {
  local payload
  payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"exit"}'

  run bash -c '
    '"$(jev_mcp_base_env)"'
    bash "'"$JEV_SERVER"'" 2>/dev/null <<< "$1"
  ' _ "$payload"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -s -e '.[1].result | type == "object"'
  printf '%s\n' "$output" | jq -s -e '.[1].result | has("nextCursor") | not'
  printf '%s\n' "$output" | jq -s -e '.[1].result | has("tools")'
  printf '%s\n' "$output" | jq -s -e '.[2].result.status == "exiting"'
}

# ---------------------------------------------------------------------------
# 2. Tool names sorted and identical across two plan keys
# ---------------------------------------------------------------------------

@test "jev tools/list names are sorted and identical across plan keys" {
  local payload names_a names_b
  payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"exit"}'

  names_a="$(
    bash -c '
      '"$(jev_mcp_base_env)"'
      export RALPH_PLAN_KEY="plan-key-alpha"
      bash "'"$JEV_SERVER"'" 2>/dev/null <<< "$1"
    ' _ "$payload" | jq -s -c '[.[1].result.tools[].name]'
  )"
  names_b="$(
    bash -c '
      '"$(jev_mcp_base_env)"'
      export RALPH_PLAN_KEY="plan-key-beta"
      bash "'"$JEV_SERVER"'" 2>/dev/null <<< "$1"
    ' _ "$payload" | jq -s -c '[.[1].result.tools[].name]'
  )"

  [ -n "$names_a" ]
  [ -n "$names_b" ]
  [ "$names_a" = "$names_b" ]
  printf '%s\n' "$names_a" | jq -e '
    type == "array"
    and length >= 4
    and . == (sort)
    and (index("jev_ask") != null)
    and (index("jev_classify_failure") != null)
    and (index("jev_classify_request") != null)
    and (index("jev_rank_relevance") != null)
  '
}

# ---------------------------------------------------------------------------
# 3. Curated tools soft-unavailable when no key
# ---------------------------------------------------------------------------

@test "jev curated tools return available false isError false when no key set" {
  local payload
  payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"jev_classify_request","arguments":{"state":"route me","options":["implement","investigate"]}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"jev_classify_failure","arguments":{"state":"stage failed"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"jev_rank_relevance","arguments":{"state":"L000 noise","options":["L000"]}}}
{"jsonrpc":"2.0","id":5,"method":"exit"}'

  run bash -c '
    '"$(jev_mcp_base_env)"'
    export RALPH_JEV=1
    unset TYPESAFE_API_KEY
    export RALPH_JEV_ENV_FILE=0
    bash "'"$JEV_SERVER"'" 2>/dev/null <<< "$1"
  ' _ "$payload"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -s -e '
    .[1].result.structuredContent.available == false
    and .[1].result.isError == false
    and (.[1] | has("error") | not)
  '
  printf '%s\n' "$output" | jq -s -e '
    .[2].result.structuredContent.available == false
    and .[2].result.isError == false
  '
  printf '%s\n' "$output" | jq -s -e '
    .[3].result.structuredContent.available == false
    and .[3].result.isError == false
  '
}

# ---------------------------------------------------------------------------
# 4. Fixture-backed curated call
# ---------------------------------------------------------------------------

@test "jev fixture-backed classify_request returns answer decision questionSetId registryVersion" {
  local payload
  payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"jev_classify_request","arguments":{"state":"implement the router target","options":["implement","investigate"]}}}
{"jsonrpc":"2.0","id":3,"method":"exit"}'

  run bash -c '
    '"$(jev_mcp_base_env)"'
    export RALPH_JEV=1
    export TYPESAFE_API_KEY="'"$JEV_MCP_TEST_KEY"'"
    export JEV_TRANSPORT=fixture
    bash "'"$JEV_SERVER"'" 2>/dev/null <<< "$1"
  ' _ "$payload"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -s -e '
    .[1].result.isError == false
    and .[1].result.structuredContent.questionSetId == "graph.router-confidence"
    and .[1].result.structuredContent.registryVersion == "1"
    and .[1].result.structuredContent.answer.target.choice == "implement"
    and .[1].result.structuredContent.decision.decision == "act"
    and .[1].result.structuredContent.decision.chosen == "implement"
  '
}

# ---------------------------------------------------------------------------
# 5. Invalid params -> -32602
# ---------------------------------------------------------------------------

@test "jev curated tool invalid params return -32602" {
  local payload
  payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"jev_classify_request","arguments":{"state":"ok","options":["implement"],"extra":"nope"}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"jev_classify_request","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"exit"}'

  run bash -c '
    '"$(jev_mcp_base_env)"'
    export RALPH_JEV=1
    export TYPESAFE_API_KEY="'"$JEV_MCP_TEST_KEY"'"
    export JEV_TRANSPORT=fixture
    bash "'"$JEV_SERVER"'" 2>/dev/null <<< "$1"
  ' _ "$payload"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -s -e '.[1].error.code == -32602'
  printf '%s\n' "$output" | jq -s -e '.[2].error.code == -32602'
}

# ---------------------------------------------------------------------------
# 6. API key never appears on stdout or stderr
# ---------------------------------------------------------------------------

@test "jev MCP server never emits the API key on stdout or stderr" {
  local payload stdout_file stderr_file
  payload='{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"jev_classify_request","arguments":{"state":"route with key present","options":["implement","investigate"]}}}
{"jsonrpc":"2.0","id":4,"method":"exit"}'
  stdout_file="$TEST_TMPDIR/jev-stdout.jsonl"
  stderr_file="$TEST_TMPDIR/jev-stderr.log"

  run bash -c '
    '"$(jev_mcp_base_env)"'
    export RALPH_JEV=1
    export TYPESAFE_API_KEY="'"$JEV_MCP_TEST_KEY"'"
    export JEV_TRANSPORT=fixture
    bash "'"$JEV_SERVER"'" >"$2" 2>"$3" <<< "$1"
  ' _ "$payload" "$stdout_file" "$stderr_file"
  [ "$status" -eq 0 ]
  [ -s "$stdout_file" ]
  jq -s -e '.[2].result.structuredContent.questionSetId == "graph.router-confidence"' <"$stdout_file"
  ! grep -F "$JEV_MCP_TEST_KEY" "$stdout_file"
  ! grep -F "$JEV_MCP_TEST_KEY" "$stderr_file"
}

# ---------------------------------------------------------------------------
# 7. RALPH_JEV_MCP unset -> not registered in generated configs
# ---------------------------------------------------------------------------

@test "ralph_mcp_proxy_generate_config omits ralph-jev when RALPH_JEV_MCP unset" {
  local ws runtime out
  ws="$TEST_TMPDIR/ws_jev_mcp_unset"
  mkdir -p "$ws/.ralph"
  cp "$MCP_SERVER" "$ws/.ralph/mcp-server.sh"
  printf '#!/usr/bin/env bash\n' > "$ws/.ralph/jev-mcp-server.sh"

  for runtime in claude codex cursor opencode antigravity; do
    out="$ws/ephemeral-$runtime.json"
    # RALPH_JEV=1 alone is insufficient; Track 2 requires RALPH_JEV_MCP=1.
    # Put -u before assignments (macOS/BSD env rejects `VAR=1 -u NAME` mid-list).
    run env -u RALPH_JEV_MCP RALPH_JEV=1 bash -c \
      'source "$1" && RALPH_DIR="$3/.ralph" && ralph_mcp_proxy_generate_config "$4" "$2" "$3"' \
      _ "$SETUP_FILE" "$out" "$ws" "$runtime"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    case "$runtime" in
      opencode)
        jq -e '.mcp | has("ralph") and (has("ralph-jev") | not)' "$out"
        ;;
      *)
        jq -e '.mcpServers | has("ralph") and (has("ralph-jev") | not)' "$out"
        ;;
    esac
  done
}
