#!/usr/bin/env bats

# Writing an operator's routing selection back into a workflow source.
# Line-based frontmatter edits: the rest of the file is preserved byte for
# byte, an existing key is replaced rather than duplicated, and the result must
# still pass plan_workflow_validate.

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
source "$BATS_TEST_DIRNAME/../../../bundle/.ralph/bash-lib/plan-todo.sh"

PERSIST="$BATS_TEST_DIRNAME/../../../bundle/.ralph/python/workflow-routing-persist.py"

setup() {
  WRP_TMP="$(mktemp -d)"
  WRP_WF="$WRP_TMP/demo.workflow.md"
  write_neutral_wf "$WRP_WF"
}

teardown() { rm -rf "$WRP_TMP"; }

write_neutral_wf() {
  printf '%s\n' \
    '---' \
    'name: demo' \
    'overview: demo workflow' \
    'kind: workflow' \
    'mode: dependency' \
    'pipeline:' \
    '  maxParallel: 1' \
    '  stages:' \
    '    - id: first' \
    '      instructions: |' \
    '        Investigate {{TASK}}.' \
    '    - id: second' \
    '      dependsOn:' \
    '        - first' \
    '      instructions: |' \
    '        Implement {{TASK}}.' \
    'todos:' \
    '  - id: first-work' \
    '    stage: first' \
    '    content: Investigate {{TASK}}' \
    '    verification: Confirm the notes exist.' \
    '    status: pending' \
    '---' \
    '# body' >"$1"
}

persist() { python3 "$PERSIST" "$WRP_WF" "$WRP_TMP/out.md" "$@"; }

@test "defaults mode writes a valid defaults block" {
  run persist defaults claude sonnet
  [ "$status" -eq 0 ]
  grep -qx 'defaults:' "$WRP_TMP/out.md"
  grep -qx '  runtime: claude' "$WRP_TMP/out.md"
  grep -qx '  model: sonnet' "$WRP_TMP/out.md"
  run plan_workflow_validate "$WRP_TMP/out.md"
  [ "$status" -eq 0 ]
}

@test "defaults mode omits the model when none was chosen" {
  run persist defaults claude ""
  [ "$status" -eq 0 ]
  grep -qx '  runtime: claude' "$WRP_TMP/out.md"
  # `! cmd` is exempt from set -e, so assert on an explicit status instead.
  run grep -qE '^  model:' "$WRP_TMP/out.md"
  [ "$status" -ne 0 ]
  run plan_workflow_validate "$WRP_TMP/out.md"
  [ "$status" -eq 0 ]
}

@test "defaults mode replaces an existing block instead of duplicating it" {
  persist defaults claude sonnet
  cp "$WRP_TMP/out.md" "$WRP_WF"
  run persist defaults codex gpt-5
  [ "$status" -eq 0 ]
  [ "$(grep -c '^defaults:$' "$WRP_TMP/out.md")" -eq 1 ]
  [ "$(grep -c '^  runtime: ' "$WRP_TMP/out.md")" -eq 1 ]
  grep -qx '  runtime: codex' "$WRP_TMP/out.md"
  grep -qx '  model: gpt-5' "$WRP_TMP/out.md"
}

@test "stages mode writes routing onto the named stages only" {
  run persist stages "first=claude,haiku" "second=codex,gpt-5"
  [ "$status" -eq 0 ]
  grep -qx '      runtime: claude' "$WRP_TMP/out.md"
  grep -qx '      model: haiku' "$WRP_TMP/out.md"
  grep -qx '      runtime: codex' "$WRP_TMP/out.md"
  grep -qx '      model: gpt-5' "$WRP_TMP/out.md"
  run plan_workflow_validate "$WRP_TMP/out.md"
  [ "$status" -eq 0 ]
}

@test "stages mode preserves the instructions block it writes above" {
  run persist stages "first=claude,haiku"
  [ "$status" -eq 0 ]
  grep -qx '        Investigate {{TASK}}.' "$WRP_TMP/out.md"
  grep -qx '        Implement {{TASK}}.' "$WRP_TMP/out.md"
  grep -qx '      dependsOn:' "$WRP_TMP/out.md"
  grep -qx '        - first' "$WRP_TMP/out.md"
}

@test "stages mode replaces existing stage routing instead of duplicating it" {
  persist stages "first=claude,haiku"
  cp "$WRP_TMP/out.md" "$WRP_WF"
  run persist stages "first=claude,opus"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^      runtime: ' "$WRP_TMP/out.md")" -eq 1 ]
  [ "$(grep -c '^      model: ' "$WRP_TMP/out.md")" -eq 1 ]
  grep -qx '      model: opus' "$WRP_TMP/out.md"
}

@test "stages mode leaves the body after the frontmatter untouched" {
  run persist stages "first=claude,haiku"
  [ "$status" -eq 0 ]
  grep -qx '# body' "$WRP_TMP/out.md"
  [ "$(grep -c '^---$' "$WRP_TMP/out.md")" -eq 2 ]
}

@test "stages mode rejects an unknown stage id" {
  run persist stages "nope=claude,haiku"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found in pipeline.stages"* ]]
}

@test "a malformed stage spec is rejected" {
  run persist stages "first"
  [ "$status" -ne 0 ]
  [[ "$output" == *"<stage-id>=<runtime>"* ]]
}

@test "an unknown mode is rejected" {
  run persist sideways claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown mode"* ]]
}
