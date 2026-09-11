#!/usr/bin/env bats
# shellcheck shell=bash

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

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
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.claude"
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
  unset CLAUDE_PLAN_MCP_CONFIG_PATH
  unset CLAUDE_PLAN_MCP_CONFIG_OWNED
  unset CLAUDE_PLAN_ALLOWED_TOOLS
  unset CLAUDE_PLAN_MINIMAL_DISABLE_MCP
  unset CLAUDE_PLAN_BARE
  unset CLAUDE_PLAN_MINIMAL
  unset RALPH_MODE
  unset RALPH_AGENT_TOOL_ACCESS
  unset RALPH_MCP_PREFLIGHT_PASSED
  unset PREBUILT_AGENT
}

teardown() {
  PATH="$ORIGINAL_PATH"
  rm -rf "$TEST_TMPDIR"
}

write_claude_stub() {
  local record="$1"
  local stdin_cap="${2:-}"
  if [[ -n "$stdin_cap" ]]; then
    cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--mcp-config" && -f "\$arg" ]]; then
    printf 'MCP_CONFIG:%s\n' "\$(cat "\$arg")" >>"$record"
  fi
  prev="\$arg"
done
printf '%s\n' "\$@" >>"$record"
cat >"$stdin_cap"
EOF
  else
    cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--mcp-config" && -f "\$arg" ]]; then
    printf 'MCP_CONFIG:%s\n' "\$(cat "\$arg")" >>"$record"
  fi
  prev="\$arg"
done
printf '%s\n' "\$@" >>"$record"
EOF
  fi
  chmod +x "$BIN_DIR/claude"
}

write_claude_stub_mcp_capture() {
  local record="$1"
  local mcp_out="$2"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--mcp-config" && -f "\$arg" ]]; then
    cp "\$arg" "$mcp_out"
  fi
  prev="\$arg"
done
printf '%s\n' "\$@" >>"$record"
EOF
  chmod +x "$BIN_DIR/claude"
}

@test "claude minimal mode preserves user, project, and local setting sources" {
  local -a args=()

  run_plan_invoke_claude_apply_minimal_flags args

  [ "${args[4]}" = "--setting-sources" ]
  [ "${args[5]}" = "user,project,local" ]
}

@test "claude no mode keeps strict empty lockdown even with ambient MCP present" {
  # Contract change: raw (RALPH_MODE=no, no explicit CLAUDE_PLAN_MINIMAL_DISABLE_MCP
  # override) always locks down with an empty catalog. It no longer reuses the
  # merged catalog that ralph_runtime_config_mcp_resolve may have built (that
  # rebuilt catalog is now reserved for the Ralph profile's ambient-preserving
  # native-discovery path; raw never consumes it).
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-no-ambient.args"
  write_claude_stub "$record"

  printf '%s\n' '{"mcpServers":{"ambient":{"command":"ambient-cmd"}}}' >"$WORKSPACE/.mcp.json"

  run bash -c '
    set -euo pipefail
    export PATH="$5/bin:$PATH"
    source "$1"
    source "$2"
    source "$6"
    export RALPH_MODE=no
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve claude "$3" "" "$3"
    export PROMPT=claude-no-ambient-prompt
    export OUTPUT_LOG="$4/output.log"
    export EXIT_CODE_FILE="$4/exit-code"
    ralph_run_plan_invoke_claude
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" "$WORKSPACE" "$TEST_TMPDIR" "$TEST_TMPDIR" "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  [ "$status" -eq 0 ]
  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *"--mcp-config"* ]]
  [[ "$captured" == *"user,project,local"* ]]
  [[ "$captured" == *'{"mcpServers":{}}'* ]]
  ! grep -q '"ambient"' "$record"
  ! grep -q 'ambient-cmd' "$record"
}

