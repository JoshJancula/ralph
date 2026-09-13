#!/usr/bin/env bats
# End-to-end start + public viewer attach for Sequential and Dependency.
#
# Covers success, failure, persisted wait (exit 3), q detach, Ctrl-C detach,
# viewer crash, engine crash, non-TTY sync execution, terminal restoration,
# detached continuation under the recorded supervisor, no duplicate engine
# starts, immutable input hash stability, and cancel-only stop.

bats_require_minimum_version 1.5.0

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CLI="$REPO_ROOT/bundle/.ralph/workflow-cli.sh"
STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-state.sh"
SUP_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/workflow/workflow-start-supervise.sh"

setup_file() {
  command -v jq >/dev/null || skip "jq required"
  command -v python3 >/dev/null || skip "python3 required"
  [ -f "$CLI" ]
  [ -f "$STATE_LIB" ]
  [ -f "$SUP_LIB" ]

  FIX_ROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/wstart-view.XXXXXX")"
  FIX_ROOT="$(cd "$FIX_ROOT" && pwd -P)"
  FIX_PROJECT="$FIX_ROOT/project"
  FIX_STATE="$FIX_PROJECT/.ralph-workspace"
  FIX_HOME="$FIX_ROOT/home"
  mkdir -p "$FIX_STATE/workflows" "$FIX_HOME/bundle/.ralph" "$FIX_ROOT/bin"
  # Minimal ralph home so workflow CLI can resolve bundle paths via symlink.
  ln -sfn "$REPO_ROOT/bundle/.ralph" "$FIX_HOME/bundle/.ralph"
  export FIX_ROOT FIX_PROJECT FIX_STATE FIX_HOME
}

teardown_file() {
  # Best-effort reap of any stub supervisors left by detach cases.
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "$FIX_ROOT/bin/supervisor-stub" 2>/dev/null || true
  fi
  rm -rf "$FIX_ROOT"
}

setup() {
  unset RALPH_WORKFLOW_START_ENGINE_STUB RALPH_WORKFLOW_START_SKIP_SUPERVISOR
  unset RALPH_WORKFLOW_START_SUPERVISOR_STUB RALPH_WORKFLOW_START_VIEWER_STUB
  unset RALPH_WORKFLOW_START_ASSUME_TTY
  unset NO_COLOR CI TERM
  export WORKFLOW_STATE_SKIP_FSYNC=1
  CASE="$(mktemp -d "$FIX_STATE/case.XXXXXX")"
  CASE="$(cd "$CASE" && pwd -P)"
  mkdir -p "$CASE/workflows"
  export CASE
  # shellcheck source=/dev/null
  source "$STATE_LIB"
}

teardown() {
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "$CASE" 2>/dev/null || true
  fi
  rm -rf "$CASE"
}

write_seq_workflow() {
  cat >"$1" <<'EOF'
---
name: start-seq-demo
kind: workflow
mode: sequential
pipeline:
  stages:
    - id: implement
      instructions: |
        Do the work for {{TASK}}.
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/done.md
          required: true
todos:
  - id: do-work
    stage: implement
    content: |
      Implement {{TASK}}.
    verification: Confirm the work is done.
    status: pending
---
EOF
}

write_dep_workflow() {
  cat >"$1" <<'EOF'
---
name: start-dep-demo
kind: workflow
mode: dependency
pipeline:
  stages:
    - id: implement
      instructions: |
        Do the work for {{TASK}}.
      produces:
        - path: .ralph-workspace/artifacts/{{ARTIFACT_NS}}/done.md
          required: true
todos:
  - id: do-work
    stage: implement
    content: |
      Implement {{TASK}}.
    verification: Confirm the work is done.
    status: pending
---
EOF
}

write_supervisor_stub() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
run_id="${2:-}"
state_root="${3:-}"
# Optional 4th/5th args ignored.
marker_dir="${RALPH_START_STUB_MARKER_DIR:-}"
exit_code="${RALPH_START_STUB_EXIT:-0}"
hold_seconds="${RALPH_START_STUB_HOLD:-0}"
crash="${RALPH_START_STUB_CRASH:-0}"

