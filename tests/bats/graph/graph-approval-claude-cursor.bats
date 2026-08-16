#!/usr/bin/env bats
# Claude and Cursor graph approval: live channel only after nonbillable help
# proof, otherwise the common resumable overlay. Cursor overlays project
# .cursor/cli.json only and never writes ~/.cursor/cli-config.json.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../run-plan/run-plan-invoke-test-helper.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh"

setup() {
  run_plan_invoke_test_setup_common
  export WORKSPACE="$TEST_TMPDIR/workspace"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
  export RALPH_PLAN_KEY="claude-graph-approval"
  export RALPH_GRAPH_NODE_ID="node-approval-1"
  export CLAUDE_PLAN_CLI="$BIN_DIR/claude"
  export CURSOR_PLAN_CLI="$BIN_DIR/cursor-agent"
  mkdir -p "$WORKSPACE/.claude" "$WORKSPACE/.cursor" "$WORKSPACE/.ralph-workspace"
  write_claude_help_stub empty-help
  write_cursor_help_stub empty-help
}

teardown() {
  run_plan_invoke_claude_graph_approval_restore success >/dev/null 2>&1 || true
  run_plan_invoke_cursor_graph_approval_restore success >/dev/null 2>&1 || true
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL CLAUDE_PLAN_CLI CURSOR_PLAN_CLI
  unset RALPH_PLAN_KEY RALPH_PLAN_WORKSPACE_ROOT
  run_plan_invoke_test_teardown_common
}

write_claude_help_stub() {
  local mode="${1:-empty-help}"
  local launched_marker="${2:-}"
  local argv_record="${3:-}"
  cat >"$BIN_DIR/claude" <<EOF
#!/usr/bin/env bash
if [[ -n "$argv_record" ]]; then
  printf '%s\n' "\$@" >>"$argv_record"
fi
if [[ "\$1" == "--help" || "\$1" == "help" || "\$1" == "-h" ]]; then
  if [[ "$mode" == "supported" ]]; then
    printf '%s\n' "Usage: claude" "  --permission-prompt-tool <name>" "Respond to the same pending tool permission request."
    exit 0
  fi
  if [[ "$mode" == "empty-help" ]]; then
    printf '%s\n' "Usage: claude" "  -p" "  --model"
    exit 0
  fi
  printf '%s\n' "unknown" >&2
  exit 2
fi
if [[ -n "$launched_marker" ]]; then
  printf 'launched\n' >"$launched_marker"
fi
printf '%s\n' "claude should not start a model during graph approval discovery" >&2
exit 3
EOF
  chmod +x "$BIN_DIR/claude"
}

write_cursor_help_stub() {
  local mode="${1:-empty-help}"
  local launched_marker="${2:-}"
  local argv_record="${3:-}"
  cat >"$BIN_DIR/cursor-agent" <<EOF
#!/usr/bin/env bash
if [[ -n "$argv_record" ]]; then
  printf '%s\n' "\$@" >>"$argv_record"
fi
if [[ "\$1" == "--help" || "\$1" == "help" || "\$1" == "-h" ]]; then
  if [[ "$mode" == "supported" ]]; then
    printf '%s\n' "Usage: cursor agent" "  --permission-prompt-tool <name>" "Respond to the same pending tool permission request."
    exit 0
  fi
  if [[ "$mode" == "force-help" ]]; then
    printf '%s\n' "Usage: cursor agent" "  -f, --force" "  --yolo" "  --auto-review" "  --approve-mcps"
    exit 0
  fi
  if [[ "$mode" == "empty-help" ]]; then
    printf '%s\n' "Usage: cursor agent" "  -p" "  --model"
    exit 0
  fi
  printf '%s\n' "unknown" >&2
  exit 2
fi
if [[ -n "$launched_marker" ]]; then
  printf 'launched\n' >"$launched_marker"
fi
printf '%s\n' "cursor should not start a model during graph approval discovery" >&2
exit 3
EOF
  chmod +x "$BIN_DIR/cursor-agent"
}

allow_request_json() {
  jq -nc \
    --arg decision "${1:-allow-run}" \
    --arg session "${2:-sess-1}" \
    --arg target "${3:-}" \
    '{
      decision: $decision,
      runtime: "claude",
      action: "Edit",
      resource: "src/app.ts",
      effect: "write",
      sessionId: $session
    } + (if $target == "" then {} else {target:$target} end)'
}

