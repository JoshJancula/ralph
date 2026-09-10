#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RESULT_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-result.sh"
POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
TOOLS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-tools.sh"
POLICY_EXAMPLE="$REPO_ROOT/bundle/.ralph/mcp-proxy-policy.example.json"
UPSTREAM_SCRIPT="$REPO_ROOT/bundle/.ralph/mcp-server.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  if [[ -d "${TEST_TMPDIR:-}" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

load_policy_and_dump() {
  local workspace="$1"
  local upstream_script="$2"
  shift 2
  local -a env_args=("$@")
  local shell_script
  read -r -d '' shell_script <<'EOF' || true
source "$1"
source "$2"
exec 2>/dev/null
if ! ralph_mcp_proxy_load_policy "$3" "$4"; then
  exit 1
fi
printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
  "$RALPH_MCP_PROXY_POLICY_SOURCE" \
  "$RALPH_MCP_PROXY_POLICY_NAME" \
  "$RALPH_MCP_PROXY_POLICY_RESULT_BYTE_CAP" \
  "$(ralph_mcp_proxy_result_byte_cap_for_tool resources/read)" \
  "$RALPH_MCP_PROXY_POLICY_CACHE_ENABLED" \
  "$RALPH_MCP_PROXY_POLICY_CACHE_READ_ONLY" \
  "$RALPH_MCP_PROXY_POLICY_TOOL_ALLOWLIST_JSON" \
  "$RALPH_MCP_PROXY_POLICY_TOOL_DENYLIST_JSON" \
  "$RALPH_MCP_PROXY_POLICY_DENIED_ARGUMENT_PATTERNS_JSON" \
  "$RALPH_MCP_PROXY_POLICY_TOOL_RESULT_BYTE_CAPS_JSON" \
  "$(jq -r ".upstreams | length" <<< "$RALPH_MCP_PROXY_POLICY_JSON")"
EOF

  if (( ${#env_args[@]} > 0 )); then
    run env "${env_args[@]}" bash -c "$shell_script" _ "$RESULT_LIB" "$POLICY_LIB" "$workspace" "$upstream_script" 2>/dev/null
  else
    run bash -c "$shell_script" _ "$RESULT_LIB" "$POLICY_LIB" "$workspace" "$upstream_script" 2>/dev/null
  fi
}

@test "loads a named policy from a file and exports per-tool caps" {
  [ -f "$POLICY_EXAMPLE" ] || skip "policy example missing"

  load_policy_and_dump "$REPO_ROOT" "$UPSTREAM_SCRIPT" RALPH_MCP_PROXY_POLICY=readonly RALPH_MCP_PROXY_POLICY_FILE="$POLICY_EXAMPLE"
  [ "$status" -eq 0 ]

  local summary_line
  summary_line="$(printf '%s\n' "$output" | tail -n1)"
  IFS='|' read -r source name result_cap tool_cap cache_enabled cache_read_only allowlist denylist denied_args tool_caps upstream_count <<< "$summary_line"
  [[ "$source" == file:* ]]
  [ "$name" = "readonly" ]
  [ "$result_cap" = "2048" ]
  [ "$tool_cap" = "512" ]
  [ "$cache_enabled" = "1" ]
  [ "$cache_read_only" = "1" ]
  printf '%s\n' "$allowlist" | jq -e 'length == 3'
  printf '%s\n' "$denylist" | jq -e 'index("ralph_write_file") != null'
  printf '%s\n' "$denied_args" | jq -e 'length == 1'
  printf '%s\n' "$tool_caps" | jq -e '."resources/read" == 512'
  [ "$upstream_count" = "1" ]
}

@test "loads inline policy JSON without a policy file" {
  local inline_policy
  inline_policy='{"name":"inline-policy","toolAllowlist":["ralph_plan_status"],"toolDenylist":["ralph_write_file"],"resultByteCap":17,"cache":{"enabled":false,"readOnly":false},"logging":{"requests":false,"responses":true}}'

  run env RALPH_MCP_PROXY_POLICY_INLINE="$inline_policy" bash -c '
    source "$1"
    source "$2"
    exec 2>/dev/null
    if ! ralph_mcp_proxy_load_policy "$3" "$4"; then
      exit 1
    fi
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
      "$RALPH_MCP_PROXY_POLICY_SOURCE" \
      "$RALPH_MCP_PROXY_POLICY_NAME" \
      "$RALPH_MCP_PROXY_POLICY_RESULT_BYTE_CAP" \
      "$(ralph_mcp_proxy_result_byte_cap_for_tool resources/read)" \
      "$RALPH_MCP_PROXY_POLICY_CACHE_ENABLED" \
      "$RALPH_MCP_PROXY_POLICY_CACHE_READ_ONLY" \
      "$RALPH_MCP_PROXY_POLICY_TOOL_ALLOWLIST_JSON" \
      "$RALPH_MCP_PROXY_POLICY_TOOL_DENYLIST_JSON" \
      "$RALPH_MCP_PROXY_POLICY_DENIED_ARGUMENT_PATTERNS_JSON" \
      "$RALPH_MCP_PROXY_POLICY_TOOL_RESULT_BYTE_CAPS_JSON" \
      "$(jq -r ".upstreams | length" <<< "$RALPH_MCP_PROXY_POLICY_JSON")"
  ' _ "$RESULT_LIB" "$POLICY_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" 2>/dev/null
  [ "$status" -eq 0 ]

  local summary_line
  summary_line="$(printf '%s\n' "$output" | tail -n1)"
  IFS='|' read -r source name result_cap tool_cap cache_enabled cache_read_only allowlist denylist _ _ upstream_count <<< "$summary_line"
  [ "$source" = "inline" ]
  [ "$name" = "inline-policy" ]
  [ "$result_cap" = "17" ]
  [ "$tool_cap" = "17" ]
  [ "$cache_enabled" = "0" ]
  [ "$cache_read_only" = "0" ]
  printf '%s\n' "$allowlist" | jq -e '.[0] == "ralph_plan_status" and length == 1'
  printf '%s\n' "$denylist" | jq -e '.[0] == "ralph_write_file" and length == 1'
  [ "$upstream_count" = "1" ]
}

@test "default policy is permissive out of the box (allow all commands and operators)" {
  # The out-of-box default must let ralph_proxy_shell run arbitrary commands and
  # shell operators; tightening is opt-in via a custom policy. Keep this in sync
  # with ralph_mcp_proxy_default_policy_json.
  run bash -c '
    source "$1"
    source "$2"
    exec 2>/dev/null
    ralph_mcp_proxy_load_policy "$3" "$4" || exit 1
    printf "%s|%s\n" \
      "$RALPH_MCP_PROXY_POLICY_OWNED_ALLOW_ALL_COMMANDS" \
      "$RALPH_MCP_PROXY_POLICY_OWNED_ALLOW_SHELL_OPERATORS"
  ' _ "$RESULT_LIB" "$POLICY_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -n1)" = "1|1" ]
}

@test "uses the built-in default policy when no explicit source is configured" {
  run bash -c '
    source "$1"
    source "$2"
    exec 2>/dev/null
    if ! ralph_mcp_proxy_load_policy "$3" "$4"; then
      exit 1
    fi
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
      "$RALPH_MCP_PROXY_POLICY_SOURCE" \
      "$RALPH_MCP_PROXY_POLICY_NAME" \
      "$RALPH_MCP_PROXY_POLICY_RESULT_BYTE_CAP" \
      "$(ralph_mcp_proxy_result_byte_cap_for_tool resources/read)" \
      "$(ralph_mcp_proxy_result_byte_cap_for_tool ralph_proxy_read)" \
      "$(ralph_mcp_proxy_result_byte_cap_for_tool ralph_proxy_grep)" \
      "$(ralph_mcp_proxy_result_byte_cap_for_tool ralph_proxy_glob)" \
      "$(ralph_mcp_proxy_result_byte_cap_for_tool ralph_proxy_shell)" \
      "$RALPH_MCP_PROXY_POLICY_CACHE_ENABLED" \
      "$RALPH_MCP_PROXY_POLICY_CACHE_READ_ONLY" \
      "$RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED" \
      "$RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_BYTES" \
      "$RALPH_MCP_PROXY_POLICY_OWNED_MAX_READ_LINES" \
      "$RALPH_MCP_PROXY_POLICY_OWNED_MAX_GREP_MATCHES" \
      "$RALPH_MCP_PROXY_POLICY_OWNED_MAX_GLOB_RESULTS" \
      "$RALPH_MCP_PROXY_POLICY_OWNED_MAX_SHELL_BYTES" \
      "$RALPH_MCP_PROXY_POLICY_OWNED_SHELL_TIMEOUT" \
      "$RALPH_MCP_PROXY_POLICY_TOOL_ALLOWLIST_JSON" \
      "$RALPH_MCP_PROXY_POLICY_TOOL_DENYLIST_JSON" \
      "$RALPH_MCP_PROXY_POLICY_DENIED_ARGUMENT_PATTERNS_JSON" \
      "$RALPH_MCP_PROXY_POLICY_TOOL_RESULT_BYTE_CAPS_JSON" \
      "$(jq -r ".upstreams | length" <<< "$RALPH_MCP_PROXY_POLICY_JSON")"
  ' _ "$RESULT_LIB" "$POLICY_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" 2>/dev/null
  [ "$status" -eq 0 ]

  local summary_line
  summary_line="$(printf '%s\n' "$output" | tail -n1)"
  IFS='|' read -r source name result_cap resource_cap read_cap grep_cap glob_cap shell_cap \
    cache_enabled cache_read_only owned_enabled max_read_bytes max_read_lines max_grep_matches \
    max_glob_results max_shell_bytes shell_timeout allowlist _ _ tool_caps upstream_count <<< "$summary_line"
  [ "$source" = "default" ]
  [ "$name" = "default" ]
  [ "$result_cap" = "16384" ]
  [ "$resource_cap" = "16384" ]
  [ "$read_cap" = "16384" ]
  [ "$grep_cap" = "16384" ]
  [ "$glob_cap" = "16384" ]
  [ "$shell_cap" = "8192" ]
  [ "$cache_enabled" = "1" ]
  [ "$cache_read_only" = "1" ]
  [ "$owned_enabled" = "1" ]
  [ "$max_read_bytes" = "32768" ]
  [ "$max_read_lines" = "250" ]
  [ "$max_grep_matches" = "50" ]
  [ "$max_glob_results" = "100" ]
  [ "$max_shell_bytes" = "8192" ]
  [ "$shell_timeout" = "600" ]
  printf '%s\n' "$allowlist" | jq -e 'length == 0'
  printf '%s\n' "$tool_caps" | jq -e '."ralph_proxy_read" == 16384 and ."ralph_proxy_grep" == 16384 and ."ralph_proxy_glob" == 16384 and ."ralph_proxy_shell" == 8192 and ."resources/read" == 16384'
  [ "$upstream_count" = "1" ]
}

assert_inline_policy_load_status() {
  local expected_status="$1"
  local inline_policy="$2"
  run env RALPH_MCP_PROXY_POLICY_INLINE="$inline_policy" bash -c '
    source "$1"
    source "$2"
    exec 2>&1
    if ralph_mcp_proxy_load_policy "$3" "$4"; then
      exit 0
    fi
    exit 1
  ' _ "$RESULT_LIB" "$POLICY_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT"
  [ "$status" -eq "$expected_status" ]
}

assert_policy_validate_status() {
  local expected_status="$1"
  local policy_json="$2"
  local policy_source="${3:-test-policy}"
  run bash -c '
    source "$1"
    exec 2>&1
    if ralph_mcp_proxy_policy_validate_json "$2" "$3"; then
      exit 0
    fi
    exit 1
  ' _ "$POLICY_LIB" "$policy_json" "$policy_source"
  [ "$status" -eq "$expected_status" ]
}

@test "policy validation accepts all new default bounded fields" {
  local valid_policy
  valid_policy='{
    "name": "bounded-defaults",
    "resultByteCap": 16384,
    "toolResultByteCaps": {
      "ralph_proxy_read": 16384,
      "ralph_proxy_grep": 16384,
      "ralph_proxy_glob": 16384,
      "ralph_proxy_shell": 8192,
      "resources/read": 16384
    },
    "resultTokenCap": 4096,
    "toolResultTokenCaps": {
      "ralph_proxy_grep": 2048
    },
    "truncationMarker": "...[truncated]",
    "proxyOwnedTools": {
      "enabled": true,
      "maxReadBytes": 32768,
      "maxReadLines": 250,
      "maxGrepMatches": 50,
      "maxGlobResults": 100,
      "maxShellOutputBytes": 8192,
      "shellTimeoutSeconds": 10,
      "shellAllowlist": ["git status", "pwd"]
    }
  }'

  assert_policy_validate_status 0 "$valid_policy" "bounded-defaults"
  assert_inline_policy_load_status 0 "$valid_policy"
}

@test "policy validation rejects malformed proxyOwnedTools" {
  assert_policy_validate_status 1 '{"name":"bad-owned","proxyOwnedTools":{"maxReadBytes":"not-a-number"}}' "bad-owned-bytes"
  [[ "$output" == *"failed schema validation"* ]]

  assert_policy_validate_status 1 '{"name":"bad-owned","proxyOwnedTools":{"enabled":"yes"}}' "bad-owned-enabled"
  [[ "$output" == *"failed schema validation"* ]]

  assert_policy_validate_status 1 '{"name":"bad-owned","proxyOwnedTools":{"shellAllowlist":["ok",123]}}' "bad-owned-shell-allowlist"
  [[ "$output" == *"failed schema validation"* ]]

  assert_inline_policy_load_status 1 '{"name":"bad-owned","proxyOwnedTools":{"maxGlobResults":-5}}'
  [[ "$output" == *"failed schema validation"* ]]
}

@test "policy validation rejects malformed resultByteCap" {
  assert_policy_validate_status 1 '{"name":"bad-cap","resultByteCap":"abc"}' "bad-cap-string"
  [[ "$output" == *"failed schema validation"* ]]

  assert_policy_validate_status 1 '{"name":"bad-cap","resultByteCap":-1}' "bad-cap-negative"
  [[ "$output" == *"failed schema validation"* ]]

  assert_policy_validate_status 1 '{"name":"bad-cap","resultByteCap":12.5}' "bad-cap-float"
  [[ "$output" == *"failed schema validation"* ]]

  assert_inline_policy_load_status 1 '{"name":"bad-cap","resultByteCap":""}'
  [[ "$output" == *"failed schema validation"* ]]
}

@test "policy validation rejects malformed toolResultByteCaps" {
  assert_policy_validate_status 1 '{"name":"bad-tool-caps","toolResultByteCaps":[]}' "bad-tool-caps-array"
  [[ "$output" == *"failed schema validation"* ]]

  assert_policy_validate_status 1 '{"name":"bad-tool-caps","toolResultByteCaps":{"ralph_proxy_read":"abc"}}' "bad-tool-caps-value"
  [[ "$output" == *"failed schema validation"* ]]

  assert_policy_validate_status 1 '{"name":"bad-tool-caps","toolResultByteCaps":{"":4096}}' "bad-tool-caps-empty-key"
  [[ "$output" == *"failed schema validation"* ]]

  assert_inline_policy_load_status 1 '{"name":"bad-tool-caps","toolResultByteCaps":{"ralph_proxy_shell":-100}}'
  [[ "$output" == *"failed schema validation"* ]]
}

@test "toolResultByteCaps keys are MCP identifiers and do not cap native runtime tools" {
  run env RALPH_MCP_PROXY_POLICY_INLINE='{"name":"native-key-mismatch","resultByteCap":9999,"toolResultByteCaps":{"Read":50,"ralph_proxy_read":100}}' bash -c '
    source "$1"
    source "$2"
    exec 2>/dev/null
    ralph_mcp_proxy_load_policy "$3" "$4" || exit 1
    printf "%s|%s\n" \
      "$(ralph_mcp_proxy_result_byte_cap_for_tool Read)" \
      "$(ralph_mcp_proxy_result_byte_cap_for_tool ralph_proxy_read)"
  ' _ "$RESULT_LIB" "$POLICY_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" 2>/dev/null
  [ "$status" -eq 0 ]

  local summary_line
  summary_line="$(printf '%s\n' "$output" | tail -n1)"
  IFS='|' read -r native_read_cap proxy_read_cap <<< "$summary_line"
  [ "$native_read_cap" = "50" ]
  [ "$proxy_read_cap" = "100" ]
}

@test "policy validation rejects malformed truncationMarker" {
  assert_policy_validate_status 1 '{"name":"bad-marker","truncationMarker":""}' "bad-marker-empty"
  [[ "$output" == *"failed schema validation"* ]]

  assert_policy_validate_status 1 '{"name":"bad-marker","truncationMarker":123}' "bad-marker-number"
  [[ "$output" == *"failed schema validation"* ]]

  assert_policy_validate_status 1 '{"name":"bad-marker","truncationMarker":false}' "bad-marker-boolean"
  [[ "$output" == *"failed schema validation"* ]]

  assert_inline_policy_load_status 1 '{"name":"bad-marker","truncationMarker":[]}'
  [[ "$output" == *"failed schema validation"* ]]
}

@test "kill switch sentinel writer emits stable JSON" {
  local workspace="$TEST_TMPDIR/workspace"
  mkdir -p "$workspace"

  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PROJECT_ROOT="$workspace" \
    RALPH_AGENT_WORKSPACE="$workspace/agent" \
    RALPH_PLAN_KEY="plan-sentinel-01" \
    bash -c '
    source "$1"
    ralph_mcp_policy_write_kill_switch_sentinel "ralph_proxy_read" "argument" "denied path" "/etc/passwd"
    ralph_mcp_policy_sentinel_path "$RALPH_PLAN_KEY"
  ' _ "$POLICY_LIB"

  [ "$status" -eq 0 ]
  local sentinel_path
  sentinel_path="$(printf "%s\n" "$output" | tail -n1)"
  [ -f "$sentinel_path" ]

  jq -e '.timestamp and .workspace and .plan_key == "plan-sentinel-01" and .tool == "ralph_proxy_read" and .category == "argument" and .reason == "denied path"' "$sentinel_path"
  # Verify new three-root diagnostics fields
  jq -e '.project_root == "'$workspace'"' "$sentinel_path"
  jq -e '.agent_workspace == "'$workspace'/agent"' "$sentinel_path"
  jq -e '.plan_workspace_root == "'$workspace'/.ralph-workspace"' "$sentinel_path"
  local summary
  summary="$(jq -r '.arguments.summary' "$sentinel_path")"
  [[ "$summary" == *"/etc/passwd"* ]]

  local hash
  hash="$(jq -r '.arguments.hash' "$sentinel_path")"
  [ "${#hash}" -eq 64 ]
}

@test "kill switch sentinel path can't escape security directory" {
  local workspace="$TEST_TMPDIR/workspace-traverse"
  mkdir -p "$workspace"

  local plan_key="../traverse/plan"
  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PROJECT_ROOT="$workspace" \
    RALPH_PLAN_KEY="$plan_key" \
    bash -c '
    source "$1"
    ralph_mcp_policy_sentinel_path "$RALPH_PLAN_KEY"
  ' _ "$POLICY_LIB"

  [ "$status" -eq 0 ]
  local sentinel_path
  sentinel_path="$(printf "%s\n" "$output" | tail -n1)"
  [[ "$sentinel_path" != *".."* ]]

  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    bash -c '
    source "$1"
    ralph_mcp_policy_security_dir
  ' _ "$POLICY_LIB"

  local security_dir
  security_dir="$(printf "%s\n" "$output" | tail -n1)"

  case "$sentinel_path" in
    "$security_dir"|"${security_dir}"/*) ;;
    *)
      echo "sentinel path escapes security directory"
      false
      ;;
  esac

  [ "$(basename "$sentinel_path")" = "kill-switch.__traverse_plan.json" ]
}

@test "sentinel includes non-empty project_root, agent_workspace, and plan_workspace_root" {
  local workspace="$TEST_TMPDIR/workspace-triroots"
  mkdir -p "$workspace"

  local agent_ws="$workspace/custom-agent"
  mkdir -p "$agent_ws"

  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PROJECT_ROOT="$workspace/project" \
    RALPH_AGENT_WORKSPACE="$agent_ws" \
    RALPH_PLAN_KEY="plan-triroots-01" \
    bash -c '
    source "$1"
    ralph_mcp_policy_write_kill_switch_sentinel "ralph_proxy_shell" "policy" "outside workspace" "../../../etc/passwd"
    ralph_mcp_policy_sentinel_path "$RALPH_PLAN_KEY"
  ' _ "$POLICY_LIB"

  [ "$status" -eq 0 ]
  local sentinel_path
  sentinel_path="$(printf "%s\n" "$output" | tail -n1)"
  [ -f "$sentinel_path" ]

  # All three roots must be non-empty and match the env vars
  jq -e '.project_root and .project_root != ""' "$sentinel_path"
  jq -e '.agent_workspace and .agent_workspace != ""' "$sentinel_path"
  jq -e '.plan_workspace_root and .plan_workspace_root != ""' "$sentinel_path"
  jq -e '.project_root == "'$workspace'/project"' "$sentinel_path"
  jq -e '.agent_workspace == "'$agent_ws'"' "$sentinel_path"
  jq -e '.plan_workspace_root == "'$workspace'/.ralph-workspace"' "$sentinel_path"
}

@test "sentinel is written under RALPH_PLAN_WORKSPACE_ROOT/security" {
  local workspace="$TEST_TMPDIR/workspace-root-test"
  mkdir -p "$workspace"

  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/state-root" \
    RALPH_PROJECT_ROOT="$workspace/project" \
    RALPH_PLAN_KEY="plan-root-test" \
    bash -c '
    source "$1"
    ralph_mcp_policy_write_kill_switch_sentinel "ralph_proxy_read" "argument" "test sentinel" "/etc/hosts"
    ralph_mcp_policy_sentinel_path "$RALPH_PLAN_KEY"
    ralph_mcp_policy_security_dir
  ' _ "$POLICY_LIB"

  [ "$status" -eq 0 ]
  local sentinel_path security_dir
  sentinel_path="$(printf "%s\n" "$output" | sed -n '1p')"
  security_dir="$(printf "%s\n" "$output" | tail -n1)"
  [ -f "$sentinel_path" ]

  case "$sentinel_path" in
    "$security_dir"|"${security_dir}"/*) ;;
    *)
      echo "sentinel path is not under RALPH_PLAN_WORKSPACE_ROOT/security"
      false
      ;;
  esac
  jq -e '.plan_workspace_root == "'$workspace'/state-root"' "$sentinel_path"
}

@test "missing file inside allowed root returns non-fatal error, no sentinel" {
  local workspace="$TEST_TMPDIR/workspace-missing-file"
  mkdir -p "$workspace/.ralph-workspace/artifacts"

  # Simulate PLAN48-style: missing artifact under workspace
  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PROJECT_ROOT="$workspace" \
    RALPH_AGENT_WORKSPACE="$workspace" \
    RALPH_MCP_WORKSPACE="$workspace" \
    RALPH_PLAN_KEY="plan-missing-artifact" \
    bash -c '
    source "$1"
    source "$2"
    # PLAN48-style: missing artifact under plan state root (non-fatal)
    ralph_mcp_proxy_path_is_allowed ".ralph-workspace/artifacts/missing.txt" 1
    echo "exit_code=$?"
  ' _ "$POLICY_LIB" "$TOOLS_LIB"

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep '^exit_code=' | tail -n1)" = "exit_code=2" ]

  # No sentinel should be written for non-fatal missing file
  local sentinel_path="$workspace/.ralph-workspace/security/kill-switch.plan-missing-artifact.json"
  [ ! -f "$sentinel_path" ]
}

@test "tmp path is allowed outside workspace without sentinel" {
  local workspace="$TEST_TMPDIR/workspace-tmp-allowed"
  local tmp_dir tmp_file resolved
  mkdir -p "$workspace"
  tmp_dir="$(mktemp -d /tmp/ralph-mcp-tmp-allowed.XXXXXX)"
  tmp_file="$tmp_dir/note.txt"
  printf 'tmp allowed\n' >"$tmp_file"

  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PROJECT_ROOT="$workspace" \
    RALPH_AGENT_WORKSPACE="$workspace" \
    RALPH_MCP_WORKSPACE="$workspace" \
    RALPH_PLAN_KEY="plan-tmp-allowed" \
    bash -c '
    source "$1"
    source "$2"
    ralph_mcp_proxy_path_is_allowed "$3" 1
    echo "exit_code=$?"
  ' _ "$POLICY_LIB" "$TOOLS_LIB" "$tmp_file"

  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep '^exit_code=' | tail -n1)" = "exit_code=0" ]
  resolved="$(printf '%s\n' "$output" | sed -n '1p')"
  [ -n "$resolved" ]

  local sentinel_path="$workspace/.ralph-workspace/security/kill-switch.plan-tmp-allowed.json"
  [ ! -f "$sentinel_path" ]
  rm -rf "$tmp_dir"
}

@test "ralph_proxy_read can read tmp path outside workspace" {
  command -v jq >/dev/null || skip "jq required"
  local workspace="$TEST_TMPDIR/workspace-tmp-read"
  local tmp_dir tmp_file args_json response
  mkdir -p "$workspace"
  tmp_dir="$(mktemp -d /tmp/ralph-mcp-tmp-read.XXXXXX)"
  tmp_file="$tmp_dir/note.txt"
  printf 'tmp read allowed\n' >"$tmp_file"
  args_json="$(jq -nc --arg path "$tmp_file" '{path: $path}')"

  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PROJECT_ROOT="$workspace" \
    RALPH_AGENT_WORKSPACE="$workspace" \
    RALPH_MCP_WORKSPACE="$workspace" \
    RALPH_PLAN_KEY="plan-tmp-read" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    bash -c '
    source "$1"
    source "$2"
    source "$3"
    ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
    ralph_mcp_proxy_call_owned_tool "$4" ralph_proxy_read "$6"
  ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$workspace" "$UPSTREAM_SCRIPT" "$args_json"

  [ "$status" -eq 0 ]
  response="$(printf '%s\n' "$output" | sed -n 's/^.*\({"content":.*\)$/\1/p' | tail -n1)"
  printf '%s\n' "$response" | jq -e '.isError == false'
  printf '%s\n' "$response" | jq -e '.content[0].text | contains("tmp read allowed")'

  local sentinel_path="$workspace/.ralph-workspace/security/kill-switch.plan-tmp-read.json"
  [ ! -f "$sentinel_path" ]
  rm -rf "$tmp_dir"
}

@test "outside-root path creates fatal sentinel" {
  local workspace="$TEST_TMPDIR/workspace-outside"
  mkdir -p "$workspace"

  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PROJECT_ROOT="$workspace" \
    RALPH_AGENT_WORKSPACE="$workspace" \
    RALPH_MCP_WORKSPACE="$workspace" \
    RALPH_PLAN_KEY="plan-outside-root" \
    bash -c '
    source "$1"
    source "$2"
    # Attempt to access path outside workspace
    ralph_mcp_proxy_path_is_allowed "/etc/passwd" 1
    echo "exit_code=$?"
  ' _ "$POLICY_LIB" "$TOOLS_LIB"

  # exit_code=1 indicates outside-root (fatal)
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep '^exit_code=' | tail -n1)" = "exit_code=1" ]
}

@test "kill switch sentinel written for fatal outside-root violation" {
  local workspace="$TEST_TMPDIR/workspace-fatal-outside"
  mkdir -p "$workspace"

  run env \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PROJECT_ROOT="$workspace/project" \
    RALPH_AGENT_WORKSPACE="$workspace/agent" \
    RALPH_PLAN_KEY="plan-fatal-outside" \
    bash -c '
    source "$1"
    ralph_mcp_policy_write_kill_switch_sentinel "ralph_proxy_read" "path" "ralph_proxy_read: path is outside the workspace" "/etc/passwd"
    ralph_mcp_policy_sentinel_path "$RALPH_PLAN_KEY"
  ' _ "$POLICY_LIB"

  [ "$status" -eq 0 ]
  local sentinel_path
  sentinel_path="$(printf "%s\n" "$output" | tail -n1)"
  [ -f "$sentinel_path" ]

  # Verify sentinel contains the three-root diagnostics
  jq -e '.tool == "ralph_proxy_read"' "$sentinel_path"
  jq -e '.category == "path"' "$sentinel_path"
  jq -e '.reason == "ralph_proxy_read: path is outside the workspace"' "$sentinel_path"
  jq -e '.project_root == "'$workspace'/project"' "$sentinel_path"
  jq -e '.agent_workspace == "'$workspace'/agent"' "$sentinel_path"
  jq -e '.plan_workspace_root == "'$workspace'/.ralph-workspace"' "$sentinel_path"
}

@test "violation mode defaults to fatal without plan runner context" {
  run bash -c '
    source "$1"
    unset RALPH_MCP_POLICY_VIOLATION_MODE RALPH_AGENT_TOOL_ACCESS RALPH_RUN_PLAN_ACTIVE RALPH_PLAN_KEY RALPH_PLAN_WORKSPACE_ROOT
    mode="$(ralph_mcp_policy_violation_mode_effective)"
    [[ "$mode" == "fatal" ]]
  ' _ "$POLICY_LIB"
  [ "$status" -eq 0 ]
}

@test "violation mode defaults to approve in runner-backed ralph context" {
  run bash -c '
    source "$1"
    unset RALPH_MCP_POLICY_VIOLATION_MODE
    export RALPH_AGENT_TOOL_ACCESS=ralph
    export RALPH_RUN_PLAN_ACTIVE=1
    export RALPH_PLAN_KEY=test-plan
    export RALPH_PLAN_WORKSPACE_ROOT=/tmp/ralph-state
    mode="$(ralph_mcp_policy_violation_mode_effective)"
    [[ "$mode" == "approve" ]]
  ' _ "$POLICY_LIB"
  [ "$status" -eq 0 ]
}

@test "configured approve falls back to fatal without operator channel" {
  run bash -c '
    source "$1"
    export RALPH_MCP_POLICY_VIOLATION_MODE=approve
    unset RALPH_AGENT_TOOL_ACCESS RALPH_RUN_PLAN_ACTIVE RALPH_PLAN_KEY RALPH_PLAN_WORKSPACE_ROOT
    mode="$(ralph_mcp_policy_violation_mode_effective)"
    [[ "$mode" == "fatal" ]]
  ' _ "$POLICY_LIB"
  [ "$status" -eq 0 ]
}

@test "plan memory tools absent when RALPH_PLAN_MEMORY=0" {
  local workspace="$TEST_TMPDIR/memory-disabled"
  mkdir -p "$workspace"

  run env \
    RALPH_MODE=hybrid \
    RALPH_PLAN_MEMORY=0 \
    RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
    source "$1"
    source "$2"
    tools="$(ralph_mcp_proxy_owned_tools_full_json)"
    printf "%s\n" "$tools" | jq -e "map(.name) | index(\"ralph_proxy_memory_list\") == null"
  ' _ "$POLICY_LIB" "$TOOLS_LIB"

  [ "$status" -eq 0 ]
}

@test "plan memory tools present in full catalog when enabled" {
  local workspace="$TEST_TMPDIR/memory-enabled"
  mkdir -p "$workspace"

  run env \
    RALPH_MODE=hybrid \
    RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
    source "$1"
    source "$2"
    tools="$(ralph_mcp_proxy_owned_tools_full_json)"
    printf "%s\n" "$tools" | jq -e "map(.name) | index(\"ralph_proxy_memory_write\") != null"
  ' _ "$POLICY_LIB" "$TOOLS_LIB"

  [ "$status" -eq 0 ]
}

@test "plan memory CRUD is isolated to active plan key" {
  local workspace="$TEST_TMPDIR/memory-crud"
  mkdir -p "$workspace/.ralph-workspace"

  run env \
    RALPH_MODE=hybrid \
    RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    RALPH_MCP_WORKSPACE="$workspace" \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PLAN_KEY="plan-a" \
    bash -c '
    source "$1"
    source "$2"
    write_args=$(jq -nc --arg key note --arg content hello "{key: \$key, content: \$content}")
    read_args=$(jq -nc --arg key note "{key: \$key}")
    write_json="$(ralph_mcp_proxy_call_owned_tool "$3" ralph_proxy_memory_write "$write_args")"
    printf "%s\n" "$write_json" | jq -e ".isError != true"
    read_json="$(ralph_mcp_proxy_call_owned_tool "$3" ralph_proxy_memory_read "$read_args")"
    printf "%s\n" "$read_json" | jq -e ".content[0].text | contains(\"hello\")"
    export RALPH_PLAN_KEY=plan-b
    cross_json="$(ralph_mcp_proxy_call_owned_tool "$3" ralph_proxy_memory_read "$read_args")"
    printf "%s\n" "$cross_json" | jq -e ".isError == true"
    [ ! -d "$3/.ralph-workspace/memory/plan-b" ]
  ' _ "$POLICY_LIB" "$TOOLS_LIB" "$workspace"

  [ "$status" -eq 0 ]
}

@test "plan memory rejects traversal keys" {
  local workspace="$TEST_TMPDIR/memory-traversal"
  mkdir -p "$workspace/.ralph-workspace"

  run env \
    RALPH_MODE=hybrid \
    RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    RALPH_MCP_WORKSPACE="$workspace" \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PLAN_KEY="plan-a" \
    bash -c '
    source "$1"
    source "$2"
    bad_args=$(jq -nc --arg key "../evil" --arg content x "{key: \$key, content: \$content}")
    result="$(ralph_mcp_proxy_call_owned_tool "$3" ralph_proxy_memory_write "$bad_args")"
    printf "%s\n" "$result" | jq -e ".isError == true"
  ' _ "$POLICY_LIB" "$TOOLS_LIB" "$workspace"

  [ "$status" -eq 0 ]
}

@test "result reduce tool absent when RALPH_RESULT_REDUCE=0" {
  local workspace="$TEST_TMPDIR/result-reduce-disabled"
  mkdir -p "$workspace"

  run env \
    RALPH_MODE=hybrid \
    RALPH_RESULT_REDUCE=0 \
    RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
    source "$1"
    source "$2"
    tools="$(ralph_mcp_proxy_result_tools_full_json_with_reduce)"
    printf "%s\n" "$tools" | jq -e "map(.name) | index(\"ralph_proxy_result_reduce\") == null"
  ' _ "$POLICY_LIB" "$TOOLS_LIB"

  [ "$status" -eq 0 ]
}

@test "result reduce tool present when enabled in hybrid mode" {
  local workspace="$TEST_TMPDIR/result-reduce-enabled"
  mkdir -p "$workspace"

  run env \
    RALPH_MODE=hybrid \
    RALPH_MCP_PROXY_POLICY_OWNED_TOOLS_ENABLED=1 \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    bash -c '
    source "$1"
    source "$2"
    tools="$(ralph_mcp_proxy_result_tools_full_json_with_reduce)"
    printf "%s\n" "$tools" | jq -e "map(.name) | index(\"ralph_proxy_result_reduce\") != null"
  ' _ "$POLICY_LIB" "$TOOLS_LIB"

  [ "$status" -eq 0 ]
}

@test "result reduce rejects jq injection and leaves source result unchanged" {
  command -v jq >/dev/null || skip "jq required"
  local workspace="$TEST_TMPDIR/result-reduce-safety"
  mkdir -p "$workspace/.ralph-workspace"

  run env \
    RALPH_MODE=hybrid \
    RALPH_MCP_PROXY_POLICY_INLINE="$(jq -nc '{name:"reduce-policy", proxyOwnedTools:{enabled:true}}')" \
    RALPH_MCP_PROXY_OWNED_TOOLS_FORCE=1 \
    RALPH_MCP_PROXY_RUNTIME=claude \
    RALPH_MCP_WORKSPACE="$workspace" \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PLAN_KEY="plan-reduce" \
    bash -c '
    source "$1"
    source "$2"
    source "$3"
    ralph_mcp_proxy_load_policy "$4" "$5" || exit 1
    content="keep-this-source-intact"
    id="$(ralph_mcp_proxy_result_store_write "$6" "$7" "$content" "ralph_proxy_shell")"
    bad=$(ralph_mcp_proxy_call_owned_tool "$6" ralph_proxy_result_reduce "$(jq -nc --arg id "$id" "{resultId:\$id, reducer:\"jq\", expression:\"system(\\\"id\\\")\"}")")
    printf "%s\n" "$bad" | jq -e ".isError == true"
    after="$(ralph_mcp_proxy_result_store_read_bytes "$6" "$7" "$id" 0 0 raw)"
    [[ "$after" == "$content" ]]
  ' _ "$POLICY_LIB" "$RESULT_LIB" "$TOOLS_LIB" "$REPO_ROOT" "$UPSTREAM_SCRIPT" "$workspace" "plan-reduce"

  [ "$status" -eq 0 ]
}

@test "MCP events are P10-shaped and evaluator output is unchanged" {
  local workspace="$TEST_TMPDIR/mcp-eval-parity"
  mkdir -p "$workspace/.ralph-workspace"
  cat >"$workspace/.ralph-workspace/killswitch.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": true,
  "banned_tools": [],
  "tool_denylist": ["Bash"],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [
    {"tool": "ralph_proxy_read", "pattern": "/etc/passwd"}
  ],
  "custom_rules": []
}
EOF

  run env \
    WORKSPACE="$workspace" \
    RALPH_PROJECT_ROOT="$workspace" \
    RALPH_AGENT_WORKSPACE="$workspace" \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_PLAN_KEY="mcp-eval" \
    RALPH_MCP_PROXY_RUNTIME="claude" \
    bash -c '
    source "$1"
    benign="$(ralph_mcp_policy_event_json "ralph_plan_status" "PLAN.md" "status")"
    jq -e ".schemaVersion == 1 and .source == \"mcp\" and .runtime == \"claude\" and .tool == \"ralph_plan_status\" and .action == \"execute\" and .effect == \"read\" and .resource == \"PLAN.md\"" <<< "$benign"
    mcp_benign="$(ralph_mcp_policy_evaluate "$benign")"
    ks_benign="$(killswitch_evaluate "$benign")"
    [[ "$mcp_benign" == "$ks_benign" ]]
    [[ "$mcp_benign" == "allow" ]]

    denied="$(ralph_mcp_policy_event_json "Bash" "" "echo hi" "execute" "write")"
    mcp_denied="$(ralph_mcp_policy_evaluate "$denied")"
    ks_denied="$(killswitch_evaluate "$denied")"
    [[ "$mcp_denied" == "$ks_denied" ]]
    [[ "$mcp_denied" == "fatal" ]]

    arg_event="$(ralph_mcp_policy_event_json "ralph_proxy_read" "/etc/passwd" "path=/etc/passwd")"
    mcp_arg="$(ralph_mcp_policy_evaluate "$arg_event")"
    ks_arg="$(killswitch_evaluate "$arg_event")"
    [[ "$mcp_arg" == "$ks_arg" ]]
    [[ "$mcp_arg" == "fatal" ]]
  ' _ "$POLICY_LIB"

  [ "$status" -eq 0 ]
}

@test "proxy policy denylist is published to the canonical evaluator at load" {
  local workspace="$TEST_TMPDIR/mcp-policy-publish"
  mkdir -p "$workspace/.ralph-workspace"
  cat >"$workspace/.ralph-workspace/killswitch.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": true,
  "banned_tools": [],
  "tool_denylist": [],
  "denied_argument_patterns": [],
  "banned_paths": [],
  "custom_rules": []
}
EOF

  local inline_policy
  inline_policy='{"name":"deny-write","toolDenylist":["ralph_write_file"],"deniedArgumentPatterns":[{"tool":"ralph_run_plan","pattern":"/tmp/"}]}'

  run env \
    WORKSPACE="$workspace" \
    RALPH_PROJECT_ROOT="$workspace" \
    RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace" \
    RALPH_MCP_PROXY_POLICY_INLINE="$inline_policy" \
    bash -c '
    source "$1"
    source "$2"
    ralph_mcp_proxy_load_policy "$3" "$4" || exit 1
    event="$(ralph_mcp_policy_event_json "ralph_write_file" "out.md" "{}")"
    decision="$(ralph_mcp_policy_evaluate "$event")"
    [[ "$decision" == "fatal" ]]
    if ralph_mcp_proxy_tool_allowed "ralph_write_file"; then
      echo "denylisted tool still allowed"
      exit 1
    fi
    if ! ralph_mcp_proxy_arguments_denied "ralph_run_plan" "plan_path=/tmp/evil.md"; then
      echo "denied argument pattern not detected via evaluator"
      exit 1
    fi
  ' _ "$RESULT_LIB" "$POLICY_LIB" "$workspace" "$UPSTREAM_SCRIPT"

  [ "$status" -eq 0 ]
}

@test "exactly one sentinel writer remains" {
  local hits files
  hits="$(grep -RIn --include='*.sh' '> "$sentinel_path"' \
    "$REPO_ROOT/bundle/.ralph/bash-lib/killswitch" \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy" || true)"
  [ -n "$hits" ]
  files="$(printf '%s\n' "$hits" | awk -F: '{print $1}' | sort -u)"
  [ "$(printf '%s\n' "$files" | wc -l | tr -d ' ')" = "1" ]
  [[ "$files" == *"/killswitch/killswitch-killer.sh" ]]
  if grep -n '> "$sentinel_path"' \
    "$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh" >/dev/null; then
    echo "mcp-proxy-policy.sh still writes sentinel files"
    return 1
  fi
}