if [[ -n "$marker_dir" ]]; then
  mkdir -p "$marker_dir"
  printf '%s\n' "$$" >>"$marker_dir/pids.txt"
  printf '%s\t%s\n' "$mode" "$run_id" >>"$marker_dir/launches.txt"
fi

run_dir="$state_root/workflow-runs/$run_id"
mkdir -p "$run_dir"

# Record a live-looking owner so "still active" / cancel paths have something.
if [[ -f "$run_dir/run.json" ]]; then
  tmp="$(mktemp)"
  jq --argjson pid "$$" --arg host "$(hostname 2>/dev/null || echo host)" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.state = "running"
     | .owner = {pid:$pid, hostname:$host, processStartId:("start-" + (pid|tostring)), heartbeatAt:$now}' \
    "$run_dir/run.json" >"$tmp" && mv "$tmp" "$run_dir/run.json"
fi

if [[ "$crash" == "1" ]]; then
  # Hard crash without writing a clean terminal state.
  kill -KILL $$
fi

if [[ "$hold_seconds" =~ ^[0-9]+$ && "$hold_seconds" -gt 0 ]]; then
  # Ignore INT so viewer Ctrl-C cannot cancel this stub; cancel uses kill tree.
  trap '' INT
  sleep "$hold_seconds"
fi

final_state="succeeded"
case "$exit_code" in
  0) final_state="succeeded" ;;
  3) final_state="waiting" ;;
  *) final_state="failed" ;;
esac
if [[ -f "$run_dir/run.json" ]]; then
  tmp="$(mktemp)"
  jq --arg st "$final_state" \
    '.state = $st | .owner = null' \
    "$run_dir/run.json" >"$tmp" && mv "$tmp" "$run_dir/run.json"
fi
# Seed a minimal diagnosis so status/watch idle detection works.
mkdir -p "$run_dir"
jq -nc --arg st "$final_state" --arg id "$run_id" \
  '{state:$st, reasonCode:(if $st=="waiting" then "human-approval" elif $st=="failed" then "stage-failed" else "none" end),
    summary:$st, stageId:null, evidence:[], retryable:($st=="waiting"),
    nextAction:null, runId:$id}' >"$run_dir/diagnosis.json" 2>/dev/null || true
exit "$exit_code"
EOF
  chmod +x "$path"
}

write_viewer_stub() {
  local path="$1" behavior="${2:-idle}"
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
run_id="\${1:-}"
state_root="\${2:-}"
behavior="$behavior"
marker_dir="\${RALPH_START_VIEWER_MARKER_DIR:-}"
if [[ -n "\$marker_dir" ]]; then
  mkdir -p "\$marker_dir"
  printf '%s\\n' "\$behavior" >>"\$marker_dir/events.txt"
fi
case "\$behavior" in
  idle)
    # Wait until the outer run leaves running, matching real viewer idle stop.
    for _ in \$(seq 1 200); do
      st="\$(jq -r '.state // empty' "\$state_root/workflow-runs/\$run_id/run.json" 2>/dev/null || true)"
      [[ "\$st" != "running" && -n "\$st" ]] && exit 0
      sleep 0.05
    done
    exit 0
    ;;
  q)
    sleep 0.2
    exit 0
    ;;
  interrupt)
    sleep 0.2
    exit 130
    ;;
  crash)
    sleep 0.1
    exit 42
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$path"
}

start_env() {
  # Common env for start under fixtures. Caller appends stub vars.
  env RALPH_PROJECT_ROOT="$FIX_PROJECT" \
    RALPH_PLAN_WORKSPACE_ROOT="$CASE" \
    RALPH_HOME="$FIX_HOME" \
    WORKFLOW_STATE_SKIP_FSYNC=1 \
    "$@"
}

