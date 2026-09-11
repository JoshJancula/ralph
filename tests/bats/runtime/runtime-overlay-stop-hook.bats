#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../helper/load-lib.bash"

CLAUDE_OVERLAY="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay-claude.sh"
CODEX_OVERLAY="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay-codex.sh"
CURSOR_OVERLAY="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay-cursor.sh"
ANTIGRAVITY_OVERLAY="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay-antigravity.sh"
RUNTIME_OVERLAY_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay.sh"
BLOCK_ADAPTER="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/stop-continuation-block-adapter.sh"
FOLLOWUP_ADAPTER="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/stop-continuation-followup-adapter.sh"
CONTINUE_ADAPTER="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/stop-continuation-continue-adapter.sh"
CORE_HOOK="$REPO_ROOT/bundle/.ralph/bash-lib/native-hook/stop-continuation-hook.sh"
BG_STATE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-job-state.sh"
CLAUDE_TEMPLATE="$REPO_ROOT/bundle/.claude/settings.json"
CURSOR_TEMPLATE="$REPO_ROOT/bundle/.cursor/hooks.json"
ANTIGRAVITY_TEMPLATE="$REPO_ROOT/bundle/.agents/hooks.json"
CLAUDE_STOP_HOOK="$REPO_ROOT/bundle/.claude/hooks/stop-continuation.sh"
CODEX_STOP_HOOK="$REPO_ROOT/bundle/.codex/hooks/stop-continuation.sh"
CURSOR_STOP_HOOK="$REPO_ROOT/bundle/.cursor/hooks/stop-continuation.sh"
ANTIGRAVITY_STOP_HOOK="$REPO_ROOT/bundle/.agents/hooks/stop-continuation.sh"
CODEX_INVOKE="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-invoke-codex.sh"
TIER_PROBE_LIB="$REPO_ROOT/bundle/.ralph/bash-lib/run-plan/run-plan-bg-tier-probe.sh"
OPENCODE_OVERLAY="$REPO_ROOT/bundle/.ralph/bash-lib/runtime-overlay/runtime-overlay-opencode.sh"

overlay_stop_hook_source_tier_probe() {
  # shellcheck disable=SC1090
  source "$TIER_PROBE_LIB"
}

overlay_stop_hook_run_tier_probe() {
  local runtime="${1:-cursor}"
  overlay_stop_hook_source_tier_probe
  ralph_bg_tier_probe_evaluate "$runtime"
}

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  workspace="$(mktemp -d)"
  WORKSPACE="$workspace"
  RALPH_PROJECT_ROOT="$workspace"
  RALPH_AGENT_WORKSPACE="$workspace"
  RALPH_PLAN_KEY="overlay-stop-hook"
  RALPH_PLAN_WORKSPACE_ROOT="$workspace/.ralph-workspace"
  RALPH_SESSION_DIR="$workspace/.ralph-workspace/sessions/$RALPH_PLAN_KEY"
  RALPH_HOME="$REPO_ROOT"
  export WORKSPACE RALPH_PROJECT_ROOT RALPH_AGENT_WORKSPACE RALPH_PLAN_KEY RALPH_PLAN_WORKSPACE_ROOT RALPH_SESSION_DIR RALPH_HOME
  mkdir -p "$workspace/.ralph-workspace" "$RALPH_SESSION_DIR"
  ln -sf "$REPO_ROOT/bundle/.ralph" "$workspace/.ralph"
  mkdir -p "$workspace/.claude/hooks" "$workspace/.codex/hooks" "$workspace/.cursor/hooks" "$workspace/.agents/hooks"
  cp "$CLAUDE_STOP_HOOK" "$workspace/.claude/hooks/stop-continuation.sh"
  cp "$CODEX_STOP_HOOK" "$workspace/.codex/hooks/stop-continuation.sh"
  cp "$CURSOR_STOP_HOOK" "$workspace/.cursor/hooks/stop-continuation.sh"
  cp "$ANTIGRAVITY_STOP_HOOK" "$workspace/.agents/hooks/stop-continuation.sh"
  chmod +x "$workspace/.claude/hooks/stop-continuation.sh" "$workspace/.codex/hooks/stop-continuation.sh" "$workspace/.cursor/hooks/stop-continuation.sh" "$workspace/.agents/hooks/stop-continuation.sh"
}