allow_cursor_request_json() {
  jq -nc \
    --arg decision "${1:-allow-run}" \
    --arg session "${2:-sess-1}" \
    --arg target "${3:-}" \
    '{
      decision: $decision,
      runtime: "cursor",
      action: "Edit",
      resource: "src/app.ts",
      effect: "write",
      sessionId: $session
    } + (if $target == "" then {} else {target:$target} end)'
}

@test "claude graph approval feature-detects live channel from cli help without a model call" {
  local launched="$TEST_TMPDIR/claude-launched"
  write_claude_help_stub supported "$launched"
  run run_plan_invoke_claude_graph_approval_live_supported "$BIN_DIR/claude"
  [ "$status" -eq 0 ]
  [ ! -f "$launched" ]
}

@test "claude graph approval reports live channel unsupported when help has no protocol surface" {
  local launched="$TEST_TMPDIR/claude-launched"
  write_claude_help_stub empty-help "$launched"
  run run_plan_invoke_claude_graph_approval_live_supported "$BIN_DIR/claude"
  [ "$status" -ne 0 ]
  [ ! -f "$launched" ]
  run _run_plan_invoke_claude_graph_approval_live_capability_missing "$BIN_DIR/claude"
  [ "$status" -eq 0 ]
  [[ "$output" == *"permission-prompt-tool"* ]]
}

@test "claude graph approval uses overlay fallback when live channel is unproved" {
  local json status
  write_claude_help_stub empty-help
  status=0
  json="$(run_plan_invoke_claude_graph_approval_start_or_fallback "$BIN_DIR/claude" "$(allow_request_json)")" || status=$?
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$json" | jq -r '.path')" = "overlay" ]
  [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.runtime')" = "claude" ]
}

@test "claude graph approval uses live channel only after nonbillable capability proof" {
  local launched="$TEST_TMPDIR/claude-launched"
  local settings="$WORKSPACE/.claude/settings.json"
  local json
  printf '%s' '{"original":true}' >"$settings"
  write_claude_help_stub supported "$launched"
  run run_plan_invoke_claude_graph_approval_start_or_fallback "$BIN_DIR/claude" "$(allow_request_json)"
  [ "$status" -eq 0 ]
  json="$output"
  [ "$(printf '%s' "$json" | jq -r '.path')" = "live" ]
  [ "$(printf '%s' "$json" | jq -r '.fallback')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.channel')" = "permission-prompt-tool" ]
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "true" ]
  [ ! -f "$launched" ]
  [ "$(cat "$settings")" = '{"original":true}' ]
}

@test "claude graph approval advertises only enforceable lifetimes" {
  local json
  write_claude_help_stub empty-help
  json="$(run_plan_invoke_claude_graph_approval_capabilities "$BIN_DIR/claude")"
  [ "$(printf '%s' "$json" | jq -r '.runtime')" = "claude" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.once')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.run')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("lifetime:always-policy") != null')" = "true" ]

  write_claude_help_stub supported
  json="$(run_plan_invoke_claude_graph_approval_capabilities "$BIN_DIR/claude")"
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
}

