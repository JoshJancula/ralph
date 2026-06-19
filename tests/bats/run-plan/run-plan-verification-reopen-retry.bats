#!/usr/bin/env bats

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

@test "post-verification reopen preserves attempts_on_line and stops after third failure" {
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
exit 1
SCRIPT
  chmod +x "$verify_script"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Post-verify retry test
- [ ] first task with failing verification
- [ ] second task should not run
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=10 \
    CURSOR_PLAN_GUTTER_ITER=3 \
    RALPH_VERIFY_AFTER_TODO="bash $verify_script"

  [ "$status" -ne 0 ]
  [[ "$output" == *"retry budget exhausted"* ]] || [[ "$output" == *"gutter"* ]]
  grep -Fq -- "- [ ] first task with failing verification" "$plan_file"
  ! grep -Fq -- "- [x] first task with failing verification" "$plan_file"
  grep -Fq -- "- [ ] second task should not run" "$plan_file"
  rm -rf "$workspace"
}

@test "verification_gate TODO stops after one failed invocation without blind retries" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home invocation_count
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  invocation_count="$workspace/invocations.txt"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
---
todos:
  - id: gate
    content: verify the bounded retry limit
    verification: printf done
    status: pending
---
# Verification gate retry cap
PLAN

  cat > "$bin_dir/cursor-agent" <<AGENT
#!/usr/bin/env bash
count_path="$invocation_count"
n=0
[[ -f "\$count_path" ]] && n=\$(cat "\$count_path")
n=\$((n+1))
printf '%s' "\$n" > "\$count_path"
printf '%s\n' "finished work without completion sentinel"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=10 \
    CURSOR_PLAN_GUTTER_ITER=3

  [ "$status" -ne 0 ]
  [ "$(cat "$invocation_count")" = "1" ]
  grep -Fq 'verification: printf done' "$plan_file"
  rm -rf "$workspace"
}

@test "post-verification reopen retry uses compact resume when available" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home verify_script counter
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  verify_script="$workspace/verify.sh"
  counter="$workspace/counter.txt"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  cat > "$verify_script" <<SCRIPT
#!/usr/bin/env bash
counter_path="$counter"
n=0
[[ -f "\$counter_path" ]] && n=\$(cat "\$counter_path")
n=\$((n+1))
printf '%s' "\$n" > "\$counter_path"
[[ \$n -lt 2 ]] && exit 1
exit 0
SCRIPT
  chmod +x "$verify_script"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Compact resume test
- [ ] task with retry that needs fix
PLAN

  cat > "$bin_dir/cursor-agent" <<AGENT
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$workspace/prompts.txt"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  mkdir -p "$session_home/post-verify-test"
  printf '%s\n' "test-session-id" > "$session_home/post-verify-test/session-id.cursor.txt"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=10 \
    CURSOR_PLAN_GUTTER_ITER=3 \
    RALPH_VERIFY_AFTER_TODO="bash $verify_script" \
    RALPH_PLAN_CLI_RESUME=1

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] task with retry that needs fix" "$plan_file"
  [[ "$output" == *"compact"* ]] || [[ "$output" == *"post-verify"* ]]
  rm -rf "$workspace"
}

@test "runner does not advance to next TODO while reopened TODO still failing verification" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home verify_script second_ran
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  verify_script="$workspace/verify.sh"
  second_ran="$workspace/second_ran.txt"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  cat > "$verify_script" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
  chmod +x "$verify_script"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# No advance test
- [ ] first task with failing verification
- [ ] second task
PLAN

  cat > "$bin_dir/cursor-agent" <<AGENT
#!/usr/bin/env bash
second_ran_path="$second_ran"
if [[ "\$*" == *"first task"* ]]; then
  printf '%s\n' "AGENT_INVOCATION_COMPLETE"
  exit 0
fi
printf '%s' "1" >> "\$second_ran_path"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=10 \
    CURSOR_PLAN_GUTTER_ITER=2 \
    RALPH_VERIFY_AFTER_TODO="bash $verify_script"

  [ "$status" -ne 0 ]
  [ ! -f "$second_ran" ]
  grep -Fq -- "- [ ] first task with failing verification" "$plan_file"
  grep -Fq -- "- [ ] second task" "$plan_file"
  rm -rf "$workspace"
}

@test "post-verification reopen preserves attempt counter across multiple retries" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home verify_script counter
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  verify_script="$workspace/verify.sh"
  counter="$workspace/counter.txt"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  cat > "$verify_script" <<SCRIPT
#!/usr/bin/env bash
counter_path="$counter"
n=0
[[ -f "\$counter_path" ]] && n=\$(cat "\$counter_path")
n=\$((n+1))
printf '%s' "\$n" > "\$counter_path"
exit 1
SCRIPT
  chmod +x "$verify_script"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Attempt counter test
- [ ] task that keeps failing verification
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=20 \
    CURSOR_PLAN_GUTTER_ITER=3 \
    RALPH_VERIFY_AFTER_TODO="bash $verify_script"

  [ "$status" -ne 0 ]
  [ -f "$counter" ]
  [ "$(cat "$counter")" = "3" ] || [ "$(cat "$counter")" -ge 3 ]
  rm -rf "$workspace"
}

@test "retry prompt contains prior verification-failure context" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home verify_script prompts
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  verify_script="$workspace/verify.sh"
  prompts="$workspace/prompts.txt"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  cat > "$verify_script" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
  chmod +x "$verify_script"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Verification context test
- [ ] task that fails verification
PLAN

  cat > "$bin_dir/cursor-agent" <<AGENT
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$workspace/prompts.txt"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=10 \
    CURSOR_PLAN_GUTTER_ITER=2 \
    RALPH_VERIFY_AFTER_TODO="bash $verify_script"

  [ "$status" -ne 0 ]
  [ -f "$prompts" ]
  local prompt_content
  prompt_content="$(cat "$prompts")"
  [[ "$prompt_content" == *"verification"* ]] || [[ "$prompt_content" == *"fail"* ]] || [[ "$prompt_content" == *"failed"* ]]
  rm -rf "$workspace"
}

@test "post-verification reopen stops immediately when gutter limit exceeded" {
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
exit 1
SCRIPT
  chmod +x "$verify_script"

  plan_file="$workspace/PLAN.md"
  cat > "$plan_file" <<'PLAN'
# Immediate stop test
- [ ] task with verification that always fails
PLAN

  cat > "$bin_dir/cursor-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
AGENT
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=20 \
    CURSOR_PLAN_GUTTER_ITER=1 \
    RALPH_VERIFY_AFTER_TODO="bash $verify_script"

  [ "$status" -ne 0 ]
  [[ "$output" == *"exhausted"* ]] || [[ "$output" == *"gutter"* ]] || [[ "$output" == *"budget"* ]]
  rm -rf "$workspace"
}
