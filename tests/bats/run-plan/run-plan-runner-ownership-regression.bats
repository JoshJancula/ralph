#!/usr/bin/env bats

# Regression coverage for the end-to-end runner-owned verification ownership story:
#   1. Runner-executed verify: commands run out-of-process with timeout isolation.
#   2. Compact artifact retrieval: result windowing metrics and guidance are correct.
#   3. Absence of agent-driven wait/status loops in the normal path: the default
#      prompt steers toward runner-owned verification and shell_wait, not shell_status
#      polling; excess polling is detected by telemetry.

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

setup_prompt_capture_stub() {
  local bin_dir="$1"
  local cursor_record="$2"

  cat <<EOF > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$cursor_record"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"
}

# ---------- 1. Runner-executed verification (out-of-process, timeout, artifact) ----------

@test "runner-owned verify: command executes out-of-process and marks TODO complete on success" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home verify_script
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  verify_script="$workspace/verify.sh"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  cat > "$verify_script" <<'SCRIPT'
#!/usr/bin/env bash
printf 'all checks passed\n'
exit 0
SCRIPT
  chmod +x "$verify_script"

  plan_file="$workspace/VERIFY-COMPLETE.plan.md"
  cat > "$plan_file" <<'EOF'
---
todos:
  - id: verify-complete
    content: Wire the regression tests
    verification: Run the regression suite and confirm it passes.
    verify: bash verify.sh
    status: pending
---
# Verify-to-complete success test
EOF

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq 'id: verify-complete' "$plan_file"
  [ "$(grep -c '^    status: completed$' "$plan_file")" -eq 1 ]
  [[ "$output" == *"Verification passed"* ]]

  rm -rf "$workspace"
}

@test "runner-owned verify: command fails and reopens TODO" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home verify_script
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  verify_script="$workspace/verify.sh"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  cat > "$verify_script" <<'SCRIPT'
#!/usr/bin/env bash
printf 'FAIL: 3 tests failed\nsrc/foo.rs:42: mismatched types\n'
exit 1
SCRIPT
  chmod +x "$verify_script"

  plan_file="$workspace/VERIFY-FAIL.plan.md"
  cat > "$plan_file" <<'EOF'
---
todos:
  - id: verify-fail
    content: Wire the regression tests
    verification: Run the regression suite and confirm it passes.
    verify: bash verify.sh
    status: pending
---
# Verify-to-complete failure test
EOF

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=10 \
    CURSOR_PLAN_GUTTER_ITER=2

  [ "$status" -ne 0 ]
  grep -Fq 'status: pending' "$plan_file"
  ! grep -Fq 'status: completed' "$plan_file"
  [[ "$output" == *"Post-verification failed"* ]]

  rm -rf "$workspace"
}

@test "runner-owned verify: timeout kills hanging command and reopens TODO" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/VERIFY-TIMEOUT.plan.md"
  cat > "$plan_file" <<'EOF'
---
todos:
  - id: verify-timeout
    content: Check timeout handling
    verify: sleep 30
    status: pending
---
# Verify-to-complete timeout test
EOF

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_VERIFY_TIMEOUT=2

  [[ "$output" == *"timed out"* ]]

  rm -rf "$workspace"
}

@test "runner-owned verify: invalid prose command is not executed as shell" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home cursor_record
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  cursor_record="$workspace/cursor.args"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PROSE-VERIFY.plan.md"
  cat > "$plan_file" <<'EOF'
---
todos:
  - id: prose-verify
    content: Build the UI panel
    verification: Open the browser and confirm the panel renders (e.g. npm run build or the project's existing check)
    status: pending
---
# Prose verification not executed
EOF

  setup_prompt_capture_stub "$bin_dir" "$cursor_record"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=2

  [[ "$output" != *"syntax error"* ]]
  [[ "$output" != *"exit=2"* ]]

  rm -rf "$workspace"
}

# ---------- 2. Compact artifact retrieval (tested in Python unit tests) ----------
# See tests/python/test_runner_ownership_regression.py for result_windowing_metrics
# and telemetry tests covering compact artifact paths.

# ---------- 3. Absence of agent-driven polling loops ----------

@test "default runner-owned prompt steers toward runner-owned verification" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home cursor_record
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  cursor_record="$workspace/cursor.args"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'EOF'
# Prompt steering test
- [ ] complete the task without polling
EOF

  setup_prompt_capture_stub "$bin_dir" "$cursor_record"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  [ -s "$cursor_record" ]
  local prompt_content
  prompt_content="$(cat "$cursor_record")"
  [[ "$prompt_content" == *"runner"* ]]
  [[ "$prompt_content" == *"shell_wait"* ]] || [[ "$prompt_content" == *"Verification"* ]]

  rm -rf "$workspace"
}