@test "claude ralph mode layers ralph-only MCP config without rebuilding ambient servers" {
  # Contract change: a Ralph profile no longer rebuilds a merged
  # ambient+ralph catalog. It passes --mcp-config with ONLY the ralph server
  # and omits --strict-mcp-config, so native discovery (left on) is what
  # would surface the ambient "ambient" server in a real claude CLI; the
  # fake adapter here only proves the composed argv, not native discovery.
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-ralph.args"
  write_claude_stub "$record"

  printf '%s\n' '{"mcpServers":{"ambient":{"command":"ambient-cmd"}}}' >"$WORKSPACE/.mcp.json"

  PROMPT="claude-ralph-prompt"
  export PROMPT
  export RALPH_MODE=ralph
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS
  RALPH_MCP_PREFLIGHT_PASSED=1
  export RALPH_MCP_PREFLIGHT_PASSED

  run bash -c '
    set -euo pipefail
    export PATH="$5/bin:$PATH"
    source "$1"
    source "$2"
    source "$6"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve claude "$3" "" "$3"
    export PROMPT=claude-ralph-prompt
    export OUTPUT_LOG="$4/output.log"
    export EXIT_CODE_FILE="$4/exit-code"
    export CLAUDE_PLAN_ALLOWED_TOOLS=Bash,Read,Edit
    export RALPH_MCP_PREFLIGHT_PASSED=1
    ralph_run_plan_invoke_claude
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" "$WORKSPACE" "$TEST_TMPDIR" "$TEST_TMPDIR" "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  [ "$status" -eq 0 ]
  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--strict-mcp-config"* ]]
  grep -q '"ralph"' "$record"
  ! grep -q '"ambient"' "$record"
  [[ "$captured" == *"mcp__ralph__ralph_proxy_read"* ]]
}

@test "claude hybrid mode layers ralph-only MCP config without rebuilding ambient servers" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-hybrid.args"
  write_claude_stub "$record"

  printf '%s\n' '{"mcpServers":{"shared":{"command":"shared-cmd"}}}' >"$ISOLATED_HOME/.claude.json"

  PROMPT="claude-hybrid-prompt"
  export PROMPT
  export RALPH_MODE=hybrid
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run bash -c '
    set -euo pipefail
    export PATH="$6/bin:$PATH"
    source "$1"
    source "$2"
    source "$7"
    export RALPH_MODE=hybrid
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    export HOME="$4"
    export RALPH_RUNTIME_MCP_HOME="$4"
    ralph_runtime_config_mcp_resolve claude "$3" "" "$3"
    export PROMPT=claude-hybrid-prompt
    export OUTPUT_LOG="$5/output.log"
    export EXIT_CODE_FILE="$5/exit-code"
    export CLAUDE_PLAN_ALLOWED_TOOLS=Bash,Read,Edit
    ralph_run_plan_invoke_claude
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" "$WORKSPACE" "$ISOLATED_HOME" "$TEST_TMPDIR" "$TEST_TMPDIR" "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  [ "$status" -eq 0 ]
  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--strict-mcp-config"* ]]
  grep -q '"ralph"' "$record"
  ! grep -q '"shared"' "$record"
  [[ "$captured" == *"mcp__ralph__ralph_proxy_batch"* ]]
}

# Profile-declared MCP entries were removed: MCP composition is native
# ambient configuration plus Ralph's protected server. See
# tests/bats/runtime-config/runtime-config-mcp.bats for the replacement
# coverage, including the rejection of the removed agent-entries env.

@test "claude ralph profile unset override layers exactly one ralph MCP server" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-ralph-unset.args"
  local mcp_out="$TEST_TMPDIR/claude-ralph-unset.mcp.json"
  write_claude_stub_mcp_capture "$record" "$mcp_out"

  export PROMPT="claude-ralph-unset-prompt"
  export RALPH_MODE=ralph
  export CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--mcp-config"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [ -f "$mcp_out" ]
  [ "$(jq -r '.mcpServers | keys | length' "$mcp_out")" -eq 1 ]
  [ "$(jq -r '.mcpServers | keys[0]' "$mcp_out")" = "ralph" ]
}

@test "claude raw profile unset override locks down with an empty catalog" {
  local record="$TEST_TMPDIR/claude-raw-unset.args"
  local stdin_cap="$TEST_TMPDIR/claude-raw-unset.stdin"
  write_claude_stub "$record" "$stdin_cap"

  export PROMPT="claude-raw-unset-prompt"
  export RALPH_MODE=no

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *'{"mcpServers":{}}'* ]]
}