teardown() {
  ralph_test_rm_workspace "$workspace"
}

overlay_stop_hook_seed_plan_context() {
  export RALPH_BG_JOBS=1
  export RALPH_BG_HOOK_TIMEOUT=5400
  export RALPH_BG_MAX_PER_TODO=8
  export RALPH_RUN_PLAN_ACTIVE=1
  export RALPH_CURRENT_PLAN_PATH="$workspace/PLAN.md"
  export RALPH_CURRENT_TODO_LINE="2"
  export RALPH_CURRENT_TODO_ORDINAL="2"
  export RALPH_CURRENT_TODO_ID="todo-stop-overlay"
  export RALPH_CURRENT_TODO_HASH="hash-stop-overlay"
  export RALPH_PROCESS_RUN_ID="run-stop-overlay"
  printf '# plan\n- [ ] stop overlay\n' >"$workspace/PLAN.md"
  # shellcheck disable=SC1090
  source "$BG_STATE_LIB"
}

overlay_stop_hook_advance_terminal_job() {
  local job_id="${1:-job-overlay}"
  ralph_bg_job_create "$job_id" "echo overlay-stop" "test" 120 1 "$$" >/dev/null
  ralph_bg_job_mark_launched "$job_id" 0 "none" "true" >/dev/null
  ralph_bg_job_mark_running "$job_id" >/dev/null
  ralph_bg_job_mark_terminal "$job_id" "passed" >/dev/null
  local job_dir
  job_dir="$(ralph_bg_job_dir "$job_id")"
  printf 'overlay-preview\n' >"$job_dir/stdout"
  printf '0\n' >"$job_dir/exit_code"
}

@test "claude merge adds Stop hook with RALPH_BG_HOOK_TIMEOUT when bg jobs enabled" {
  source "$CLAUDE_OVERLAY"
  export RALPH_BG_JOBS=1
  export RALPH_BG_HOOK_TIMEOUT=5400
  export RALPH_NATIVE_HOOKS=on
  printf '%s\n' '{"keep":"user","hooks":{"PreToolUse":[{"matcher":"Custom","hooks":[{"type":"command","command":"./keep-me.sh"}]}]}}' \
    >"$workspace/.claude/settings.json"
  runtime_overlay_claude_merge_settings_file "$workspace/.claude/settings.json" "$CLAUDE_TEMPLATE" 1
  run jq -r '.hooks.Stop[0].hooks[0].timeout,.hooks.Stop[0].hooks[0].command,.keep' "$workspace/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "5400" ]
  [[ "${lines[1]}" == *"stop-continuation.sh"* ]]
  [ "${lines[2]}" = "user" ]
}

@test "claude merge preserves operator Stop and context hooks with background jobs disabled" {
  source "$CLAUDE_OVERLAY"
  local settings="$workspace/.claude/settings.json"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"operator-stop"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"operator-context"}]}]},"enabledPlugins":{"operator@local":true},"permissions":{"deny":["Read(./private)"]}}' >"$settings"
  local before
  before="$(cat "$settings")"
  export RALPH_BG_JOBS=0 RALPH_NATIVE_HOOKS=on
  run_plan_invoke_claude_native_hooks_prepare
  jq -e '.hooks.Stop[0].hooks[0].command == "operator-stop" and
    .hooks.SessionStart[0].hooks[0].command == "operator-context" and
    .enabledPlugins["operator@local"] == true and
    .permissions.deny == ["Read(./private)"]' "$settings"
  run_plan_invoke_claude_native_hooks_cleanup
  [ "$(cat "$settings")" = "$before" ]
}

@test "claude merge omits Stop hook when RALPH_BG_JOBS is disabled" {
  source "$CLAUDE_OVERLAY"
  export RALPH_BG_JOBS=0
  printf '%s\n' '{"hooks":{}}' >"$workspace/.claude/settings.json"
  runtime_overlay_claude_merge_settings_file "$workspace/.claude/settings.json" "$CLAUDE_TEMPLATE" 0
  run jq -r '.hooks.Stop // empty' "$workspace/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "claude prepare exports CLAUDE_CODE_STOP_HOOK_BLOCK_CAP from RALPH_BG_MAX_PER_TODO" {
  source "$RUNTIME_OVERLAY_LIB"
  source "$CLAUDE_OVERLAY"
  overlay_stop_hook_source_tier_probe
  export RALPH_NATIVE_HOOKS=on
  export RALPH_BG_JOBS=1
  export RALPH_BG_MAX_PER_TODO=8
  export RALPH_BG_TIER_SELECTED=hook
  export CLAUDE_PLAN_BARE=0
  runtime_overlay_init_state "claude" "$RALPH_PLAN_KEY"
  run_plan_invoke_claude_native_hooks_prepare
  [ "$CLAUDE_CODE_STOP_HOOK_BLOCK_CAP" = "8" ]
}

