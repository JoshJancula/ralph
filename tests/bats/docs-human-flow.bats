#!/usr/bin/env bats

@test "README documents the interactive-first human flow and fallback artifacts" {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  run grep -Fq "interactive-first" "$ROOT_DIR/README.md"
  [ "$status" -eq 0 ]
  run grep -Fq "RALPH_HUMAN_ACK_TOOL" "$ROOT_DIR/README.md"
  [ "$status" -eq 0 ]
  run grep -Fq ".ralph-workspace/sessions" "$ROOT_DIR/README.md"
  [ "$status" -eq 0 ]
}

@test "AGENT-WORKFLOW covers orchestrator escalation and human artifact storage" {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  run grep -Fq "RALPH_HUMAN_ACK_TOOL" "$ROOT_DIR/docs/AGENT-WORKFLOW.md"
  [ "$status" -eq 0 ]
  run grep -Fq "human-replies.md" "$ROOT_DIR/docs/AGENT-WORKFLOW.md"
  [ "$status" -eq 0 ]
  run grep -Fq "interactive-first flow" "$ROOT_DIR/docs/AGENT-WORKFLOW.md"
  [ "$status" -eq 0 ]
}

@test "Worker walkthrough mentions the human artifact namespace path" {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  run grep -Fq ".ralph-workspace/sessions/<RALPH_PLAN_KEY>/human-replies.md" "$ROOT_DIR/docs/worker-ralph-example.md"
  [ "$status" -eq 0 ]
  run grep -Fq "RALPH_HUMAN_ACK_TOOL" "$ROOT_DIR/docs/worker-ralph-example.md"
  [ "$status" -eq 0 ]
  run grep -Fq "interactive-first flow" "$ROOT_DIR/docs/worker-ralph-example.md"
  [ "$status" -eq 0 ]
}
