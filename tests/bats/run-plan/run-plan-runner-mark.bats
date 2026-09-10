#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
BG_STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
PLAN_TODO_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"

runner_mark_plan_key() {
  local plan_file="$1"
  # shellcheck disable=SC1090
  source "$PLAN_TODO_LIB"
  plan_log_basename "$plan_file"
}

runner_mark_output_log_for_plan() {
  local workspace="$1"
  local plan_file="$2"
  local plan_key
  plan_key="$(runner_mark_plan_key "$plan_file")"
  printf '%s/.ralph-workspace/logs/%s/plan-runner-%s.log\n' "$workspace" "$plan_key" "$plan_key"
}

runner_mark_seed_bg_job() {
  local session_home="$1"
  local plan_file="$2"
  local todo_body="$3"
  local line_num="$4"
  local job_id="$5"
  local terminal_mode="${6:-running}"
  local identity_run_id="${7:-run-runner-mark}"
  local identity_todo_hash="${8:-}"

  command -v jq >/dev/null 2>&1 || skip "jq unavailable"

  local plan_key todo_hash
  # shellcheck disable=SC1090
  source "$PLAN_TODO_LIB"
  plan_key="$(plan_log_basename "$plan_file")"
  todo_hash="$(plan_todo_hash "$todo_body")"
  if [[ -n "$identity_todo_hash" ]]; then
    todo_hash="$identity_todo_hash"
  fi

  export RALPH_SESSION_DIR="$session_home/$plan_key"
  export RALPH_PROJECT_ROOT="$(dirname "$plan_file")"
  export RALPH_PLAN_WORKSPACE_ROOT="$RALPH_PROJECT_ROOT/.ralph-workspace"
  export RALPH_AGENT_WORKSPACE="$RALPH_PROJECT_ROOT"
  export RALPH_PLAN_KEY="$plan_key"
  export RUNTIME="cursor"
  export RALPH_PROCESS_RUN_ID="$identity_run_id"
  export RALPH_CURRENT_TODO_LINE="$line_num"
  export RALPH_CURRENT_TODO_ORDINAL="1"
  export RALPH_CURRENT_TODO_ID=""
  export RALPH_CURRENT_TODO_HASH="$todo_hash"
  export RALPH_BG_MAX_PER_TODO=8
  mkdir -p "$RALPH_SESSION_DIR"
  # shellcheck disable=SC1090
  source "$BG_STATE_LIB"

  ralph_bg_job_create "$job_id" "sleep 999" "runner-mark-test" 3600 2 "$$" >/dev/null
  ralph_bg_job_mark_launched "$job_id" 4242 "setsid" "true" >/dev/null
  ralph_bg_job_mark_running "$job_id" >/dev/null
  case "$terminal_mode" in
    running) ;;
    consumed)
      ralph_bg_job_mark_terminal "$job_id" "passed" >/dev/null
      ralph_bg_job_consume "$job_id" >/dev/null
      ;;
    *)
      ralph_bg_job_mark_terminal "$job_id" "$terminal_mode" >/dev/null
      ;;
  esac
}

setup_stub_run_plan_support() {
  local workspace="$1"
  local select_model_dir="$workspace/.cursor/ralph"
  local agent_tool_dir="$workspace/.ralph"

  mkdir -p "$select_model_dir" "$agent_tool_dir"
  cat <<'EOF' > "$select_model_dir/select-model.sh"
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

  cat <<'EOF' > "$agent_tool_dir/agent-config-tool.sh"
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

@test "runner marks markdown TODO when agent prints sentinel without editing plan" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Runner mark test
- [ ] runner-owned markdown completion
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] runner-owned markdown completion" "$plan_file"

  rm -rf "$workspace"
}

@test "runner marks markdown TODO when a blank separator follows the checkbox" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Runner mark test
- [ ] runner-owned markdown completion

EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] runner-owned markdown completion" "$plan_file"

  rm -rf "$workspace"
}

@test "runner marks structured frontmatter TODO status completed" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/STRUCTURED.plan.md"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: runner-mark
    content: runner-owned structured completion
    status: pending