@test "claude durable hook detection requires stop-continuation hook" {
  source "$CLAUDE_OVERLAY"
  cp "$CLAUDE_TEMPLATE" "$workspace/.claude/settings.json"
  runtime_overlay_claude_hooks_detected_in_file "$workspace/.claude/settings.json"
  python3 - <<'PY' "$workspace/.claude/settings.json"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
stop = data.get("hooks", {}).get("Stop") or []
stop[0]["hooks"] = [h for h in stop[0]["hooks"] if "stop-continuation" not in h.get("command", "")]
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  run runtime_overlay_claude_hooks_detected_in_file "$workspace/.claude/settings.json"
  [ "$status" -ne 0 ]
}

@test "claude overlay restore preserves user custom hook after Stop merge" {
  source "$RUNTIME_OVERLAY_LIB"
  source "$CLAUDE_OVERLAY"
  export RALPH_BG_JOBS=1
  export RALPH_NATIVE_HOOKS=on
  printf '%s\n' '{"keep":"native","hooks":{"PreToolUse":[{"matcher":"Custom","hooks":[{"type":"command","command":"./keep-me.sh"}]}]}}' \
    >"$workspace/.claude/settings.json"
  runtime_overlay_init_state "claude" "$RALPH_PLAN_KEY"
  runtime_overlay_record_original_file "$workspace/.claude/settings.json"
  runtime_overlay_claude_merge_settings_file "$workspace/.claude/settings.json" "$CLAUDE_TEMPLATE" 1
  jq -e '.hooks.PreToolUse[] | select(.matcher == "Custom")' "$workspace/.claude/settings.json" >/dev/null
  runtime_overlay_run_cleanup
  run jq -r '.keep,.hooks.PreToolUse[0].hooks[0].command' "$workspace/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "native" ]
  [ "${lines[1]}" = "./keep-me.sh" ]
}

@test "codex append config injects Stop hook with explicit timeout when bg jobs enabled" {
  # shellcheck disable=SC1090
  source "$CODEX_INVOKE"
  source "$CODEX_OVERLAY"
  overlay_stop_hook_source_tier_probe
  export RALPH_BG_JOBS=1
  export RALPH_BG_HOOK_TIMEOUT=5400
  export RALPH_BG_TIER_SELECTED=hook
  args=()
  _run_plan_invoke_codex_append_native_hook_config_args args
  local found_stop=0 found_timeout=0 config
  for config in "${args[@]}"; do
    [[ "$config" == hooks.Stop=* ]] && found_stop=1
    [[ "$config" == *"timeout=5400"* ]] && found_timeout=1
  done
  [ "$found_stop" -eq 1 ]
  [ "$found_timeout" -eq 1 ]
}

@test "codex append config omits Stop hook when RALPH_BG_JOBS is disabled" {
  # shellcheck disable=SC1090
  source "$CODEX_INVOKE"
  source "$CODEX_OVERLAY"
  export RALPH_BG_JOBS=0
  args=()
  _run_plan_invoke_codex_append_native_hook_config_args args
  local config
  for config in "${args[@]}"; do
    [[ "$config" == hooks.Stop=* ]] && return 1
  done
  return 0
}