@test "claude ralph profile explicit lockdown override forces strict empty catalog" {
  local record="$TEST_TMPDIR/claude-ralph-explicit-lock.args"
  local stdin_cap="$TEST_TMPDIR/claude-ralph-explicit-lock.stdin"
  write_claude_stub "$record" "$stdin_cap"

  export PROMPT="claude-ralph-explicit-lock-prompt"
  export RALPH_MODE=ralph
  export CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP=1

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *'{"mcpServers":{}}'* ]]
  ! grep -q 'MCP_CONFIG:' "$record"
}

@test "claude raw profile explicit lockdown override forces strict empty catalog" {
  local record="$TEST_TMPDIR/claude-raw-explicit-lock.args"
  local stdin_cap="$TEST_TMPDIR/claude-raw-explicit-lock.stdin"
  write_claude_stub "$record" "$stdin_cap"

  export PROMPT="claude-raw-explicit-lock-prompt"
  export RALPH_MODE=no
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP=1

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--strict-mcp-config"* ]]
  [[ "$captured" == *'{"mcpServers":{}}'* ]]
}

@test "claude ralph profile explicit permit override layers ralph-only config" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-ralph-explicit-permit.args"
  local mcp_out="$TEST_TMPDIR/claude-ralph-explicit-permit.mcp.json"
  write_claude_stub_mcp_capture "$record" "$mcp_out"

  export PROMPT="claude-ralph-explicit-permit-prompt"
  export RALPH_MODE=ralph
  export CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [[ "$captured" == *"--mcp-config"* ]]
  [ -f "$mcp_out" ]
  [ "$(jq -r '.mcpServers | keys | length' "$mcp_out")" -eq 1 ]
  [ "$(jq -r '.mcpServers | keys[0]' "$mcp_out")" = "ralph" ]
}

@test "claude raw profile explicit permit override leaves native discovery alone" {
  local record="$TEST_TMPDIR/claude-raw-explicit-permit.args"
  local stdin_cap="$TEST_TMPDIR/claude-raw-explicit-permit.stdin"
  write_claude_stub "$record" "$stdin_cap"

  export PROMPT="claude-raw-explicit-permit-prompt"
  export RALPH_MODE=no
  export CLAUDE_PLAN_MINIMAL_DISABLE_MCP=0

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" != *"--strict-mcp-config"* ]]
  [[ "$captured" != *"--mcp-config"* ]]
  ! grep -q 'MCP_CONFIG:' "$record"
}

@test "claude invoke cleans up owned temp MCP config but not runtime resolve artifact" {
  [ -x "$(command -v jq)" ] || skip "jq required"

  local record="$TEST_TMPDIR/claude-cleanup.args"
  local ambient="$WORKSPACE/.mcp.json"
  local ambient_before
  printf '%s\n' '{"mcpServers":{"ambient":{"command":"printf"}}}' >"$ambient"
  ambient_before="$(shasum -a 256 "$ambient" | awk '{print $1}')"
  write_claude_stub "$record"

  PROMPT="claude-cleanup-prompt"
  export PROMPT
  export RALPH_MODE=ralph
  CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Edit"
  export CLAUDE_PLAN_ALLOWED_TOOLS

  run bash -c '
    set -euo pipefail
    export PATH="$5/bin:$PATH"
    source "$1"
    source "$2"
    source "$6"
    export RALPH_MODE=ralph
    export WORKSPACE="$3"
    export RALPH_PROJECT_ROOT="$3"
    ralph_runtime_config_mcp_resolve claude "$3" "" "$3"
    resolve_path="$RALPH_RUNTIME_MCP_RESOLVE_PATH"
    export PROMPT=claude-cleanup-prompt
    export OUTPUT_LOG="$4/output.log"
    export EXIT_CODE_FILE="$4/exit-code"
    export CLAUDE_PLAN_ALLOWED_TOOLS=Bash,Read,Edit
    ralph_run_plan_invoke_claude
    test -f "$resolve_path"
    [ "$(find "$4" -name "ralph-claude-mcp-*" | wc -l | tr -d " ")" -eq 0 ]
    ralph_runtime_config_mcp_cleanup
    test ! -f "$resolve_path"
  ' _ "$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-setup.sh" "$REPO_ROOT/bundle/.ralph/bash-lib/runtime-config/runtime-config-mcp.sh" "$WORKSPACE" "$TEST_TMPDIR" "$TEST_TMPDIR" "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"

  [ "$status" -eq 0 ]
  [ "$(shasum -a 256 "$ambient" | awk '{print $1}')" = "$ambient_before" ]
}

