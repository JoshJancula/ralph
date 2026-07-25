#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"
RUNTIME_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"

setup() {
  workspace="$(mktemp -d)"
  WORKSPACE="$workspace"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_PLAN_KEY="test-overlay"
  RUNTIME="claude"
}

teardown() {
  rm -rf "$workspace"
}

@test "runtime overlay records generated and mutated files plus summary metadata" {
  source "$RUNTIME_OVERLAY_LIB"
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  runtime_overlay_set_overlay_mode "bounded"
  runtime_overlay_set_tool_access_mode "ralph"
  runtime_overlay_set_native_hooks_requested "on"
  runtime_overlay_set_native_hooks_effective "off"
  runtime_overlay_set_mcp_effective "true"
  runtime_overlay_add_capability "hook-detection"
  runtime_overlay_add_warning "hooks disabled for bare mode"

  generated="$workspace/generated.txt"
  printf '%s' "generated content" > "$generated"
  runtime_overlay_record_generated_file "$generated"

  original="$workspace/config.yml"
  printf '%s' "original config" > "$original"
  runtime_overlay_record_original_file "$original"

  runtime_overlay_register_cleanup "touch \"$workspace/cleanup-marker\""
  runtime_overlay_run_cleanup
  [ -f "$workspace/cleanup-marker" ]

  runtime_overlay_write_summary
  summary_file="$(runtime_overlay_summary_path)"
  python3 - "$summary_file" "$generated" "$original" <<'PY'
import json, sys

summary = json.load(open(sys.argv[1]))
assert summary["runtime"] == "claude"
assert summary["plan_key"] == "test-overlay"
assert summary["tool_access_mode"] == "ralph"
assert summary["native_hooks_requested"] == "on"
assert summary["native_hooks_effective"] == "off"
assert summary["mcp_effective"] == "true"
assert summary["overlay_mode"] == "bounded"
assert summary["generated_files"] == [sys.argv[2]]
assert summary["mutated_files"] == [sys.argv[3]]
assert summary["warnings"] == ["hooks disabled for bare mode"]
assert summary["capabilities"] == ["hook-detection"]
PY

  backup="$workspace/.ralph-workspace/runtime-config/$RALPH_PLAN_KEY/originals/config.yml"
  [ -f "$backup" ]
}

@test "runtime overlay rejects generated files outside workspace" {
  source "$RUNTIME_OVERLAY_LIB"
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  run bash -c '
    source "'"$RUNTIME_OVERLAY_LIB"'"
    WORKSPACE="'"$workspace"'"
    RALPH_PLAN_KEY="test-overlay"
    runtime_overlay_init_state "'"$RUNTIME"'" "'"$RALPH_PLAN_KEY"'"
    runtime_overlay_record_generated_file /tmp/outside.txt
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside"* ]]
}

@test "runtime overlay stale restore replays journaled files" {
  source "$RUNTIME_OVERLAY_LIB"

  plan_key="stale-plan"
  plan_dir="$workspace/.ralph-workspace/runtime-config/$plan_key"
  journal_dir="$plan_dir/journals"
  originals_dir="$plan_dir/originals"
  mkdir -p "$journal_dir" "$originals_dir/.cursor" "$originals_dir/.claude"

  mkdir -p "$workspace/.cursor" "$workspace/.claude" "$workspace/tmp"
  cursor_target="$workspace/.cursor/mcp.json"
  claude_target="$workspace/.claude/settings.json"
  cursor_backup="$originals_dir/.cursor/mcp.json"
  claude_backup="$originals_dir/.claude/settings.json"

  expected_cursor='{"original":true}'
  expected_claude='{"original":true}'
  printf '%s' "$expected_cursor" > "$cursor_backup"
  printf '%s' "$expected_claude" > "$claude_backup"
  printf '{"mutated":"cursor"}' > "$cursor_target"
  printf '{"mutated":"claude"}' > "$claude_target"

  codex_temp="$workspace/tmp/ralph-codex-config.json"
  opencode_temp="$workspace/tmp/ralph-opencode-config.json"
  printf '{}' > "$codex_temp"
  printf '{}' > "$opencode_temp"

  journal_path="$journal_dir/journal-${plan_key}-999999-1.json"
  python3 - <<'PY' "$journal_path" "$plan_key" "$workspace" "$codex_temp" "$opencode_temp" "$cursor_target" "$cursor_backup" "$claude_target" "$claude_backup"
import json, sys

path, plan_key, workspace, codex, opencode, cursor, cursor_backup, claude, claude_backup = sys.argv[1:]
data = {
    "pid": 999999,
    "start_time": 1,
    "runtime": "cursor",
    "plan_key": plan_key,
    "workspace_root": workspace,
    "cleanup_status": "pending",
    "cleanup_time": None,
    "generated_files": [
        {"path": codex},
        {"path": opencode}
    ],
    "mutated_files": [
        {"path": cursor, "backup": cursor_backup},
        {"path": claude, "backup": claude_backup}
    ]
}
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY

  run runtime_overlay_restore_stale_runs "$workspace" "$plan_key" 0
  [ "$status" -eq 0 ]
  [ ! -f "$codex_temp" ]
  [ ! -f "$opencode_temp" ]
  [ "$(cat "$cursor_target")" = "$expected_cursor" ]
  [ "$(cat "$claude_target")" = "$expected_claude" ]

  python3 - <<'PY' "$journal_path"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["cleanup_status"] == "cleaned"
assert data["mutated_files"][0]["restored"] is True
assert data["generated_files"][0]["cleaned"] is True
PY
}