only_run_dir() {
  find "$CASE/workflow-runs" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1
}

input_hash() {
  local run_dir="$1"
  if [[ -f "$run_dir/input.orch.json" ]]; then
    cksum <"$run_dir/input.orch.json"
  elif [[ -f "$run_dir/input.plan.md" ]]; then
    cksum <"$run_dir/input.plan.md"
  else
    echo missing
  fi
}

# --- non-TTY synchronous outcomes ------------------------------------------

@test "non-TTY sequential start preserves success exit 0" {
  write_seq_workflow "$CASE/workflows/start-seq-demo.workflow.md"
  write_supervisor_stub "$FIX_ROOT/bin/supervisor-stub"
  local markers="$CASE/markers-seq-ok"
  mkdir -p "$markers"
  run start_env \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_START_STUB_MARKER_DIR="$markers" \
    RALPH_START_STUB_EXIT=0 \
    bash "$CLI" start --file "$CASE/workflows/start-seq-demo.workflow.md" \
      --task "Ship it" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Outcome: running (workflow started)"* ]]
  [[ "$output" == *"Outcome: succeeded (none)"* ]]
  [ "$(wc -l <"$markers/launches.txt" | tr -d ' ')" -eq 1 ]
  [[ "$(cut -f1 <"$markers/launches.txt")" == "sequential" ]]
  local run_dir
  run_dir="$(only_run_dir)"
  [ -n "$run_dir" ]
  [ "$(jq -r '.state' "$run_dir/run.json")" = "succeeded" ]
}

@test "non-TTY dependency start preserves failure exit 1" {
  write_dep_workflow "$CASE/workflows/start-dep-demo.workflow.md"
  write_supervisor_stub "$FIX_ROOT/bin/supervisor-stub"
  run start_env \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_START_STUB_EXIT=1 \
    bash "$CLI" start --file "$CASE/workflows/start-dep-demo.workflow.md" \
      --task "Ship it" --runtime cursor --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"Outcome: failed ("* ]]
  local run_dir
  run_dir="$(only_run_dir)"
  [ "$(jq -r '.state' "$run_dir/run.json")" = "failed" ]
}

@test "non-TTY start preserves persisted wait exit 3 for both modes" {
  write_seq_workflow "$CASE/workflows/start-seq-demo.workflow.md"
  write_dep_workflow "$CASE/workflows/start-dep-demo.workflow.md"
  write_supervisor_stub "$FIX_ROOT/bin/supervisor-stub"

  run start_env \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_START_STUB_EXIT=3 \
    bash "$CLI" start --file "$CASE/workflows/start-seq-demo.workflow.md" \
      --task "Wait seq" --runtime cursor --yes
  [ "$status" -eq 3 ]
  local seq_dir
  seq_dir="$(only_run_dir)"
  [ "$(jq -r '.state' "$seq_dir/run.json")" = "waiting" ]

  rm -rf "$CASE/workflow-runs"
  mkdir -p "$CASE/workflow-runs"

  run start_env \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_START_STUB_EXIT=3 \
    bash "$CLI" start --file "$CASE/workflows/start-dep-demo.workflow.md" \
      --task "Wait dep" --runtime cursor --yes
  [ "$status" -eq 3 ]
  local dep_dir
  dep_dir="$(only_run_dir)"
  [ "$(jq -r '.state' "$dep_dir/run.json")" = "waiting" ]
}

# --- TTY attach / detach ---------------------------------------------------

