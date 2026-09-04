#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/../../helper/load-lib.bash"

KILLSWITCH_CORE="$REPO_ROOT/bundle/.ralph/bash-lib/killswitch/killswitch-core.sh"
CLAUDE_HOOK="$REPO_ROOT/bundle/.claude/hooks/rewrite-bash-command.sh"
CODEX_HOOK="$REPO_ROOT/bundle/.codex/hooks/pre-tool-bash-policy.sh"
CURSOR_SHELL_HOOK="$REPO_ROOT/bundle/.cursor/hooks/pre-tool-shell-policy.sh"
CURSOR_NUDGE_HOOK="$REPO_ROOT/bundle/.cursor/hooks/pre-tool-exploration-policy.sh"

setup() {
  WS="$(mktemp -d)"
  RECORD="$WS/hook-record.jsonl"
  mkdir -p "$WS/.ralph-workspace"
  cat >"$WS/.ralph-workspace/killswitch.json" <<'EOF'
{
  "schema_version": 2,
  "enabled": true,
  "dry_run": true,
  "banned_tools": [],
  "tool_denylist": ["Bash", "Shell", "command_execution"],
  "allowed_tools": [],
  "banned_paths": [],
  "allowed_paths": [],
  "allowed_commands": [],
  "allowed_patterns": [],
  "denied_argument_patterns": [],
  "custom_rules": []
}
EOF
}

teardown() {
  rm -rf "$WS"
}

hook_env() {
  local mode="${1:-native}"
  printf '%s' \
    "WORKSPACE=$WS " \
    "CLAUDE_PROJECT_DIR=$WS " \
    "RALPH_HOME=$REPO_ROOT " \
    "RALPH_PROJECT_ROOT=$WS " \
    "RALPH_AGENT_WORKSPACE=$WS " \
    "RALPH_PLAN_WORKSPACE_ROOT=$WS/.ralph-workspace " \
    "RALPH_PLAN_KEY=ks-hooks-primary " \
    "RALPH_MODE=$mode " \
    "KILLSWITCH_RUNNER_PID= " \
    "RALPH_KILLSWITCH_HOOK_RECORD=$RECORD " \
    "RALPH_BASH_REWRITE=0 " \
    "RALPH_NATIVE_SHELL_WRAPPER=0 "
}

pretool_json() {
  local event="${1:-}"
  local tool="${2:-}"
  local command="${3:-}"
  jq -nc \
    --arg event "$event" \
    --arg tool "$tool" \
    --arg command "$command" \
    --arg cwd "$WS" \
    '{
      hook_event_name: $event,
      tool_name: $tool,
      cwd: $cwd,
      workspace_roots: [$cwd],
      tool_input: {command: $command}
    }'
}

read_nudge_json() {
  local event="${1:-}"
  local tool="${2:-}"
  jq -nc \
    --arg event "$event" \
    --arg tool "$tool" \
    --arg cwd "$WS" \
    '{
      hook_event_name: $event,
      tool_name: $tool,
      cwd: $cwd,
      workspace_roots: [$cwd],
      tool_input: {path: "README.md"}
    }'
}

core_decision() {
  local runtime="${1:-}"
  local tool="${2:-}"
  local arguments="${3:-}"
  (
    export WORKSPACE="$WS"
    export RALPH_HOME="$REPO_ROOT"
    export RALPH_PROJECT_ROOT="$WS"
    export RALPH_AGENT_WORKSPACE="$WS"
    export RALPH_PLAN_WORKSPACE_ROOT="$WS/.ralph-workspace"
    export RALPH_PLAN_KEY="ks-hooks-primary"
    export KILLSWITCH_RUNNER_PID=""
    source "$KILLSWITCH_CORE"
    local event_json
    event_json="$(jq -nc \
      --argjson schemaVersion 1 \
      --arg source "native-hook" \
      --arg runtime "$runtime" \
      --arg tool "$tool" \
      --arg action "execute" \
      --arg effect "write" \
      --arg resource "" \
      --arg arguments "$arguments" \
      '{schemaVersion:$schemaVersion,source:$source,runtime:$runtime,tool:$tool,action:$action,effect:$effect,resource:$resource,arguments:$arguments}')"
    killswitch_evaluate "$event_json"
  )
}