@test "claude graph approval applies once as a reversible project settings overlay" {
  local settings="$WORKSPACE/.claude/settings.json"
  local json
  printf '%s' '{"original":true}' >"$settings"
  json="$(run_plan_invoke_claude_graph_approval_apply "$(allow_request_json allow-once)")"
  [ "$(printf '%s' "$json" | jq -r '.path')" = "overlay" ]
  [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-once" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "once" ]
  [ "$(printf '%s' "$json" | jq -r '.equalOrNarrower')" = "true" ]
  [ "$(jq -r '.original' "$settings")" = "true" ]
  [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
  [ "$(jq -r '.permissions.deny | length' "$settings")" = "0" ]
}

@test "claude graph approval applies run as a reversible project settings overlay" {
  local settings="$WORKSPACE/.claude/settings.json"
  local json
  printf '%s' '{"original":true}' >"$settings"
  json="$(run_plan_invoke_claude_graph_approval_apply "$(allow_request_json allow-run sess-9)")"
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "run" ]
  [ "$(printf '%s' "$json" | jq -r '.continuation')" = "session" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionStrategy')" = "resume" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionId')" = "sess-9" ]
  [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
}

@test "claude graph approval applies project allow-always as a temporary overlay without ambient writes" {
  local settings="$WORKSPACE/.claude/settings.json"
  local json home_settings="$HOME/.claude/settings.json"
  local home_before=""
  printf '%s' '{"original":true}' >"$settings"
  if [[ -f "$home_settings" ]]; then
    home_before="$(cat "$home_settings")"
  fi
  json="$(run_plan_invoke_claude_graph_approval_apply "$(allow_request_json allow-always)")"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-always" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "run" ]
  [ "$(printf '%s' "$json" | jq -r '.path')" = "overlay" ]
  [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
  if [[ -n "$home_before" ]]; then
    [ "$(cat "$home_settings")" = "$home_before" ]
  else
    [ ! -f "$home_settings" ]
  fi
}

@test "claude graph approval deny takes precedence over allow" {
  local settings="$WORKSPACE/.claude/settings.json"
  local json
  printf '%s' '{"permissions":{"allow":["Edit(src/app.ts)"],"deny":[]}}' >"$settings"
  json="$(run_plan_invoke_claude_graph_approval_apply "$(jq -nc '{
    decision: "deny",
    runtime: "claude",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write"
  }')")"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "deny" ]
  [ "$(jq -r '.permissions.deny[]' "$settings")" = "Edit(src/app.ts)" ]
  [ "$(jq -r '.permissions.allow | index("Edit(src/app.ts)")' "$settings")" = "null" ]

  json="$(run_plan_invoke_claude_graph_approval_apply "$(allow_request_json allow-run)")"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-run" ]
  [ "$(jq -r '.permissions.deny[]' "$settings")" = "Edit(src/app.ts)" ]
  [ "$(jq -r '.permissions.allow | index("Edit(src/app.ts)")' "$settings")" = "null" ]
}

@test "claude graph approval resumes the same session when continuation is supported" {
  local json
  json="$(run_plan_invoke_claude_graph_approval_apply "$(allow_request_json allow-run sess-resume)")"
  [ "$(printf '%s' "$json" | jq -r '.continuation')" = "session" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionStrategy')" = "resume" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionId')" = "sess-resume" ]
}

@test "claude graph approval rejects an unsupported lifetime" {
  run run_plan_invoke_claude_graph_approval_apply "$(jq -nc '{
    decision: "allow-always",
    nativeDecision: "always-policy",
    runtime: "claude",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported"* || "$output" == *"lifetime"* ]]
}

@test "claude graph approval restores settings byte-exact on success denial failure and timeout" {
  local settings="$WORKSPACE/.claude/settings.json"
  local original='{"original":true,"hooks":{"PreToolUse":[]}}'
  local json reason restored
  for reason in success denial failure timeout; do
    printf '%s' "$original" >"$settings"
    json="$(run_plan_invoke_claude_graph_approval_apply "$(allow_request_json allow-run)")"
    [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
    [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
    restored="$(run_plan_invoke_claude_graph_approval_restore "$reason")"
    [ "$(printf '%s' "$restored" | jq -r '.restored')" = "true" ]
    [ "$(printf '%s' "$restored" | jq -r '.reason')" = "$reason" ]
    [ "$(cat "$settings")" = "$original" ]
  done
}

@test "claude graph approval restores settings on signal" {
  local settings="$WORKSPACE/.claude/settings.json"
  local original='{"original":true}'
  local script status_file request_file
  printf '%s' "$original" >"$settings"
  status_file="$WORKSPACE/signal-status"
  request_file="$WORKSPACE/request.json"
  script="$WORKSPACE/signal-child.sh"
  allow_request_json allow-run >"$request_file"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"
export WORKSPACE="$WORKSPACE"
export RALPH_PROJECT_ROOT="$WORKSPACE"
export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
export RALPH_PLAN_KEY="claude-graph-approval"
export RALPH_GRAPH_NODE_ID="node-approval-1"
export CLAUDE_PLAN_CLI="$BIN_DIR/claude"
export PATH="$BIN_DIR:\$PATH"
run_plan_invoke_claude_graph_approval_apply "\$(cat "$request_file")" >/dev/null
kill -TERM \$\$
echo still-running >"$status_file"
EOF
  chmod +x "$script"
  run bash "$script"
  [ "$status" -ne 0 ]
  [ ! -f "$status_file" ]
  [ "$(cat "$settings")" = "$original" ]
}

@test "claude graph approval refuses ambient user writes" {
  run run_plan_invoke_claude_graph_approval_apply "$(jq -nc --arg target "$HOME/.claude/settings.json" '{
    decision: "allow-once",
    runtime: "claude",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write",
    target: $target
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ambient"* ]]

  run run_plan_invoke_claude_graph_approval_apply "$(jq -nc '{
    decision: "allow-once",
    runtime: "claude",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write",
    fallback: "--dangerously-skip-permissions"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejects"* ]]
}

@test "claude graph approval leaves non-graph invoke unchanged" {
  local record="$TEST_TMPDIR/claude.args"
  local stdin_capture="$TEST_TMPDIR/claude.stdin"
  local settings="$WORKSPACE/.claude/settings.json"
  printf '%s' '{"original":true}' >"$settings"
  run_plan_invoke_test_write_stub "claude" "$record" "$stdin_capture"
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  export PROMPT="claude-nongraph-prompt"
  export RALPH_MODE=native
  export CLAUDE_PLAN_CLI="$BIN_DIR/claude"

  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [ "$(cat "$stdin_capture")" = "claude-nongraph-prompt" ]
  [[ "$(cat "$record")" != *"--permission-prompt-tool"* ]]
  [[ "$(cat "$record")" != *"permission-prompt-tool"* ]]
  [ "$(jq -r '.kind // empty' "$settings")" != "ralph-approval-overlay" ]
  [ "$(jq -r '.permissions.allow // [] | index("Edit(src/app.ts)")' "$settings")" = "null" ]
}

@test "claude graph approval apply is graph-only" {
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  run run_plan_invoke_claude_graph_approval_apply "$(allow_request_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"graph-only"* ]]
}

@test "cursor graph approval feature-detects live channel from cli help without a model call" {
  local launched="$TEST_TMPDIR/cursor-launched"
  write_cursor_help_stub supported "$launched"
  run run_plan_invoke_cursor_graph_approval_live_supported "$BIN_DIR/cursor-agent"
  [ "$status" -eq 0 ]
  [ ! -f "$launched" ]
}

@test "cursor graph approval reports live channel unsupported when help has no protocol surface" {
  local launched="$TEST_TMPDIR/cursor-launched"
  write_cursor_help_stub empty-help "$launched"
  run run_plan_invoke_cursor_graph_approval_live_supported "$BIN_DIR/cursor-agent"
  [ "$status" -ne 0 ]
  [ ! -f "$launched" ]
  run _run_plan_invoke_cursor_graph_approval_live_capability_missing "$BIN_DIR/cursor-agent"
  [ "$status" -eq 0 ]
  [[ "$output" == *"permission-prompt-tool"* ]]
}

@test "cursor graph approval does not treat force yolo or auto-review as a live channel" {
  local launched="$TEST_TMPDIR/cursor-launched"
  local json status
  write_cursor_help_stub force-help "$launched"
  run run_plan_invoke_cursor_graph_approval_live_supported "$BIN_DIR/cursor-agent"
  [ "$status" -ne 0 ]
  [ ! -f "$launched" ]
  status=0
  json="$(run_plan_invoke_cursor_graph_approval_start_or_fallback "$BIN_DIR/cursor-agent" "$(allow_cursor_request_json)")" || status=$?
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$json" | jq -r '.path')" = "overlay" ]
  [ "$(printf '%s' "$json" | jq -r '.runtime')" = "cursor" ]
  [ ! -f "$launched" ]
}

@test "cursor graph approval uses overlay fallback when live channel is unproved" {
  local json status
  write_cursor_help_stub empty-help
  status=0
  json="$(run_plan_invoke_cursor_graph_approval_start_or_fallback "$BIN_DIR/cursor-agent" "$(allow_cursor_request_json)")" || status=$?
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$json" | jq -r '.path')" = "overlay" ]
  [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.runtime')" = "cursor" ]
}

@test "cursor graph approval uses live channel only after nonbillable capability proof" {
  local launched="$TEST_TMPDIR/cursor-launched"
  local settings="$WORKSPACE/.cursor/cli.json"
  local json
  printf '%s' '{"original":true}' >"$settings"
  write_cursor_help_stub supported "$launched"
  run run_plan_invoke_cursor_graph_approval_start_or_fallback "$BIN_DIR/cursor-agent" "$(allow_cursor_request_json)"
  [ "$status" -eq 0 ]
  json="$output"
  [ "$(printf '%s' "$json" | jq -r '.path')" = "live" ]
  [ "$(printf '%s' "$json" | jq -r '.fallback')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.channel')" = "permission-prompt-tool" ]
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "true" ]
  [ ! -f "$launched" ]
  [ "$(cat "$settings")" = '{"original":true}' ]
}

@test "cursor graph approval advertises only enforceable lifetimes" {
  local json
  write_cursor_help_stub empty-help
  json="$(run_plan_invoke_cursor_graph_approval_capabilities "$BIN_DIR/cursor-agent")"
  [ "$(printf '%s' "$json" | jq -r '.runtime')" = "cursor" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.once')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.run')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("lifetime:always-policy") != null')" = "true" ]

  write_cursor_help_stub supported
  json="$(run_plan_invoke_cursor_graph_approval_capabilities "$BIN_DIR/cursor-agent")"
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
}

@test "cursor graph approval applies once as a reversible project cli.json overlay" {
  local settings="$WORKSPACE/.cursor/cli.json"
  local json
  printf '%s' '{"original":true}' >"$settings"
  json="$(run_plan_invoke_cursor_graph_approval_apply "$(allow_cursor_request_json allow-once)")"
  [ "$(printf '%s' "$json" | jq -r '.path')" = "overlay" ]
  [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-once" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "once" ]
  [ "$(printf '%s' "$json" | jq -r '.equalOrNarrower')" = "true" ]
  [ "$(jq -r '.original' "$settings")" = "true" ]
  [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
  [ "$(jq -r '.permissions.deny | length' "$settings")" = "0" ]
}

@test "cursor graph approval applies run as a reversible project cli.json overlay" {
  local settings="$WORKSPACE/.cursor/cli.json"
  local json
  printf '%s' '{"original":true}' >"$settings"
  json="$(run_plan_invoke_cursor_graph_approval_apply "$(allow_cursor_request_json allow-run sess-9)")"
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "run" ]
  [ "$(printf '%s' "$json" | jq -r '.continuation')" = "session" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionStrategy')" = "resume" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionId')" = "sess-9" ]
  [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
}

@test "cursor graph approval applies project allow-always as a temporary overlay without ambient writes" {
  local settings="$WORKSPACE/.cursor/cli.json"
  local json home_settings="$HOME/.cursor/cli-config.json"
  local home_before=""
  printf '%s' '{"original":true}' >"$settings"
  if [[ -f "$home_settings" ]]; then
    home_before="$(cat "$home_settings")"
  fi
  json="$(run_plan_invoke_cursor_graph_approval_apply "$(allow_cursor_request_json allow-always)")"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-always" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "run" ]
  [ "$(printf '%s' "$json" | jq -r '.path')" = "overlay" ]
  [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
  if [[ -n "$home_before" ]]; then
    [ "$(cat "$home_settings")" = "$home_before" ]
  else
    [ ! -f "$home_settings" ]
  fi
}

@test "cursor graph approval deny takes precedence over allow" {
  local settings="$WORKSPACE/.cursor/cli.json"
  local json
  printf '%s' '{"permissions":{"allow":["Edit(src/app.ts)"],"deny":[]}}' >"$settings"
  json="$(run_plan_invoke_cursor_graph_approval_apply "$(jq -nc '{
    decision: "deny",
    runtime: "cursor",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write"
  }')")"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "deny" ]
  [ "$(jq -r '.permissions.deny[]' "$settings")" = "Edit(src/app.ts)" ]
  [ "$(jq -r '.permissions.allow | index("Edit(src/app.ts)")' "$settings")" = "null" ]

  json="$(run_plan_invoke_cursor_graph_approval_apply "$(allow_cursor_request_json allow-run)")"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-run" ]
  [ "$(jq -r '.permissions.deny[]' "$settings")" = "Edit(src/app.ts)" ]
  [ "$(jq -r '.permissions.allow | index("Edit(src/app.ts)")' "$settings")" = "null" ]
}

@test "cursor graph approval resumes the same session when continuation is supported" {
  local json
  json="$(run_plan_invoke_cursor_graph_approval_apply "$(allow_cursor_request_json allow-run sess-resume)")"
  [ "$(printf '%s' "$json" | jq -r '.continuation')" = "session" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionStrategy')" = "resume" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionId')" = "sess-resume" ]
}

@test "cursor graph approval rejects an unsupported lifetime" {
  run run_plan_invoke_cursor_graph_approval_apply "$(jq -nc '{
    decision: "allow-always",
    nativeDecision: "always-policy",
    runtime: "cursor",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported"* || "$output" == *"lifetime"* ]]
}

@test "cursor graph approval restores cli.json byte-exact on success denial failure and timeout" {
  local settings="$WORKSPACE/.cursor/cli.json"
  local original='{"original":true,"hooks":{"PreToolUse":[]}}'
  local json reason restored
  for reason in success denial failure timeout; do
    printf '%s' "$original" >"$settings"
    json="$(run_plan_invoke_cursor_graph_approval_apply "$(allow_cursor_request_json allow-run)")"
    [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
    [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
    restored="$(run_plan_invoke_cursor_graph_approval_restore "$reason")"
    [ "$(printf '%s' "$restored" | jq -r '.restored')" = "true" ]
    [ "$(printf '%s' "$restored" | jq -r '.reason')" = "$reason" ]
    [ "$(cat "$settings")" = "$original" ]
  done
}

@test "cursor graph approval restores cli.json on signal" {
  local settings="$WORKSPACE/.cursor/cli.json"
  local original='{"original":true}'
  local script status_file request_file
  printf '%s' "$original" >"$settings"
  status_file="$WORKSPACE/signal-status"
  request_file="$WORKSPACE/request.json"
  script="$WORKSPACE/signal-child.sh"
  allow_cursor_request_json allow-run >"$request_file"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh"
export WORKSPACE="$WORKSPACE"
export RALPH_PROJECT_ROOT="$WORKSPACE"
export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
export RALPH_PLAN_KEY="cursor-graph-approval"
export RALPH_GRAPH_NODE_ID="node-approval-1"
export CURSOR_PLAN_CLI="$BIN_DIR/cursor-agent"
export PATH="$BIN_DIR:\$PATH"
run_plan_invoke_cursor_graph_approval_apply "\$(cat "$request_file")" >/dev/null
kill -TERM \$\$
echo still-running >"$status_file"
EOF
  chmod +x "$script"
  run bash "$script"
  [ "$status" -ne 0 ]
  [ ! -f "$status_file" ]
  [ "$(cat "$settings")" = "$original" ]
}

@test "cursor graph approval refuses ambient user writes" {
  run run_plan_invoke_cursor_graph_approval_apply "$(jq -nc --arg target "$HOME/.cursor/cli-config.json" '{
    decision: "allow-once",
    runtime: "cursor",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write",
    target: $target
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ambient"* ]]

  run run_plan_invoke_cursor_graph_approval_apply "$(jq -nc '{
    decision: "allow-once",
    runtime: "cursor",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write",
    fallback: "--force"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejects"* ]]

  run run_plan_invoke_cursor_graph_approval_apply "$(jq -nc '{
    decision: "allow-once",
    runtime: "cursor",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write",
    fallback: "--yolo"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejects"* ]]
}

@test "cursor graph approval leaves non-graph invoke unchanged" {
  local record="$TEST_TMPDIR/cursor.args"
  local settings="$WORKSPACE/.cursor/cli.json"
  printf '%s' '{"original":true}' >"$settings"
  run_plan_invoke_test_write_stub "cursor-agent" "$record"
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  export PROMPT="cursor-nongraph-prompt"
  export RALPH_MODE=native
  export CURSOR_PLAN_CLI="$BIN_DIR/cursor-agent"

  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  [[ "$(cat "$record")" == *"-p"* ]]
  [[ "$(cat "$record")" == *"--force"* ]]
  [[ "$(cat "$record")" == *"cursor-nongraph-prompt"* ]]
  [[ "$(cat "$record")" != *"--permission-prompt-tool"* ]]
  [[ "$(cat "$record")" != *"permission-prompt-tool"* ]]
  [ "$(jq -r '.kind // empty' "$settings")" != "ralph-approval-overlay" ]
  [ "$(jq -r '.permissions.allow // [] | index("Edit(src/app.ts)")' "$settings")" = "null" ]
  [ "$(cat "$settings")" = '{"original":true}' ]
}

@test "cursor graph approval apply is graph-only" {
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  run run_plan_invoke_cursor_graph_approval_apply "$(allow_cursor_request_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"graph-only"* ]]
}