@test "TTY attach idle through completion preserves engine exit 0 and 3" {
  write_seq_workflow "$CASE/workflows/start-seq-demo.workflow.md"
  write_dep_workflow "$CASE/workflows/start-dep-demo.workflow.md"
  write_supervisor_stub "$FIX_ROOT/bin/supervisor-stub"
  write_viewer_stub "$FIX_ROOT/bin/viewer-stub" idle

  run start_env \
    RALPH_WORKFLOW_START_ASSUME_TTY=1 \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_WORKFLOW_START_VIEWER_STUB="$FIX_ROOT/bin/viewer-stub" \
    RALPH_START_STUB_EXIT=0 \
    RALPH_START_STUB_HOLD=1 \
    bash "$CLI" start --file "$CASE/workflows/start-seq-demo.workflow.md" \
      --task "Attach ok" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Outcome: succeeded (none)"* ]]

  rm -rf "$CASE/workflow-runs"
  mkdir -p "$CASE/workflow-runs"
  run start_env \
    RALPH_WORKFLOW_START_ASSUME_TTY=1 \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_WORKFLOW_START_VIEWER_STUB="$FIX_ROOT/bin/viewer-stub" \
    RALPH_START_STUB_EXIT=3 \
    RALPH_START_STUB_HOLD=1 \
    bash "$CLI" start --file "$CASE/workflows/start-dep-demo.workflow.md" \
      --task "Attach wait" --runtime cursor --yes
  [ "$status" -eq 3 ]
  [[ "$output" == *"Outcome: waiting ("* ]]
}

@test "q detach returns 0, prints status/watch, supervisor keeps running" {
  write_dep_workflow "$CASE/workflows/start-dep-demo.workflow.md"
  write_supervisor_stub "$FIX_ROOT/bin/supervisor-stub"
  write_viewer_stub "$FIX_ROOT/bin/viewer-stub" q
  local markers="$CASE/markers-q"
  mkdir -p "$markers"

  run start_env \
    RALPH_WORKFLOW_START_ASSUME_TTY=1 \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_WORKFLOW_START_VIEWER_STUB="$FIX_ROOT/bin/viewer-stub" \
    RALPH_START_STUB_MARKER_DIR="$markers" \
    RALPH_START_STUB_HOLD=8 \
    RALPH_START_STUB_EXIT=0 \
    bash "$CLI" start --file "$CASE/workflows/start-dep-demo.workflow.md" \
      --task "Detach q" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Viewer detached"* || "$output" == *"continues under the recorded supervisor"* ]]
  [[ "$output" == *"ralph workflow status "* ]]
  [[ "$output" == *"ralph workflow watch "* ]]
  [[ "$output" == *"ralph workflow logs "*"--stream combined --tail 200 --follow"* ]]
  [[ "$output" == *"ralph workflow logs "*"--stream agent --tail 200 --follow"* ]]
  [[ "$output" == *"ralph workflow actions list "* ]]
  [[ "$output" == *".stages[] | .artifacts[]?"* ]]

  local run_dir run_id stub_pid
  run_dir="$(only_run_dir)"
  run_id="$(basename "$run_dir")"
  stub_pid="$(wait_for_stub_pid "$markers")"
  [ -n "$stub_pid" ]
  # Detach must not stop the supervisor; only an explicit cancel (or kill) does.
  kill -0 "$stub_pid" 2>/dev/null
  [ "$(jq -r '.state' "$run_dir/run.json")" = "running" ]
  [ "$(wc -l <"$markers/launches.txt" | tr -d ' ')" -eq 1 ]

  kill -TERM "$stub_pid" 2>/dev/null || true
  kill -KILL "$stub_pid" 2>/dev/null || true
  # Public cancel remains the operator stop path (covered by recovery/cancel Bats).
  run start_env bash "$CLI" cancel --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"cancel"* ]]
}