---
# Structured runner mark test
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq 'content: runner-owned structured completion' "$plan_file"
  [ "$(grep -c '^    status: completed$' "$plan_file")" -eq 1 ]
  ! grep -Fq 'status: pending' "$plan_file"

  rm -rf "$workspace"
}

@test "runner marks markdown TODO when JSON usage sees embedded sentinel" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Runner mark JSON test
- [ ] runner-owned JSON completion
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' '{"type":"result","result":"done\nAGENT_INVOCATION_COMPLETE\n","usage":{"inputTokens":10,"outputTokens":2}}'
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] runner-owned JSON completion" "$plan_file"

  rm -rf "$workspace"
}

@test "runner writes a one-shot human request for OpenCode auto-rejects" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home session_dir
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Permission pause test
- [ ] pause when runtime rejects a permission-gated call
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' '! permission requested: external_directory (/tmp/*); auto-rejecting' >&2
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 4 ]
  session_dir="$(find "$session_home" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -n "$session_dir" ]
  [ -f "$session_dir/pending-human.txt" ]
  [ -f "$session_dir/permission-remediation.json" ]
  [ -f "$session_dir/human-request.json" ]
  [ -f "$session_dir/HUMAN-INPUT-REQUIRED.md" ]
  grep -Fq 'external_directory' "$session_dir/pending-human.txt"
  jq -e '.kind == "permission"' "$session_dir/human-request.json"
  jq -e '.placeholder == true' "$session_dir/operator-response.txt"
  jq -e '.blocked_path == "/tmp/*"' "$session_dir/permission-remediation.json"

  rm -rf "$workspace"
}

@test "runner does not mark markdown TODO when completion sentinel is missing" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Runner mark test
- [ ] sentinel missing should stay open
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "finished work without sentinel"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  grep -Fq -- "- [ ] sentinel missing should stay open" "$plan_file"
  ! grep -Fq -- "- [x] sentinel missing should stay open" "$plan_file"

  rm -rf "$workspace"
}

@test "runner marks markdown TODO when structured completion footer replaces the sentinel" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Runner mark test
- [ ] structured completion should advance
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: SKIPPED"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] structured completion should advance" "$plan_file"

  rm -rf "$workspace"
}

@test "runner completes TODO when prose has permission vocabulary alongside completion footer" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home session_dir
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Poisoning eval mark test
- [ ] run the poisoning evaluation suite
EOF

  # A security/poisoning eval legitimately prints permission-shaped vocabulary
  # ("permission denied", "blocked", "rejected") as part of its summary while
  # still completing the TODO. The runner must not misread that prose as a real
  # permission block, intercept the completion, and loop the TODO.
  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "All poisoning scenarios passed: malicious verification permission denied,"
printf '%s\n' "fabricated commit blocked, tenant access rejected, destructive supersession forbidden."
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: SKIPPED"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] run the poisoning evaluation suite" "$plan_file"
  # No permission pause artifacts should have been written.
  session_dir="$(find "$session_home" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [ -n "$session_dir" ]; then
    [ ! -f "$session_dir/pending-human.txt" ]
    [ ! -f "$session_dir/permission-remediation.json" ]
    [ ! -f "$session_dir/human-request.json" ]
  fi

  rm -rf "$workspace"
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

@test "default runner-owned prompt tells agent not to edit the plan" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home cursor_record
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  cursor_record="$workspace/cursor.args"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Prompt compatibility test
- [ ] inspect runner-owned completion prompt
EOF

  setup_prompt_capture_stub "$bin_dir" "$cursor_record"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_PLAN_AGENT_MARKS_TODOS=0

  [ "$status" -eq 0 ]
  [ -s "$cursor_record" ]
  grep -Fq "mcp__ralph__ralph_complete_todo" "$cursor_record"
  grep -Fq "TODO_COMPLETION: COMPLETE" "$cursor_record"
  grep -Fq "TODO_VERIFICATION: PASS" "$cursor_record"
  ! grep -Fq "change \`- [ ]\` to \`- [x]\` on that line" "$cursor_record"

  rm -rf "$workspace"
}

@test "RALPH_PLAN_AGENT_MARKS_TODOS=1 retains legacy plan-editing prompt text" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home cursor_record
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  cursor_record="$workspace/cursor.args"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Prompt compatibility test
- [ ] inspect legacy completion prompt
EOF

  setup_prompt_capture_stub "$bin_dir" "$cursor_record"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_PLAN_AGENT_MARKS_TODOS=1

  [ "$status" -eq 0 ]
  [ -s "$cursor_record" ]
  grep -Fq "When done, mark \`- [ ]\` on line" "$cursor_record"
  ! grep -Fq "the runner marks it when the sentinel is observed" "$cursor_record"

  rm -rf "$workspace"
}

@test "runner reopens markdown TODO when post-verification fails after sentinel marking" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  cat <<'EOF' > "$plan_file"
# Post-verify reopen test
- [ ] first task with failing verify
- [ ] second task keeps plan open
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_VERIFY_AFTER_TODO=false

  grep -Fq -- "- [ ] first task with failing verify" "$plan_file"
  ! grep -Fq -- "- [x] first task with failing verify" "$plan_file"
  grep -Fq -- "- [ ] second task keeps plan open" "$plan_file"
  [[ "$output" == *"Post-verification failed"* ]]
  [[ "$output" == *"TODO reopened"* ]]

  rm -rf "$workspace"
}

@test "runner marks structured TODO via verify-to-complete when sentinel is glued" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home verify_script
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  verify_script="$workspace/.ralph-workspace/verify-ran.txt"
  mkdir -p "$bin_dir" "$session_home" "$(dirname "$verify_script")"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/VERIFY-TO-COMPLETE.plan.md"
  cat <<EOF > "$plan_file"
---
todos:
  - id: verify-complete
    content: Update the usage report wiring
    verification: Run the usage report check and confirm it passes.
    verify: bash bundle/.ralph/usage-report.sh --workspace .
    status: pending
---
# Verify-to-complete test
EOF

  mkdir -p "$workspace/bundle/.ralph"
  cat <<EOF > "$workspace/bundle/.ralph/usage-report.sh"
#!/usr/bin/env bash
printf 'ok\n' >"$verify_script"
exit 0
EOF
  chmod +x "$workspace/bundle/.ralph/usage-report.sh"

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETEEarlier note without newline boundary"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$status" -eq 0 ]
  [ -f "$verify_script" ]
  grep -Fq 'id: verify-complete' "$plan_file"
  [ "$(grep -c '^    status: completed$' "$plan_file")" -eq 1 ]

  rm -rf "$workspace"
}

@test "demux ignores completion marker in tool_result shell output" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"

  local tmp_dir usage_file
  tmp_dir="$(mktemp -d)"
  usage_file="$tmp_dir/usage.json"

  cat <<'EOF' > "$tmp_dir/stream.ndjson"
{"type":"user","message":{"content":[{"type":"tool_result","content":"AGENT_INVOCATION_COMPLETE\n"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Still working.\n"}]}}
EOF

  python3 "$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py" \
    claude /dev/null "$usage_file" <"$tmp_dir/stream.ndjson" >/dev/null

  jq -e '.completion_sentinel_seen == false' "$usage_file"

  cat <<'EOF' > "$tmp_dir/stream-assistant.ndjson"
{"type":"assistant","message":{"content":[{"type":"text","text":"Done.\nAGENT_INVOCATION_COMPLETE\n"}]}}
EOF

  python3 "$REPO_ROOT/bundle/.ralph/python/run-plan-cli-json-demux.py" \
    claude /dev/null "$usage_file" <"$tmp_dir/stream-assistant.ndjson" >/dev/null

  jq -e '.completion_sentinel_seen == true' "$usage_file"

  rm -rf "$tmp_dir"
}

@test "runner accepts first-pass VERIFICATION_RESULT PASS for prose verification without extra retry" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home counter
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  counter="$workspace/agent-calls.txt"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PROSE.plan.md"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: prose-verify
    content: Add the savings panel to the usage hub
    verification: Open the usage hub in a browser and confirm the savings panel renders (the headline number matches the CLI) and looks correct.
    status: pending
---
# Prose verification test
EOF

  cat <<EOF > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
n=0
[[ -f "$counter" ]] && n=\$(cat "$counter")
n=\$((n+1)); printf '%s' "\$n" > "$counter"
printf '%s\n' "VERIFICATION_RESULT: PASS"
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=4

  [ "$status" -eq 0 ]
  [ "$(grep -c '^    status: completed$' "$plan_file")" -eq 1 ]
  ! grep -Fq 'status: pending' "$plan_file"
  [[ "$output" != *"Verification required for TODO"* ]]
  [[ "$output" != *"syntax error"* ]]
  [[ "$output" != *"exit=2"* ]]
  [ "$(cat "$counter")" -eq 1 ]

  rm -rf "$workspace"
}

@test "runner never runs prose verification as a shell command and stays bounded without a result" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PROSE.plan.md"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: prose-verify
    content: Add the savings panel to the usage hub
    verification: Build the server (e.g. npm run build) and confirm the panel works.
    status: pending
---
# Prose verification bound test
EOF

  # Agent never reports VERIFICATION_RESULT, so the TODO stays open and the run
  # stops at the gutter limit instead of looping forever. The prose (which has
  # parentheses) must never be executed as a shell command.
  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=20 CURSOR_PLAN_GUTTER_ITER=2

  [ "$status" -ne 0 ]
  [ "$(grep -c '^    status: pending$' "$plan_file")" -eq 1 ]
  ! grep -Fq 'status: completed' "$plan_file"
  [[ "$output" == *"did not confirm verification"* ]]
  [[ "$output" != *"syntax error"* ]]
  [[ "$output" != *"exit=2"* ]]

  rm -rf "$workspace"
}

@test "runner falls back to strict Verify command only when the agent omitted a verdict" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/CMD.plan.md"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: cmd-verify
    content: Wire the savings calculator
    verification: Run the calculator checks and confirm they pass.
    verify: bash check.sh
    status: pending
---
# Command verification test
EOF

  cat <<'EOF' > "$workspace/check.sh"
#!/usr/bin/env bash
exit 1
EOF

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "AGENT_INVOCATION_COMPLETE"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home"

  [ "$(grep -c '^    status: pending$' "$plan_file")" -eq 1 ]
  ! grep -Fq 'status: completed' "$plan_file"
  [[ "$output" == *"Post-verification failed"* ]]

  rm -rf "$workspace"
}

@test "first-pass prompt includes completion helper request for strict Verify metadata too" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home cursor_record
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  cursor_record="$workspace/cursor.args"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PROSE-PROMPT.plan.md"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: prose-prompt-verify
    content: Add the savings panel
    verification: Open the usage hub in a browser and confirm the savings panel renders correctly.
    verify: bash scripts/run-bats.sh
    status: pending
---
# Prose verification prompt test
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

@test "first-pass prompt omits VERIFICATION_RESULT request when no verification step present" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  local workspace plan_file bin_dir session_home cursor_record
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  cursor_record="$workspace/cursor.args"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/NOVERIFY-PROMPT.plan.md"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: no-verify-todo
    content: Implement a simple helper function
    status: pending
---
# No verification prompt test
EOF

  setup_prompt_capture_stub "$bin_dir" "$cursor_record"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    CURSOR_PLAN_MAX_ITER=1

  [ -s "$cursor_record" ]
  ! grep -Fq "VERIFICATION_RESULT" "$cursor_record"

  rm -rf "$workspace"
}

@test "runner refuses completion while outstanding background job is running" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home todo_body log_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  todo_body="wait for outstanding job before completion"
  cat <<EOF > "$plan_file"
# Outstanding job completion gate
- [ ] ${todo_body}
EOF

  cat <<EOF > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
ralph_bg_job_create "job-outstanding-running" "sleep 999" "runner-mark-test" 3600 2 \$\$ >/dev/null
ralph_bg_job_mark_launched "job-outstanding-running" 4242 "setsid" "true" >/dev/null
ralph_bg_job_mark_running "job-outstanding-running" >/dev/null
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: SKIPPED"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_BG_JOBS=1 CURSOR_PLAN_MAX_ITER=1

  grep -Fq -- "- [ ] ${todo_body}" "$plan_file"
  ! grep -Fq -- "- [x] ${todo_body}" "$plan_file"
  log_file="$(runner_mark_output_log_for_plan "$workspace" "$plan_file")"
  [ -f "$log_file" ]
  grep -Fq "background job blocks completion: job_id=job-outstanding-running state=running" "$log_file"

  ralph_test_rm_workspace "$workspace"
}

@test "runner refuses completion while terminal background job is unconsumed" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home todo_body log_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  todo_body="wait for terminal job consumption before completion"
  cat <<EOF > "$plan_file"
# Terminal job completion gate
- [ ] ${todo_body}
EOF

  cat <<EOF > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
ralph_bg_job_create "job-terminal-unconsumed" "sleep 999" "runner-mark-test" 3600 2 \$\$ >/dev/null
ralph_bg_job_mark_launched "job-terminal-unconsumed" 4242 "setsid" "true" >/dev/null
ralph_bg_job_mark_running "job-terminal-unconsumed" >/dev/null
ralph_bg_job_mark_terminal "job-terminal-unconsumed" "passed" >/dev/null
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: SKIPPED"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_BG_JOBS=1 CURSOR_PLAN_MAX_ITER=1

  grep -Fq -- "- [ ] ${todo_body}" "$plan_file"
  ! grep -Fq -- "- [x] ${todo_body}" "$plan_file"
  log_file="$(runner_mark_output_log_for_plan "$workspace" "$plan_file")"
  [ -f "$log_file" ]
  grep -Fq "background job blocks completion: job_id=job-terminal-unconsumed state=terminal" "$log_file"

  ralph_test_rm_workspace "$workspace"
}

@test "runner completes TODO when stale foreign background job record exists" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home todo_body line_num
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  todo_body="ignore stale foreign background job on completion"
  line_num="2"
  cat <<EOF > "$plan_file"
# Stale foreign job completion gate
- [ ] ${todo_body}
EOF

  runner_mark_seed_bg_job "$session_home" "$plan_file" "$todo_body" "$line_num" \
    "job-stale-foreign" "running" "run-foreign" "hash-stale-not-current"

  cat <<'EOF' > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: SKIPPED"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_BG_JOBS=1 CURSOR_PLAN_MAX_ITER=1

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] ${todo_body}" "$plan_file"

  ralph_test_rm_workspace "$workspace"
}

@test "runner completes TODO when background job record is already consumed" {
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local workspace plan_file bin_dir session_home todo_body log_file
  workspace="$(mktemp -d)"
  bin_dir="$workspace/bin"
  session_home="$workspace/.sessions"
  mkdir -p "$bin_dir" "$session_home"
  setup_stub_run_plan_support "$workspace"

  plan_file="$workspace/PLAN.md"
  todo_body="allow completion after consumed background job"
  cat <<EOF > "$plan_file"
# Consumed job completion gate
- [ ] ${todo_body}
EOF

  cat <<EOF > "$bin_dir/cursor-agent"
#!/usr/bin/env bash
set -euo pipefail
source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
ralph_bg_job_create "job-already-consumed" "sleep 999" "runner-mark-test" 3600 2 \$\$ >/dev/null
ralph_bg_job_mark_launched "job-already-consumed" 4242 "setsid" "true" >/dev/null
ralph_bg_job_mark_running "job-already-consumed" >/dev/null
ralph_bg_job_mark_terminal "job-already-consumed" "passed" >/dev/null
ralph_bg_job_consume "job-already-consumed" >/dev/null
printf '%s\n' "TODO_COMPLETION: COMPLETE"
printf '%s\n' "TODO_VERIFICATION: SKIPPED"
exit 0
EOF
  chmod +x "$bin_dir/cursor-agent"

  run_plan_with_stub "$workspace" "$bin_dir" "$plan_file" "$session_home" \
    RALPH_BG_JOBS=1 CURSOR_PLAN_MAX_ITER=1

  [ "$status" -eq 0 ]
  grep -Fq -- "- [x] ${todo_body}" "$plan_file"

  ralph_test_rm_workspace "$workspace"
}
