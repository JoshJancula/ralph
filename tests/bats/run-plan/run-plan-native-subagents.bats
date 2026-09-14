#!/usr/bin/env bats
# Standard nativeSubagents contract: off|inherit (default inherit); on removed.
# shellcheck shell=bash

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
# shellcheck disable=SC1090
source "$BATS_TEST_DIRNAME/run-plan-invoke-test-helper.bash"

setup() {
  bats_skip_known_ci_flakes
  VALIDATE_PLAN_SH="$REPO_ROOT/bundle/.ralph/validate-plan.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/plan-todo.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-common.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-claude.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-cursor.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-opencode.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-antigravity.sh"
  run_plan_invoke_test_setup_common
  # Invoke helper owns TEST_TMPDIR; keep plan fixtures there.
}

teardown() {
  run_plan_invoke_test_teardown_common
}

@test "standard nativeSubagents: accepts off and emits it in TODO JSON" {
  plan_file="$TEST_TMPDIR/standard-native-off.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: standard
todos:
  - id: task-1
    content: do the thing
    runtime: cursor
    nativeSubagents: off
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -eq 0 ]

  run plan_pipeline_todo_metadata_json "$plan_file" task-1
  [ "$status" -eq 0 ]
  mode="$(printf '%s\n' "$output" | awk 'END{print}' | jq -r '.nativeSubagents')"
  [ "$mode" = "off" ]

  run plan_pipeline_effective_metadata_json "$plan_file" task-1
  [ "$status" -eq 0 ]
  mode="$(printf '%s\n' "$output" | awk 'END{print}' | jq -r '.nativeSubagents')"
  [ "$mode" = "off" ]
}

@test "standard nativeSubagents: accepts inherit and emits it in TODO JSON" {
  plan_file="$TEST_TMPDIR/standard-native-inherit.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: standard
todos:
  - id: task-1
    content: do the thing
    runtime: cursor
    nativeSubagents: inherit
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -eq 0 ]

  run plan_pipeline_effective_metadata_json "$plan_file" task-1
  [ "$status" -eq 0 ]
  mode="$(printf '%s\n' "$output" | awk 'END{print}' | jq -r '.nativeSubagents')"
  [ "$mode" = "inherit" ]
}

@test "standard nativeSubagents: omitted defaults to inherit" {
  plan_file="$TEST_TMPDIR/standard-native-default.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: standard
todos:
  - id: task-1
    content: do the thing
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -eq 0 ]

  run plan_pipeline_todo_metadata_json "$plan_file" task-1
  [ "$status" -eq 0 ]
  raw="$(printf '%s\n' "$output" | awk 'END{print}' | jq -r '.nativeSubagents')"
  [ "$raw" = "" ]

  run plan_pipeline_effective_metadata_json "$plan_file" task-1
  [ "$status" -eq 0 ]
  mode="$(printf '%s\n' "$output" | awk 'END{print}' | jq -r '.nativeSubagents')"
  [ "$mode" = "inherit" ]
}

@test "standard nativeSubagents: removed on is rejected" {
  plan_file="$TEST_TMPDIR/standard-native-on.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: standard
todos:
  - id: task-1
    content: do the thing
    runtime: cursor
    nativeSubagents: on
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"todo task-1 nativeSubagents:"* ]]
  [[ "$output" == *"on"* ]]
}

@test "standard nativeSubagents: removed subagents key is rejected" {
  plan_file="$TEST_TMPDIR/standard-removed-subagents.plan.md"
  cat <<'EOF' >"$plan_file"
---
execution: standard
todos:
  - id: task-1
    content: do the thing
    runtime: cursor
    subagents: inherit
    status: pending
---
EOF

  run bash "$VALIDATE_PLAN_SH" "$plan_file"
  [ "$status" -ne 0 ]
  [[ "$output" == *"todo task-1 subagents:"* ]]
  [[ "$output" == *"was removed"* ]]
  [[ "$output" == *"nativeSubagents"* ]]
}

@test "inherit changes no runtime argv for claude invoke" {
  local inherit_record baseline_record
  inherit_record="$TEST_TMPDIR/inherit.args"
  baseline_record="$TEST_TMPDIR/baseline.args"
  export PROMPT="native-subagents-inherit"
  export RALPH_MODE=native

  unset RALPH_PLAN_SUBAGENTS RALPH_PLAN_NATIVE_SUBAGENTS
  run_plan_invoke_test_write_stub "claude" "$baseline_record"
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  run_plan_invoke_test_write_stub "claude" "$inherit_record"
  export RALPH_PLAN_NATIVE_SUBAGENTS=inherit
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  ! grep -Fxq -- "--disallowedTools" "$inherit_record"
  ! grep -Fxq -- "Agent" "$inherit_record"
  # inherit must match the unset/default argv surface (no added Agent, no deny).
  diff -u "$baseline_record" "$inherit_record"
}