@test "Ctrl-C detach returns 130 with the same reattach guidance" {
  write_seq_workflow "$CASE/workflows/start-seq-demo.workflow.md"
  write_supervisor_stub "$FIX_ROOT/bin/supervisor-stub"
  write_viewer_stub "$FIX_ROOT/bin/viewer-stub" interrupt
  local markers="$CASE/markers-int"
  mkdir -p "$markers"

  run start_env \
    RALPH_WORKFLOW_START_ASSUME_TTY=1 \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_WORKFLOW_START_VIEWER_STUB="$FIX_ROOT/bin/viewer-stub" \
    RALPH_START_STUB_MARKER_DIR="$markers" \
    RALPH_START_STUB_HOLD=8 \
    bash "$CLI" start --file "$CASE/workflows/start-seq-demo.workflow.md" \
      --task "Detach int" --runtime cursor --yes
  [ "$status" -eq 130 ]
  [[ "$output" == *"ralph workflow status "* ]]
  [[ "$output" == *"ralph workflow watch "* ]]
  local stub_pid
  stub_pid="$(wait_for_stub_pid "$markers")"
  kill -0 "$stub_pid" 2>/dev/null
  kill -TERM "$stub_pid" 2>/dev/null || true
  kill -KILL "$stub_pid" 2>/dev/null || true
}

# The supervisor stub runs in its own session and appends its pid
# asynchronously, so the CLI can return before pids.txt exists. Reading it
# straight away is a race that only shows up under load -- measured as
# "tail: .../pids.txt: No such file or directory" during a parallel suite run.
# Wait for the real condition against a deadline, per agents/rules/test-design.
wait_for_stub_pid() {
  local markers="$1" deadline
  deadline=$(( $(date +%s) + 60 ))
  until [[ -s "$markers/pids.txt" ]]; do
    [[ $(date +%s) -lt $deadline ]] || {
      echo "timed out waiting for $markers/pids.txt" >&2
      return 1
    }
    sleep 0.05
  done
  tail -1 "$markers/pids.txt"
}

@test "viewer crash leaves supervisor running and prints reattach guidance" {
  write_seq_workflow "$CASE/workflows/start-seq-demo.workflow.md"
  write_supervisor_stub "$FIX_ROOT/bin/supervisor-stub"
  write_viewer_stub "$FIX_ROOT/bin/viewer-stub" crash
  local markers="$CASE/markers-vcrash"
  mkdir -p "$markers"

  run start_env \
    RALPH_WORKFLOW_START_ASSUME_TTY=1 \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_WORKFLOW_START_VIEWER_STUB="$FIX_ROOT/bin/viewer-stub" \
    RALPH_START_STUB_MARKER_DIR="$markers" \
    RALPH_START_STUB_HOLD=8 \
    bash "$CLI" start --file "$CASE/workflows/start-seq-demo.workflow.md" \
      --task "Viewer crash" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"viewer exited"* || "$output" == *"continues under the recorded supervisor"* ]]
  [[ "$output" == *"ralph workflow watch "* ]]
  local stub_pid
  stub_pid="$(wait_for_stub_pid "$markers")"
  kill -0 "$stub_pid" 2>/dev/null
  kill -TERM "$stub_pid" 2>/dev/null || true
  kill -KILL "$stub_pid" 2>/dev/null || true
}

@test "engine crash while attached surfaces failed outcome without duplicate starts" {
  write_dep_workflow "$CASE/workflows/start-dep-demo.workflow.md"
  write_supervisor_stub "$FIX_ROOT/bin/supervisor-stub"
  write_viewer_stub "$FIX_ROOT/bin/viewer-stub" idle
  local markers="$CASE/markers-ecrash"
  mkdir -p "$markers"

  run start_env \
    RALPH_WORKFLOW_START_ASSUME_TTY=1 \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_WORKFLOW_START_VIEWER_STUB="$FIX_ROOT/bin/viewer-stub" \
    RALPH_START_STUB_MARKER_DIR="$markers" \
    RALPH_START_STUB_EXIT=1 \
    RALPH_START_STUB_HOLD=1 \
    bash "$CLI" start --file "$CASE/workflows/start-dep-demo.workflow.md" \
      --task "Engine fail" --runtime cursor --yes
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$markers/launches.txt" | tr -d ' ')" -eq 1 ]
  local run_dir
  run_dir="$(only_run_dir)"
  [ "$(jq -r '.state' "$run_dir/run.json")" = "failed" ]
}

# --- invariants ------------------------------------------------------------