@test "claude bare mode omits setting sources and MCP overlay flags" {
  local record="$TEST_TMPDIR/claude-bare.args"
  local stdin_cap="$TEST_TMPDIR/claude-bare.stdin"
  write_claude_stub "$record" "$stdin_cap"

  PROMPT="claude-bare-prompt"
  export PROMPT
  CLAUDE_PLAN_BARE=1
  export CLAUDE_PLAN_BARE
  export RALPH_MODE=native

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  local captured
  captured="$(cat "$record")"
  [[ "$captured" == *"--bare"* ]]
  [[ "$captured" != *"--setting-sources"* ]]
  [[ "$captured" != *"--strict-mcp-config"* ]]
}

WARM_LIB="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/bundle/.ralph/bash-lib/run-plan/run-plan-claude-speculative-cache-warm.sh"
TEARDOWN_LIB="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/bundle/.ralph/bash-lib/ralph-process-teardown.sh"

write_claude_unsupported_warm_stub() {
  cat <<'EOF' >"$BIN_DIR/claude"
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
  echo 'Claude Code 2.1.186-style CLI (no cache_control)'
  echo '  --system-prompt <text>'
  echo '  --output-format stream-json'
  exit 0
fi
printf '%s\n' "$@" >>"${CLAUDE_WARM_RECORD:-/dev/null}"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"
}

write_claude_supported_warm_stub() {
  local record="$1"
  cat <<EOF >"$BIN_DIR/claude"
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then
  echo '  --cache-control <policy>  Prompt cache breakpoint control'
  echo '  --max-output-tokens <n>  Cap model output tokens'
  echo '  --system-prompt <text>'
  echo '  --output-format stream-json'
  exit 0
fi
if [[ " \$* " == *" --cache-control "* ]]; then
  printf '%s\n' "\$@" >>"$record"
  printf '{"type":"result","usage":{"input_tokens":1000,"output_tokens":1,"cache_creation_input_tokens":900,"cache_read_input_tokens":0}}\n'
  exit 0
fi
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/claude"
}

@test "claude cache warm capability probe reports unsupported without cache-control" {
  # shellcheck disable=SC1090
  source "$WARM_LIB"
  write_claude_unsupported_warm_stub

  run run_plan_invoke_claude_cache_warm_capability_probe claude
  [ "$status" -eq 1 ]
  [[ "$output" == unsupported* ]]
}

@test "claude cache warm capability probe reports supported on fake adapter" {
  # shellcheck disable=SC1090
  source "$WARM_LIB"
  local record="$TEST_TMPDIR/claude-warm-cap.args"
  write_claude_supported_warm_stub "$record"

  run run_plan_invoke_claude_cache_warm_capability_probe claude
  [ "$status" -eq 0 ]
  [ "$output" = "supported" ]
}

@test "unsupported claude CLI performs no speculative warm request" {
  # shellcheck disable=SC1090
  source "$WARM_LIB"
  # shellcheck disable=SC1090
  source "$TEARDOWN_LIB"
  local record="$TEST_TMPDIR/claude-warm-none.args"
  export CLAUDE_WARM_RECORD="$record"
  write_claude_unsupported_warm_stub

  export RUNTIME=claude
  export RALPH_MODE=ralph
  export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM=1
  export PROMPT_STATIC="STABLE-PREFIX block"
  export RALPH_PLAN_KEY="warm-none"
  export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"

  ralph_claude_speculative_cache_warm_maybe_start 20

  [ "${RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED:-0}" = "0" ]
  [ ! -f "$record" ]
}

