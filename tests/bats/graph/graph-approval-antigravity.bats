#!/usr/bin/env bats
# Antigravity graph permission bypass and resumable approval.
# Graph nodes omit --dangerously-skip-permissions unless an explicit trusted
# isolated-sandbox policy authorizes it. Approval uses proved native controls
# or the common overlay, surfaces awaiting-operator instead of hanging, and
# restores temporary config on every exit. Non-graph argv and exact model
# strings stay unchanged.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../run-plan/run-plan-invoke-test-helper.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-antigravity.sh"

setup() {
  run_plan_invoke_test_setup_common
  export WORKSPACE="$TEST_TMPDIR/workspace"
  export RALPH_PROJECT_ROOT="$WORKSPACE"
  export RALPH_AGENT_WORKSPACE="$WORKSPACE"
  export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
  export RALPH_PLAN_KEY="antigravity-graph-bypass"
  export RALPH_GRAPH_NODE_ID="node-approval-1"
  export ANTIGRAVITY_PLAN_CLI="$BIN_DIR/agy"
  export PROMPT="antigravity-graph-bypass-prompt"
  mkdir -p "$WORKSPACE/.ralph" "$WORKSPACE/.ralph-workspace" "$WORKSPACE/.agents"
  unset ANTIGRAVITY_PLAN_SKIP_PERMISSIONS
  unset RALPH_GRAPH_TRUSTED_ISOLATED_SANDBOX RALPH_GRAPH_PERMISSION_BYPASS
  unset RALPH_GRAPH_WORKSPACE_MODE RALPH_GRAPH_GIT_SANDBOX_PROVEN
  unset RALPH_GRAPH_NODE_POLICY RALPH_GRAPH_APPROVAL
  unset SELECTED_MODEL
}

teardown() {
  run_plan_invoke_antigravity_graph_approval_restore success >/dev/null 2>&1 || true
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL ANTIGRAVITY_PLAN_CLI
  unset ANTIGRAVITY_PLAN_SKIP_PERMISSIONS
  unset RALPH_GRAPH_TRUSTED_ISOLATED_SANDBOX RALPH_GRAPH_PERMISSION_BYPASS
  unset RALPH_GRAPH_WORKSPACE_MODE RALPH_GRAPH_GIT_SANDBOX_PROVEN
  unset RALPH_GRAPH_NODE_POLICY SELECTED_MODEL
  unset RALPH_PLAN_KEY RALPH_PLAN_WORKSPACE_ROOT
  run_plan_invoke_test_teardown_common
}

write_agy_stub() {
  local record="$1"
  cat >"$BIN_DIR/agy" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$record"
exit 0
EOF
  chmod +x "$BIN_DIR/agy"
}

write_agy_help_stub() {
  local mode="${1:-empty-help}"
  local launched_marker="${2:-}"
  local argv_record="${3:-}"
  cat >"$BIN_DIR/agy" <<EOF
#!/usr/bin/env bash
if [[ -n "$argv_record" ]]; then
  printf '%s\n' "\$@" >>"$argv_record"
fi
if [[ "\$1" == "--help" || "\$1" == "help" || "\$1" == "-h" ]]; then
  if [[ "$mode" == "supported" ]]; then
    printf '%s\n' "Usage: agy" "  --permission-prompt-tool <name>" "Respond to the same pending tool permission request."
    exit 0
  fi
  if [[ "$mode" == "skip-only" ]]; then
    printf '%s\n' "Usage: agy" "  --dangerously-skip-permissions" "  --mode accept-edits" "  --sandbox"
    exit 0
  fi
  if [[ "$mode" == "empty-help" ]]; then
    printf '%s\n' "Usage: agy" "  --print" "  --model"
    exit 0
  fi
  printf '%s\n' "unknown" >&2
  exit 2
fi
if [[ -n "$launched_marker" ]]; then
  printf 'launched\n' >"$launched_marker"
fi
printf '%s\n' "agy should not start a model during graph approval discovery" >&2
exit 3
EOF
  chmod +x "$BIN_DIR/agy"
}

allow_request_json() {
  jq -nc \
    --arg decision "${1:-allow-run}" \
    --arg session "${2:-sess-1}" \
    --arg target "${3:-}" \
    '{
      decision: $decision,
      runtime: "antigravity",
      action: "Edit",
      resource: "src/app.ts",
      effect: "write",
      sessionId: $session
    } + (if $target == "" then {} else {target:$target} end)'
}

