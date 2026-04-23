#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../.ralph/bash-lib/human-interaction.sh"

setup() {
  TTY_HUMAN_HISTORY=""
}

create_cursor_workspace() {
  local workspace="$1"
  mkdir -p "$workspace/.cursor/ralph"
  cat <<'EOF' >"$workspace/.cursor/ralph/select-model.sh"
#!/usr/bin/env bash
select_model_cursor(){ echo "auto"; }
EOF
  chmod +x "$workspace/.cursor/ralph/select-model.sh"
  mkdir -p "$workspace/.ralph"
  cat <<'EOF' >"$workspace/.ralph/agent-config-tool.sh"
#!/usr/bin/env bash
case "$1" in
  list|validate|model|context|allowed-tools|downstream-stages)
    exit 0
    ;;
  *)
    echo "unsupported agent-config subcommand $1" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$workspace/.ralph/agent-config-tool.sh"
}

create_stub_cursor_agent() {
  local dir="$1"
  cat <<'EOF' >"$dir/cursor-agent"
#!/usr/bin/env bash
printf 'cursor-agent stub\n'
exit 0
EOF
  chmod +x "$dir/cursor-agent"
}

@test "interactive history block includes question and answer" {
  ralph_record_interactive_reply "What should I do?" "Answer in-line."
  run ralph_interactive_history_block
  [ "$status" -eq 0 ]
  [[ "$output" == *"Agent asked"* ]]
  [[ "$output" == *"Operator answered"* ]]
  [[ "$output" == *"What should I do?"* ]]
  [[ "$output" == *"Answer in-line."* ]]
}

@test "human ack helper uses the configured tool" {
  local tmpdir tool
  tmpdir="$(mktemp -d)"
  tool="$tmpdir/ack-tool.sh"
  cat <<'EOF' >"$tool"
#!/usr/bin/env bash
printf 'ready'
EOF
  chmod +x "$tool"

  unset RALPH_HUMAN_ACK_TOOL
  export RALPH_HUMAN_ACK_TOOL="$tool"

  run ralph_human_ack_tool_path
  [ "$status" -eq 0 ]
  [ "$output" = "$tool" ]

  unset RALPH_HUMAN_ACK_TOOL
  rm -rf "$tmpdir"
}

@test "human exchange persistence writes artifact" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  export HUMAN_ARTIFACTS_DIR="$tmpdir"

  run ralph_persist_human_exchange "Offline question" "Offline answer"
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  grep -q "Offline question" "$output"
  grep -q "Offline answer" "$output"

  rm -rf "$tmpdir"
}

@test "orchestrator bridge forwards question when a tool is configured" {
  local tmpdir question_file tool
  tmpdir="$(mktemp -d)"
  question_file="$tmpdir/question.txt"
  printf 'What now?' >"$question_file"

  tool="$tmpdir/ack-tool.sh"
  cat <<'EOF' >"$tool"
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --human-ack-question-file)
      shift
      question_file="$1"
      ;;
    --human-ack-plan)
      shift
      plan="$1"
      ;;
    --human-ack-workspace)
      shift
      workspace="$1"
      ;;
    *)
      shift
      ;;
  esac
done
printf 'tool-plan=%s tool-workspace=%s question=%s\n' "$plan" "$workspace" "$(cat "$question_file")"
EOF
  chmod +x "$tool"

  export RALPH_HUMAN_ACK_TOOL="$tool"
  export WORKSPACE="/tmp/project"
  export PLAN_PATH="PLAN.md"

  run ralph_forward_human_question_to_orchestrator "$question_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool-plan=PLAN.md"* ]]
  [[ "$output" == *"tool-workspace=/tmp/project"* ]]
  [[ "$output" == *"question=What now?"* ]]

  rm -rf "$tmpdir"
}