sentinel_path() {
  printf '%s/.ralph-workspace/security/kill-switch.ks-hooks-primary.json' "$WS"
}

@test "claude fatal denylist matches core evaluator and writes sentinel" {
  local payload expected
  payload="$(pretool_json PreToolUse Bash "echo hi")"
  expected="$(core_decision claude Bash "echo hi")"
  [ "$expected" = "fatal" ]

  run bash -c "$(hook_env native) bash '$CLAUDE_HOOK'" <<<"$payload"
  [ "$status" -eq 77 ]
  [ -f "$(sentinel_path)" ]
  jq -e '.tool == "Bash" and .reason == "tool denylist"' "$(sentinel_path)"
  jq -e '.runtime == "claude" and .decision == "fatal" and .applied == true' "$RECORD"
}

@test "codex fatal denylist matches core evaluator and writes sentinel" {
  local payload expected
  payload="$(pretool_json PreToolUse Bash "echo hi")"
  expected="$(core_decision codex Bash "echo hi")"
  [ "$expected" = "fatal" ]

  run bash -c "$(hook_env native) bash '$CODEX_HOOK'" <<<"$payload"
  [ "$status" -eq 77 ]
  [ -f "$(sentinel_path)" ]
  jq -e '.tool == "Bash" and .reason == "tool denylist"' "$(sentinel_path)"
  jq -e '.runtime == "codex" and .decision == "fatal" and .applied == true' "$RECORD"
}

@test "cursor fatal denylist matches core evaluator and writes sentinel" {
  local payload expected
  payload="$(pretool_json preToolUse Shell "echo hi")"
  expected="$(core_decision cursor Shell "echo hi")"
  [ "$expected" = "fatal" ]

  run bash -c "$(hook_env native) bash '$CURSOR_SHELL_HOOK'" <<<"$payload"
  [ "$status" -eq 77 ]
  [ -f "$(sentinel_path)" ]
  jq -e '.tool == "Shell" and .reason == "tool denylist"' "$(sentinel_path)"
  jq -e '.runtime == "cursor" and .decision == "fatal" and .applied == true' "$RECORD"
}

@test "ralph-mode-off does not write a sentinel for claude, codex, or cursor" {
  local claude_payload codex_payload cursor_payload
  claude_payload="$(pretool_json PreToolUse Bash "echo hi")"
  codex_payload="$(pretool_json PreToolUse Bash "echo hi")"
  cursor_payload="$(pretool_json preToolUse Shell "echo hi")"

  run bash -c "$(hook_env no) bash '$CLAUDE_HOOK'" <<<"$claude_payload"
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]

  run bash -c "$(hook_env no) bash '$CODEX_HOOK'" <<<"$codex_payload"
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]

  run bash -c "$(hook_env no) bash '$CURSOR_SHELL_HOOK'" <<<"$cursor_payload"
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]
}

@test "nudge does not write a sentinel for claude, codex, or cursor" {
  local claude_nudge codex_nudge cursor_nudge
  claude_nudge="$(read_nudge_json PreToolUse Grep)"
  codex_nudge="$(read_nudge_json PreToolUse grep)"
  cursor_nudge="$(read_nudge_json preToolUse Grep)"

  run bash -c "$(hook_env native) bash '$CLAUDE_HOOK'" <<<"$claude_nudge"
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]
  jq -e '.runtime == "claude" and .decision == "nudge" and .applied == false' "$RECORD"

  : >"$RECORD"
  run bash -c "$(hook_env native) bash '$CODEX_HOOK'" <<<"$codex_nudge"
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]
  jq -e '.runtime == "codex" and .decision == "nudge" and .applied == false' "$RECORD"

  : >"$RECORD"
  run bash -c "$(hook_env ralph) RALPH_NATIVE_EXPLORATION_NUDGE=1 bash '$CURSOR_NUDGE_HOOK'" <<<"$cursor_nudge"
  [ "$status" -eq 0 ]
  [ ! -f "$(sentinel_path)" ]
  jq -e '.permission == "deny"' <<<"$output"
  jq -e '.runtime == "cursor" and .decision == "nudge" and .applied == false' "$RECORD"
}