@test "cleanup-plan --runtime-config restores stale overlays" {
  source "$RUNTIME_OVERLAY_LIB"
  plan_key="cleanup-plan"
  plan_dir="$workspace/.ralph-workspace/runtime-config/$plan_key"
  journal_dir="$plan_dir/journals"
  originals_dir="$plan_dir/originals"
  mkdir -p "$journal_dir" "$originals_dir/.cursor" "$originals_dir/.claude" "$workspace/tmp"

  mkdir -p "$workspace/.cursor" "$workspace/.claude"
  cursor_target="$workspace/.cursor/mcp.json"
  claude_target="$workspace/.claude/settings.json"
  cursor_backup="$originals_dir/.cursor/mcp.json"
  claude_backup="$originals_dir/.claude/settings.json"

  expected_cursor='{"original":true}'
  expected_claude='{"original":true}'
  printf '%s' "$expected_cursor" > "$cursor_backup"
  printf '%s' "$expected_claude" > "$claude_backup"
  printf '{"mutated":"cursor"}' > "$cursor_target"
  printf '{"mutated":"claude"}' > "$claude_target"

  codex_temp="$workspace/tmp/ralph-codex-reset.json"
  opencode_temp="$workspace/tmp/ralph-opencode-reset.json"
  printf '{}' > "$codex_temp"
  printf '{}' > "$opencode_temp"

  journal_path="$journal_dir/journal-${plan_key}-888-1.json"
  python3 - <<'PY' "$journal_path" "$plan_key" "$workspace" "$codex_temp" "$opencode_temp" "$cursor_target" "$cursor_backup" "$claude_target" "$claude_backup"
import json, sys

path, plan_key, workspace, codex, opencode, cursor, cursor_backup, claude, claude_backup = sys.argv[1:]
data = {
    "pid": 888,
    "start_time": 1,
    "runtime": "claude",
    "plan_key": plan_key,
    "workspace_root": workspace,
    "cleanup_status": "pending",
    "cleanup_time": None,
    "generated_files": [
        {"path": codex},
        {"path": opencode}
    ],
    "mutated_files": [
        {"path": cursor, "backup": cursor_backup},
        {"path": claude, "backup": claude_backup}
    ]
}
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY

  run "$REPO_ROOT/.ralph/cleanup-plan.sh" --runtime-config "$plan_key" "$workspace"
  [ "$status" -eq 0 ]
  [ ! -f "$codex_temp" ]
  [ ! -f "$opencode_temp" ]
  [ "$(cat "$cursor_target")" = "$expected_cursor" ]
  [ "$(cat "$claude_target")" = "$expected_claude" ]

  python3 - <<'PY' "$journal_path"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["cleanup_status"] == "cleaned"
assert data["mutated_files"][1]["restored"] is True
PY
}

@test "runtime overlay stale restore can mark recovered-after-interruption distinctly" {
  source "$RUNTIME_OVERLAY_LIB"

  plan_key="recover-plan"
  plan_dir="$workspace/.ralph-workspace/runtime-config/$plan_key"
  journal_dir="$plan_dir/journals"
  originals_dir="$plan_dir/originals"
  mkdir -p "$journal_dir" "$originals_dir/.cursor" "$workspace/.cursor"

  cursor_target="$workspace/.cursor/mcp.json"
  cursor_backup="$originals_dir/.cursor/mcp.json"
  printf '%s' '{"original":true}' > "$cursor_backup"
  printf '%s' '{"mutated":true}' > "$cursor_target"

  journal_path="$journal_dir/journal-${plan_key}-777-1.json"
  python3 - <<'PY' "$journal_path" "$plan_key" "$workspace" "$cursor_target" "$cursor_backup"
import json, sys
path, plan_key, workspace, cursor, cursor_backup = sys.argv[1:]
data = {
    "pid": 777,
    "start_time": 1,
    "runtime": "cursor",
    "plan_key": plan_key,
    "workspace_root": workspace,
    "cleanup_status": "pending",
    "cleanup_time": None,
    "generated_files": [],
    "mutated_files": [{"path": cursor, "backup": cursor_backup, "restored": False}]
}
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY

  run runtime_overlay_restore_stale_runs "$workspace" "$plan_key" 0 "recovered_after_interruption" "cursor"
  [ "$status" -eq 0 ]
  [ "$(cat "$cursor_target")" = '{"original":true}' ]

  python3 - <<'PY' "$journal_path"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["cleanup_status"] == "recovered_after_interruption"
assert data["recovered_after_interruption"] is True
assert data["mutated_files"][0]["restored"] is True
PY
}
