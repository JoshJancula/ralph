#!/usr/bin/env bats
# G03/G04: the preview-before-mutation confirmation gate for `graph run` and
# `graph resume`. Covers accept, decline, missing --yes, closed stdin,
# direct `graph-run.sh run`, graph-routed `ralph run --plan`, and resume.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

GRAPH_RUN_SH="$REPO_ROOT/bundle/.ralph/graph-run.sh"
PTY_EXEC="$REPO_ROOT/tests/bats/bin/ralph-pty-exec"

setup() {
  TMPD="$(mktemp -d)"
  BIN_DIR="$TMPD/bin"
  mkdir -p "$BIN_DIR"
  PROJECT="$TMPD/project"
  mkdir -p "$PROJECT/src" "$PROJECT/.ralph" "$PROJECT/.ralph-workspace"
  printf 'base\n' >"$PROJECT/src/app.txt"
  PLAN="$PROJECT/confirm.plan.md"
  DISPATCH_MARKER="$TMPD/dispatch.marker"
  unset GRAPH_PREFLIGHT_UNAVAILABLE
  unset GRAPH_PREFLIGHT_CLI_CLAUDE GRAPH_PREFLIGHT_CLI_CURSOR
  unset GRAPH_PREFLIGHT_CLI_CODEX GRAPH_PREFLIGHT_CLI_OPENCODE
  unset GRAPH_PREFLIGHT_CLI_ANTIGRAVITY
  unset GRAPH_RUNTIME_CAPABILITIES_PROBE
  unset RALPH_GRAPH_GIT_SANDBOX_PROVEN
  unset CLAUDE_PLAN_CLI CURSOR_PLAN_CLI CODEX_PLAN_CLI OPENCODE_PLAN_CLI ANTIGRAVITY_PLAN_CLI
  unset GRAPH_DISPATCH_ORCHESTRATOR RALPH_ALLOW_NESTED_RUNS
  PATH="$BIN_DIR:$PATH"
}

teardown() {
  chmod -R u+w "$TMPD" 2>/dev/null || true
  rm -rf "$TMPD"
}

write_cli_stub() {
  local path="$1" runtime="$2"
  cat >"$path" <<EOF
#!/bin/sh
case "\$1" in
  --help|help|-h)
    printf '%s\n' "Usage: $runtime" "  --permission-prompt-tool <name>"
    exit 0
    ;;
  auth)
    [ "\${2:-}" = "status" ] && { printf 'Logged in\n'; exit 0; }
    ;;
esac
exit 3
EOF
  chmod +x "$path"
  case "$runtime" in
    claude) export GRAPH_PREFLIGHT_CLI_CLAUDE="$path" ;;
    cursor) export GRAPH_PREFLIGHT_CLI_CURSOR="$path" ;;
    codex) export GRAPH_PREFLIGHT_CLI_CODEX="$path" ;;
    opencode) export GRAPH_PREFLIGHT_CLI_OPENCODE="$path" ;;
    antigravity) export GRAPH_PREFLIGHT_CLI_ANTIGRAVITY="$path" ;;
  esac
}

write_plan() {
  cat >"$PLAN" <<'PLAN'
---
name: confirm-test
namespace: confirm-test
execution: graph
pipeline:
  stages:
    - id: impl
      runtime: claude
      workspaceMode: snapshot
todos:
  - id: impl-1
    stage: impl
    content: do the work
    status: pending
---
PLAN
}

write_dispatch_stub() {
  cat >"$TMPD/orchestrator-stub.sh" <<EOF
#!/bin/sh
printf 'dispatched %s\n' "\$*" >>"$DISPATCH_MARKER"
echo "orchestrator stub must not start a model session" >&2
exit 3
EOF
  chmod +x "$TMPD/orchestrator-stub.sh"
  export GRAPH_DISPATCH_ORCHESTRATOR="$TMPD/orchestrator-stub.sh"
}