@test "codex hooks config probe accepts hooks.PostToolUse override without requiring features.hooks gate" {
  source "$CODEX_OVERLAY"
  run bash -c '
    source "$1"
    _run_plan_invoke_codex_hooks_config_supported() {
      local cli_name="${1:-codex}" exec_help stderr_file probe_status=0
      exec_help="--config --dangerously-bypass-hook-trust"
      stderr_file="$(mktemp)"
      if [[ "$exec_help" != *"--config"* || "$exec_help" != *"--dangerously-bypass-hook-trust"* ]]; then
        rm -f "$stderr_file"; return 1
      fi
      codex exec --config "hooks.PostToolUse=[]" >/dev/null 2>"$stderr_file" <<< "" || probe_status=$?
      if [[ "$probe_status" -ne 0 ]] && grep -qE "unknown configuration field|Error parsing -c overrides|missing field" "$stderr_file"; then
        rm -f "$stderr_file"; return 1
      fi
      rm -f "$stderr_file"; return 0
    }
    _run_plan_invoke_codex_hooks_config_supported codex
  ' _ "$CODEX_OVERLAY"
  [ "$status" -eq 0 ]
}

@test "block adapter serializes neutral continue payload to decision block" {
  # shellcheck disable=SC1090
  source "$BLOCK_ADAPTER"
  local neutral block_out decision
  neutral='{"version":1,"decision":"continue","releaseReason":null,"continuation":{"jobId":"job-block","commandSummary":"echo overlay-stop","status":"passed","exitCode":0,"elapsedSeconds":1,"preview":"overlay-preview","resultId":null,"resultPath":null}}'
  block_out="$(ralph_bg_stop_block_adapter_emit_block "$neutral")"
  decision="$(jq -r '.decision' <<<"$block_out")"
  [ "$decision" = "block" ]
  [[ "$block_out" == *"overlay-preview"* ]]
  [[ "$block_out" == *"job-block"* ]]
}

@test "block adapter integration emits block through sourced core stub" {
  fake_core="$workspace/fake-stop-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"continue","continuation":{"jobId":"job-block","commandSummary":"echo overlay-stop","status":"passed","exitCode":0,"elapsedSeconds":1,"preview":"overlay-preview","resultId":null,"resultPath":null}}'
}
EOF
  output="$(
    RALPH_BG_STOP_CORE_SCRIPT="$fake_core" bash -c 'source "$1"; ralph_bg_stop_block_adapter_main' _ "$BLOCK_ADAPTER" <<<"{}"
  )"
  decision="$(jq -r '.decision' <<<"$output")"
  [ "$decision" = "block" ]
}

@test "block adapter releases silently when stop_hook_active guard is set" {
  fake_core="$workspace/fake-stop-guard-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"release","releaseReason":"runtime-guard-active","continuation":null}'
}
EOF
  output="$(
    RALPH_BG_STOP_CORE_SCRIPT="$fake_core" bash -c 'source "$1"; ralph_bg_stop_block_adapter_main' _ "$BLOCK_ADAPTER" <<<'{"stop_hook_active":true}'
  )"
  [ -z "$output" ]
}

@test "block adapter releases silently when no outstanding job exists" {
  fake_core="$workspace/fake-stop-empty-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"release","releaseReason":"no-outstanding-job","continuation":null}'
}
EOF
  output="$(
    RALPH_BG_STOP_CORE_SCRIPT="$fake_core" bash -c 'source "$1"; ralph_bg_stop_block_adapter_main' _ "$BLOCK_ADAPTER" <<<"{}"
  )"
  [ -z "$output" ]
}

@test "claude stop hook script resolves core and emits block decision" {
  fake_core="$workspace/fake-stop-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"continue","continuation":{"jobId":"job-claude-script","commandSummary":"echo overlay-stop","status":"passed","exitCode":0,"elapsedSeconds":1,"preview":"overlay-preview","resultId":null,"resultPath":null}}'
}
EOF
  export CLAUDE_PROJECT_DIR="$workspace"
  export RALPH_BG_STOP_CORE_SCRIPT="$fake_core"
  output="$(bash "$workspace/.claude/hooks/stop-continuation.sh" <<<"{}")"
  decision="$(jq -r '.decision' <<<"$output")"
  [ "$decision" = "block" ]
  [[ "$output" == *"job-claude-script"* ]]
}

@test "codex stop hook script resolves core and emits block decision" {
  fake_core="$workspace/fake-stop-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"continue","continuation":{"jobId":"job-codex-script","commandSummary":"echo overlay-stop","status":"passed","exitCode":0,"elapsedSeconds":1,"preview":"overlay-preview","resultId":null,"resultPath":null}}'
}
EOF
  export RALPH_BG_STOP_CORE_SCRIPT="$fake_core"
  output="$(bash "$workspace/.codex/hooks/stop-continuation.sh" <<<"{}")"
  decision="$(jq -r '.decision' <<<"$output")"
  [ "$decision" = "block" ]
  [[ "$output" == *"job-codex-script"* ]]
}

