#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

POLICY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-policy.sh"
APPROVALS_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp-proxy/mcp-proxy-approvals.sh"
PROTOCOL_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/mcp/mcp-protocol.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export RALPH_PLAN_WORKSPACE_ROOT="$TEST_TMPDIR/.ralph-workspace"
  export RALPH_PLAN_KEY="approval-test.plan"
  export WORKSPACE="$TEST_TMPDIR/workspace"
  mkdir -p "$WORKSPACE"
}

teardown() {
  if [[ -d "${TEST_TMPDIR:-}" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

load_approvals_lib() {
  # shellcheck source=/dev/null
  source "$POLICY_LIB"
  # shellcheck source=/dev/null
  source "$APPROVALS_LIB"
}

@test "approval request JSON is schema-complete" {
  load_approvals_lib
  local request_id request_path
  request_id="$(
    ralph_mcp_approvals_write_request \
      "ralph_proxy_grep" \
      "boundary" \
      "path outside workspace" \
      '{"path":"/etc/passwd","pattern":"root"}'
  )"
  [ -n "$request_id" ]

  request_path="$(ralph_mcp_approvals_request_path "$request_id")"
  [ -f "$request_path" ]

  jq -e '
    (.id | type) == "string" and length > 0
    and (.timestamp | type) == "string" and length > 0
    and (.plan_key | type) == "string"
    and (.tool | type) == "string"
    and (.category | type) == "string"
    and (.reason | type) == "string"
    and (.arguments.summary | type) == "string"
    and (.arguments.hash | type) == "string"
    and (.arguments_json | type) == "string"
    and (.project_root | type) == "string"
    and (.agent_workspace | type) == "string"
    and (.timeout_seconds | type) == "number"
    and (.expires_at | type) == "string" and length > 0
  ' "$request_path"
}

@test "decision parsing returns approve or deny with reason" {
  load_approvals_lib
  local request_id decision_path result
  request_id="$(
    ralph_mcp_approvals_write_request \
      "ralph_proxy_read" \
      "boundary" \
      "test" \
      '{"path":"../secret"}'
  )"

  decision_path="$(ralph_mcp_approvals_decision_path "$request_id")"
  jq -n \
    --arg id "$request_id" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{id: $id, decision: "deny", reason: "not allowed", decided_by: "file", timestamp: $timestamp}' \
    >"$decision_path"

  run ralph_mcp_approvals_read_decision "$request_id"
  [ "$status" -eq 0 ]
  [ "$output" = $'deny\tnot allowed' ]

  rm -f "$decision_path"
  jq -n \
    --arg id "$request_id" \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{id: $id, decision: "approve", reason: "", decided_by: "tty", timestamp: $timestamp}' \
    >"$decision_path"

  result="$(ralph_mcp_approvals_read_decision "$request_id")"
  [ "$result" = "approve" ]
}

@test "decision file owned by another UID is rejected" {
  load_approvals_lib
  local request_id decision_path stub_stat_dir
  request_id="$(
    ralph_mcp_approvals_write_request \
      "ralph_proxy_grep" \
      "boundary" \
      "test" \
      '{"path":"x","pattern":"y"}'
  )"

  decision_path="$(ralph_mcp_approvals_decision_path "$request_id")"
  jq -n --arg id "$request_id" '{id: $id, decision: "approve", reason: "", decided_by: "file", timestamp: "2026-01-01T00:00:00Z"}' \
    >"$decision_path"

  stub_stat_dir="$(mktemp -d)"
  cat <<'EOF' >"$stub_stat_dir/stat"
#!/usr/bin/env bash
if [[ "$1" == "-c" && "$2" == "%u" ]]; then
  printf '999\n'
  exit 0
fi
if [[ "$1" == "-f" && "$2" == "%u" ]]; then
  printf '999\n'
  exit 0
fi
command stat "$@"
EOF
  chmod +x "$stub_stat_dir/stat"

  run env PATH="$stub_stat_dir:$PATH" bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    ralph_mcp_approvals_read_decision "$3"
  ' _ "$POLICY_LIB" "$APPROVALS_LIB" "$request_id"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ignoring decision to prevent injection."* ]]

  rm -rf "$stub_stat_dir"
}