@test "supported fake claude warm is bounded and records separate usage when enabled" {
  [ -x "$(command -v python3)" ] || skip "python3 required"

  local record usage_file funcs core_lib
  record="$TEST_TMPDIR/claude-warm-enabled.args"
  usage_file="$TEST_TMPDIR/speculative-usage.json"
  funcs="$TEST_TMPDIR/funcs.sh"
  core_lib="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"

  run bash -c '
    set -euo pipefail
    export PATH="$1/bin:$PATH"
    source "$2"
    source "$3"
    sed -n "/^_ralph_append_invocation_usage_history() {/,/^}$/p" "$4" >"$5"
    SCRIPT_DIR="$(dirname "$(dirname "$(dirname "$4")")")"
    source "$5"

    cat <<EOF >"$1/bin/claude"
#!/usr/bin/env bash
if [[ "\${1:-}" == "--help" ]]; then
  echo "  --cache-control <policy>  Prompt cache breakpoint control"
  echo "  --max-output-tokens <n>  Cap model output tokens"
  echo "  --system-prompt <text>"
  echo "  --output-format stream-json"
  exit 0
fi
if [[ " \$* " == *" --cache-control "* ]]; then
  printf "%s\n" "\$@" >>"$6"
  printf "{\"type\":\"result\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":1,\"cache_creation_input_tokens\":900,\"cache_read_input_tokens\":0}}\n"
  exit 0
fi
exit 0
EOF
    chmod +x "$1/bin/claude"

    export RUNTIME=claude
    export WORKSPACE="$1/workspace"
    export RALPH_PLAN_KEY=warm-enabled
    export RALPH_PLAN_WORKSPACE_ROOT="$1/workspace/.ralph-workspace"
    export RALPH_PLAN_INVOCATION_USAGE_FILE="$7"
    export RALPH_CLAUDE_SPECULATIVE_CACHE_WARM=1
    export PROMPT_STATIC="STABLE-PREFIX for warm"
    export SELECTED_MODEL=test-model
    export ITERATION=3

    ralph_claude_speculative_cache_warm_maybe_start 42
    [[ "${RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED}" == "1" ]]
    ralph_claude_speculative_cache_warm_finalize

    grep -q -- "--cache-control" "$6"
    grep -q -- "--max-output-tokens" "$6"
    grep -q -- "--system-prompt" "$6"
    grep -q "STABLE-PREFIX for warm" "$6"

    python3 - <<PY
import json
with open("$7", encoding="utf-8") as fh:
    doc = json.load(fh)
assert len(doc["invocations"]) == 1
rec = doc["invocations"][0]
assert rec["invocation_kind"] == "speculative_cache_warm"
assert rec["session_strategy"] == "speculative_cache_warm"
assert rec["output_tokens"] == 1
assert rec["cache_creation_input_tokens"] == 900
assert rec["todo_line"] == 42
PY
  ' _ "$TEST_TMPDIR" "$WARM_LIB" "$TEARDOWN_LIB" "$core_lib" "$funcs" "$record" "$usage_file"

  [ "$status" -eq 0 ]
}

@test "speculative cache warm stays disabled by default in ralph mode" {
  # shellcheck disable=SC1090
  source "$WARM_LIB"
  local record="$TEST_TMPDIR/claude-warm-default.args"
  write_claude_supported_warm_stub "$record"

  export RUNTIME=claude
  export RALPH_MODE=ralph
  unset RALPH_CLAUDE_SPECULATIVE_CACHE_WARM
  export PROMPT_STATIC="STABLE-PREFIX block"
  export RALPH_PLAN_KEY="warm-default"
  export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"

  ralph_claude_speculative_cache_warm_maybe_start 10

  [ "${RALPH_CLAUDE_SPECULATIVE_CACHE_WARM_STARTED:-0}" = "0" ]
  [ ! -s "$record" ]
}

