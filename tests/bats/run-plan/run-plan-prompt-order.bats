#!/usr/bin/env bats
# shellcheck shell=bash
# Coverage for the runtime-specific PROMPT_STATIC merge order in run-plan-core.sh:
# OpenCode places the static block before the per-TODO text (shared cache prefix);
# claude/cursor/codex assembly is unchanged.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RUN_PLAN_CORE_FILE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  TEST_TMPDIR="$(mktemp -d)"

  # Extract the inline PROMPT_STATIC merge block so the ordering logic under test
  # is the exact code shipped in run-plan-core.sh, not a copy.
  MERGE_BLOCK_FILE="$TEST_TMPDIR/prompt-merge-block.sh"
  sed -n '/if \[\[ "\$RUNTIME" == "opencode" && -n "\$PROMPT_STATIC" \]\]; then/,/^    fi$/p' \
    "$RUN_PLAN_CORE_FILE" >"$MERGE_BLOCK_FILE"
  [ -s "$MERGE_BLOCK_FILE" ]
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

apply_merge() {
  RUNTIME="$1"
  PROMPT="$2"
  PROMPT_STATIC="$3"
  # shellcheck disable=SC1090
  source "$MERGE_BLOCK_FILE"
}

@test "extracted merge block covers both opencode and non-claude branches" {
  grep -q 'RUNTIME" == "opencode"' "$MERGE_BLOCK_FILE"
  grep -q 'RUNTIME" != "claude"' "$MERGE_BLOCK_FILE"
}

@test "opencode prompt places static block before the per-TODO text" {
  local todo_prompt='Complete exactly this TODO and nothing else:

**TODO (line 7):** Fix the widget'
  apply_merge "opencode" "$todo_prompt" "STATIC-BLOCK agent context"

  [ "$PROMPT" = "STATIC-BLOCK agent context"$'\n\n'"$todo_prompt" ]
  # Static prefix is byte-identical across invocations: PROMPT starts with it.
  [[ "$PROMPT" == "STATIC-BLOCK agent context"* ]]
  # TODO text appears after the static block.
  local prefix="${PROMPT%%\*\*TODO*}"
  [[ "$prefix" == *"STATIC-BLOCK agent context"* ]]
}

@test "opencode prompt is unchanged when PROMPT_STATIC is empty" {
  apply_merge "opencode" "todo text only" ""
  [ "$PROMPT" = "todo text only" ]
}

@test "cursor prompt assembly is unchanged (static appended after TODO text)" {
  apply_merge "cursor" "todo text" "STATIC-BLOCK"
  [ "$PROMPT" = "todo text"$'\n'"STATIC-BLOCK" ]
}

@test "codex prompt assembly is unchanged (static appended after TODO text)" {
  apply_merge "codex" "todo text" "STATIC-BLOCK"
  [ "$PROMPT" = "todo text"$'\n'"STATIC-BLOCK" ]
}

@test "claude prompt assembly is unchanged (PROMPT_STATIC not merged into PROMPT)" {
  apply_merge "claude" "todo text" "STATIC-BLOCK"
  [ "$PROMPT" = "todo text" ]
  [ "$PROMPT_STATIC" = "STATIC-BLOCK" ]
}

@test "structured plan with block-scalar todo content embeds full body in prompt" {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: multiline-task
    content: |
      Execute these steps:
      1. Verify the setup
      2. Run the tests
      3. Collect metrics
    verification: |
      bash scripts/test.sh
    status: pending
---
# Test plan
EOF

  output="$(
    set -e
    export RALPH_RUN_PLAN_LIBRARY_ONLY=1
    source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
    source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
    unset RALPH_RUN_PLAN_LIBRARY_ONLY

    todo_result="$(get_next_todo "$plan_file")"
    todo_target="$(printf '%s\n' "$todo_result" | cut -d'|' -f2)"
    todo_text="$(printf '%s\n' "$todo_result" | cut -d'|' -f3-)"

    printf '%s\n' "$todo_text"
  )"

  [ -n "$output" ]
  [ "$output" != "|" ]
  [ "$output" != "" ]
  [[ "$output" == *"Execute these steps"* ]]
  [[ "$output" == *"Verify the setup"* ]]
  [[ "$output" == *"Run the tests"* ]]

  todo_bytes="${#output}"
  [ "$todo_bytes" -gt 1 ]

  rm "$plan_file"
}

@test "structured plan todo_bytes metric reflects full block scalar content length" {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  plan_file="$(mktemp)"
  cat <<'EOF' > "$plan_file"
---
todos:
  - id: another-multiline
    content: |
      Line 1
      Line 2
      Line 3
    status: pending
---
# Test plan
EOF

  output="$(
    set -e
    export RALPH_RUN_PLAN_LIBRARY_ONLY=1
    source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
    source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
    unset RALPH_RUN_PLAN_LIBRARY_ONLY

    todo_result="$(get_next_todo "$plan_file")"
    todo_text="$(printf '%s\n' "$todo_result" | cut -d'|' -f3-)"

    printf '%d\n' "${#todo_text}"
  )"

  [ -n "$output" ]
  todo_bytes="$output"
  [ "$todo_bytes" -gt 1 ]
  [ "$todo_bytes" -gt 10 ]

  rm "$plan_file"
}