@test "cursor merge adds stop hook with RALPH_BG_HOOK_TIMEOUT when bg jobs enabled" {
  source "$CURSOR_OVERLAY"
  export RALPH_BG_JOBS=1
  export RALPH_BG_HOOK_TIMEOUT=5400
  export RALPH_NATIVE_HOOKS=on
  printf '%s\n' '{"version":1,"keep":"user","hooks":{"preToolUse":[{"command":"./keep-me.sh","matcher":"Shell"}]}}' \
    >"$workspace/.cursor/hooks.json"
  runtime_overlay_cursor_merge_hooks_file "$workspace/.cursor/hooks.json" "$CURSOR_TEMPLATE" 1
  run jq -r '.hooks.stop[0].timeout,.hooks.stop[0].command,.hooks.stop[0].loop_limit,.keep' "$workspace/.cursor/hooks.json"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "5400" ]
  [[ "${lines[1]}" == *"stop-continuation.sh"* ]]
  [ "${lines[2]}" = "5" ]
  [ "${lines[3]}" = "user" ]
}

@test "cursor merge omits stop hook when RALPH_BG_JOBS is disabled" {
  source "$CURSOR_OVERLAY"
  export RALPH_BG_JOBS=0
  printf '%s\n' '{"version":1,"hooks":{}}' >"$workspace/.cursor/hooks.json"
  runtime_overlay_cursor_merge_hooks_file "$workspace/.cursor/hooks.json" "$CURSOR_TEMPLATE" 0
  run jq -r '.hooks.stop // empty' "$workspace/.cursor/hooks.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cursor durable hook detection requires stop-continuation hook" {
  source "$CURSOR_OVERLAY"
  cp "$CURSOR_TEMPLATE" "$workspace/.cursor/hooks.json"
  runtime_overlay_cursor_hooks_detected_in_file "$workspace/.cursor/hooks.json"
  python3 - <<'PY' "$workspace/.cursor/hooks.json"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
stop = data.get("hooks", {}).get("stop") or []
data["hooks"]["stop"] = [entry for entry in stop if "stop-continuation" not in entry.get("command", "")]
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  run runtime_overlay_cursor_hooks_detected_in_file "$workspace/.cursor/hooks.json"
  [ "$status" -ne 0 ]
}

@test "followup adapter serializes neutral continue payload to followup_message" {
  # shellcheck disable=SC1090
  source "$FOLLOWUP_ADAPTER"
  local neutral followup_out message
  neutral='{"version":1,"decision":"continue","releaseReason":null,"continuation":{"jobId":"job-followup","commandSummary":"echo overlay-stop","status":"passed","exitCode":0,"elapsedSeconds":1,"preview":"overlay-preview","resultId":null,"resultPath":null}}'
  followup_out="$(ralph_bg_stop_followup_adapter_emit_followup "$neutral")"
  message="$(jq -r '.followup_message' <<<"$followup_out")"
  [[ -n "$message" ]]
  [[ "$message" == *"overlay-preview"* ]]
  [[ "$message" == *"job-followup"* ]]
}

@test "followup adapter releases silently when loop_count reaches loop_limit" {
  fake_core="$workspace/fake-stop-loop-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"release","releaseReason":"runtime-guard-active","continuation":null}'
}
EOF
  output="$(
    RALPH_BG_STOP_CORE_SCRIPT="$fake_core" bash -c 'source "$1"; ralph_bg_stop_followup_adapter_main' _ "$FOLLOWUP_ADAPTER" <<<'{"loop_count":5,"loop_limit":5}'
  )"
  [ -z "$output" ]
}

@test "followup adapter releases silently when no outstanding job exists" {
  fake_core="$workspace/fake-stop-empty-followup-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"release","releaseReason":"no-outstanding-job","continuation":null}'
}
EOF
  output="$(
    RALPH_BG_STOP_CORE_SCRIPT="$fake_core" bash -c 'source "$1"; ralph_bg_stop_followup_adapter_main' _ "$FOLLOWUP_ADAPTER" <<<"{}"
  )"
  [ -z "$output" ]
}