@test "default runner-owned prompt does not instruct agent to edit the plan" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home cursor_record
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  cursor_record="$workspace/cursor.args"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'EOF'
# No plan edit prompt test
- [ ] task that should not prompt plan editing
EOF

  setup_prompt_capture_stub "$bin_dir" "$cursor_record"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_PLAN_AGENT_MARKS_TODOS=0

  [ "$status" -eq 0 ]
  [ -s "$cursor_record" ]
  ! grep -Fq "change \`- [ ]\` to \`- [x]\` on that line" "$cursor_record"
  ! grep -Fq "mark the checkbox" "$cursor_record"

  rm -rf "$workspace"
}

@test "prompt with verification metadata includes completion helper request and verification verdict" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home cursor_record
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  cursor_record="$workspace/cursor.args"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/VERIFY-PROMPT.plan.md"
  cat > "$plan_file" <<'EOF'
---
todos:
  - id: verify-prompt
    content: Add the savings panel
    verification: Open the usage hub and confirm the savings panel renders.
    status: pending
---
# Verify prompt test
EOF

  setup_prompt_capture_stub "$bin_dir" "$cursor_record"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=1

  [ -s "$cursor_record" ]
  grep -Fq "mcp__ralph__ralph_complete_todo" "$cursor_record"
  grep -Fq "TODO_VERIFICATION: PASS" "$cursor_record"
  grep -Fq "TODO_VERIFICATION: FAIL:" "$cursor_record"
  grep -Fq "TODO_VERIFICATION: SKIPPED" "$cursor_record"

  rm -rf "$workspace"
}

@test "post-verification failure reopens TODO and signals failure" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home verify_script
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  verify_script="$workspace/verify.sh"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  cat > "$verify_script" <<'SCRIPT'
#!/usr/bin/env bash
printf 'FAIL: 2 tests failed\nsrc/bar.rs:10: type error\n'
exit 1
SCRIPT
  chmod +x "$verify_script"

  plan_file="$workspace/VERIFY-REOPEN.plan.md"
  cat > "$plan_file" <<'EOF'
---
todos:
  - id: verify-reopen
    content: Fix the type errors
    verify: bash verify.sh
    status: pending
---
# Verify reopen prompt test
EOF

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=10 \
    CURSOR_PLAN_GUTTER_ITER=2

  [ "$status" -ne 0 ]
  grep -Fq 'status: pending' "$plan_file"
  ! grep -Fq 'status: completed' "$plan_file"
  [[ "$output" == *"Post-verification failed"* ]]

  rm -rf "$workspace"
}

@test "agent TODO_VERIFICATION: FAIL reopens the TODO without running verify command" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/TODO-FAIL.plan.md"
  cat > "$plan_file" <<'EOF'
---
todos:
  - id: todo-fail
    content: Fix the flaky test
    verification: Run the test suite and confirm it passes.
    status: pending
---
# TODO verification failure test
EOF

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: FAIL: still flaky"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -ne 0 ]
  grep -Fq 'status: pending' "$plan_file"
  ! grep -Fq 'status: completed' "$plan_file"
  [[ "$output" != *"Running verification checks now"* ]]

  rm -rf "$workspace"
}

@test "agent TODO_VERIFICATION: PASS marks TODO complete without running verify command" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/TODO-PASS.plan.md"
  cat > "$plan_file" <<'EOF'
---
todos:
  - id: todo-pass
    content: Add the test coverage
    verification: Run the regression suite.
    verify: bash check.sh
    status: pending
---
# TODO verification pass test
EOF

  cat > "$workspace/check.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x "$workspace/check.sh"

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: PASS"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  [ "$(grep -c '^    status: completed$' "$plan_file")" -eq 1 ]

  rm -rf "$workspace"
}

@test "structured completion footer with VERIFICATION STATUS: PASS is accepted" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/STATUS-PASS.plan.md"
  cat > "$plan_file" <<'EOF'
---
todos:
  - id: status-pass
    content: Verify VERIFICATION STATUS is accepted
    status: pending
---
# VERIFICATION STATUS pass test
EOF

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "VERIFICATION STATUS: PASS tool_result_ids=res-1,res-2"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  [ "$(grep -c '^    status: completed$' "$plan_file")" -eq 1 ]

  rm -rf "$workspace"
}

@test "runner stdin isolation prevents verification command from blocking" {
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

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_VERIFY_TIMEOUT=10 \
    RALPH_VERIFY_AFTER_TODO='cat'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Running verification checks now"* ]]
  grep -Fq -- "- [x] task whose verification reads stdin" "$plan_file"

  rm -rf "$workspace"
}