@test "invoke-common removed on is rejected" {
  run ralph_run_plan_native_subagents_mode
  # default inherit
  [ "$status" -eq 0 ]
  [ "$output" = "inherit" ]

  export RALPH_PLAN_NATIVE_SUBAGENTS=on
  run ralph_run_plan_native_subagents_mode
  [ "$status" -ne 0 ]
  [[ "$output" == *"was removed"* ]] || [[ "$output" == *"on"* ]]

  export RALPH_PLAN_NATIVE_SUBAGENTS=off
  run ralph_run_plan_native_subagents_mode
  [ "$status" -eq 0 ]
  [ "$output" = "off" ]

  unset RALPH_PLAN_NATIVE_SUBAGENTS
  export RALPH_PLAN_SUBAGENTS=on
  run ralph_run_plan_subagents_mode
  [ "$status" -ne 0 ]
}

@test "Claude off deny argv uses --disallowedTools Agent" {
  local off_record
  off_record="$TEST_TMPDIR/claude-off.args"
  export PROMPT="claude-native-subagents-off"
  export RALPH_MODE=native
  export RALPH_PLAN_NATIVE_SUBAGENTS=off
  export CLAUDE_PLAN_ALLOWED_TOOLS="Bash,Read,Agent"

  run_plan_invoke_test_write_claude_stub "$off_record"
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  grep -Fxq -- "--disallowedTools" "$off_record"
  grep -Fxq -- "Agent" "$off_record"
  # Deny is a separate argv pair; allowed list may still name Agent.
  grep -Fxq -- "Bash,Read,Agent" "$off_record"
}

@test "Claude inherit preserves ambient argv with no Agent deny" {
  local inherit_record baseline_record
  inherit_record="$TEST_TMPDIR/claude-inherit.args"
  baseline_record="$TEST_TMPDIR/claude-baseline.args"
  export PROMPT="claude-native-subagents-inherit"
  export RALPH_MODE=native

  unset RALPH_PLAN_SUBAGENTS RALPH_PLAN_NATIVE_SUBAGENTS
  run_plan_invoke_test_write_claude_stub "$baseline_record"
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  run_plan_invoke_test_write_claude_stub "$inherit_record"
  export RALPH_PLAN_NATIVE_SUBAGENTS=inherit
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]

  ! grep -Fxq -- "--disallowedTools" "$inherit_record"
  ! grep -Fxq -- "Agent" "$inherit_record"
  diff -u "$baseline_record" "$inherit_record"
}

@test "Claude unsupported-version fails off preflight before invoke" {
  local off_record
  off_record="$TEST_TMPDIR/claude-unsupported.args"
  : >"$off_record"
  export PROMPT="claude-native-subagents-unsupported"
  export RALPH_MODE=native
  export RALPH_PLAN_NATIVE_SUBAGENTS=off

  run_plan_invoke_test_write_claude_stub "$off_record" "" unsupported
  run ralph_run_plan_invoke_claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"--disallowedTools"* ]] || [[ "$output" == *"nativeSubagents=off"* ]]
  # Preflight refuses before model argv is recorded.
  ! grep -Fxq -- "-p" "$off_record"
  ! grep -Fxq -- "--disallowedTools" "$off_record"
}

@test "Claude off and inherit write no Ralph child overlay or prompt contract" {
  local off_record inherit_record overlay_dir
  off_record="$TEST_TMPDIR/claude-no-overlay-off.args"
  inherit_record="$TEST_TMPDIR/claude-no-overlay-inherit.args"
  overlay_dir="$WORKSPACE/.ralph-workspace/native-subagent-overlays"
  mkdir -p "$overlay_dir"
  export PROMPT="claude-no-overlay"
  export RALPH_MODE=native
  export PROMPT_STATIC="stable-preamble-only"
  # Legacy read-only child env must not inject Ralph overlays/contracts via Claude invoke.
  export RALPH_PLAN_NATIVE_SUBAGENT_MODE=read-only
  export RALPH_PLAN_NATIVE_SUBAGENT_AGENTS="research"

  run_plan_invoke_test_write_claude_stub "$off_record"
  export RALPH_PLAN_NATIVE_SUBAGENTS=off
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ "$PROMPT_STATIC" = "stable-preamble-only" ]
  [[ "$PROMPT_STATIC" != *"Native Subagent Contract"* ]]
  grep -Fxq -- "stable-preamble-only" "$off_record"

  run_plan_invoke_test_write_claude_stub "$inherit_record"
  export RALPH_PLAN_NATIVE_SUBAGENTS=inherit
  run ralph_run_plan_invoke_claude
  [ "$status" -eq 0 ]
  [ "$PROMPT_STATIC" = "stable-preamble-only" ]
  [[ "$PROMPT_STATIC" != *"Native Subagent Contract"* ]]

  # No Ralph-generated child overlay files under the workspace scratch path.
  [ -z "$(find "$overlay_dir" -type f 2>/dev/null)" ]
}