@test "cursor stop hook script resolves core and emits followup_message" {
  fake_core="$workspace/fake-stop-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"continue","continuation":{"jobId":"job-cursor-script","commandSummary":"echo overlay-stop","status":"passed","exitCode":0,"elapsedSeconds":1,"preview":"overlay-preview","resultId":null,"resultPath":null}}'
}
EOF
  export WORKSPACE="$workspace"
  export RALPH_BG_STOP_CORE_SCRIPT="$fake_core"
  output="$(bash "$workspace/.cursor/hooks/stop-continuation.sh" <<<"{}")"
  message="$(jq -r '.followup_message' <<<"$output")"
  [[ -n "$message" ]]
  [[ "$message" == *"job-cursor-script"* ]]
}

@test "cursor overlay restore preserves user custom hook after stop merge" {
  source "$RUNTIME_OVERLAY_LIB"
  source "$CURSOR_OVERLAY"
  export RALPH_BG_JOBS=1
  export RALPH_NATIVE_HOOKS=on
  printf '%s\n' '{"version":1,"keep":"native","hooks":{"preToolUse":[{"command":"./keep-me.sh","matcher":"Shell"}]}}' \
    >"$workspace/.cursor/hooks.json"
  runtime_overlay_init_state "cursor" "$RALPH_PLAN_KEY"
  runtime_overlay_record_original_file "$workspace/.cursor/hooks.json"
  runtime_overlay_cursor_merge_hooks_file "$workspace/.cursor/hooks.json" "$CURSOR_TEMPLATE" 1
  jq -e '.hooks.preToolUse[] | select(.command == "./keep-me.sh")' "$workspace/.cursor/hooks.json" >/dev/null
  runtime_overlay_run_cleanup
  run jq -r '.keep,.hooks.preToolUse[0].command' "$workspace/.cursor/hooks.json"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "native" ]
  [ "${lines[1]}" = "./keep-me.sh" ]
}

@test "antigravity merge adds Stop hook with RALPH_BG_HOOK_TIMEOUT when bg jobs enabled" {
  source "$ANTIGRAVITY_OVERLAY"
  export RALPH_BG_JOBS=1
  export RALPH_BG_HOOK_TIMEOUT=5400
  export RALPH_NATIVE_HOOKS=on
  printf '%s\n' '{"version":1,"keep":"user","hooks":{"preToolUse":[{"command":"./keep-me.sh","matcher":"Shell"}]}}' \
    >"$workspace/.agents/hooks.json"
  runtime_overlay_antigravity_merge_hooks_file "$workspace/.agents/hooks.json" "$ANTIGRAVITY_TEMPLATE" 1
  run jq -r '.hooks.Stop[0].timeout,.hooks.Stop[0].command,.keep' "$workspace/.agents/hooks.json"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "5400" ]
  [[ "${lines[1]}" == *"stop-continuation.sh"* ]]
  [ "${lines[2]}" = "user" ]
}

@test "antigravity merge omits Stop hook when RALPH_BG_JOBS is disabled" {
  source "$ANTIGRAVITY_OVERLAY"
  export RALPH_BG_JOBS=0
  printf '%s\n' '{"version":1,"hooks":{}}' >"$workspace/.agents/hooks.json"
  runtime_overlay_antigravity_merge_hooks_file "$workspace/.agents/hooks.json" "$ANTIGRAVITY_TEMPLATE" 0
  run jq -r '.hooks.Stop // empty' "$workspace/.agents/hooks.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "antigravity durable hook detection requires stop-continuation hook" {
  source "$ANTIGRAVITY_OVERLAY"
  cp "$ANTIGRAVITY_TEMPLATE" "$workspace/.agents/hooks.json"
  runtime_overlay_antigravity_hooks_detected_in_file "$workspace/.agents/hooks.json"
  python3 - <<'PY' "$workspace/.agents/hooks.json"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
stop = data.get("hooks", {}).get("Stop") or []
data["hooks"]["Stop"] = [entry for entry in stop if "stop-continuation" not in entry.get("command", "")]
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  run runtime_overlay_antigravity_hooks_detected_in_file "$workspace/.agents/hooks.json"
  [ "$status" -ne 0 ]
}

