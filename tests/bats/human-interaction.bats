#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../.cursor/ralph/bash-lib/human-interaction.sh"

setup() {
  TTY_HUMAN_HISTORY=""
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