@test "antigravity graph bypass omits dangerously-skip-permissions by default" {
  local record="$TEST_TMPDIR/agy.args"
  write_agy_stub "$record"

  run run_plan_invoke_antigravity_should_skip_permissions
  [ "$status" -ne 0 ]
  run run_plan_invoke_antigravity_trusted_isolated_sandbox_authorized
  [ "$status" -ne 0 ]

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  ! grep -Fxq -- "--dangerously-skip-permissions" "$record"
  grep -Fxq -- "--print" "$record"
  grep -Fxq -- "antigravity-graph-bypass-prompt" "$record"
}

@test "antigravity graph bypass does not treat skip-permissions default as authorization" {
  local record="$TEST_TMPDIR/agy-default.args"
  write_agy_stub "$record"
  export RALPH_GRAPH_WORKSPACE_MODE="snapshot"
  export ANTIGRAVITY_PLAN_SKIP_PERMISSIONS=1

  run run_plan_invoke_antigravity_should_skip_permissions
  [ "$status" -ne 0 ]
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--dangerously-skip-permissions" "$record"
}

@test "antigravity graph bypass omits skip-permissions on shared workspace even with explicit policy" {
  local record="$TEST_TMPDIR/agy-shared.args"
  write_agy_stub "$record"
  export RALPH_GRAPH_WORKSPACE_MODE="shared"
  export RALPH_GRAPH_TRUSTED_ISOLATED_SANDBOX=1

  run run_plan_invoke_antigravity_isolated_sandbox
  [ "$status" -ne 0 ]
  run run_plan_invoke_antigravity_trusted_isolated_sandbox_authorized
  [ "$status" -ne 0 ]
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--dangerously-skip-permissions" "$record"
}

@test "antigravity graph bypass omits skip-permissions on snapshot without explicit policy" {
  local record="$TEST_TMPDIR/agy-snapshot.args"
  write_agy_stub "$record"
  export RALPH_GRAPH_WORKSPACE_MODE="snapshot"

  run run_plan_invoke_antigravity_isolated_sandbox
  [ "$status" -eq 0 ]
  run run_plan_invoke_antigravity_trusted_isolated_sandbox_policy
  [ "$status" -ne 0 ]
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--dangerously-skip-permissions" "$record"
}

@test "antigravity graph bypass admits skip-permissions when trusted isolated-sandbox policy authorizes snapshot" {
  local record="$TEST_TMPDIR/agy-trusted-snapshot.args"
  write_agy_stub "$record"
  export RALPH_GRAPH_WORKSPACE_MODE="snapshot"
  export RALPH_GRAPH_TRUSTED_ISOLATED_SANDBOX=1

  run run_plan_invoke_antigravity_trusted_isolated_sandbox_authorized
  [ "$status" -eq 0 ]
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--dangerously-skip-permissions" "$record"
}

@test "antigravity graph bypass admits skip-permissions from node policy trustedIsolatedSandbox" {
  local record="$TEST_TMPDIR/agy-policy.args"
  write_agy_stub "$record"
  export RALPH_GRAPH_NODE_POLICY='{"parentWorkspaceMode":"snapshot","trustedIsolatedSandbox":true}'
  unset RALPH_GRAPH_WORKSPACE_MODE

  run run_plan_invoke_antigravity_trusted_isolated_sandbox_authorized
  [ "$status" -eq 0 ]
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--dangerously-skip-permissions" "$record"
}

@test "antigravity graph bypass admits skip-permissions when trusted isolated-sandbox policy authorizes proved worktree" {
  local record="$TEST_TMPDIR/agy-worktree.args"
  write_agy_stub "$record"
  export RALPH_GRAPH_WORKSPACE_MODE="worktree"
  export RALPH_GRAPH_GIT_SANDBOX_PROVEN=1
  export RALPH_GRAPH_PERMISSION_BYPASS="trusted-isolated-sandbox"

  run run_plan_invoke_antigravity_trusted_isolated_sandbox_authorized
  [ "$status" -eq 0 ]
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--dangerously-skip-permissions" "$record"
}

