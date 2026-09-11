#!/usr/bin/env bats
# shellcheck shell=bash
# Coverage for stable/volatile prompt ordering in run-plan-core.sh:
#   - Claude keeps the stable block separate (passed via --append-system-prompt).
#   - Every non-Claude runtime places the byte-identical stable block first.

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
  if [[ "$RUNTIME" == "claude" ]]; then
    return 0
  fi
  PROMPT="$(ralph_run_plan_assemble_prompt_ordered "" "$PROMPT_STATIC" "$PROMPT")"
}

@test "opencode places static block before the per-TODO text (enabled)" {
  local todo_prompt='Complete exactly this TODO and nothing else:

**TODO (line 7):** Fix the widget'
  RALPH_MODE=ralph apply_merge "opencode" "$todo_prompt" "STATIC-BLOCK agent context"
  [ "$PROMPT" = "STATIC-BLOCK agent context"$'\n\n'"$todo_prompt" ]
  local prefix="${PROMPT%%\*\*TODO*}"
  [[ "$prefix" == *"STATIC-BLOCK agent context"* ]]
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

# D4 / F6: Claude ralph/hybrid catalog steers exploration to native Read/Grep/Glob;
# proxy shell remains primary for shell; proxy read is for plan roots / batch only.
@test "claude ralph catalog guidance prefers native exploration over proxy read/search" {
  run ralph_mode_prompt_guidance_ralph_catalog claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"are the primary exploration tools"* ]]
  [[ "$output" == *"Native"* && "$output" == *"Grep"* && "$output" == *"Glob"* ]]
  [[ "$output" == *"mcp__ralph__ralph_proxy_shell"* ]]
  [[ "$output" == *"read-only plan roots"* ]]
  [[ "$output" == *"mcp__ralph__ralph_proxy_batch"* ]]
  [[ "$output" != *"primary path for read"* ]]
  [[ "$output" != *"does NOT satisfy that requirement"* ]]
  [[ "$output" != *"use these as your primary path for read/search"* ]]
}

@test "claude hybrid guidance keeps native-first exploration catalog wording" {
  run ralph_mode_prompt_guidance claude hybrid
  [ "$status" -eq 0 ]
  [[ "$output" == *"are the primary exploration tools"* ]]
  [[ "$output" == *"mcp__ralph__ralph_proxy_shell"* ]]
  [[ "$output" != *"primary path for read"* ]]
}

# D4 / F6 (other runtimes): same native-first exploration catalog; proxy shell
# for shell; proxy read reserved for plan roots / batch.
@test "cursor ralph catalog guidance prefers native exploration over proxy read/search" {
  run ralph_mode_prompt_guidance_ralph_catalog cursor
  [ "$status" -eq 0 ]
  [[ "$output" == *"are the primary exploration tools"* ]]
  [[ "$output" == *"ralph_proxy_shell"* ]]
  [[ "$output" == *"read-only plan roots"* ]]
  [[ "$output" == *"ralph_proxy_batch"* ]]
  [[ "$output" != *"primary path for read"* ]]
  [[ "$output" != *"Use native \`Read\` only immediately before"* ]]
}

@test "opencode ralph catalog guidance prefers native exploration over proxy read/search" {
  run ralph_mode_prompt_guidance_ralph_catalog opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"are the primary exploration tools"* ]]
  [[ "$output" == *"ralph_proxy_shell"* ]]
  [[ "$output" == *"read-only plan roots"* ]]
  [[ "$output" != *"primary path for read"* ]]
  [[ "$output" != *"Use native \`Read\` only immediately before"* ]]
}

@test "codex ralph catalog guidance prefers native exploration over proxy read/search" {
  run ralph_mode_prompt_guidance_ralph_catalog_codex ralph
  [ "$status" -eq 0 ]
  [[ "$output" == *"are the primary exploration tools"* ]]
  [[ "$output" == *"ralph_proxy_shell"* ]]
  [[ "$output" == *"read-only plan roots"* ]]
  [[ "$output" != *"primary path for read"* ]]
  [[ "$output" != *"Prefer Ralph tooling first"* ]]
  [[ "$output" != *"Use \`ralph_proxy_read\` for large file reads instead of native"* ]]
}