@test "continue adapter serializes neutral continue payload to decision continue" {
  # shellcheck disable=SC1090
  source "$CONTINUE_ADAPTER"
  local neutral continue_out decision reason
  neutral='{"version":1,"decision":"continue","releaseReason":null,"continuation":{"jobId":"job-continue","commandSummary":"echo overlay-stop","status":"passed","exitCode":0,"elapsedSeconds":1,"preview":"overlay-preview","resultId":null,"resultPath":null}}'
  continue_out="$(ralph_bg_stop_continue_adapter_emit_continue "$neutral")"
  decision="$(jq -r '.decision' <<<"$continue_out")"
  reason="$(jq -r '.reason' <<<"$continue_out")"
  [ "$decision" = "continue" ]
  [[ -n "$reason" ]]
  [[ "$reason" == *"overlay-preview"* ]]
  [[ "$reason" == *"job-continue"* ]]
}

@test "continue adapter releases silently when RALPH_BG_MAX_PER_TODO guard is reached" {
  fake_core="$workspace/fake-stop-guard-continue-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"release","releaseReason":"continuation-cap","continuation":null}'
}
EOF
  output="$(
    RALPH_BG_STOP_CORE_SCRIPT="$fake_core" bash -c 'source "$1"; ralph_bg_stop_continue_adapter_main' _ "$CONTINUE_ADAPTER" <<<"{}"
  )"
  [ -z "$output" ]
}

@test "continue adapter releases silently when no outstanding job exists" {
  fake_core="$workspace/fake-stop-empty-continue-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"release","releaseReason":"no-outstanding-job","continuation":null}'
}
EOF
  output="$(
    RALPH_BG_STOP_CORE_SCRIPT="$fake_core" bash -c 'source "$1"; ralph_bg_stop_continue_adapter_main' _ "$CONTINUE_ADAPTER" <<<"{}"
  )"
  [ -z "$output" ]
}

@test "antigravity stop hook script resolves core and emits continue decision" {
  fake_core="$workspace/fake-stop-core.sh"
  cat >"$fake_core" <<'EOF'
ralph_bg_stop_hook_main() {
  printf '%s\n' '{"version":1,"decision":"continue","continuation":{"jobId":"job-antigravity-script","commandSummary":"echo overlay-stop","status":"passed","exitCode":0,"elapsedSeconds":1,"preview":"overlay-preview","resultId":null,"resultPath":null}}'
}
EOF
  export WORKSPACE="$workspace"
  export RALPH_BG_STOP_CORE_SCRIPT="$fake_core"
  output="$(bash "$workspace/.agents/hooks/stop-continuation.sh" <<<"{}")"
  decision="$(jq -r '.decision' <<<"$output")"
  reason="$(jq -r '.reason' <<<"$output")"
  [ "$decision" = "continue" ]
  [[ -n "$reason" ]]
  [[ "$reason" == *"job-antigravity-script"* ]]
}

@test "antigravity overlay restore preserves user custom hook after Stop merge" {
  source "$RUNTIME_OVERLAY_LIB"
  source "$ANTIGRAVITY_OVERLAY"
  export RALPH_BG_JOBS=1
  export RALPH_NATIVE_HOOKS=on
  printf '%s\n' '{"version":1,"keep":"native","hooks":{"preToolUse":[{"command":"./keep-me.sh","matcher":"Shell"}]}}' \
    >"$workspace/.agents/hooks.json"
  runtime_overlay_init_state "antigravity" "$RALPH_PLAN_KEY"
  runtime_overlay_record_original_file "$workspace/.agents/hooks.json"
  runtime_overlay_antigravity_merge_hooks_file "$workspace/.agents/hooks.json" "$ANTIGRAVITY_TEMPLATE" 1
  jq -e '.hooks.preToolUse[] | select(.command == "./keep-me.sh")' "$workspace/.agents/hooks.json" >/dev/null
  runtime_overlay_run_cleanup
  run jq -r '.keep,.hooks.preToolUse[0].command' "$workspace/.agents/hooks.json"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "native" ]
  [ "${lines[1]}" = "./keep-me.sh" ]
}