@test "Cursor off unsupported fails before invoke" {
  local off_record
  off_record="$TEST_TMPDIR/cursor-unsupported-off.args"
  : >"$off_record"
  export PROMPT="cursor-native-subagents-unsupported"
  export RALPH_MODE=native
  export RALPH_PLAN_NATIVE_SUBAGENTS=off

  run_plan_invoke_test_write_stub "cursor-agent" "$off_record"
  run ralph_run_plan_invoke_cursor
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents=off"* ]]
  [[ "$output" == *"unsupported for runtime cursor"* ]]
  # Preflight refuses before model argv is recorded.
  ! grep -Fxq -- "-p" "$off_record"
  ! grep -Fxq -- "--force" "$off_record"
}

@test "Cursor inherit preserves ambient argv with pass-through" {
  local inherit_record baseline_record
  inherit_record="$TEST_TMPDIR/cursor-inherit.args"
  baseline_record="$TEST_TMPDIR/cursor-baseline.args"
  export PROMPT="cursor-native-subagents-inherit"
  # Keep mode off hooks/MCP overlays so argv comparison isolates nativeSubagents.
  export RALPH_MODE=no

  unset RALPH_PLAN_SUBAGENTS RALPH_PLAN_NATIVE_SUBAGENTS
  unset CURSOR_PLAN_NATIVE_HOOKS_ACTIVE CURSOR_PLAN_MCP_CONFIG_TARGET
  run_plan_invoke_test_write_stub "cursor-agent" "$baseline_record"
  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]

  run_plan_invoke_test_write_stub "cursor-agent" "$inherit_record"
  export RALPH_PLAN_NATIVE_SUBAGENTS=inherit
  run ralph_run_plan_invoke_cursor
  [ "$status" -eq 0 ]

  grep -Fxq -- "-p" "$inherit_record"
  grep -Fxq -- "--force" "$inherit_record"
  # inherit must match the unset/default argv surface (no deny, no prompt suppression).
  diff -u "$baseline_record" "$inherit_record"
}

@test "Codex off deny argv uses --config agents.enabled=false" {
  local off_record
  off_record="$TEST_TMPDIR/codex-off.args"
  export PROMPT="codex-native-subagents-off"
  export RALPH_MODE=no
  export RALPH_PLAN_NATIVE_SUBAGENTS=off
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1

  run_plan_invoke_test_write_codex_stub "$off_record"
  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]
  grep -Fxq -- "--config" "$off_record"
  grep -Fxq -- "agents.enabled=false" "$off_record"
  grep -Fxq -- "exec" "$off_record"
}

@test "Codex inherit preserves ambient argv with no agents.enabled deny" {
  local inherit_record baseline_record
  inherit_record="$TEST_TMPDIR/codex-inherit.args"
  baseline_record="$TEST_TMPDIR/codex-baseline.args"
  export PROMPT="codex-native-subagents-inherit"
  # Keep mode off hooks/MCP overlays so argv comparison isolates nativeSubagents.
  export RALPH_MODE=no
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1

  unset RALPH_PLAN_SUBAGENTS RALPH_PLAN_NATIVE_SUBAGENTS
  run_plan_invoke_test_write_codex_stub "$baseline_record"
  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]

  run_plan_invoke_test_write_codex_stub "$inherit_record"
  export RALPH_PLAN_NATIVE_SUBAGENTS=inherit
  run ralph_run_plan_invoke_codex
  [ "$status" -eq 0 ]

  ! grep -Fxq -- "agents.enabled=false" "$inherit_record"
  grep -Fxq -- "exec" "$inherit_record"
  # inherit must match the unset/default argv surface (no deny, no prompt suppression).
  diff -u "$baseline_record" "$inherit_record"
}