@test "codex hybrid guidance keeps native-first exploration catalog wording" {
  run ralph_mode_prompt_guidance_ralph_catalog_codex hybrid
  [ "$status" -eq 0 ]
  [[ "$output" == *"are the primary exploration tools"* ]]
  [[ "$output" == *"ralph_proxy_shell"* ]]
  [[ "$output" != *"primary path for read"* ]]
  [[ "$output" != *"Prefer Ralph tooling when it is healthy for read/search"* ]]
}

@test "antigravity ralph catalog guidance prefers native exploration over proxy read/search" {
  run ralph_mode_prompt_guidance_ralph_catalog antigravity
  [ "$status" -eq 0 ]
  [[ "$output" == *"are the primary exploration tools"* ]]
  [[ "$output" == *"ralph_proxy_shell"* ]]
  [[ "$output" == *"read-only plan roots"* ]]
  [[ "$output" != *"primary path for read"* ]]
}

@test "hybrid guidance footer does not re-steer exploration to proxy read/search" {
  run ralph_mode_prompt_guidance cursor hybrid
  [ "$status" -eq 0 ]
  [[ "$output" == *"are the primary exploration tools"* ]]
  [[ "$output" == *"When Ralph tooling is slow, failing, or unsuitable"* ]]
  [[ "$output" != *"primary path for read"* ]]
  [[ "$output" != *"Prefer Ralph tooling when it is healthy for read/search"* ]]
}

# Coverage for ralph_mode_prompt_guidance_ralph_failure_footer: agents must
# cut over to native tools on a Ralph tooling failure when native fallback is
# available (hybrid / non-strict ralph), and only pause for the operator when
# strict proxy forbids native fallback. Regression guard against agents getting
# stuck asking the operator to "restore the Ralph MCP connection".
@test "hybrid failure footer tells agents to cut over to native tools" {
  run ralph_mode_prompt_guidance claude hybrid
  [ "$status" -eq 0 ]
  [[ "$output" == *"cut over to the native runtime tools"* ]]
  [[ "$output" == *"do not stop to ask the operator"* ]]
  [[ "$output" != *"write one structured human-request record to pending-human.txt and stop"* ]]
}

@test "non-strict ralph failure footer cuts over to available native tools" {
  RALPH_STRICT_PROXY=0 RALPH_AGENT_TOOL_ACCESS_REQUIRE_PROXY=0 run ralph_mode_prompt_guidance claude ralph
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cut over to the native runtime tools that remain available"* ]]
  [[ "$output" != *"write one structured human-request record to pending-human.txt and stop"* ]]
}

@test "strict ralph failure footer keeps the pending-human pause" {
  RALPH_STRICT_PROXY=1 run ralph_mode_prompt_guidance claude ralph
  [ "$status" -eq 0 ]
  [[ "$output" == *"write one structured human-request record to pending-human.txt and stop"* ]]
  [[ "$output" != *"cut over to the native runtime tools"* ]]
}

@test "failure footer variants select correct guidance" {
  run ralph_mode_prompt_guidance_ralph_failure_footer full
  [[ "$output" == *"Immediately cut over to the native runtime tools"* ]]
  run ralph_mode_prompt_guidance_ralph_failure_footer partial
  [[ "$output" == *"complete as much of the TODO as they cover"* ]]
  run ralph_mode_prompt_guidance_ralph_failure_footer none
  [[ "$output" == *"write one structured human-request record to pending-human.txt and stop"* ]]
  # Default (no arg) is the conservative pause.
  run ralph_mode_prompt_guidance_ralph_failure_footer
  [[ "$output" == *"write one structured human-request record to pending-human.txt and stop"* ]]
}