@test "claude session continuation tier probe selects hook matching evaluate" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-tier-probe.sh"

  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=auto
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  mkdir -p "$WORKSPACE/.claude"

  local probe expected
  probe="$(ralph_bg_tier_probe_evaluate claude)"
  expected="$(jq -r '.tier' <<<"$probe")"
  [ "$expected" = "hook" ]
  [[ "$(jq -r '.reason' <<<"$probe")" == *"claude-stop-hook"* ]]

  ralph_bg_tier_probe_apply claude >/dev/null
  [ "${RALPH_BG_TIER_SELECTED:-}" = "$expected" ]
  [[ "${RALPH_BG_TIER_REASON:-}" == *"claude-stop-hook"* ]]
}

@test "claude tier1 continuation holds session and emits no resume argv" {
  local record="$TEST_TMPDIR/claude-tier1-held.args"
  write_claude_stub "$record"
  export SESSION_ID_FILE="$TEST_TMPDIR/session-id.claude.txt"
  printf '%s\n' "held-claude-session" >"$SESSION_ID_FILE"
  export RALPH_BG_TIER_SELECTED=hook
  export RALPH_USAGE_SESSION_CONTINUITY=held
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  export CLAUDE_PLAN_BARE=1
  unset RALPH_MODE
  unset RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export PROMPT="claude-tier1-held"

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  ! grep -Fxq -- "--resume" "$record"
  ! grep -Fxq -- "--session-id" "$record"
  ! grep -Fxq -- "held-claude-session" "$record"
}

@test "claude tier2 continuation resumes exact session id while fresh todo-start omits resume" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-session.sh"
  ralph_run_plan_log() { :; }

  export RALPH_SESSION_DIR="$TEST_TMPDIR/session"
  mkdir -p "$RALPH_SESSION_DIR"
  export RUNTIME=claude
  export RALPH_PROCESS_RUN_ID=run-claude-tier2
  export RALPH_CURRENT_TODO_ORDINAL=1
  export SESSION_ID_FILE="$RALPH_SESSION_DIR/session-id.claude.txt"
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  export RALPH_PLAN_CLI_RESUME=0
  export RALPH_PLAN_CAPTURE_USAGE=0
  export CLAUDE_PLAN_BARE=1
  export RALPH_BG_TIER_SELECTED=invocation
  unset RALPH_MODE

  export RALPH_CURRENT_TODO_LINE=17
  export RALPH_CURRENT_TODO_ID=claude-tier2-start-todo
  export RALPH_CURRENT_TODO_HASH=hash-claude-tier2-start
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]

  local start_record="$TEST_TMPDIR/claude-tier2-start.args"
  write_claude_stub "$start_record"
  export PROMPT="claude-tier2-start"
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--resume" "$start_record"

  export RALPH_CURRENT_TODO_LINE=18
  export RALPH_CURRENT_TODO_ID=claude-tier2-cont-todo
  export RALPH_CURRENT_TODO_HASH=hash-claude-tier2-cont
  ralph_session_todo_create "exact-claude-session" "exact" >/dev/null
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-continue" ]
  [ "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" = "exact-claude-session" ]

  local cont_record="$TEST_TMPDIR/claude-tier2-cont.args"
  write_claude_stub "$cont_record"
  export PROMPT="claude-tier2-continue"
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  grep -Fxq -- "--resume" "$cont_record"
  grep -Fxq -- "exact-claude-session" "$cont_record"

  export RALPH_CURRENT_TODO_ID=claude-tier2-rework
  export RALPH_CURRENT_TODO_HASH=hash-claude-tier2-rework
  export RALPH_CURRENT_TODO_LINE=19
  export RALPH_PLAN_CLI_RESUME=0
  unset RALPH_PLAN_INVOCATION_REASON RALPH_RUN_PLAN_RESUME_SESSION_ID RALPH_RUN_PLAN_NEW_SESSION_ID RALPH_RUN_PLAN_RESUME_BARE
  export RALPH_PLAN_SESSION_STRATEGY=fresh
  ralph_session_todo_prepare_invocation
  [ "${RALPH_PLAN_INVOCATION_REASON:-}" = "todo-start" ]
  [ -z "${RALPH_RUN_PLAN_RESUME_SESSION_ID:-}" ]
}