@test "Codex unsupported-version fails off preflight before invoke" {
  local off_record
  off_record="$TEST_TMPDIR/codex-unsupported.args"
  : >"$off_record"
  export PROMPT="codex-native-subagents-unsupported"
  export RALPH_MODE=no
  export RALPH_PLAN_NATIVE_SUBAGENTS=off
  export CODEX_PLAN_NO_ADD_AGENTS_DIR=1

  run_plan_invoke_test_write_codex_stub "$off_record" unsupported
  run ralph_run_plan_invoke_codex
  [ "$status" -ne 0 ]
  [[ "$output" == *"--config"* ]] || [[ "$output" == *"nativeSubagents=off"* ]]
  # Preflight refuses before model argv is recorded.
  ! grep -Fxq -- "exec" "$off_record"
  ! grep -Fxq -- "agents.enabled=false" "$off_record"
}

@test "OpenCode off unsupported fails before invoke" {
  local off_record
  off_record="$TEST_TMPDIR/opencode-unsupported-off.args"
  : >"$off_record"
  export PROMPT="opencode-native-subagents-unsupported"
  export RALPH_MODE=native
  export RALPH_PLAN_NATIVE_SUBAGENTS=off

  run_plan_invoke_test_write_stub "opencode" "$off_record"
  run ralph_run_plan_invoke_opencode
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents=off"* ]]
  [[ "$output" == *"unsupported for runtime opencode"* ]]
  # Preflight refuses before model argv is recorded.
  ! grep -Fxq -- "run" "$off_record"
  ! grep -Fxq -- "--agent" "$off_record"
}

@test "OpenCode inherit preserves ambient argv with pass-through" {
  local inherit_record baseline_record
  inherit_record="$TEST_TMPDIR/opencode-inherit.args"
  baseline_record="$TEST_TMPDIR/opencode-baseline.args"
  export PROMPT="opencode-native-subagents-inherit"
  # Keep mode off hooks/MCP overlays so argv comparison isolates nativeSubagents.
  export RALPH_MODE=no

  unset RALPH_PLAN_SUBAGENTS RALPH_PLAN_NATIVE_SUBAGENTS
  unset OPENCODE_PLAN_MCP_CONFIG_PATH OPENCODE_CONFIG
  run_plan_invoke_test_write_stub "opencode" "$baseline_record"
  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]

  run_plan_invoke_test_write_stub "opencode" "$inherit_record"
  export RALPH_PLAN_NATIVE_SUBAGENTS=inherit
  run ralph_run_plan_invoke_opencode
  [ "$status" -eq 0 ]

  grep -Fxq -- "run" "$inherit_record"
  grep -Fxq -- "--agent" "$inherit_record"
  # inherit must match the unset/default argv surface (no deny, no prompt suppression).
  diff -u "$baseline_record" "$inherit_record"
}

@test "Antigravity off unsupported fails before invoke" {
  local off_record
  off_record="$TEST_TMPDIR/antigravity-unsupported-off.args"
  : >"$off_record"
  export PROMPT="antigravity-native-subagents-unsupported"
  export RALPH_MODE=native
  export RALPH_PLAN_NATIVE_SUBAGENTS=off

  run_plan_invoke_test_write_stub "agy" "$off_record"
  run ralph_run_plan_invoke_antigravity
  [ "$status" -ne 0 ]
  [[ "$output" == *"nativeSubagents=off"* ]]
  [[ "$output" == *"unsupported for runtime antigravity"* ]]
  # Preflight refuses before model argv is recorded.
  ! grep -Fxq -- "--print" "$off_record"
  ! grep -Fxq -- "--output-format" "$off_record"
}

@test "Antigravity inherit preserves ambient argv with pass-through" {
  local inherit_record baseline_record
  inherit_record="$TEST_TMPDIR/antigravity-inherit.args"
  baseline_record="$TEST_TMPDIR/antigravity-baseline.args"
  export PROMPT="antigravity-native-subagents-inherit"
  # Keep mode off hooks/MCP overlays so argv comparison isolates nativeSubagents.
  export RALPH_MODE=no

  unset RALPH_PLAN_SUBAGENTS RALPH_PLAN_NATIVE_SUBAGENTS
  unset ANTIGRAVITY_CONFIG ANTIGRAVITY_PLAN_CLI
  run_plan_invoke_test_write_stub "agy" "$baseline_record"
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]

  run_plan_invoke_test_write_stub "agy" "$inherit_record"
  export RALPH_PLAN_NATIVE_SUBAGENTS=inherit
  run ralph_run_plan_invoke_antigravity
  [ "$status" -eq 0 ]

  grep -Fxq -- "--print" "$inherit_record"
  grep -Fxq -- "--output-format" "$inherit_record"
  # inherit must match the unset/default argv surface (no deny, no prompt suppression).
  diff -u "$baseline_record" "$inherit_record"
}