run_dir_count() {
  find "$PROJECT/.ralph-workspace/graph-runs/confirm-test" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

@test "decline at a TTY prints the preview and creates no run" {
  write_cli_stub "$BIN_DIR/claude" claude
  write_plan
  write_dispatch_stub

  run "$PTY_EXEC" bash "$GRAPH_RUN_SH" run "$PLAN" --workspace "$PROJECT" <<<"no"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Plan: $PLAN"* ]]
  [[ "$output" == *"Namespace: confirm-test"* ]]
  # The ROLE column was dropped with the removed role field.
  [[ "$output" == *"ID"*"RUNTIME"*"MODEL"*"WORKSPACE"* ]]
  [[ "$output" != *"ROLE"* ]]
  [[ "$output" == *"impl"*"claude"* ]]
  [[ "$output" == *"Confirmation id:"* ]]
  [[ "$output" == *"Command:"*"--workspace"*"$PROJECT"* ]]
  [[ "$output" == *'Type "run" to confirm'* ]]
  [[ "$output" == *"No run created; no command was run."* ]]

  [ "$(run_dir_count)" -eq 0 ]
  [ ! -f "$DISPATCH_MARKER" ]
}

@test "missing --yes with closed stdin (non-TTY) refuses without creating a run" {
  write_cli_stub "$BIN_DIR/claude" claude
  write_plan
  write_dispatch_stub

  run bash "$GRAPH_RUN_SH" run "$PLAN" --workspace "$PROJECT" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --yes"* ]]
  [ "$(run_dir_count)" -eq 0 ]
  [ ! -f "$DISPATCH_MARKER" ]
}

@test "closed stdin reaches a TTY prompt and declines without hanging" {
  write_cli_stub "$BIN_DIR/claude" claude
  write_plan
  write_dispatch_stub

  # The budget only has to separate "declined promptly" from "hung": a real
  # hang here waits on stdin forever, so any finite deadline catches it. 15s did
  # not survive the suite -- several files run in parallel, each forking dozens
  # of children, and this same test was measured at 8s under load 78 and past
  # 16s under load 120 -- which made a load spike look like a hang. The
  # dedicated deadline test below still pins the timeout mechanism itself.
  run env RALPH_PTY_TIMEOUT_SECONDS=90 "$PTY_EXEC" bash "$GRAPH_RUN_SH" run "$PLAN" --workspace "$PROJECT" </dev/null
  [ "$status" -ne 0 ]
  [ "$status" -ne 124 ]
  [[ "$output" == *"No run created; no command was run."* ]]
  [ "$(run_dir_count)" -eq 0 ]
  [ ! -f "$DISPATCH_MARKER" ]
}

@test "PTY helper terminates a stuck interactive child at its deadline" {
  run env RALPH_PTY_TIMEOUT_SECONDS=1 "$PTY_EXEC" sh -c 'trap "" TERM; sleep 30'
  [ "$status" -eq 124 ]
  [[ "$output" == *"timed out after 1s"* ]]
}

@test "accept at a TTY (typed run) invokes dispatch only after the preview is printed" {
  write_cli_stub "$BIN_DIR/claude" claude
  write_plan
  write_dispatch_stub

  [ ! -f "$DISPATCH_MARKER" ]
  run "$PTY_EXEC" bash "$GRAPH_RUN_SH" run "$PLAN" --workspace "$PROJECT" --max-parallel 1 <<<"run"
  [[ "$output" == *"Plan: $PLAN"* ]]
  [[ "$output" == *"ID"*"RUNTIME"*"MODEL"*"WORKSPACE"* ]]
  [[ "$output" == *"Confirmation id:"* ]]
  [[ "$output" == *"Command:"*"--namespace"*"confirm-test"*"--workspace"*"$PROJECT"*"--max-parallel"*"1"* ]]
  preview_line="$(printf '%s\n' "$output" | grep -n "^Confirmation id:" | head -1 | cut -d: -f1)"
  prompt_line="$(printf '%s\n' "$output" | grep -n 'Type "run" to confirm' | head -1 | cut -d: -f1)"
  [ -n "$preview_line" ]
  [ -n "$prompt_line" ]
  [ "$preview_line" -lt "$prompt_line" ]

  # The scheduler's own run banner (node dispatch) only appears after the
  # confirmation prompt line, proving dispatch happens after the preview
  # and typed confirmation, never before.
  banner_line="$(printf '%s\n' "$output" | grep -n "Node agents" | head -1 | cut -d: -f1)"
  [ -n "$banner_line" ]
  [ "$prompt_line" -lt "$banner_line" ]

  [ "$(run_dir_count)" -eq 1 ]
  [ -f "$DISPATCH_MARKER" ]
}

@test "accept via --yes with closed stdin proceeds without reading stdin" {
  write_cli_stub "$BIN_DIR/claude" claude
  write_plan
  write_dispatch_stub

  run bash "$GRAPH_RUN_SH" run "$PLAN" --workspace "$PROJECT" --yes </dev/null
  [[ "$output" == *"Operation: run (confirmed-noninteractive)"* ]]
  [[ "$output" == *"Confirmed non-interactively (--yes); proceeding."* ]]
  [[ "$output" == *"Command:"*"--workspace"*"$PROJECT"*"--yes"* ]]
  [ "$(run_dir_count)" -eq 1 ]
  [ -f "$DISPATCH_MARKER" ]
  run_file="$(find "$PROJECT/.ralph-workspace/graph-runs/confirm-test" -mindepth 2 -maxdepth 2 -name run.json | head -1)"
  [ "$(jq -r '.schemaVersion' "$run_file")" = "3" ]
  [[ "$(jq -r '.supervisorPid' "$run_file")" =~ ^[0-9]+$ ]]
}

@test "graph-run.sh run gates on confirmation and ralph run refuses a graph plan" {
  write_cli_stub "$BIN_DIR/claude" claude
  write_plan
  write_dispatch_stub

  # Direct invocation.
  run bash "$GRAPH_RUN_SH" run "$PLAN" --workspace "$PROJECT" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --yes"* ]]
  [ "$(run_dir_count)" -eq 0 ]

  # ralph run --plan now accepts leaf plans only; a graph plan is refused at the
  # boundary instead of being routed to graph-run.sh. Build a throwaway
  # RALPH_HOME shim the way install.sh writes one and confirm the refusal, so
  # the confirmation gate is reached only through the engine entrypoint above.
  home="$TMPD/ralph-home"
  mkdir -p "$home/bundle/.ralph"
  cp -R "$REPO_ROOT/bundle/.ralph/." "$home/bundle/.ralph/"
  shim="$TMPD/ralph-shim.sh"
  awk '
    /^  cat > "\$tmp" <<.SHIM.$/ { flag = 1; next }
    /^SHIM$/ { flag = 0 }
    flag { print }
  ' "$REPO_ROOT/install.sh" >"$shim"

  run env RALPH_HOME="$home" bash "$shim" run --plan "$PLAN" --workspace "$PROJECT" </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"leaf plans only"* ]]
  [[ "$output" == *"ralph workflow start --file"* ]]
  [ "$(run_dir_count)" -eq 0 ]

  # --yes does not buy past the boundary: a graph plan is still not a leaf plan,
  # so no run is created by this route at all.
  run env RALPH_HOME="$home" bash "$shim" run --plan "$PLAN" --workspace "$PROJECT" --yes </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"leaf plans only"* ]]
  [ "$(run_dir_count)" -eq 0 ]
}