@test "antigravity graph bypass rejects worktree without proved sandbox" {
  local record="$TEST_TMPDIR/agy-unproved.args"
  write_agy_stub "$record"
  export RALPH_GRAPH_WORKSPACE_MODE="worktree"
  unset RALPH_GRAPH_GIT_SANDBOX_PROVEN
  export RALPH_GRAPH_TRUSTED_ISOLATED_SANDBOX=1

  run run_plan_invoke_antigravity_isolated_sandbox
  [ "$status" -ne 0 ]
  run run_plan_invoke_antigravity_trusted_isolated_sandbox_authorized
  [ "$status" -ne 0 ]
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--dangerously-skip-permissions" "$record"
}

@test "antigravity graph bypass honors ANTIGRAVITY_PLAN_SKIP_PERMISSIONS=0 even when policy authorizes" {
  local record="$TEST_TMPDIR/agy-optout.args"
  write_agy_stub "$record"
  export RALPH_GRAPH_WORKSPACE_MODE="snapshot"
  export RALPH_GRAPH_TRUSTED_ISOLATED_SANDBOX=1
  export ANTIGRAVITY_PLAN_SKIP_PERMISSIONS=0

  run run_plan_invoke_antigravity_should_skip_permissions
  [ "$status" -ne 0 ]
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  ! grep -Fxq -- "--dangerously-skip-permissions" "$record"
}

@test "antigravity graph bypass leaves non-graph invoke unchanged" {
  local record="$TEST_TMPDIR/agy-nongraph.args"
  write_agy_stub "$record"
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  unset RALPH_GRAPH_WORKSPACE_MODE RALPH_GRAPH_TRUSTED_ISOLATED_SANDBOX
  export PROMPT="antigravity-nongraph-prompt"
  export RALPH_MODE=native

  run run_plan_invoke_antigravity_graph_enabled
  [ "$status" -ne 0 ]
  run run_plan_invoke_antigravity_should_skip_permissions
  [ "$status" -eq 0 ]
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  grep -Fxq -- "--print" "$record"
  grep -Fxq -- "antigravity-nongraph-prompt" "$record"
  grep -Fxq -- "--dangerously-skip-permissions" "$record"
  grep -Fxq -- "--output-format" "$record"
  grep -Fxq -- "stream-json" "$record"
}

@test "antigravity graph bypass preserves exact model display strings" {
  local record="$TEST_TMPDIR/agy-model.args"
  write_agy_stub "$record"
  export SELECTED_MODEL="Claude Sonnet 4.6 (thinking)"

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--model" "$record"
  grep -Fxq -- "Claude Sonnet 4.6 (thinking)" "$record"
  ! grep -Fxq -- "--dangerously-skip-permissions" "$record"
  ! grep -Eiq -- 'claude-sonnet|sonnet-4' "$record"
}

@test "antigravity graph approval feature-detects live channel from cli help without a model call" {
  local launched="$TEST_TMPDIR/agy-launched"
  write_agy_help_stub supported "$launched"
  run run_plan_invoke_antigravity_graph_approval_live_supported "$BIN_DIR/agy"
  [ "$status" -eq 0 ]
  [ ! -f "$launched" ]
}

@test "antigravity graph approval reports live channel unsupported when help has no protocol surface" {
  local launched="$TEST_TMPDIR/agy-launched"
  write_agy_help_stub empty-help "$launched"
  run run_plan_invoke_antigravity_graph_approval_live_supported "$BIN_DIR/agy"
  [ "$status" -ne 0 ]
  [ ! -f "$launched" ]
  run _run_plan_invoke_antigravity_graph_approval_live_capability_missing "$BIN_DIR/agy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"permission-prompt-tool"* ]]
}

@test "antigravity graph approval does not treat dangerously-skip-permissions as native live control" {
  local launched="$TEST_TMPDIR/agy-launched"
  write_agy_help_stub skip-only "$launched"
  run run_plan_invoke_antigravity_graph_approval_live_supported "$BIN_DIR/agy"
  [ "$status" -ne 0 ]
  [ ! -f "$launched" ]
}

@test "antigravity graph approval uses overlay fallback when live channel is unproved" {
  local json status
  write_agy_help_stub empty-help
  status=0
  json="$(run_plan_invoke_antigravity_graph_approval_start_or_fallback "$BIN_DIR/agy" "$(allow_request_json)")" || status=$?
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$json" | jq -r '.path')" = "overlay" ]
  [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.runtime')" = "antigravity" ]
}