@test "run-plan creates pending-human.txt with mode 600 when operator dialog is required" {
  RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local tmp_workspace stub_dir session_home pending_file mode
  tmp_workspace="$(mktemp -d)"
  create_cursor_workspace "$tmp_workspace"
  printf '%s\n' "- [ ] ask the user for help" "- [ ] follow-up work" >"$tmp_workspace/PLAN.md"

  session_home="$tmp_workspace/.sessions"
  mkdir -p "$session_home"

  stub_dir="$(mktemp -d)"
  cat <<'EOF' >"$stub_dir/cursor-agent"
#!/usr/bin/env bash
plan_file="${WORKSPACE:-}/PLAN.md"
[[ -z "$WORKSPACE" ]] && plan_file="PLAN.md"
if [[ -f "$plan_file" ]]; then
  python3 - "$plan_file" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("- [ ] ask the user for help", "- [x] ask the user for help", 1)
path.write_text(text)
PY
fi
printf 'cursor-agent stub\n'
exit 0
EOF
  chmod +x "$stub_dir/cursor-agent"

  run bash -c '
    set -euo pipefail
    export RALPH_PLAN_SESSION_HOME="$1/.sessions"
    export RALPH_PLAN_WORKSPACE_ROOT="$1/.ralph-workspace"
    export RALPH_HUMAN_OFFLINE_EXIT=1
    export RALPH_HUMAN_POLL_INTERVAL=0
    export RALPH_USAGE_RISKS_ACKNOWLEDGED=1
    PATH="$2:$PATH"
    export PATH
    CURSOR_PLAN_NO_COLOR=1
    CLAUDE_PLAN_NO_COLOR=1
    CODEX_PLAN_NO_COLOR=1
    export CURSOR_PLAN_NO_COLOR CLAUDE_PLAN_NO_COLOR CODEX_PLAN_NO_COLOR
    "$3" --runtime cursor --plan PLAN.md --workspace "$1" --non-interactive --model auto
  ' _ "$tmp_workspace" "$stub_dir:$PATH" "$RUN_PLAN_SH"

  session_dir="$(find "$session_home" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "$session_dir" ]
  pending_file="$session_dir/pending-human.txt"
  [ -f "$pending_file" ]

  mode="$(TARGET_FILE="$pending_file" python3 - <<'PY'
import os
path = os.environ["TARGET_FILE"]
print(oct(os.stat(path).st_mode & 0o777))
PY
)"
  [ "$mode" = "0o600" ]

  rm -rf "$stub_dir" "$tmp_workspace"
}

@test "run-plan writes runtime-specific session-id file with mode 600 when resume override is provided" {
  RUN_PLAN_SH="$REPO_ROOT/bundle/.ralph/run-plan.sh"
  [ -f "$RUN_PLAN_SH" ] || skip "bundle run-plan missing"

  local tmp_workspace session_home session_id_file mode
  tmp_workspace="$(mktemp -d)"
  create_cursor_workspace "$tmp_workspace"
  printf '%s\n' "- [x] done" >"$tmp_workspace/PLAN.md"

  session_home="$tmp_workspace/.sessions"
  mkdir -p "$session_home"

  run bash -c '
    set -euo pipefail
    export RALPH_PLAN_SESSION_HOME="$1/.sessions"
    export RALPH_PLAN_WORKSPACE_ROOT="$1/.ralph-workspace"
    export RESUME_SESSION_ID_OVERRIDE="resume-123"
    "$2" --runtime cursor --plan PLAN.md --workspace "$1" --non-interactive --model auto --resume resume-123
  ' _ "$tmp_workspace" "$RUN_PLAN_SH"

  session_dir="$(find "$session_home" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "$session_dir" ]
  session_id_file="$session_dir/session-id.cursor.txt"
  [ -f "$session_id_file" ]

  mode="$(TARGET_FILE="$session_id_file" python3 - <<'PY'
import os
path = os.environ["TARGET_FILE"]
print(oct(os.stat(path).st_mode & 0o777))
PY
)"
  [ "$mode" = "0o600" ]

  rm -rf "$tmp_workspace"
}

@test "operator response file owned by another UID is rejected with a warning" {
  RUN_PLAN_CORE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan-core.sh"
  [ -f "$RUN_PLAN_CORE" ] || skip "bundle run-plan-core missing"

  local human_funcs="$(mktemp)" stub_stat_dir response_file
  sed -n "/^ralph_operator_response_file_owned_by_current_user()/,/^}/p" "$RUN_PLAN_CORE" >"$human_funcs"

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

  response_file="$(mktemp)"
  printf 'answer' >"$response_file"

  run bash -c '
    set -euo pipefail
    PATH="$1:$PATH"
    export PATH
    source "$2"
    OPERATOR_RESPONSE_FILE="$3"
    ralph_operator_response_file_owned_by_current_user "$OPERATOR_RESPONSE_FILE"
  ' _ "$stub_stat_dir:$PATH" "$human_funcs" "$response_file"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ignoring response to prevent injection."* ]]

  rm -f "$human_funcs" "$response_file"
  rm -rf "$stub_stat_dir"
}

@test "orchestrator bridge falls back when the tool fails" {
  local tmpdir question_file tool
  tmpdir="$(mktemp -d)"
  question_file="$tmpdir/question.txt"
  printf 'Something else?' >"$question_file"

  tool="$tmpdir/ack-tool.sh"
  cat <<'EOF' >"$tool"
#!/usr/bin/env bash
>&2 echo "failing tool"
exit 4
EOF
  chmod +x "$tool"

  export RALPH_HUMAN_ACK_TOOL="$tool"
  export WORKSPACE="/tmp/project"
  export PLAN_PATH="PLAN.md"

  run ralph_forward_human_question_to_orchestrator "$question_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failing tool"* ]]

  rm -rf "$tmpdir"
}
