#!/usr/bin/env bats
# Live in-band permission approval for OpenCode plan runs.
#
# A denied permission ends an `opencode run` turn, and re-invoking costs a whole
# turn of re-reading. Attaching the run to a loopback `opencode serve` lets the
# runner answer the live request instead, so the agent continues in place.
#
# The serve transport underneath (SSE capture, decision mapping, reply POST) is
# covered by tests/bats/graph/graph-approval-opencode.bats. These tests cover
# only what the plan-run path adds: the gate, the operator prompt, and the
# request-by-request answering loop.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/run-plan-invoke-test-helper.bash"
source "$REPO_ROOT/bundle/.ralph/bash-lib/permission-classify.sh"
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  run_plan_invoke_test_setup_common
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  unset RALPH_LIVE_APPROVALS RALPH_PERMISSION_RESPONSE_DECISION
  export RALPH_OPENCODE_SERVE_REGISTRY="$TEST_TMPDIR/opencode-serve.sessions"
}

teardown() {
  unset RALPH_GRAPH_NODE_ID RALPH_GRAPH_APPROVAL
  unset RALPH_LIVE_APPROVALS RALPH_PERMISSION_RESPONSE_DECISION
  unset RALPH_OPENCODE_SERVE_REGISTRY
  run_plan_invoke_test_teardown_common
}

live_captured_request() {
  local session="${1:-ses-live}" request_id="${2:-perm-live}"
  jq -nc \
    --arg session "$session" \
    --arg request_id "$request_id" '{
      schemaVersion: 1,
      runtime: "opencode",
      session: $session,
      requestId: $request_id,
      permission: "external_directory",
      effect: "read",
      resource: "/tmp/scratch.txt",
      patterns: ["/tmp/*"],
      always: []
    }'
}

# --- gate ---

@test "live approvals are on for a graph node regardless of terminal" {
  export RALPH_GRAPH_NODE_ID="node-1"
  run run_plan_invoke_opencode_serve_enabled
  [ "$status" -eq 0 ]
}

@test "live approvals are on when a decision is pre-set for an unattended run" {
  export RALPH_PERMISSION_RESPONSE_DECISION=allow
  run run_plan_invoke_opencode_serve_enabled
  [ "$status" -eq 0 ]
}

@test "live approvals stay off with no operator to answer" {
  # No graph node, no pre-set decision, and bats has no controlling terminal:
  # nobody would ever see the prompt, so the run must take the fallback.
  run run_plan_invoke_opencode_serve_enabled
  [ "$status" -ne 0 ]
}

@test "live approvals honor an explicit off switch even when answerable" {
  export RALPH_PERMISSION_RESPONSE_DECISION=allow
  export RALPH_LIVE_APPROVALS=0
  run run_plan_invoke_opencode_serve_enabled
  [ "$status" -ne 0 ]
}

@test "live approvals off switch never overrides graph mode" {
  export RALPH_GRAPH_NODE_ID="node-1"
  export RALPH_LIVE_APPROVALS=0
  run run_plan_invoke_opencode_serve_enabled
  [ "$status" -eq 0 ]
}

@test "plan serve start refuses auto mode" {
  export RALPH_PERMISSION_RESPONSE_DECISION=allow
  run run_plan_invoke_opencode_serve_plan_start "opencode" --auto
  [ "$status" -eq 1 ]
  [[ "$output" == *"auto mode"* ]]
}