@test "pre-seeded decision resolves immediately without waiting full timeout" {
  load_approvals_lib
  local request_id decision_path start elapsed result
  request_id="$(
    ralph_mcp_approvals_write_request \
      "ralph_proxy_glob" \
      "boundary" \
      "test" \
      '{"glob_pattern":"*.sh"}'
  )"

  decision_path="$(ralph_mcp_approvals_decision_path "$request_id")"
  jq -n --arg id "$request_id" '{id: $id, decision: "approve", reason: "", decided_by: "file", timestamp: "2026-01-01T00:00:00Z"}' \
    >"$decision_path"

  start=$SECONDS
  result="$(RALPH_APPROVAL_TIMEOUT=30 RALPH_APPROVAL_POLL_INTERVAL=1 ralph_mcp_approvals_wait_for_decision "$request_id" 30)"
  elapsed=$((SECONDS - start))
  [ "$result" = "approve" ]
  [ "$elapsed" -lt 5 ]
}

@test "timeout cleanup writes audit log and removes request files" {
  load_approvals_lib
  local request_id request_path audit_path lines_before lines_after
  request_id="$(
    ralph_mcp_approvals_write_request \
      "ralph_proxy_shell" \
      "denied-command" \
      "blocked command" \
      '{"command":"rm -rf /"}'
  )"
  request_path="$(ralph_mcp_approvals_request_path "$request_id")"
  audit_path="$(ralph_mcp_approvals_audit_log_path)"

  lines_before=0
  [[ -f "$audit_path" ]] && lines_before="$(wc -l <"$audit_path" | tr -d ' ')"

  run bash -c '
    set -euo pipefail
    source "$1"
    source "$2"
    export RALPH_APPROVAL_TIMEOUT=1
    export RALPH_APPROVAL_POLL_INTERVAL=1
    ralph_mcp_approvals_wait_for_decision "$3" 1
  ' _ "$POLICY_LIB" "$APPROVALS_LIB" "$request_id"
  [ "$status" -eq 1 ]

  ralph_mcp_approvals_finalize "$request_id" "timeout" "operator approval timed out" "timeout"

  [ ! -f "$request_path" ]
  [ -f "$audit_path" ]
  lines_after="$(wc -l <"$audit_path" | tr -d ' ')"
  [ "$lines_after" -gt "$lines_before" ]

  tail -n1 "$audit_path" | jq -e '
    .outcome == "timeout"
    and .request_id == "'"$request_id"'"
    and (.tool | type) == "string"
  '
}

@test "approve-mode proxy boundary violation escalates immediately" {
  load_approvals_lib

  local approvals_dir
  approvals_dir="$(ralph_mcp_approvals_dir)"

  mkdir -p "$approvals_dir"
  rm -f "$approvals_dir"/request.*.json "$approvals_dir/approvals.log"

  local start elapsed
  start=$SECONDS
  local request_id request_path
  request_id="$(
    ralph_mcp_approvals_write_request \
      "ralph_proxy_grep" \
      "boundary" \
      "boundary violation" \
      '{"path":"../etc/passwd","pattern":"root"}'
  )"
  [ -n "$request_id" ]
  request_path="$(ralph_mcp_approvals_request_path "$request_id")"
  [ -s "$request_path" ]

  ralph_mcp_approvals_finalize "$request_id" "escalated" "approval escalated" "server"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 5 ]

  # request.<id>.json must be preserved for escalations.
  [ -s "$request_path" ]
  [ -f "$approvals_dir/approvals.log" ]

  run bash -c '
    set -euo pipefail
    last_line="$(tail -n1 "'"$approvals_dir"'/approvals.log")"
    jq -e '"'"'.outcome == "escalated"'"'"' <<<"$last_line" >/dev/null
  '
  [ "$status" -eq 0 ]
}

@test "send_notification emits JSON-RPC without id" {
  # shellcheck source=/dev/null
  source "$PROTOCOL_LIB"
  run send_notification "notifications/progress" '{"progressToken":"tok-1","progress":1,"total":10,"message":"waiting"}'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .jsonrpc == "2.0"
    and .method == "notifications/progress"
    and (.id | not)
    and .params.progressToken == "tok-1"
    and .params.message == "waiting"
  '
}