@test "tier probe selects hook for claude when isolation is available" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=auto
  export RUNTIME=claude
  output="$(overlay_stop_hook_run_tier_probe claude)"
  run jq -r '.tier,.reason,.isolationAvailable,.hookSupportPresent' <<<"$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "hook" ]
  [[ "${lines[1]}" == *"claude-stop-hook"* ]]
  [ "${lines[2]}" = "true" ]
  [ "${lines[3]}" = "true" ]
}

@test "opencode tier probe falls back to invocation when session.idle continuation is unproven" {
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=auto
  export RUNTIME=opencode
  unset RALPH_BG_OPENCODE_SESSION_IDLE_PROVEN
  output="$(overlay_stop_hook_run_tier_probe opencode)"
  run jq -r '.tier,.reason,.hookSupportPresent' <<<"$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "invocation" ]
  [[ "${lines[1]}" == *"opencode-session-idle"* ]]
  [ "${lines[2]}" = "false" ]
}

@test "tier probe records invocation fallback when isolation primitive is unavailable" {
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=auto
  export RUNTIME=cursor
  output="$(
    bash -c '
      source "$1"
      ralph_bg_tier_probe_isolation_mode() { return 1; }
      ralph_bg_tier_probe_evaluate cursor
    ' _ "$TIER_PROBE_LIB"
  )"
  run jq -r '.tier,.reason,.isolationAvailable,.isolationMode' <<<"$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "invocation" ]
  [[ "${lines[1]}" == *"fallback-no-isolation"* ]]
  [ "${lines[2]}" = "false" ]
  [ "${lines[3]}" = "none" ]
}

@test "RALPH_BG_TIER invocation override forces invocation tier" {
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=invocation
  export RUNTIME=claude
  output="$(overlay_stop_hook_run_tier_probe claude)"
  run jq -r '.tier,.reason,.override' <<<"$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "invocation" ]
  [ "${lines[1]}" = "forced-by-RALPH_BG_TIER" ]
  [ "${lines[2]}" = "invocation" ]
}

@test "RALPH_BG_TIER hook fails loudly for opencode when session.idle is unproven" {
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=hook
  export RUNTIME=opencode
  unset RALPH_BG_OPENCODE_SESSION_IDLE_PROVEN
  overlay_stop_hook_source_tier_probe
  run ralph_bg_tier_probe_apply opencode
  [ "$status" -ne 0 ]
  [[ "$output" == *"RALPH_BG_TIER=hook requires tier-1"* ]]
}

@test "RALPH_BG_TIER hook succeeds for claude when probe requirements are met" {
  command -v setsid >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || skip "no isolation primitive"
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=hook
  export RUNTIME=claude
  overlay_stop_hook_source_tier_probe
  run ralph_bg_tier_probe_apply claude
  [ "$status" -eq 0 ]
  run jq -r '.tier,.override' <<<"$output"
  [ "${lines[0]}" = "hook" ]
  [ "${lines[1]}" = "hook" ]
}

@test "tier probe telemetry is written into overlay summary" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=auto
  export RUNTIME=opencode
  source "$RUNTIME_OVERLAY_LIB"
  # shellcheck disable=SC1090
  source "$TIER_PROBE_LIB"
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  ralph_bg_tier_probe_apply opencode >/dev/null
  runtime_overlay_write_summary
  summary_file="$(runtime_overlay_summary_path)"
  [ -f "$summary_file" ]
  run jq -r '.bg_tier,.bg_tier_reason' "$summary_file"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "invocation" ]
  [[ "${lines[1]}" == *"opencode-session-idle"* ]]
}

@test "opencode overlay prepare records invocation tier without stop hook adapter" {
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  export RALPH_BG_JOBS=1
  export RALPH_BG_TIER=auto
  export RUNTIME=opencode
  export RALPH_MODE=hybrid
  export RALPH_NATIVE_HOOKS=on
  source "$RUNTIME_OVERLAY_LIB"
  # shellcheck disable=SC1090
  source "$OPENCODE_OVERLAY"
  runtime_overlay_init_state "$RUNTIME" "$RALPH_PLAN_KEY"
  run_plan_invoke_opencode_native_hooks_prepare
  [ "${RALPH_BG_TIER_SELECTED:-}" = "invocation" ]
  [[ "${RALPH_BG_TIER_REASON:-}" == *"opencode-session-idle"* ]]
  run_plan_invoke_opencode_native_hooks_cleanup
}