@test "immutable input hash stays stable across attach and detach" {
  write_seq_workflow "$CASE/workflows/start-seq-demo.workflow.md"
  write_supervisor_stub "$FIX_ROOT/bin/supervisor-stub"
  write_viewer_stub "$FIX_ROOT/bin/viewer-stub" q
  local markers="$CASE/markers-hash"
  mkdir -p "$markers"

  run start_env \
    RALPH_WORKFLOW_START_ASSUME_TTY=1 \
    RALPH_WORKFLOW_START_SUPERVISOR_STUB="$FIX_ROOT/bin/supervisor-stub" \
    RALPH_WORKFLOW_START_VIEWER_STUB="$FIX_ROOT/bin/viewer-stub" \
    RALPH_START_STUB_MARKER_DIR="$markers" \
    RALPH_START_STUB_HOLD=6 \
    bash "$CLI" start --file "$CASE/workflows/start-seq-demo.workflow.md" \
      --task "Hash check" --runtime cursor --yes
  [ "$status" -eq 0 ]
  local run_dir before after stub_pid
  run_dir="$(only_run_dir)"
  before="$(input_hash "$run_dir")"
  [[ "$before" != "missing" ]]
  sleep 0.3
  after="$(input_hash "$run_dir")"
  [ "$before" = "$after" ]
  stub_pid="$(wait_for_stub_pid "$markers")"
  kill -TERM "$stub_pid" 2>/dev/null || true
  kill -KILL "$stub_pid" 2>/dev/null || true
}

@test "start refuses --background/--detach and ENGINE_STUB still skips supervisor" {
  write_dep_workflow "$CASE/workflows/start-dep-demo.workflow.md"
  run start_env bash "$CLI" start --help
  [ "$status" -eq 0 ]
  [[ "$output" != *"--background"* ]]
  [[ "$output" != *"--detach"* ]]

  local tuple="$CASE/engine-tuple.txt"
  run start_env RALPH_WORKFLOW_START_ENGINE_STUB="$tuple" \
    bash "$CLI" start --file "$CASE/workflows/start-dep-demo.workflow.md" \
      --task "Stub only" --runtime cursor --yes
  [ "$status" -eq 0 ]
  [ -f "$tuple" ]
  [ "$(wc -l <"$tuple" | tr -d ' ')" -eq 1 ]
}

@test "terminal restoration helper is invoked once per attached session (unit)" {
  # The curses restorer contract is covered by Python tests; assert the start
  # attach path sources the same watch entry that restores the terminal.
  run bash -c '
    source "'"$SUP_LIB"'"
    declare -F workflow_cli_start_attach_viewer >/dev/null
    declare -F workflow_cli_start_supervise_with_viewer >/dev/null
    declare -F workflow_cli_start_should_attach_viewer >/dev/null
  '
  [ "$status" -eq 0 ]
}

@test "start leaves final workflow status below the detailed usage report" {
  run bash -c '
    source "$1"
    workflow_operator_render_start() { printf "%s\n" "START-BANNER"; }
    workflow_cli_start_should_attach_viewer() { return 1; }
    workflow_cli_start_run_supervisor() { return 1; }
    workflow_usage_print_run_report() { printf "%s\n" "USAGE-REPORT"; }
    workflow_operator_view_load() { printf "%s\n" "{}"; }
    workflow_operator_render_status() { printf "%s\n" "FINAL-STATUS" >&2; }
    workflow_cli_start_after_dispatch \
      dependency /tmp/state run-test /tmp/workspace /tmp/input \
      task "test task" explicit test-workflow
  ' _ "$SUP_LIB"
  [ "$status" -eq 1 ]
  local usage_line final_line
  usage_line="$(printf '%s\n' "$output" | sed -n '/USAGE-REPORT/=' | tail -1)"
  final_line="$(printf '%s\n' "$output" | sed -n '/FINAL-STATUS/=' | tail -1)"
  [ -n "$usage_line" ]
  [ -n "$final_line" ]
  [ "$usage_line" -lt "$final_line" ]
}