@test "resume previews its retry set and gates on confirmation before touching the ledger" {
  write_cli_stub "$BIN_DIR/claude" claude
  write_plan
  write_dispatch_stub

  run bash "$GRAPH_RUN_SH" run "$PLAN" --workspace "$PROJECT" --yes </dev/null
  [ "$(run_dir_count)" -eq 1 ]
  run_dir="$(find "$PROJECT/.ralph-workspace/graph-runs/confirm-test" -mindepth 1 -maxdepth 1 -type d | head -1)"
  run_id="$(basename "$run_dir")"
  status_before="$(jq -r '.status' "$run_dir/run.json")"

  # graph-run.sh resume resolves roots from cwd (it has no --workspace flag,
  # unlike run/preflight/status); invoke it from inside the project, the
  # same way an operator would.
  cd "$PROJECT"

  # Missing --yes with closed stdin: refuse, ledger status untouched.
  run bash "$GRAPH_RUN_SH" resume "$PLAN" --namespace confirm-test --run "$run_id" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --yes"* ]]
  [ "$(jq -r '.status' "$run_dir/run.json")" = "$status_before" ]

  # Decline at a TTY: preview shows the retry set, ledger status untouched.
  run "$PTY_EXEC" bash "$GRAPH_RUN_SH" resume "$PLAN" --namespace confirm-test --run "$run_id" <<<"no"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Retry set:"* ]]
  [[ "$output" == *"impl"* ]]
  [[ "$output" == *"No run created; no command was run."* ]]
  [ "$(jq -r '.status' "$run_dir/run.json")" = "$status_before" ]

  # Accept via --yes: proceeds past confirmation (dispatch stub still
  # refuses to start a model, but the ledger is now advanced to running).
  run bash "$GRAPH_RUN_SH" resume "$PLAN" --namespace confirm-test --run "$run_id" --yes </dev/null
  [[ "$output" == *"Retry set:"* ]]
  [[ "$output" == *"Operation: resume (confirmed-noninteractive)"* ]]
  [[ "$output" == *"Command:"*"--namespace"*"confirm-test"*"--run"*"$run_id"*"--yes"* ]]
  [ -f "$run_dir/run.json" ]
}
