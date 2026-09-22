#!/usr/bin/env bats
# Honest byte-cap footer for ralph_proxy_shell when delivered text is shorter
# than captured output (COMPACTION-CACHE-AUDIT b1). Covers compaction on/off
# and store available/unavailable.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  command -v jq >/dev/null || skip "jq required"
  WS="$(mktemp -d)"
  export RALPH_MCP_WORKSPACE="$WS"
  export RALPH_PLAN_KEY="plan-shell-cap-footer"
  export RALPH_MODE=ralph
  export RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1
  unset RALPH_PROXY_SHELL_COMPACT
  unset RALPH_MCP_PROXY_POLICY_INLINE
  unset RALPH_MCP_PROXY_POLICY_FILE
  unset RALPH_MCP_PROXY_POLICY
  unset RALPH_PLAN_WORKSPACE_ROOT
  seed_find_tree
}

teardown() {
  if [[ -n "${UNWRITABLE_ROOT:-}" && -d "$UNWRITABLE_ROOT" ]]; then
    chmod u+w "$UNWRITABLE_ROOT" 2>/dev/null || true
    rm -rf "$UNWRITABLE_ROOT"
  fi
  rm -rf "$WS"
}

seed_find_tree() {
  local i
  mkdir -p "$WS/bash-lib"
  for i in $(seq 1 150); do
    printf 'x\n' >"$WS/bash-lib/file-$(printf '%04d' "$i")-with-a-reasonably-long-name-for-byte-budget.sh"
  done
}

# Owned-tool call plus response-level shaping (same order as mcp-server.sh).
invoke_shell_shaped() {
  local args_json="$1"
  shift
  env \
    RALPH_MCP_WORKSPACE="$WS" \
    RALPH_PLAN_KEY="$RALPH_PLAN_KEY" \
    RALPH_MODE=ralph \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    "$@" \
    bash -c '
      source "$1"
      source "$2"
      source "$3"
      ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
      result_json="$(ralph_mcp_proxy_call_owned_tool "$4" "ralph_proxy_shell" "$6")"
      params_json="$(jq -nc --argjson arguments "$6" "{name:\"ralph_proxy_shell\",arguments:\$arguments}")"
      upstream_json="$(jq -nc --argjson result "$result_json" "{result:\$result}")"
      shaped_json="$(ralph_mcp_proxy_shape_response "tools/call" "$params_json" "$upstream_json")"
      jq -c ".result // {}" <<<"$shaped_json"
    ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$WS" "$UPSTREAM_SCRIPT" "$args_json"
}

response_text() {
  jq -r '.content[0].text // empty'
}

capture_byte_count() {
  # Match bash command-substitution length (trailing newlines stripped), which is
  # what ralph_proxy_shell stores as the captured stdout payload.
  local out
  out="$(cd "$WS" && find bash-lib -name "*.sh")"
  printf '%s\n' "${#out}"
}

assert_shell_cap_footer() {
  local text="$1"
  local total="$2"
  local expect_result_id="${3:-1}"
  local last_line shown_phrase remainder_phrase

  last_line="$(printf '%s\n' "$text" | tail -n1)"
  shown_phrase="of ${total} bytes shown"
  remainder_phrase='remainder not stored; re-run with a narrower command or redirect to a file]'
  if [[ "$last_line" != *"ralph_proxy_shell:"*"$shown_phrase"* ]]; then
    echo "assert_shell_cap_footer: unexpected last line: $last_line" >&2
    echo "assert_shell_cap_footer: expected total=$total" >&2
    return 1
  fi
  if [[ "$text" == *"...[truncated]"* ]]; then
    echo "assert_shell_cap_footer: found ...[truncated] marker" >&2
    return 1
  fi
  if [[ "$expect_result_id" == "1" ]]; then
    if [[ "$last_line" != *"full output: ralph_proxy_result_read resultId="* ]]; then
      echo "assert_shell_cap_footer: missing resultId footer: $last_line" >&2
      return 1
    fi
  else
    if [[ "$last_line" != *"$remainder_phrase" ]]; then
      echo "assert_shell_cap_footer: missing remainder footer: $last_line" >&2
      return 1
    fi
    if [[ "$text" == *"resultId="* ]]; then
      echo "assert_shell_cap_footer: unexpected resultId in text" >&2
      return 1
    fi
    if [[ "$text" == *"(lines omitted; full output in raw view)"* ]]; then
      echo "assert_shell_cap_footer: omit marker without resultId" >&2
      return 1
    fi
  fi
}

@test "shell-cap-footer: COMPACT=1 declined find gets visible footer (store available)" {
  local response text total
  total="$(capture_byte_count)"
  [[ "$total" -gt 8192 ]]

  response="$(invoke_shell_shaped "$(jq -nc '{command:"find bash-lib -name \"*.sh\""}')" RALPH_PROXY_SHELL_COMPACT=1)"
  printf '%s\n' "$response" | jq -e '.isError != true'
  text="$(printf '%s\n' "$response" | response_text)"
  assert_shell_cap_footer "$text" "$total" 1
  if [[ "$text" == *"(lines omitted; full output in raw view)"* ]]; then
    [[ "$text" == *"resultId="* ]]
  fi
}

@test "shell-cap-footer: default COMPACT off also footers and avoids double truncated marker" {
  local response text total
  total="$(capture_byte_count)"
  [[ "$total" -gt 8192 ]]

  response="$(invoke_shell_shaped "$(jq -nc '{command:"find bash-lib -name \"*.sh\""}')")"
  printf '%s\n' "$response" | jq -e '.isError != true'
  text="$(printf '%s\n' "$response" | response_text)"
  assert_shell_cap_footer "$text" "$total" 1
}

@test "shell-cap-footer: unwritable store root still footers without omit or resultId" {
  local response text total footer last_line
  total="$(capture_byte_count)"
  [[ "$total" -gt 8192 ]]

  # Plan fixture: RALPH_PLAN_WORKSPACE_ROOT points at an unwritable state root
  # so the result store cannot accept the write. Pre-create the log file the
  # proxy appends to, then revoke write on the root and tool-results (existing
  # child dirs stay writable if only the parent mode is cleared).
  UNWRITABLE_ROOT="$WS/unwritable-state-root"
  mkdir -p "$UNWRITABLE_ROOT/logs/$RALPH_PLAN_KEY" "$UNWRITABLE_ROOT/tool-results"
  : >"$UNWRITABLE_ROOT/logs/$RALPH_PLAN_KEY/mcp.log"
  chmod a-w "$UNWRITABLE_ROOT/tool-results" "$UNWRITABLE_ROOT"

  response="$(invoke_shell_shaped "$(jq -nc '{command:"find bash-lib -name \"*.sh\""}')" \
    RALPH_PROXY_SHELL_COMPACT=1 \
    RALPH_PLAN_WORKSPACE_ROOT="$UNWRITABLE_ROOT")"
  printf '%s\n' "$response" | jq -e '.isError != true'
  text="$(printf '%s\n' "$response" | response_text)"
  assert_shell_cap_footer "$text" "$total" 0
  last_line="$(printf '%s\n' "$text" | tail -n1)"
  footer="[ralph_proxy_shell: 8192 of ${total} bytes shown; remainder not stored; re-run with a narrower command or redirect to a file]"
  [[ "$last_line" == "$footer" ]]
}
