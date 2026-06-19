#!/usr/bin/env bats

# Coverage for the unified verification gate: timeout + stdin isolation so an
# interactive or hung strict verify command can never freeze the runner, and the
# hybrid agent-verdict-first flow.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"

setup_stub_run_plan_support() {
  local workspace="$1"
  local select_model_dir="$workspace/.cursor/ralph"
  local agent_tool_dir="$workspace/.ralph"

  mkdir -p "$select_model_dir" "$agent_tool_dir"
  cat > "$select_model_dir/select-model.sh" <<'EOF'
#!/usr/bin/env bash
select_model_cursor() {
  if [[ "$1" == "--batch" ]]; then
    shift
  fi
  printf '%s\n' "stub-model"
}
export -f select_model_cursor >/dev/null 2>&1 || true
EOF
  chmod +x "$select_model_dir/select-model.sh"

  cat > "$agent_tool_dir/agent-config-tool.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list|validate|model|context|allowed-tools|downstream-stages)
    ;;
  *)
    ;;
esac
exit 0
EOF
  chmod +x "$agent_tool_dir/agent-config-tool.sh"
}

run_plan_with_stub() {
  local workspace="$1"
  local bin_dir="$2"
  local plan_file="$3"
  local session_home="$4"
  shift 4

  run bash -c '
    set -euo pipefail
    _workspace="$1"
    _bin_dir="$2"
    _plan_file="$3"
    _run_plan="$4"
    _session_home="$5"
    shift 5
    cd "$_workspace"
    export PATH="$_bin_dir:$PATH"
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    export RALPH_PLAN_SESSION_HOME="$_session_home"
    export CURSOR_PLAN_MAX_ITER=1
    export RALPH_PLAN_NO_CAFFEINATE=1
    export RALPH_LAUNCHER_PID=$$
    unset RALPH_AGENT_TOOL_ACCESS RALPH_NATIVE_HOOKS RALPH_MODE RALPH_PLAN_KEY RALPH_ARTIFACT_NS
    while [[ $# -gt 0 ]]; do
      export "$1"
      shift
    done
    "$_run_plan" --runtime cursor --plan "$(basename "$_plan_file")" --non-interactive --model stub-model --workspace "$_workspace"
  ' _ "$workspace" "$bin_dir" "$plan_file" "$RUN_PLAN_SH" "$session_home" "$@"
}

@test "verification gate kills a hung command at RALPH_VERIFY_TIMEOUT and reopens the TODO" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Timeout test
- [ ] task with a hanging verification command
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_VERIFY_TIMEOUT=2 \
    RALPH_VERIFY_AFTER_TODO='sleep 30'

  # The run completes (the command is killed) instead of hanging.
  [[ "$output" == *"Running verification checks now"* ]]
  [[ "$output" == *"timed out"* ]]
  # The TODO is reopened rather than left complete.
  grep -Fq -- "- [ ] task with a hanging verification command" "$plan_file"
  ! grep -Fq -- "- [x] task with a hanging verification command" "$plan_file"

  rm -rf "$workspace"
}

@test "verification gate isolates stdin so a command reading stdin gets EOF instead of blocking" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Stdin isolation test
- [ ] task whose verification reads stdin
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  # `cat` with no args reads stdin; without </dev/null it would block forever and
  # this test would hang. With stdin isolation it sees EOF immediately and passes.
  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_VERIFY_TIMEOUT=10 \
    RALPH_VERIFY_AFTER_TODO='cat'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Running verification checks now"* ]]
  grep -Fq -- "- [x] task whose verification reads stdin" "$plan_file"

  rm -rf "$workspace"
}

@test "verification gate accepts agent VERIFICATION_RESULT: PASS without runner re-run by default" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Trust agent verdict test
- [ ] task with a flaky verification command. Verification: confirm the flaky command passes
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "VERIFICATION_RESULT: PASS"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_VERIFY_AFTER_TODO='exit 1'

  [ "$status" -eq 0 ]
  [[ "$output" != *"Running verification checks now"* ]]
  grep -Fq -- "- [x] task with a flaky verification command" "$plan_file"

  rm -rf "$workspace"
}

@test "verification gate skips direct verification when agent reports PASS" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home marker_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  marker_file="$workspace/direct-verification-ran.txt"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Trust agent verdict test
- [ ] task with direct verification command. Verification: bash ./check.sh
PLAN

  cat > "$workspace/check.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "ran" >"$marker_file"
exit 0
EOF
  chmod +x "$workspace/check.sh"

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "VERIFICATION STATUS: PASS tool_result_ids=res-123,res-456"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  [[ "$output" != *"Running direct verification"* ]]
  [ ! -f "$marker_file" ]
  grep -Fq -- "- [x] task with direct verification command" "$plan_file"

  rm -rf "$workspace"
}

@test "verification gate accepts VERIFICATION STATUS: PASS without runner re-run" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Trust agent verdict test
- [ ] task with a flaky verification command. Verification: confirm the flaky command passes
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "VERIFICATION STATUS: PASS"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_VERIFY_AFTER_TODO='exit 1'

  [ "$status" -eq 0 ]
  [[ "$output" != *"Running verification checks now"* ]]
  grep -Fq -- "- [x] task with a flaky verification command" "$plan_file"

  rm -rf "$workspace"
}

@test "verification gate accepts structured TODO footer without AGENT_INVOCATION_COMPLETE" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Structured completion test
- [ ] task with structured completion footer. Verification: confirm the footer is honored
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: PASS"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] task with structured completion footer" "$plan_file"

  rm -rf "$workspace"
}

@test "verification gate reopens immediately on agent VERIFICATION_RESULT: FAIL without runner re-run" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Strict trust test
- [ ] task that must not self-certify. Verification: confirm the failing checks are resolved
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "VERIFICATION_RESULT: FAIL: tests are still red"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_VERIFY_AFTER_TODO='exit 1'

  [[ "$output" != *"Running verification checks now"* ]]
  grep -Fq -- "- [ ] task that must not self-certify" "$plan_file"
  ! grep -Fq -- "- [x] task that must not self-certify" "$plan_file"

  rm -rf "$workspace"
}

@test "verification gate reopens on structured TODO_VERIFICATION: FAIL" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Structured fail test
- [ ] task with structured verification failure. Verification: confirm the footer is honored
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: FAIL: still broken"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -ne 0 ]
  grep -Fq -- "- [ ] task with structured verification failure" "$plan_file"
  ! grep -Fq -- "- [x] task with structured verification failure" "$plan_file"

  rm -rf "$workspace"
}

@test "invalid strict verify command does not execute and requests agent verification instead" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home cursor_record
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  cursor_record="$workspace/cursor.args"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Invalid verify test
- [ ] task with an invalid strict verify. Verify: bats -T
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  cat > "$bin_dir/cursor-agent" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cursor_record"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=2 CURSOR_PLAN_GUTTER_ITER=2

  [ "$status" -ne 0 ]
  [[ "$output" != *"Running verification checks now"* ]]
  grep -Fq -- "- [ ] task with an invalid strict verify" "$plan_file"
  grep -Fq -- "could not be used automatically" "$cursor_record"

  rm -rf "$workspace"
}