@test "antigravity graph approval uses live channel only after nonbillable capability proof" {
  local launched="$TEST_TMPDIR/agy-launched"
  local settings="$WORKSPACE/.agents/settings.json"
  local json
  printf '%s' '{"original":true}' >"$settings"
  write_agy_help_stub supported "$launched"
  run run_plan_invoke_antigravity_graph_approval_start_or_fallback "$BIN_DIR/agy" "$(allow_request_json)"
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

@test "antigravity graph approval advertises only enforceable lifetimes" {
  local json
  write_agy_help_stub empty-help
  json="$(run_plan_invoke_antigravity_graph_approval_capabilities "$BIN_DIR/agy")"
  [ "$(printf '%s' "$json" | jq -r '.runtime')" = "antigravity" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionContinuation')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.sameOperationResponse')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.once')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes.run')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
  [ "$(printf '%s' "$json" | jq -r '.unsupported | index("lifetime:always-policy") != null')" = "true" ]

  write_agy_help_stub supported
  json="$(run_plan_invoke_antigravity_graph_approval_capabilities "$BIN_DIR/agy")"
  [ "$(printf '%s' "$json" | jq -r '.liveRequestStreaming')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetimes["always-policy"]')" = "false" ]
}

@test "antigravity graph approval applies once as a reversible project settings overlay" {
  local settings="$WORKSPACE/.agents/settings.json"
  local json
  printf '%s' '{"original":true}' >"$settings"
  json="$(run_plan_invoke_antigravity_graph_approval_apply "$(allow_request_json allow-once)")"
  [ "$(printf '%s' "$json" | jq -r '.path')" = "overlay" ]
  [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-once" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "once" ]
  [ "$(printf '%s' "$json" | jq -r '.equalOrNarrower')" = "true" ]
  [ "$(jq -r '.original' "$settings")" = "true" ]
  [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
  [ "$(jq -r '.permissions.deny | length' "$settings")" = "0" ]
}

@test "antigravity graph approval applies run as a reversible project settings overlay" {
  local settings="$WORKSPACE/.agents/settings.json"
  local json
  printf '%s' '{"original":true}' >"$settings"
  json="$(run_plan_invoke_antigravity_graph_approval_apply "$(allow_request_json allow-run sess-9)")"
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "run" ]
  [ "$(printf '%s' "$json" | jq -r '.continuation')" = "session" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionStrategy')" = "resume" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionId')" = "sess-9" ]
  [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
}

@test "antigravity graph approval applies project allow-always as a temporary overlay without ambient writes" {
  local settings="$WORKSPACE/.agents/settings.json"
  local json home_settings="$HOME/.agents/settings.json"
  local home_before=""
  printf '%s' '{"original":true}' >"$settings"
  if [[ -f "$home_settings" ]]; then
    home_before="$(cat "$home_settings")"
  fi
  json="$(run_plan_invoke_antigravity_graph_approval_apply "$(allow_request_json allow-always)")"
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

@test "antigravity graph approval deny takes precedence over allow" {
  local settings="$WORKSPACE/.agents/settings.json"
  local json
  printf '%s' '{"permissions":{"allow":["Edit(src/app.ts)"],"deny":[]}}' >"$settings"
  json="$(run_plan_invoke_antigravity_graph_approval_apply "$(jq -nc '{
    decision: "deny",
    runtime: "antigravity",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write"
  }')")"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "deny" ]
  [ "$(printf '%s' "$json" | jq -r '.lifetime')" = "deny" ]
  [ "$(jq -r '.permissions.deny[]' "$settings")" = "Edit(src/app.ts)" ]
  [ "$(jq -r '.permissions.allow | index("Edit(src/app.ts)")' "$settings")" = "null" ]

  json="$(run_plan_invoke_antigravity_graph_approval_apply "$(allow_request_json allow-run)")"
  [ "$(printf '%s' "$json" | jq -r '.decision')" = "allow-run" ]
  [ "$(jq -r '.permissions.deny[]' "$settings")" = "Edit(src/app.ts)" ]
  [ "$(jq -r '.permissions.allow | index("Edit(src/app.ts)")' "$settings")" = "null" ]
}

@test "antigravity graph approval resumes the same session when continuation is supported" {
  local json
  json="$(run_plan_invoke_antigravity_graph_approval_apply "$(allow_request_json allow-run sess-resume)")"
  [ "$(printf '%s' "$json" | jq -r '.continuation')" = "session" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionStrategy')" = "resume" ]
  [ "$(printf '%s' "$json" | jq -r '.sessionId')" = "sess-resume" ]
}

@test "antigravity graph approval rejects an unsupported lifetime" {
  run run_plan_invoke_antigravity_graph_approval_apply "$(jq -nc '{
    decision: "allow-always",
    nativeDecision: "always-policy",
    runtime: "antigravity",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported"* || "$output" == *"lifetime"* ]]
}

@test "antigravity graph approval restores settings byte-exact on success denial failure and timeout" {
  local settings="$WORKSPACE/.agents/settings.json"
  local original='{"original":true,"hooks":{"PreToolUse":[]}}'
  local json reason restored
  for reason in success denial failure timeout; do
    printf '%s' "$original" >"$settings"
    json="$(run_plan_invoke_antigravity_graph_approval_apply "$(allow_request_json allow-run)")"
    [ "$(printf '%s' "$json" | jq -r '.applied')" = "true" ]
    [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
    restored="$(run_plan_invoke_antigravity_graph_approval_restore "$reason")"
    [ "$(printf '%s' "$restored" | jq -r '.restored')" = "true" ]
    [ "$(printf '%s' "$restored" | jq -r '.reason')" = "$reason" ]
    [ "$(cat "$settings")" = "$original" ]
  done
}

@test "antigravity graph approval restores settings on signal" {
  local settings="$WORKSPACE/.agents/settings.json"
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
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-antigravity.sh"
export WORKSPACE="$WORKSPACE"
export RALPH_PROJECT_ROOT="$WORKSPACE"
export RALPH_PLAN_WORKSPACE_ROOT="$WORKSPACE/.ralph-workspace"
export RALPH_PLAN_KEY="antigravity-graph-bypass"
export RALPH_GRAPH_NODE_ID="node-approval-1"
export ANTIGRAVITY_PLAN_CLI="$BIN_DIR/agy"
export PATH="$BIN_DIR:\$PATH"
run_plan_invoke_antigravity_graph_approval_apply "\$(cat "$request_file")" >/dev/null
kill -TERM \$\$
echo still-running >"$status_file"
EOF
  chmod +x "$script"
  run bash "$script"
  [ "$status" -ne 0 ]
  [ ! -f "$status_file" ]
  [ "$(cat "$settings")" = "$original" ]
}

@test "antigravity graph approval refuses ambient user writes" {
  run run_plan_invoke_antigravity_graph_approval_apply "$(jq -nc --arg target "$HOME/.agents/settings.json" '{
    decision: "allow-once",
    runtime: "antigravity",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write",
    target: $target
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ambient"* ]]

  run run_plan_invoke_antigravity_graph_approval_apply "$(jq -nc --arg target "$HOME/.gemini/settings.json" '{
    decision: "allow-once",
    runtime: "antigravity",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write",
    target: $target
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ambient"* ]]

  run run_plan_invoke_antigravity_graph_approval_apply "$(jq -nc '{
    decision: "allow-once",
    runtime: "antigravity",
    action: "Edit",
    resource: "src/app.ts",
    effect: "write",
    fallback: "--dangerously-skip-permissions"
  }')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejects"* ]]
}

@test "antigravity graph approval surfaces awaiting-operator instead of hanging" {
  local launched="$TEST_TMPDIR/agy-launched"
  local json status
  write_agy_help_stub empty-help "$launched"
  status=0
  json="$(run_plan_invoke_antigravity_graph_approval_start_or_fallback "$BIN_DIR/agy")" || status=$?
  [ "$status" -eq 4 ]
  [ "$(printf '%s' "$json" | jq -r '.path')" = "awaiting-operator" ]
  [ "$(printf '%s' "$json" | jq -r '.status')" = "awaiting-operator" ]
  [ "$(printf '%s' "$json" | jq -r '.classification')" = "operator-permission" ]
  [ "$(printf '%s' "$json" | jq -r '.operatorAction')" = "await-operator" ]
  [ "$(printf '%s' "$json" | jq -r '.exitCode')" = "4" ]
  [ "$(printf '%s' "$json" | jq -r '.permissionRequest.decision')" = "pending" ]
  [ "$(printf '%s' "$json" | jq -r '.permissionRequest | type')" = "object" ]
  [ ! -f "$launched" ]
}

@test "antigravity graph approval restores temporary config on invoke exit" {
  local settings="$WORKSPACE/.agents/settings.json"
  local original='{"original":true}'
  local record="$TEST_TMPDIR/agy-restore.args"
  printf '%s' "$original" >"$settings"
  write_agy_stub "$record"
  run_plan_invoke_antigravity_graph_approval_apply "$(allow_request_json allow-run)" >/dev/null
  [ "$(jq -r '.permissions.allow[]' "$settings")" = "Edit(src/app.ts)" ]
  unset ANTIGRAVITY_CONFIG
  export PROMPT="antigravity-approval-restore-prompt"
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  [ "$(cat "$settings")" = "$original" ]
  [ -z "${ANTIGRAVITY_CONFIG:-}" ]
}

@test "antigravity graph approval leaves non-graph invoke unchanged" {
  local record="$TEST_TMPDIR/agy-nongraph-approval.args"
  local settings="$WORKSPACE/.agents/settings.json"
  printf '%s' '{"original":true}' >"$settings"
  write_agy_stub "$record"
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  export PROMPT="antigravity-nongraph-approval-prompt"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  [ -s "$record" ]
  grep -Fxq -- "--print" "$record"
  grep -Fxq -- "antigravity-nongraph-approval-prompt" "$record"
  grep -Fxq -- "--dangerously-skip-permissions" "$record"
  [ "$(jq -r '.kind // empty' "$settings")" != "ralph-approval-overlay" ]
  [ "$(jq -r '.permissions.allow // [] | index("Edit(src/app.ts)")' "$settings")" = "null" ]
}

@test "antigravity graph approval apply is graph-only" {
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  run run_plan_invoke_antigravity_graph_approval_apply "$(allow_request_json)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"graph-only"* ]]
}

@test "antigravity graph approval preserves exact model display strings" {
  local record="$TEST_TMPDIR/agy-approval-model.args"
  write_agy_stub "$record"
  export SELECTED_MODEL="Claude Sonnet 4.6 (thinking)"
  export PROMPT="antigravity-approval-model-prompt"

  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]
  grep -Fxq -- "--model" "$record"
  grep -Fxq -- "Claude Sonnet 4.6 (thinking)" "$record"
  ! grep -Fxq -- "--dangerously-skip-permissions" "$record"
  ! grep -Eiq -- 'claude-sonnet|sonnet-4' "$record"
}

@test "cross-runtime fake-adapter permission normalization asserts exact action resource choices" {
  # Antigravity destination for normalize-other-runtime-permissions.
  write_agy_help_stub empty-help
  export ANTIGRAVITY_PLAN_CLI="$BIN_DIR/agy"

  run run_plan_invoke_antigravity_graph_approval_parse_permission "$(jq -nc '{
    sessionId: "ses-agy",
    nativeRequestId: "req-agy",
    tool: "Edit",
    action: "edit",
    resource: "src/app.ts",
    effect: "write"
  }')"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.actionable')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.runtime')" = "antigravity" ]
  [ "$(printf '%s' "$output" | jq -r '.sessionId')" = "ses-agy" ]
  [ "$(printf '%s' "$output" | jq -r '.nativeRequestId')" = "req-agy" ]
  [ "$(printf '%s' "$output" | jq -r '.tool')" = "edit" ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "edit" ]
  [ "$(printf '%s' "$output" | jq -r '.resource')" = "src/app.ts" ]
  [ "$(printf '%s' "$output" | jq -r '.effect')" = "write" ]
  [ "$(printf '%s' "$output" | jq -c '.choices')" = '["allow-once","allow-run","deny"]' ]
  [ "$(printf '%s' "$output" | jq -c '.lifetimes')" = '["once","run"]' ]
  [ "$(printf '%s' "$output" | jq -r '.choices | index("allow-always")')" = "null" ]
  [ "$(printf '%s' "$output" | jq -r '.lifetimes | index("always-policy")')" = "null" ]

  run run_plan_invoke_antigravity_graph_approval_parse_permission '{"tool":"permission","action":"permission","effect":"write"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.actionable')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.classification')" = "unknown" ]
}
