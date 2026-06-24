#!/usr/bin/env bats
# shellcheck shell=bash
# Coverage for the named stable/volatile prompt merge in run-plan-core.sh
# (ralph_run_plan_merge_prompt + ralph_run_plan_stable_prefix_enabled):
#   - Claude keeps the stable block separate (passed via --system-prompt).
#   - With stable-prefix ordering enabled (Ralph/hybrid default), every non-Claude
#     runtime places the byte-identical stable block first.
#   - With it disabled (native/no default), OpenCode stays stable-first while
#     Cursor/Codex/Antigravity keep the legacy stable-last order.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEST_TMPDIR="$(mktemp -d)"
  # Source the shipped functions directly (no fragile snippet extraction).
  export RALPH_RUN_PLAN_LIBRARY_ONLY=1
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-core.sh"
  unset RALPH_RUN_PLAN_LIBRARY_ONLY
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

apply_merge() {
  RUNTIME="$1"
  PROMPT="$2"
  PROMPT_STATIC="$3"
  ralph_run_plan_merge_prompt "$RUNTIME"
}

@test "stable-prefix gate follows rollout defaults" {
  RALPH_MODE=ralph RALPH_PROMPT_STABLE_PREFIX="" run ralph_run_plan_stable_prefix_enabled
  [ "$status" -eq 0 ]
  RALPH_MODE=no RALPH_PROMPT_STABLE_PREFIX="" run ralph_run_plan_stable_prefix_enabled
  [ "$status" -eq 1 ]
  RALPH_MODE=no RALPH_PROMPT_STABLE_PREFIX=1 run ralph_run_plan_stable_prefix_enabled
  [ "$status" -eq 0 ]
  RALPH_MODE=ralph RALPH_PROMPT_STABLE_PREFIX=0 run ralph_run_plan_stable_prefix_enabled
  [ "$status" -eq 1 ]
  RALPH_MODE=ralph RALPH_PROMPT_STABLE_PREFIX=bogus run ralph_run_plan_stable_prefix_enabled
  [ "$status" -eq 2 ]
}

@test "opencode places static block before the per-TODO text (enabled)" {
  local todo_prompt='Complete exactly this TODO and nothing else:

**TODO (line 7):** Fix the widget'
  RALPH_MODE=ralph apply_merge "opencode" "$todo_prompt" "STATIC-BLOCK agent context"
  [ "$PROMPT" = "STATIC-BLOCK agent context"$'\n\n'"$todo_prompt" ]
  local prefix="${PROMPT%%\*\*TODO*}"
  [[ "$prefix" == *"STATIC-BLOCK agent context"* ]]
}

@test "opencode is stable-first even when stable-prefix is disabled" {
  RALPH_MODE=no RALPH_PROMPT_STABLE_PREFIX=0 apply_merge "opencode" "todo text" "STATIC-BLOCK"
  [ "$PROMPT" = "STATIC-BLOCK"$'\n\n'"todo text" ]
}

@test "merge is unchanged when PROMPT_STATIC is empty" {
  RALPH_MODE=ralph apply_merge "opencode" "todo text only" ""
  [ "$PROMPT" = "todo text only" ]
  RALPH_MODE=ralph apply_merge "cursor" "todo text only" ""
  [ "$PROMPT" = "todo text only" ]
}

@test "cursor is stable-first when stable-prefix is enabled" {
  RALPH_MODE=ralph apply_merge "cursor" "todo text" "STATIC-BLOCK"
  [ "$PROMPT" = "STATIC-BLOCK"$'\n\n'"todo text" ]
}

@test "codex is stable-first when stable-prefix is enabled" {
  RALPH_MODE=ralph apply_merge "codex" "todo text" "STATIC-BLOCK"
  [ "$PROMPT" = "STATIC-BLOCK"$'\n\n'"todo text" ]
}

@test "antigravity is stable-first when stable-prefix is enabled" {
  RALPH_MODE=ralph apply_merge "antigravity" "todo text" "STATIC-BLOCK"
  [ "$PROMPT" = "STATIC-BLOCK"$'\n\n'"todo text" ]
}

@test "cursor keeps legacy stable-last order when disabled" {
  RALPH_MODE=no RALPH_PROMPT_STABLE_PREFIX=0 apply_merge "cursor" "todo text" "STATIC-BLOCK"
  [ "$PROMPT" = "todo text"$'\n'"STATIC-BLOCK" ]
}

@test "codex keeps legacy stable-last order when disabled" {
  RALPH_MODE=no RALPH_PROMPT_STABLE_PREFIX=0 apply_merge "codex" "todo text" "STATIC-BLOCK"
  [ "$PROMPT" = "todo text"$'\n'"STATIC-BLOCK" ]
}

@test "claude prompt assembly is unchanged (PROMPT_STATIC not merged into PROMPT)" {
  RALPH_MODE=ralph apply_merge "claude" "todo text" "STATIC-BLOCK"
  [ "$PROMPT" = "todo text" ]
  [ "$PROMPT_STATIC" = "STATIC-BLOCK" ]
}