@test "plan serve start declines rather than fails when unavailable" {
  # Exit 2 is the "fall back to exit-and-resume" signal; exit 1 would abort the
  # invocation over a transport that is merely absent.
  export RALPH_PERMISSION_RESPONSE_DECISION=allow
  run run_plan_invoke_opencode_serve_plan_start "$TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}

# --- operator prompt ---

@test "live permission prompt names the classification, effect and resource" {
  run run_plan_invoke_opencode_live_permission_prompt "$(live_captured_request)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"external_directory"* ]]
  [[ "$output" == *"read"* ]]
  [[ "$output" == *"/tmp/scratch.txt"* ]]
  [[ "$output" == *"[y/N]"* ]]
  # The plan is still running; saying it paused would be a lie.
  [[ "$output" == *"not paused"* ]]
}

# --- answering ---

@test "an allowed live request replies once, not a standing grant" {
  export RALPH_PERMISSION_RESPONSE_DECISION=allow
  local sent="$TEST_TMPDIR/respond.args"
  run_plan_invoke_opencode_serve_respond() {
    printf '%s\n' "$2" >>"$sent"
    printf '{"resolved":true}\n'
  }
  printf '127.0.0.1\n' >"$TEST_TMPDIR/host"
  printf '4096\n' >"$TEST_TMPDIR/port"

  run run_plan_invoke_opencode_serve_answer_request "$TEST_TMPDIR" "$(live_captured_request)" 1
  [ "$status" -eq 0 ]
  [ "$output" = "once" ]
  [ "$(cat "$sent")" = "once" ]
  [ -f "$TEST_TMPDIR/requests/1/request.json" ]
  [ "$(jq -r '.requestId' "$TEST_TMPDIR/requests/1/request.json")" = "perm-live" ]
}

@test "a denied live request replies deny" {
  export RALPH_PERMISSION_RESPONSE_DECISION=deny
  local sent="$TEST_TMPDIR/respond.args"
  run_plan_invoke_opencode_serve_respond() {
    printf '%s\n' "$2" >>"$sent"
    printf '{"resolved":true}\n'
  }
  printf '127.0.0.1\n' >"$TEST_TMPDIR/host"
  printf '4096\n' >"$TEST_TMPDIR/port"

  run run_plan_invoke_opencode_serve_answer_request "$TEST_TMPDIR" "$(live_captured_request)" 1
  [ "$status" -eq 0 ]
  [ "$output" = "deny" ]
  [ "$(cat "$sent")" = "deny" ]
}

@test "an unanswerable live request is left to the runtime" {
  # No pre-set decision and no terminal: never silently record a deny, and never
  # block the watcher on a prompt nobody can see.
  local sent="$TEST_TMPDIR/respond.args"
  run_plan_invoke_opencode_serve_respond() {
    printf '%s\n' "$2" >>"$sent"
    printf '{"resolved":true}\n'
  }
  printf '127.0.0.1\n' >"$TEST_TMPDIR/host"
  printf '4096\n' >"$TEST_TMPDIR/port"

  run run_plan_invoke_opencode_serve_answer_request "$TEST_TMPDIR" "$(live_captured_request)" 1
  [ "$status" -ne 0 ]
  [ ! -s "$sent" ]
}

@test "the watcher answers every permission event in arrival order" {
  export RALPH_PERMISSION_RESPONSE_DECISION=allow
  local sent="$TEST_TMPDIR/respond.args"
  printf '127.0.0.1\n' >"$TEST_TMPDIR/host"
  printf '4096\n' >"$TEST_TMPDIR/port"

  _run_plan_invoke_opencode_serve_read_sse() {
    printf '%s\n' '{"type":"server.connected","properties":{}}'
    printf '%s\n' "$(jq -nc '{type:"permission.asked",properties:{sessionID:"ses-a",id:"perm-a",permission:"external_directory",metadata:{tool:"read",filepath:"/tmp/a.txt"},patterns:["/tmp/*"]}}')"
    printf '%s\n' 'not json at all'
    printf '%s\n' "$(jq -nc '{type:"permission.asked",properties:{sessionID:"ses-a",id:"perm-b",permission:"external_directory",metadata:{tool:"read",filepath:"/tmp/b.txt"},patterns:["/tmp/*"]}}')"
  }
  run_plan_invoke_opencode_serve_respond() {
    jq -r '.requestId' "$1/request.json" >>"$sent"
    printf '{"resolved":true}\n'
  }

  run run_plan_invoke_opencode_serve_watch_permissions "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$sent")" = "perm-a" ]
  [ "$(sed -n 2p "$sent")" = "perm-b" ]
  [ "$(wc -l <"$sent" | tr -d ' ')" = "2" ]
}

# --- invocation wiring ---

@test "an attached run passes --attach to opencode run" {
  local record="$TEST_TMPDIR/opencode.args"
  run_plan_invoke_test_write_stub opencode "$record"
  export OPENCODE_PLAN_CLI="$BIN_DIR/opencode"
  export PROMPT="live-approval-prompt"
  export RALPH_MODE=native
  local fake_serve_dir="$TEST_TMPDIR/serve"
  mkdir -p "$fake_serve_dir"
  printf '127.0.0.1\n' >"$fake_serve_dir/host"
  printf '4096\n' >"$fake_serve_dir/port"
  run_plan_invoke_opencode_serve_plan_start() { printf '%s\n' "$fake_serve_dir"; }
  run_plan_invoke_opencode_serve_watch_permissions() { :; }
  run_plan_invoke_opencode_serve_close() { :; }

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [[ "$(cat "$record")" == *"--attach"* ]]
  [[ "$(cat "$record")" == *"http://127.0.0.1:4096"* ]]
  [[ "$(cat "$record")" == *"live-approval-prompt"* ]]
}

@test "a graph node run never attaches its own serve" {
  # The graph scheduler owns a serve session for the node; a second server here
  # would take the run's permission events away from the one it waits on.
  local record="$TEST_TMPDIR/opencode.args"
  run_plan_invoke_test_write_stub opencode "$record"
  export OPENCODE_PLAN_CLI="$BIN_DIR/opencode"
  export PROMPT="graph-node-prompt"
  export RALPH_MODE=native
  export RALPH_GRAPH_NODE_ID="node-1"
  local started="$TEST_TMPDIR/plan-start-called"
  run_plan_invoke_opencode_serve_plan_start() { printf 'called\n' >"$started"; return 2; }

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [ ! -f "$started" ]
  [[ "$(cat "$record")" != *"--attach"* ]]
}

@test "an unattached run passes no --attach and starts no serve" {
  local record="$TEST_TMPDIR/opencode.args"
  run_plan_invoke_test_write_stub opencode "$record"
  export OPENCODE_PLAN_CLI="$BIN_DIR/opencode"
  export PROMPT="fallback-prompt"
  export RALPH_MODE=native

  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]
  [[ "$(cat "$record")" != *"--attach"* ]]
  [[ "$(cat "$record")" != *"serve"* ]]
  [[ "$(cat "$record")" == *"fallback-prompt"* ]]
}