@test "stable-prefix fingerprint is deterministic and content-free" {
  local fp1 fp2
  fp1="$(ralph_run_plan_stable_prefix_fingerprint "STATIC-BLOCK agent context")"
  fp2="$(ralph_run_plan_stable_prefix_fingerprint "STATIC-BLOCK agent context")"
  [ -n "$fp1" ]
  [ "$fp1" = "$fp2" ]
  [[ "$fp1" != *"STATIC-BLOCK"* ]]
  local fp3
  fp3="$(ralph_run_plan_stable_prefix_fingerprint "different content")"
  [ "$fp1" != "$fp3" ]
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

@test "continuation-summary gate follows rollout defaults" {
  RALPH_MODE=ralph RALPH_CONTINUATION_SUMMARY="" run ralph_run_plan_continuation_summary_enabled
  [ "$status" -eq 0 ]
  RALPH_MODE=no RALPH_CONTINUATION_SUMMARY="" run ralph_run_plan_continuation_summary_enabled
  [ "$status" -eq 1 ]
  RALPH_MODE=no RALPH_CONTINUATION_SUMMARY=1 run ralph_run_plan_continuation_summary_enabled
  [ "$status" -eq 0 ]
  RALPH_MODE=ralph RALPH_CONTINUATION_SUMMARY=0 run ralph_run_plan_continuation_summary_enabled
  [ "$status" -eq 1 ]
  RALPH_MODE=ralph RALPH_CONTINUATION_SUMMARY=bogus run ralph_run_plan_continuation_summary_enabled
  [ "$status" -eq 2 ]
}

@test "continuation summary injects after stable prefix and before TODO text" {
  local todo_prompt='Complete exactly this TODO and nothing else:

**TODO (line 7):** Fix the widget'
  local summary='## Continuation summary

Completed work (runner-verified, deterministic):

- **#1 line 5**
  - Summary: prior work done
'
  RALPH_MODE=ralph
  PROMPT="$todo_prompt"
  PROMPT_STATIC="STATIC-BLOCK agent context"
  PROMPT="${summary}"$'\n\n'"${PROMPT}"
  apply_merge "cursor" "$PROMPT" "$PROMPT_STATIC"
  [[ "$PROMPT" == "STATIC-BLOCK agent context"$'\n\n'"$summary"$'\n\n'"$todo_prompt" ]]
  local prefix="${PROMPT%%Complete exactly*}"
  [[ "$prefix" == *"STATIC-BLOCK agent context"* ]]
  [[ "$prefix" == *"Continuation summary"* ]]
}

@test "hierarchical continuation-summary gate follows rollout defaults" {
  local py_dir="$REPO_ROOT/bundle/.ralph/python"
  RALPH_MODE=ralph RALPH_CONTINUATION_SUMMARY_HIERARCHICAL="" run python3 -c "
import sys
sys.path.insert(0, '$py_dir')
import continuation_summary as cs
raise SystemExit(0 if cs.hierarchical_continuation_enabled() else 1)
"
  [ "$status" -eq 0 ]
  RALPH_MODE=no RALPH_CONTINUATION_SUMMARY_HIERARCHICAL="" run python3 -c "
import sys
sys.path.insert(0, '$py_dir')
import continuation_summary as cs
raise SystemExit(0 if not cs.hierarchical_continuation_enabled() else 1)
"
  [ "$status" -eq 0 ]
  RALPH_MODE=no RALPH_CONTINUATION_SUMMARY_HIERARCHICAL=1 run python3 -c "
import sys
sys.path.insert(0, '$py_dir')
import continuation_summary as cs
raise SystemExit(0 if cs.hierarchical_continuation_enabled() else 1)
"
  [ "$status" -eq 0 ]
  RALPH_MODE=ralph RALPH_CONTINUATION_SUMMARY_HIERARCHICAL=0 run python3 -c "
import sys
sys.path.insert(0, '$py_dir')
import continuation_summary as cs
raise SystemExit(0 if not cs.hierarchical_continuation_enabled() else 1)
"
  [ "$status" -eq 0 ]
}

@test "disabled continuation summary leaves prompt unchanged" {
  RALPH_MODE=no RALPH_CONTINUATION_SUMMARY=0
  PROMPT="todo text only"
  PROMPT_STATIC="STATIC-BLOCK"
  apply_merge "cursor" "$PROMPT" "$PROMPT_STATIC"
  [ "$PROMPT" = "todo text only"$'\n'"STATIC-BLOCK" ]
}

@test "progressive-context gate follows rollout defaults" {
  RALPH_MODE=ralph RALPH_PROGRESSIVE_CONTEXT="" run ralph_run_plan_progressive_context_enabled
  [ "$status" -eq 0 ]
  RALPH_MODE=no RALPH_PROGRESSIVE_CONTEXT="" run ralph_run_plan_progressive_context_enabled
  [ "$status" -eq 1 ]
  RALPH_MODE=no RALPH_PROGRESSIVE_CONTEXT=1 run ralph_run_plan_progressive_context_enabled
  [ "$status" -eq 0 ]
  RALPH_MODE=ralph RALPH_PROGRESSIVE_CONTEXT=0 run ralph_run_plan_progressive_context_enabled
  [ "$status" -eq 1 ]
  RALPH_MODE=ralph RALPH_PROGRESSIVE_CONTEXT=bogus run ralph_run_plan_progressive_context_enabled
  [ "$status" -eq 2 ]
}

@test "progressive volatile context injects before stable merge" {
  local todo_prompt='Complete exactly this TODO and nothing else:

**TODO (line 7):** Fix the widget'
  local volatile='**Selected rules and skills (full bodies for this TODO):**

--- Rule file: `.cursor/rules/widget.md` ---
Widget rule body.'
  RALPH_MODE=ralph
  PROMPT="$todo_prompt"
  PROMPT="${volatile}"$'\n\n'"${PROMPT}"
  PROMPT_STATIC="STATIC tier1 metadata"
  apply_merge "cursor" "$PROMPT" "$PROMPT_STATIC"
  [[ "$PROMPT" == "STATIC tier1 metadata"$'\n\n'"$volatile"$'\n\n'"$todo_prompt" ]]
}
